import XCTest
@testable import UpdateCore

private final class DownloadProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var started: XCTestExpectation?
    private static var stopped: XCTestExpectation?
    private static var status: Int?
    private static var body: Data?
    private static var finishResponse = true
    static func configure(started: XCTestExpectation, stopped: XCTestExpectation?, status: Int?, body: Data?, finishResponse: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        self.started = started; self.stopped = stopped; self.status = status; self.body = body
        self.finishResponse = finishResponse
    }
    private var onStop: XCTestExpectation?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let started = Self.started, status = Self.status, body = Self.body, finishResponse = Self.finishResponse
        onStop = Self.stopped
        Self.lock.unlock()
        started?.fulfill()
        if let status {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream"])!, cacheStoragePolicy: .notAllowed)
            if let body { client?.urlProtocol(self, didLoad: body) }
            if finishResponse { client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() { onStop?.fulfill(); onStop = nil }
}

final class DownloadsTests: XCTestCase {
    func testPatternsArchitectureAndAmbiguity() throws {
        var arm = asset; arm.name = "App-macos-arm64.dmg"
        var intel = arm; intel.id = 12; intel.name = "App-macos-x86_64.dmg"
        XCTAssertEqual(try DownloadSelection.select([arm], patterns: "", architecture: .arm64), [arm])
        XCTAssertThrowsError(try DownloadSelection.select([arm], patterns: "", architecture: .x86_64))
        XCTAssertThrowsError(try DownloadSelection.select([arm], patterns: "", architecture: .unknown))
        XCTAssertThrowsError(try DownloadSelection.select([arm, intel], patterns: "", architecture: .arm64))
        XCTAssertEqual(try DownloadSelection.select([arm, intel], patterns: "*arm64*\nApp-macos-?????.dmg\n*arm64*"), [arm])
        XCTAssertFalse(DownloadSelection.glob(arm.name, pattern: "macos"))
        var universal = arm; universal.name = "App-Darwin-universal.zip"
        XCTAssertEqual(try DownloadSelection.select([universal], patterns: "", architecture: .x86_64), [universal])
        var checksum = intel; checksum.name = "checksums.txt"
        XCTAssertEqual(try DownloadSelection.select([arm, checksum], patterns: "", architecture: .arm64), [arm])
        var unknown = arm; unknown.name = "app.dmg"
        XCTAssertThrowsError(try DownloadSelection.select([unknown], patterns: "", architecture: .arm64))
    }

    func testLegacyRuleMigration() throws {
        let old = Data(#"{"automatic":true,"rule":"mac*?"}"#.utf8)
        let config = try JSONDecoder().decode(DownloadConfiguration.self, from: old)
        XCTAssertTrue(DownloadSelection.glob("App-mac*?.dmg", pattern: config.rule))
        XCTAssertFalse(DownloadSelection.glob("App-macos.dmg", pattern: config.rule))
        XCTAssertEqual(try JSONDecoder().decode(DownloadConfiguration.self, from: JSONEncoder().encode(config)), config)
    }

    func testMirrorURLsAndCredentialStripping() throws {
        let upstream = URL(string: "https://github.com/a/b/releases/download/v1/App.dmg")!
        let mirror = try DownloadMirror.requestURL(upstream, slug: "a/b", prefix: "https://mirror.example/prefix")
        XCTAssertEqual(mirror.absoluteString, "https://mirror.example/prefix/" + upstream.absoluteString)
        for prefix in ["http://mirror.example", "https://user:pass@mirror.example", "https://mirror.example?q=1", "https://mirror.example/#x"] {
            XCTAssertThrowsError(try DownloadMirror.validate(prefix))
        }
        XCTAssertThrowsError(try DownloadMirror.requestURL(URL(string: "https://evil.example/a/b/releases/download/v1/a")!, slug: "a/b", prefix: "https://mirror.example"))
        XCTAssertThrowsError(try DownloadMirror.requestURL(upstream, slug: "other/repo", prefix: "https://mirror.example"))
        var request = URLRequest(url: mirror)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.setValue("secret", forHTTPHeaderField: "Cookie")
        XCTAssertNil(DownloadMirror.redirect(request, mirror: mirror)?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(DownloadMirror.redirect(request, mirror: mirror)?.value(forHTTPHeaderField: "Cookie"))
        request.url = URL(string: "https://release-assets.githubusercontent.com/asset")
        XCTAssertNotNil(DownloadMirror.redirect(request, mirror: mirror))
        request.url = URL(string: "https://other.example/asset")
        XCTAssertNil(DownloadMirror.redirect(request, mirror: mirror))
    }

    func testByteWeightedProgress() {
        let value = DownloadProgress(receivedBytes: 125, totalBytes: 500, completedAssets: 1, totalAssets: 3)
        XCTAssertEqual(value.fraction, 0.25)
        XCTAssertEqual(DownloadProgress(receivedBytes: 999, totalBytes: 500, totalAssets: 2).fraction, 1)
        XCTAssertEqual(DownloadProgress(totalBytes: 0, completedAssets: 1, totalAssets: 2).fraction, 0.5)
    }
    func testLegacyReleaseAndAssetRoundTrip() throws {
        let data = Data(#"{"id":1,"tag_name":"v1","html_url":"https://github.com/a/b/releases/1","prerelease":false}"#.utf8)
        var release = try JSONDecoder().decode(Release.self, from: data)
        XCTAssertEqual(release.assets, [])
        release.assets = [asset]
        XCTAssertEqual(try JSONDecoder().decode(Release.self, from: JSONEncoder().encode(release)), release)
    }

    func testSafetyAndRedirects() {
        XCTAssertFalse(DownloadSafety.matches("app.dmg", rule: "  "))
        XCTAssertTrue(DownloadSafety.matches("App-MACOS.dmg", rule: " macos "))
        for name in ["../evil", "/tmp/evil", "..", "a\\b", "a:b", "x\n", ""] {
            XCTAssertFalse(DownloadSafety.validFilename(name), name)
        }
        XCTAssertTrue(DownloadSafety.validFilename("App macOS.dmg"))
        for value in ["http://github.com/a", "https://github.com.evil.test/a", "https://evil.githubusercontent.com/a", "https://user@github.com/a"] {
            XCTAssertFalse(DownloadSafety.trusted(URL(string: value)!))
        }
        var request = URLRequest(url: URL(string: "https://release-assets.githubusercontent.com/a")!)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let clean = DownloadSafety.redirect(from: URL(string: "https://api.github.com/a"), request: request)
        XCTAssertNil(clean?.value(forHTTPHeaderField: "Authorization"))
        request.url = URL(string: "https://evil.test/a")
        XCTAssertNil(DownloadSafety.redirect(from: URL(string: "https://api.github.com/a"), request: request))
    }

    func testTransportCancellationStopsURLProtocol() async throws {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "underlying request stopped")
        DownloadProtocol.configure(started: started, stopped: stopped, status: nil, body: nil)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DownloadProtocol.self]
        let bridge = DownloadRedirectDelegate(mirror: nil, progress: { _, _ in })
        let task = Task { try await bridge.run(URLRequest(url: URL(string: "https://github.com/test")!), configuration: config) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("must cancel") } catch is CancellationError {} catch { XCTFail("\(error)") }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testTransportFirstByteTimeout() async throws {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "timeout stops request")
        DownloadProtocol.configure(started: started, stopped: stopped, status: nil, body: nil)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DownloadProtocol.self]
        let bridge = DownloadRedirectDelegate(mirror: nil, firstByteTimeout: 0.2, progress: { _, _ in })
        do {
            _ = try await bridge.run(URLRequest(url: URL(string: "https://github.com/secret?token=secret")!), configuration: config)
            XCTFail("must time out")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stage=first-byte"))
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
        await fulfillment(of: [started, stopped], timeout: 2)
    }

    func testTransportIdleAndHTTPFailWithoutCompletedBody() async throws {
        for status in [200, 403] {
            let started = expectation(description: "started")
            let stopped = expectation(description: "stalled request stopped")
            DownloadProtocol.configure(started: started, stopped: stopped, status: status,
                body: Data(repeating: 65, count: 65536), finishResponse: false)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [DownloadProtocol.self]
            let bridge = DownloadRedirectDelegate(mirror: nil, firstByteTimeout: 2, idleTimeout: 0.2, progress: { _, _ in })
            do {
                _ = try await bridge.run(URLRequest(url: URL(string: "https://github.com/test")!), configuration: config)
                XCTFail("must fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(status == 200 ? "stage=idle" : "HTTP 403"), error.localizedDescription)
            }
            await fulfillment(of: [started, stopped], timeout: 2)
        }
    }

    func testTransportTransfersAndRejectsHTTPAndJSON() async throws {
        for (status, body, succeeds) in [(200, "binary payload", true), (403, "denied", false), (200, "{\"message\":\"rate limit\"}", false)] {
            let started = expectation(description: "request started")
            DownloadProtocol.configure(started: started, stopped: nil, status: status, body: Data(body.utf8))
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [DownloadProtocol.self]
            let bridge = DownloadRedirectDelegate(mirror: nil, progress: { _, _ in })
            do {
                let file = try await bridge.run(URLRequest(url: URL(string: "https://github.com/test")!), configuration: config)
                defer { try? FileManager.default.removeItem(at: file) }
                XCTAssertTrue(succeeds)
                XCTAssertEqual(try Data(contentsOf: file), Data(body.utf8))
            } catch { XCTAssertFalse(succeeds, "\(error)") }
            await fulfillment(of: [started], timeout: 2)
        }
    }

    @MainActor func testManualSurvivesProcessAndRestartStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state.json")
        let manager = DownloadManager(stateURL: state) { _, _, _, _, _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw CancellationError()
        }
        var repo = Repository(slug: "a/b")
        repo.latest = release(2)
        manager.setRule("*macos*", for: repo.id)
        manager.downloadLatest(repository: repo, token: nil)
        XCTAssertEqual(manager.progress[repo.id]?.filename, asset.name)
        manager.process(repository: repo, discovered: [], token: nil)
        XCTAssertTrue(manager.active.contains(repo.id))
        let restored = DownloadManager(stateURL: state)
        XCTAssertTrue(restored.active.isEmpty)
        XCTAssertTrue(restored.status(for: repo.id).contains("中断"))
        manager.cancel(repo.id)
    }

    private var asset: ReleaseAsset {
        ReleaseAsset(id: 11, name: "app-macos.dmg", size: 10, browserDownloadURL: URL(string: "https://github.com/a/b/download/app.dmg")!)
    }
    private func release(_ id: Int64) -> Release {
        Release(id: id, tagName: "v\(id)", htmlURL: URL(string: "https://github.com/a/b/releases/\(id)")!, assets: [asset])
    }
    @MainActor private func settle(_ manager: DownloadManager) async {
        for _ in 0..<1000 {
            if manager.active.isEmpty { return }
            await Task.yield()
        }
        XCTFail("Download task did not finish")
    }

    @MainActor func testBaselineLatestOnlyAndPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state.json")
        var calls = 0
        let manager = DownloadManager(stateURL: state, root: directory) { _, _, _, _, _ in
            calls += 1
            throw DownloadFailure("offline")
        }
        var repo = Repository(slug: "a/b")
        XCTAssertFalse(manager.configuration(for: repo.id).automatic)
        manager.setAutomatic(true, for: repo.id)
        manager.setRule("*macos*", for: repo.id)
        let baseline = repo.apply([release(2)], at: Date())
        manager.process(repository: repo, discovered: baseline, token: nil)
        XCTAssertEqual(calls, 0)
        // A newly discovered older release must never be downloaded.
        let older = repo.apply([release(2), release(1)], at: Date())
        manager.process(repository: repo, discovered: older, token: nil)
        XCTAssertEqual(calls, 0)
        let discovered = repo.apply([release(3), release(2)], at: Date())
        manager.process(repository: repo, discovered: discovered, token: nil)
        await settle(manager)
        XCTAssertEqual(calls, 1)
        let restored = DownloadManager(stateURL: state, root: directory) { _, _, _, _, _ in
            calls += 1
            throw DownloadFailure("offline")
        }
        for _ in 0..<5 {
            restored.process(repository: repo, discovered: [], token: nil)
            await settle(restored)
        }
        XCTAssertEqual(calls, 3)
        XCTAssertTrue(restored.status(for: repo.id).contains("上限"))
        restored.downloadLatest(repository: repo, token: nil)
        await settle(restored)
        XCTAssertEqual(calls, 4)
        restored.setAutomatic(false, for: repo.id)
        restored.setAutomatic(true, for: repo.id)
        restored.process(repository: repo, discovered: [], token: nil)
        XCTAssertEqual(calls, 4)
    }

    @MainActor func testEmptyRuleAndCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let manager = DownloadManager(stateURL: directory.appendingPathComponent("state.json")) { _, _, _, _, _ in
            calls += 1
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw DownloadFailure("unexpected")
        }
        var repo = Repository(slug: "a/b")
        repo.latest = release(2)
        manager.setAutomatic(true, for: repo.id)
        manager.process(repository: repo, discovered: [release(2)], token: nil)
        XCTAssertTrue(manager.active.isEmpty)
        manager.setRule("*macos*", for: repo.id)
        manager.process(repository: repo, discovered: [release(2)], token: nil)
        await Task.yield()
        manager.setAutomatic(false, for: repo.id)
        XCTAssertTrue(manager.active.isEmpty)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertLessThanOrEqual(calls, 1)
        XCTAssertTrue(manager.status(for: repo.id).contains("已停止"))
    }
}
