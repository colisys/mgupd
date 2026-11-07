import Foundation
import XCTest
@testable import UpdateCore

final class ModelsTests: XCTestCase {
    private func release(_ id: Int64, _ time: TimeInterval? = nil, prerelease: Bool = false) -> Release {
        Release(id: id, tagName: "v\(id)", htmlURL: URL(string: "https://github.com/a/b/releases/\(id)")!,
                publishedAt: time.map { Date(timeIntervalSince1970: $0) }, prerelease: prerelease)
    }

    func testBaselineSortingFilteringAndDedupe() {
        var repository = Repository(slug: "a/b")
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(repository.apply([release(1, 10), release(2, 20), release(3, 30, prerelease: true)], at: now).isEmpty)
        XCTAssertTrue(repository.initialized)
        XCTAssertFalse(repository.unread)
        XCTAssertEqual(repository.latest?.id, 2)
        XCTAssertEqual(repository.seenReleaseIDs, [2, 1])
        repository.error = "old failure"
        let new = repository.apply([release(4, 40), release(4, 40), release(2, 20), release(5)], at: now)
        XCTAssertEqual(new.map(\.id), [4, 5])
        XCTAssertTrue(repository.unread)
        XCTAssertNil(repository.error)
        XCTAssertEqual(repository.lastChecked, now)
        XCTAssertEqual(repository.seenReleaseIDs, [2, 1, 4, 5])
        repository.unread = false
        XCTAssertTrue(repository.apply([release(1, 10)], at: now).isEmpty)
        XCTAssertFalse(repository.unread)
    }

    func testEmptyBaselineAndPrereleaseSetting() {
        var repository = Repository(slug: "a/b")
        XCTAssertTrue(repository.apply([], at: Date()).isEmpty)
        XCTAssertTrue(repository.initialized)
        XCTAssertNil(repository.latest)
        XCTAssertEqual(repository.apply([release(1)], at: Date()).map(\.id), [1])
        XCTAssertTrue(repository.apply([release(2, prerelease: true)], at: Date()).isEmpty)
        repository.includePrereleases = true
        XCTAssertEqual(repository.apply([release(2, prerelease: true)], at: Date()).map(\.id), [2])
        XCTAssertTrue(repository.apply([], at: Date()).isEmpty)
        XCTAssertTrue(repository.unread)
    }

    func testIDsAreNotTrimmed() {
        var repository = Repository(slug: "a/b", includePrereleases: true)
        let releases = (1...2000).map { release(Int64($0)) }
        repository.apply(releases, at: Date())
        repository.apply([], at: Date())
        XCTAssertEqual(repository.seenReleaseIDs.count, 2000)
        XCTAssertTrue(repository.apply(releases, at: Date()).isEmpty)
    }

    func testReleaseSnakeKeys() throws {
        let data = Data(#"{"id":9,"tag_name":"v9","name":null,"html_url":"https://github.com/a/b/releases/9","published_at":"2026-01-01T00:00:00Z","prerelease":false,"body":"notes"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(Release.self, from: data)
        XCTAssertEqual(release.tagName, "v9")
        XCTAssertNotNil(release.publishedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Release.self, from: encoder.encode(release)), release)
    }
}

final class RepositoryInputTests: XCTestCase {
    func testAcceptedInputs() throws {
        for input in ["Owner/repo", " https://github.com/Owner/repo\n", "https://GITHUB.COM/Owner/repo"] {
            XCTAssertEqual(try RepositoryInput.normalize(input), "Owner/repo")
        }
        XCTAssertEqual(try RepositoryInput.normalize("a/repo.name_-"), "a/repo.name_-")
    }

    func testRejectedInputs() {
        for input in ["", "owner", "a/b/c", "/a/b", "a/b/", "a/..", "a/.", "a/%2e%2e", "a/b%2fc", "a/b?x=y", "a/b#x", "a\\b/c", "a/b c", "-a/b", "a--b/c", "a_/b", "用户/repo", "http://github.com/a/b", "https://evil.com/a/b", "https://github.com.evil.com/a/b", "https://user@github.com/a/b", "https://github.com:443/a/b", "https://github.com/a/b?x=1", "https://github.com/a/b#readme", "https://github.com/a/%2F", "https://github.com/a/b/../c", "https://github.com/a/b/"] {
            XCTAssertThrowsError(try RepositoryInput.normalize(input), input)
        }
    }
}

final class StateStoreTests: XCTestCase {
    func testMissingRoundTripOverwriteAndCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/state.json")
        let store = StateStore(url: url)
        let defaults = try store.load()
        XCTAssertTrue(defaults.repositories.isEmpty)
        XCTAssertEqual(defaults.settings.intervalMinutes, 30)
        XCTAssertFalse(defaults.settings.notificationsEnabled)
        var state = StoredState()
        var repository = Repository(slug: "a/b", includePrereleases: true)
        let release = Release(id: 1, tagName: "v1", htmlURL: URL(string: "https://github.com/a/b")!)
        repository.apply([release], at: Date(timeIntervalSince1970: 100))
        repository.enabled = false
        repository.unread = true
        repository.error = "test"
        state.repositories = [repository]
        state.settings.intervalMinutes = 60
        state.settings.notificationsEnabled = true
        try store.save(state)
        let loaded = try store.load()
        XCTAssertEqual(loaded.repositories.first?.id, repository.id)
        XCTAssertEqual(loaded.repositories.first?.seenReleaseIDs, [1])
        XCTAssertEqual(loaded.repositories.first?.latest, release)
        XCTAssertEqual(loaded.repositories.first?.lastChecked, repository.lastChecked)
        XCTAssertEqual(loaded.repositories.first?.error, "test")
        XCTAssertEqual(loaded.repositories.first?.enabled, false)
        XCTAssertEqual(loaded.repositories.first?.includePrereleases, true)
        XCTAssertEqual(loaded.repositories.first?.initialized, true)
        XCTAssertEqual(loaded.repositories.first?.unread, true)
        XCTAssertEqual(loaded.settings.intervalMinutes, 60)
        XCTAssertTrue(loaded.settings.notificationsEnabled)
        try store.save(StoredState())
        XCTAssertTrue(try store.load().repositories.isEmpty)
        try Data("bad json".utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
        try Data("{}".utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
    }
}
