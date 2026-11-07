import Foundation
import Darwin

public struct DownloadFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum DownloadSafety {
    public static func matches(_ name: String, rule: String) -> Bool {
        let rule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        return !rule.isEmpty && name.range(of: rule, options: .caseInsensitive) != nil
    }

    public static func validFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 240
            && !name.contains("/") && !name.contains("\\") && !name.contains(":")
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    public static func trusted(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["api.github.com", "github.com", "objects.githubusercontent.com",
                "release-assets.githubusercontent.com", "github-releases.githubusercontent.com"].contains(host)
    }

    public static func redirect(from source: URL?, request: URLRequest) -> URLRequest? {
        guard let url = request.url, trusted(url) else { return nil }
        var clean = request
        if source?.host?.lowercased() != url.host?.lowercased() || url.host?.lowercased() != "api.github.com" {
            clean.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        clean.setValue(nil, forHTTPHeaderField: "Cookie")
        clean.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        return clean
    }
}

final class DownloadRedirectDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var timer: DispatchSourceTimer?
    private var finished = false
    private var received = false
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var host = "unknown"
    private let firstByteTimeout: TimeInterval
    private let idleTimeout: TimeInterval

    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); defer { lock.unlock() }
                guard !finished else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                host = request.url?.host ?? "unknown"
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: request)
                self.task = task
                lastActivity = ProcessInfo.processInfo.systemUptime
                let timer = DispatchSource.makeTimerSource()
                self.timer = timer
                timer.schedule(deadline: .now(), repeating: 0.1)
                timer.setEventHandler { [weak self] in self?.checkTimeoutAndResponse() }
                timer.resume()
                task.resume()
            }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }

    private func failure(_ stage: String, _ detail: String) -> DownloadFailure {
        DownloadFailure("下载失败 [host=\(host) stage=\(stage)]：\(detail)")
    }

    private func validate(_ response: URLResponse?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        host = http.url?.host ?? host
        guard http.statusCode == 200 else { throw failure("response", "HTTP \(http.statusCode)") }
        guard let url = http.url, mirror.map({ DownloadMirror.allowed(url, mirror: $0) }) ?? DownloadSafety.trusted(url) else {
            throw failure("response", "不安全的下载地址")
        }
        let mime = http.mimeType?.lowercased() ?? ""
        if mime.contains("html") || mime.contains("json") { throw failure("response", "返回 HTML/JSON 而非附件") }
    }

    private func checkTimeoutAndResponse() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        do { try validate(task?.response) } catch { finish(.failure(error)); return }
        if ProcessInfo.processInfo.systemUptime - lastActivity > (received ? idleTimeout : firstByteTimeout) {
            finish(.failure(failure(received ? "idle" : "first-byte", "网络超时")))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
    let mirror: URL?
    let progress: @Sendable (Int64, Int64) -> Void
    init(mirror: URL?, firstByteTimeout: TimeInterval = 30, idleTimeout: TimeInterval = 30,
         progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.mirror = mirror; self.progress = progress
        self.firstByteTimeout = firstByteTimeout; self.idleTimeout = idleTimeout
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("mgupd-\(UUID().uuidString).download")
        do {
            try validate(downloadTask.response)
            let handle = try FileHandle(forReadingFrom: location)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 512) ?? Data()
            let text = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !text.hasPrefix("<!doctype html"), !text.hasPrefix("<html"), !text.hasPrefix("{"), !text.hasPrefix("[") else {
                throw failure("content", "返回 HTML/JSON 而非附件")
            }
            try FileManager.default.moveItem(at: location, to: saved)
            finish(.success(saved))
        } catch {
            try? FileManager.default.removeItem(at: saved)
            finish(.failure((error as? DownloadFailure) ?? failure("temporary-file", "无法读取或保存临时附件")))
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finish(.failure(failure(received ? "transfer" : "first-byte", "URLSession code=\((error as NSError?)?.code ?? 0)")))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        do { try validate(downloadTask.response) } catch { finish(.failure(error)); return }
        received = true
        lastActivity = ProcessInfo.processInfo.systemUptime
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { completionHandler(nil); return }
        let clean = mirror.map { DownloadMirror.redirect(request, mirror: $0) }
            ?? DownloadSafety.redirect(from: response.url, request: request)
        completionHandler(clean)
        if clean == nil { finish(.failure(failure("redirect", "已阻止不安全的重定向"))) }
        else { host = clean?.url?.host ?? host }
    }
}

public struct AssetDownloader {
    public init() {}

    public func download(asset: ReleaseAsset, slug: String, releaseID: Int64,
                         token: String?, root: URL, mirrorPrefix: String = "",
                         progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> URL {
        let slug = try RepositoryInput.normalize(slug)
        guard DownloadSafety.validFilename(asset.name), asset.id > 0, releaseID > 0, asset.size >= 0 else {
            throw DownloadFailure("附件名称、ID 或大小无效。")
        }
        // A configured credential always forces direct API downloads, including public repositories.
        let useMirror = (token == nil || token?.isEmpty == true) && !mirrorPrefix.isEmpty
        let url: URL
        if let token, !token.isEmpty {
            url = URL(string: "https://api.github.com/repos/\(slug)/releases/assets/\(asset.id)")!
        } else {
            // Reuse the strict repository-specific browser URL validation for direct downloads too.
            _ = try DownloadMirror.requestURL(asset.browserDownloadURL, slug: slug, prefix: "https://github.com/")
            url = try useMirror ? DownloadMirror.requestURL(asset.browserDownloadURL, slug: slug, prefix: mirrorPrefix) : asset.browserDownloadURL
        }
        let mirror = useMirror ? url : nil
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("MGUpd/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token, !token.isEmpty {
            guard !token.contains("\r"), !token.contains("\n") else { throw DownloadFailure("访问令牌无效。") }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForResource = 3600
        let temporary = try await DownloadRedirectDelegate(mirror: mirror, progress: progress).run(request, configuration: config)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()

        let fm = FileManager.default
        let size = try fm.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber
        guard size?.int64Value == asset.size else { throw DownloadFailure("附件大小校验失败。") }
        // Reject symlinked destination components rather than following them outside the chosen root.
        var folder = root
        try Self.makeSafeDirectory(folder)
        for part in slug.split(separator: "/").map(String.init) + [String(releaseID)] {
            folder.appendPathComponent(part, isDirectory: true)
            try Self.makeSafeDirectory(folder)
        }
        let destination = folder.appendingPathComponent(asset.name)
        let staging = folder.appendingPathComponent(".mgupd-\(UUID().uuidString).partial")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: temporary, to: staging)
        // Quarantine is mandatory: failure must not publish an unquarantined executable.
        let quarantine = "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));MGUpd;\(UUID().uuidString)"
        let result = quarantine.withCString { value in
            setxattr(staging.path, "com.apple.quarantine", value, strlen(value), 0, 0)
        }
        guard result == 0 else { throw DownloadFailure("无法设置下载隔离属性；未保存附件。") }
        try Task.checkCancellation()
        // Same-directory exclusive rename is atomic and cannot replace an existing file.
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw DownloadFailure("无法保存附件（文件可能已存在）；不会覆盖已有文件。")
        }
        return destination
    }

    private static func makeSafeDirectory(_ url: URL) throws {
        let fm = FileManager.default
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for part in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(part, isDirectory: true)
            if !fm.fileExists(atPath: current.path) {
                try fm.createDirectory(at: current, withIntermediateDirectories: false)
            }
            let attributes = try fm.attributesOfItem(atPath: current.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw DownloadFailure("下载路径包含符号链接或非文件夹项目。")
            }
        }
    }
}
