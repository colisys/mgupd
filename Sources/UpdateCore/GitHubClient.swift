import Foundation

public enum GitHubClientError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int, rateLimitReset: Date?)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub 返回了无效响应。"
        case let .httpStatus(status, reset):
            let message: String
            switch status {
            case 401: message = "GitHub 身份验证失败，请检查访问令牌。"
            case 403: message = "GitHub 拒绝访问：权限不足或已达到 API 速率限制。"
            case 404: message = "找不到 GitHub 仓库，请检查仓库名称及私有仓库访问权限。"
            case 429: message = "GitHub 请求过于频繁，请稍后重试。"
            case 300..<400: message = "为保护访问令牌，已阻止 GitHub 请求重定向。"
            default: message = "GitHub 请求失败（HTTP \(status)）。"
            }
            if let reset {
                return message + " 速率限制重置时间：\(ISO8601DateFormatter().string(from: reset))。"
            }
            return message
        }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct APIRelease: Decodable {
    let release: Release
    let draft: Bool

    enum CodingKeys: String, CodingKey { case draft }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        draft = try container.decode(Bool.self, forKey: .draft)
        release = try Release(from: decoder)
    }
}

public struct GitHubClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func releases(for slug: String, token: String?) async throws -> [Release] {
        let normalized = try RepositoryInput.normalize(slug)
        let delegate = NoRedirectDelegate()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 timestamp")
            }
            return date
        }
        var result: [Release] = []
        var seen = Set<Int64>()
        for page in 1...10 {
            // Construct every page locally: never follow a Link URL with credentials.
            var components = URLComponents()
            components.scheme = "https"
            components.host = "api.github.com"
            components.path = "/repos/\(normalized)/releases"
            components.queryItems = [URLQueryItem(name: "per_page", value: "100"),
                                     URLQueryItem(name: "page", value: String(page))]
            guard let url = components.url else { throw RepositoryInputError.invalid }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MGUpd/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                guard !token.contains("\r"), !token.contains("\n") else {
                    throw GitHubClientError.httpStatus(401, rateLimitReset: nil)
                }
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await session.data(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw GitHubClientError.invalidResponse }
            guard http.statusCode == 200 else {
                let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                    .flatMap(TimeInterval.init)
                    .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
                throw GitHubClientError.httpStatus(http.statusCode, rateLimitReset: reset)
            }
            let entries = try decoder.decode([APIRelease].self, from: data)
            for entry in entries where !entry.draft && seen.insert(entry.release.id).inserted {
                result.append(entry.release)
            }
            let link = http.value(forHTTPHeaderField: "Link")
            let hasNext: Bool
            if let link {
                hasNext = link.range(of: #"rel\s*=\s*"[^"]*\bnext\b[^"]*""#, options: .regularExpression) != nil
            } else {
                // Without pagination metadata, keep reading full pages up to the limit.
                hasNext = entries.count >= 100
            }
            if !hasNext { return result }
        }
        // Monitoring uses a bounded recent window, not a complete release archive.
        return result
    }
}
