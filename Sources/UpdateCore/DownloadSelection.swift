import Foundation
import Darwin

public enum MachineArchitecture: String {
    case arm64, x86_64, unknown
    public static var current: Self {
        var arm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0, arm == 1 { return .arm64 }
        var translated: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0, translated == 1 { return .arm64 }
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return .unknown
        #endif
    }
}

public enum DownloadSelection {
    public static func glob(_ name: String, pattern: String) -> Bool {
        var expression = "^"
        var escaped = false
        for character in pattern {
            if escaped { expression += NSRegularExpression.escapedPattern(for: String(character)); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "*" { expression += ".*" }
            else if character == "?" { expression += "." }
            else { expression += NSRegularExpression.escapedPattern(for: String(character)) }
        }
        if escaped { expression += "\\\\" }
        expression += "$"
        return name.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
    }
    public static func migrateSubstring(_ rule: String) -> String {
        let value = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        return "*" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "?", with: "\\?") + "*"
    }
    public static func select(_ assets: [ReleaseAsset], patterns: String,
                              architecture: MachineArchitecture = .current) throws -> [ReleaseAsset] {
        let rules = patterns.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var seen = Set<Int64>()
        let unique = assets.filter { seen.insert($0.id).inserted }
        if !rules.isEmpty {
            let matches = unique.filter { asset in rules.contains { glob(asset.name, pattern: $0) } }
            guard !matches.isEmpty else { throw DownloadFailure("没有附件匹配文件名 pattern。") }
            return matches
        }
        let products = unique.filter { asset in
            let name = asset.name.lowercased()
            return ![".asc", ".sig", ".sha256", ".sha512", ".sha256sum", ".sha512sum"].contains(where: name.hasSuffix)
                && !name.contains("checksums") && !name.hasPrefix("sha256sums") && !name.hasPrefix("sha512sums")
        }
        guard products.count == 1, let asset = products.first, architecture != .unknown else {
            throw DownloadFailure("多个产物或本机架构未知：必须显式配置文件名 pattern（每行一个）。")
        }
        let name = asset.name.lowercased()
        func token(_ expression: String) -> Bool {
            name.range(of: "(^|[^a-z0-9])(?:" + expression + ")([^a-z0-9]|$)", options: .regularExpression) != nil
        }
        let mac = token("macos|darwin|osx|mac")
        let universal = token("universal|universal2")
        let arm = token("arm64|aarch64")
        let intel = token("x86_64|amd64|x64")
        guard mac, !token("windows|linux|android|ios"), universal || (architecture == .arm64 ? arm && !intel : intel && !arm) else {
            throw DownloadFailure("无法明确确认唯一产物适用于 macOS / \(architecture.rawValue)：必须配置文件名 pattern。")
        }
        return [asset]
    }
}

public struct DownloadProgress: Equatable {
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var completedAssets: Int
    public var totalAssets: Int
    public var filename: String
    public var fraction: Double {
        if totalBytes > 0 { return min(1, max(0, Double(receivedBytes) / Double(totalBytes))) }
        return totalAssets > 0 ? Double(completedAssets) / Double(totalAssets) : 0
    }
    public init(receivedBytes: Int64 = 0, totalBytes: Int64, completedAssets: Int = 0, totalAssets: Int, filename: String = "") {
        self.receivedBytes = receivedBytes; self.totalBytes = totalBytes
        self.completedAssets = completedAssets; self.totalAssets = totalAssets; self.filename = filename
    }
}

public enum DownloadMirror {
    public static func validate(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "" }
        guard let c = URLComponents(string: value), c.scheme == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              !value.contains("\\"), !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) else {
            throw DownloadFailure("镜像必须为 HTTPS 前缀，不得包含凭据、查询参数或片段。")
        }
        return value.hasSuffix("/") ? value : value + "/"
    }
    public static func requestURL(_ upstream: URL, slug: String, prefix: String) throws -> URL {
        let normalized = try RepositoryInput.normalize(slug)
        guard DownloadSafety.trusted(upstream), upstream.host == "github.com", upstream.query == nil,
              upstream.fragment == nil, upstream.path.hasPrefix("/\(normalized)/releases/download/"),
              !upstream.pathComponents.contains(".."),
              !upstream.absoluteString.lowercased().contains("%2f"),
              !upstream.absoluteString.lowercased().contains("%5c") else {
            throw DownloadFailure("附件 URL 不是此仓库的合法 GitHub Release 下载地址。")
        }
        let prefix = try validate(prefix)
        guard !prefix.isEmpty, let result = URL(string: prefix + upstream.absoluteString) else {
            throw DownloadFailure("镜像地址无效。")
        }
        return result
    }
    public static func allowed(_ url: URL, mirror: URL) -> Bool {
        let sameOrigin = url.scheme == "https" && url.host?.lowercased() == mirror.host?.lowercased()
            && (url.port ?? 443) == (mirror.port ?? 443) && url.user == nil && url.password == nil
        return sameOrigin || DownloadSafety.trusted(url)
    }
    public static func redirect(_ request: URLRequest, mirror: URL) -> URLRequest? {
        guard let url = request.url, allowed(url, mirror: mirror) else { return nil }
        var request = request
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        request.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        return request
    }
}
