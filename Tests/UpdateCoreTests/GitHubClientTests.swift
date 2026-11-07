import Foundation
import XCTest
@testable import UpdateCore

private final class MockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, [String: String], Data)
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func register(_ handler: @escaping Handler, id: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers[id] = handler
    }

    static func unregister(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: id)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = request.value(forHTTPHeaderField: "X-Test-ID").flatMap { Self.handlers[$0] }
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.badServerResponse) }
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class GitHubClientTests: XCTestCase {
    private func withClient(_ handler: @escaping MockURLProtocol.Handler,
                            operation: (GitHubClient) async throws -> Void) async throws {
        let id = UUID().uuidString
        MockURLProtocol.register(handler, id: id)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Test-ID": id]
        let session = URLSession(configuration: config)
        defer {
            session.invalidateAndCancel()
            MockURLProtocol.unregister(id)
        }
        try await operation(GitHubClient(session: session))
    }

    private static func payload(_ ids: [Int], draft: Bool = false, prerelease: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ids.map {
            ["id": $0, "tag_name": "v\($0)", "html_url": "https://github.com/a/b/releases/\($0)",
             "published_at": "2026-01-01T00:00:00.123Z", "prerelease": prerelease, "draft": draft] as [String: Any]
        })
    }

    func testPaginationHeadersAndDeduplication() async throws {
        try await withClient({ request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.url?.path, "/repos/a/b/releases")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
            XCTAssertEqual(request.timeoutInterval, 30)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "per_page" }?.value, "100")
            let page = query.first { $0.name == "page" }?.value
            if page == "1" {
                return (200, ["Link": "<https://evil.example/steal>; rel=\"next\""], try Self.payload([1, 2]))
            }
            XCTAssertEqual(page, "2")
            return (200, [:], try Self.payload([2, 3]))
        }) { client in
            let releases = try await client.releases(for: "a/b", token: "secret")
            XCTAssertEqual(releases.map(\.id), [1, 2, 3])
            XCTAssertNotNil(releases.first?.publishedAt)
        }
    }

    func testDraftExcludedAndPrereleaseRetained() async throws {
        try await withClient({ request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let drafts = try JSONSerialization.jsonObject(with: Self.payload([1], draft: true)) as! [[String: Any]]
            let prereleases = try JSONSerialization.jsonObject(with: Self.payload([2], prerelease: true)) as! [[String: Any]]
            return (200, [:], try JSONSerialization.data(withJSONObject: drafts + prereleases))
        }) { client in
            let releases = try await client.releases(for: "a/b", token: "  ")
            XCTAssertEqual(releases.map(\.id), [2])
            XCTAssertTrue(releases[0].prerelease)
        }
    }

    func testFriendlyHTTPFailuresAndReset() async throws {
        for status in [401, 403, 404, 429, 500, 302] {
            try await withClient({ _ in
                (status, ["X-RateLimit-Reset": "1800000000", "Location": "https://evil.example"], Data("secret server body".utf8))
            }) { client in
                do {
                    _ = try await client.releases(for: "a/b", token: "secret")
                    XCTFail("Expected HTTP error")
                } catch let error as GitHubClientError {
                    guard case let .httpStatus(actual, reset) = error else { return XCTFail("Wrong error") }
                    XCTAssertEqual(actual, status)
                    XCTAssertEqual(reset, Date(timeIntervalSince1970: 1800000000))
                    XCTAssertTrue(error.localizedDescription.contains("重置时间"))
                    XCTAssertFalse(error.localizedDescription.contains("secret"))
                }
            }
        }
    }

    func testPaginationLimitReturnsRecentWindowAndEstablishesSilentBaseline() async throws {
        for hasLink in [true, false] {
            var requestedPages: [Int] = []
            try await withClient({ request in
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let page = Int(query.first { $0.name == "page" }!.value!)!
                requestedPages.append(page)
                XCTAssertLessThanOrEqual(page, 10)
                let headers = hasLink ? ["Link": "<https://api.github.com/next>; rel=\"next\""] : [:]
                let newestID = 1100 - (page - 1) * 100
                return (200, headers, try Self.payload(Array(((newestID - 99)...newestID).reversed())))
            }) { client in
                let releases = try await client.releases(for: "a/b", token: nil)
                XCTAssertEqual(requestedPages, Array(1...10))
                XCTAssertEqual(releases.count, 1000)
                XCTAssertEqual(releases.first?.id, 1100)
                XCTAssertEqual(releases.last?.id, 101)

                var repository = Repository(slug: "a/b")
                XCTAssertTrue(repository.apply(releases, at: Date()).isEmpty)
                XCTAssertTrue(repository.initialized)
                XCTAssertFalse(repository.unread)
                XCTAssertNil(repository.error)
                XCTAssertEqual(repository.latest?.id, 1100)
                XCTAssertTrue(repository.apply(releases, at: Date()).isEmpty)

                let next = Release(id: 1101, tagName: "v1101",
                                   htmlURL: URL(string: "https://github.com/a/b/releases/1101")!,
                                   publishedAt: Date(), prerelease: false)
                XCTAssertEqual(repository.apply([next] + releases, at: Date()).map(\.id), [1101])
                XCTAssertTrue(repository.unread)
                XCTAssertEqual(repository.latest?.id, 1101)
            }
        }
    }

    func testFullPageWithoutLinkRequestsAnotherPage() async throws {
        try await withClient({ request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let page = query.first { $0.name == "page" }?.value
            if page == "1" { return (200, [:], try Self.payload(Array(1...100))) }
            XCTAssertEqual(page, "2")
            return (200, [:], Data("[]".utf8))
        }) { client in
            let releases = try await client.releases(for: "a/b", token: nil)
            XCTAssertEqual(releases.count, 100)
        }
    }

    func testMalformedResponseAndTransportErrorsPropagate() async throws {
        try await withClient({ _ in (200, [:], Data("not json".utf8)) }) { client in
            do {
                _ = try await client.releases(for: "a/b", token: nil)
                XCTFail("Expected decoding error")
            } catch { XCTAssertTrue(error is DecodingError) }
        }
        try await withClient({ _ in throw URLError(.timedOut) }) { client in
            do {
                _ = try await client.releases(for: "a/b", token: nil)
                XCTFail("Expected transport error")
            } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        }
    }

    func testInvalidSlugNeverMakesRequest() async throws {
        try await withClient({ _ in
            XCTFail("Invalid slug must not reach network")
            return (200, [:], Data("[]".utf8))
        }) { client in
            do {
                _ = try await client.releases(for: "a/../../private", token: "secret")
                XCTFail("Expected input error")
            } catch { XCTAssertTrue(error is RepositoryInputError) }
        }
    }
}
