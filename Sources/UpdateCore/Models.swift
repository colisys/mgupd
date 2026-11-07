import Foundation

public struct ReleaseAsset: Codable, Equatable, Identifiable {
    public var id: Int64
    public var name: String
    public var size: Int64
    public var browserDownloadURL: URL

    public init(id: Int64, name: String, size: Int64, browserDownloadURL: URL) {
        self.id = id; self.name = name; self.size = size; self.browserDownloadURL = browserDownloadURL
    }

    enum CodingKeys: String, CodingKey {
        case id, name, size
        case browserDownloadURL = "browser_download_url"
    }
}

public struct Release: Codable, Equatable, Identifiable {
    public var id: Int64
    public var tagName: String
    public var name: String?
    public var htmlURL: URL
    public var publishedAt: Date?
    public var prerelease: Bool
    public var body: String?
    public var assets: [ReleaseAsset]

    public init(id: Int64, tagName: String, name: String? = nil, htmlURL: URL,
                publishedAt: Date? = nil, prerelease: Bool = false, body: String? = nil, assets: [ReleaseAsset] = []) {
        self.id = id
        self.tagName = tagName
        self.name = name
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
        self.prerelease = prerelease
        self.body = body
        self.assets = assets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        tagName = try c.decode(String.self, forKey: .tagName)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        htmlURL = try c.decode(URL.self, forKey: .htmlURL)
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
        prerelease = try c.decode(Bool.self, forKey: .prerelease)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        assets = try c.decodeIfPresent([ReleaseAsset].self, forKey: .assets) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id, name, prerelease, body, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

public struct Repository: Codable, Identifiable {
    public var id: UUID
    public var slug: String
    public var enabled: Bool = true
    public var includePrereleases: Bool = false
    public var initialized: Bool = false
    public var seenReleaseIDs: [Int64] = []
    public var latest: Release? = nil
    public var unread: Bool = false
    public var lastChecked: Date? = nil
    public var error: String? = nil

    public init(slug: String, includePrereleases: Bool = false) {
        self.id = UUID()
        self.slug = slug
        self.includePrereleases = includePrereleases
    }

    /// Records a successful poll. The first poll establishes a silent baseline,
    /// including an empty response. IDs are retained indefinitely.
    @discardableResult
    public mutating func apply(_ releases: [Release], at date: Date) -> [Release] {
        let sorted = releases.filter { includePrereleases || !$0.prerelease }.sorted {
            if $0.publishedAt != $1.publishedAt {
                return ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
            }
            return $0.id > $1.id
        }
        var seen = Set(seenReleaseIDs)
        var discovered: [Release] = []
        for release in sorted where seen.insert(release.id).inserted {
            seenReleaseIDs.append(release.id)
            if initialized { discovered.append(release) }
        }
        latest = sorted.first
        initialized = true
        lastChecked = date
        error = nil
        if !discovered.isEmpty { unread = true }
        return discovered
    }
}

public struct AppSettings: Codable {
    public var intervalMinutes: Int = 30
    public var notificationsEnabled: Bool = false
    public init() {}
}

public struct StoredState: Codable {
    public var repositories: [Repository] = []
    public var settings: AppSettings = AppSettings()
    public init() {}
}
