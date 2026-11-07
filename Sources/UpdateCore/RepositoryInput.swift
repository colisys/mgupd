import Foundation

public enum RepositoryInputError: Error, LocalizedError {
    case invalid

    public var errorDescription: String? {
        "请输入 owner/repo 或 https://github.com/owner/repo 格式的仓库地址。"
    }
}

public enum RepositoryInput {
    public static func normalize(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug: String
        if trimmed.lowercased().hasPrefix("https://") {
            guard let url = URLComponents(string: trimmed),
                  url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == "github.com",
                  url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil,
                  url.percentEncodedPath.hasPrefix("/") else {
                throw RepositoryInputError.invalid
            }
            slug = String(url.percentEncodedPath.dropFirst())
        } else {
            slug = trimmed
        }
        let parts = slug.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw RepositoryInputError.invalid }
        let owner = String(parts[0])
        let repo = String(parts[1])
        // ASCII allowlists intentionally reject encoded separators and dot segments.
        guard owner.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", options: .regularExpression) != nil,
              !owner.contains("--"),
              repo.range(of: "^[A-Za-z0-9._-]{1,100}$", options: .regularExpression) != nil,
              repo != ".", repo != ".." else {
            throw RepositoryInputError.invalid
        }
        return "\(owner)/\(repo)"
    }
}
