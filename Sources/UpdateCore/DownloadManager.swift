import Foundation
import Combine

public struct DownloadConfiguration: Codable, Equatable {
    public var automatic = false
    public var rule = ""
    public init() {}
    enum CodingKeys: String, CodingKey { case automatic, rule, patternVersion }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        let stored = try c.decodeIfPresent(String.self, forKey: .rule) ?? ""
        rule = try c.decodeIfPresent(Int.self, forKey: .patternVersion) == 1 ? stored : DownloadSelection.migrateSubstring(stored)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(automatic, forKey: .automatic)
        try c.encode(rule, forKey: .rule)
        try c.encode(1, forKey: .patternVersion)
    }
}

private struct DownloadEntry: Codable {
    var configuration = DownloadConfiguration()
    var pending: Int64?
    var attempts = 0
    var completed: [String: String] = [:]
    var message = "尚未下载"
}

@MainActor
public final class DownloadManager: ObservableObject {
    public typealias Transfer = (ReleaseAsset, String, Int64, String?, URL) async throws -> URL
    @Published private var entries: [UUID: DownloadEntry] = [:]
    @Published public private(set) var storageError: String?
    @Published public private(set) var active: Set<UUID> = []
    public let root: URL
    private let stateURL: URL
    private let transfer: Transfer?
    @Published public private(set) var progress: [UUID: DownloadProgress] = [:]
    @Published public private(set) var mirrorPrefix = ""
    @Published public private(set) var mirrorError: String?
    private var mirrorWritable = true
    private var mirrorURL: URL { stateURL.deletingPathExtension().appendingPathExtension("mirror.json") }
    private var writable = true
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UUID] = [:]

    public init(stateURL: URL? = nil, root: URL? = nil, transfer: Transfer? = nil) {
        self.stateURL = stateURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MGUpd/downloads.json")
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/MGUpd")
        self.transfer = transfer
        do {
            entries = try JSONDecoder().decode([UUID: DownloadEntry].self, from: Data(contentsOf: self.stateURL))
            for id in Array(entries.keys) where entries[id]?.message.hasPrefix("正在下载") == true {
                entries[id]?.message = "上次下载已中断；可手动重试"
            }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
        } catch {
            writable = false
            storageError = "无法读取下载记录；为保护原文件，本次禁用下载：\(error.localizedDescription)"
        }
        do {
            mirrorPrefix = try DownloadMirror.validate(JSONDecoder().decode(String.self, from: Data(contentsOf: mirrorURL)))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
        } catch {
            mirrorWritable = false
            mirrorError = "无法读取镜像配置；保留原文件，本次使用直连：\(error.localizedDescription)"
        }
    }

    public func setMirror(_ value: String) {
        guard mirrorWritable else { return }
        do {
            let prefix = try DownloadMirror.validate(value)
            let data = try JSONEncoder().encode(prefix)
            try FileManager.default.createDirectory(at: mirrorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: mirrorURL, options: .atomic)
            for id in Array(active) { cancel(id) }
            mirrorPrefix = prefix
            mirrorError = nil
        } catch { mirrorError = error.localizedDescription }
    }

    public func selectionMessage(for repository: Repository) -> String? {
        guard let latest = repository.latest else { return nil }
        do { _ = try DownloadSelection.select(latest.assets, patterns: configuration(for: repository.id).rule); return nil }
        catch { return error.localizedDescription }
    }

    public func configuration(for id: UUID) -> DownloadConfiguration { entries[id]?.configuration ?? .init() }
    public func status(for id: UUID) -> String { entries[id]?.message ?? "尚未下载" }
    public func setAutomatic(_ enabled: Bool, for id: UUID) {
        cancel(id)
        entries[id, default: DownloadEntry()].configuration.automatic = enabled
        save()
    }
    public func setRule(_ rule: String, for id: UUID) {
        guard configuration(for: id).rule != rule else { return }
        cancel(id)
        entries[id, default: DownloadEntry()].configuration.rule = rule
        save()
    }

    /// Call on repository pause, removal, or filter changes, too. Does not delete downloaded files.
    public func cancel(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        generations.removeValue(forKey: id)
        active.remove(id)
        progress[id] = nil
        if entries[id] != nil {
            entries[id]?.pending = nil
            entries[id]?.message = "已停止；可手动下载最新匹配附件"
        }
        save()
    }
    public func remove(_ id: UUID) {
        cancel(id)
        entries.removeValue(forKey: id)
        save()
    }

    public func process(repository: Repository, discovered: [Release], token: String?) {
        let id = repository.id
        guard repository.enabled else { cancelIfPending(id); return }
        guard configuration(for: id).automatic else { return }
        guard let latest = repository.latest else { cancelIfPending(id); return }
        if let pending = entries[id]?.pending, pending != latest.id { cancel(id) }
        guard !active.contains(id), writable else { return }
        let matches: [ReleaseAsset]
        do { matches = try DownloadSelection.select(latest.assets, patterns: configuration(for: id).rule) }
        catch { report(error.localizedDescription, for: id); return }
        if discovered.contains(where: { $0.id == latest.id }) {
            if entries[id]?.pending != latest.id {
                entries[id, default: DownloadEntry()].pending = latest.id
                entries[id]?.attempts = 0
            }
        }
        guard entries[id]?.pending == latest.id, (entries[id]?.attempts ?? 0) < 3 else { return }
        start(repository: repository, release: latest, assets: matches, token: token, automatic: true)
    }

    public func downloadLatest(repository: Repository, token: String?) {
        guard writable, !active.contains(repository.id), let latest = repository.latest else { return }
        let assets: [ReleaseAsset]
        do { assets = try DownloadSelection.select(latest.assets, patterns: configuration(for: repository.id).rule) }
        catch { report(error.localizedDescription, for: repository.id); return }
        start(repository: repository, release: latest, assets: assets, token: token, automatic: false)
    }

    public func report(_ message: String, for id: UUID) {
        entries[id, default: DownloadEntry()].message = message
        save()
    }

    public func folder(for repository: Repository) -> URL? {
        guard let slug = try? RepositoryInput.normalize(repository.slug) else { return nil }
        var folder = root.appendingPathComponent(slug, isDirectory: true)
        if let latest = repository.latest { folder.appendPathComponent(String(latest.id), isDirectory: true) }
        return folder
    }

    private func cancelIfPending(_ id: UUID) {
        if active.contains(id) || entries[id]?.pending != nil { cancel(id) }
    }

    private func start(repository: Repository, release: Release, assets: [ReleaseAsset], token: String?, automatic: Bool) {
        let id = repository.id
        if automatic { entries[id, default: DownloadEntry()].attempts += 1 }
        entries[id, default: DownloadEntry()].message = "正在下载 \(assets.count) 个匹配附件…"
        guard save() else { return }
        let generation = UUID()
        generations[id] = generation
        active.insert(id)
        let total = assets.reduce(Int64(0)) { partial, asset in
            let (sum, overflow) = partial.addingReportingOverflow(max(0, asset.size))
            return overflow ? Int64.max : sum
        }
        progress[id] = DownloadProgress(totalBytes: total, totalAssets: assets.count, filename: assets.first?.name ?? "")
        let mirror = mirrorPrefix
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generations[id] == generation {
                    self.tasks[id] = nil
                    self.generations[id] = nil
                    self.active.remove(id)
                }
            }
            do {
                var finishedBytes: Int64 = 0
                var finishedAssets = 0
                for asset in assets {
                    try Task.checkCancellation()
                    guard self.generations[id] == generation else { return }
                    let key = "\(release.id)/\(asset.id)"
                    if let path = self.entries[id]?.completed[key], FileManager.default.fileExists(atPath: path) {
                        finishedBytes += max(0, asset.size)
                        finishedAssets += 1
                        self.progress[id] = DownloadProgress(receivedBytes: finishedBytes, totalBytes: total, completedAssets: finishedAssets, totalAssets: assets.count)
                        continue
                    }
                    self.progress[id] = DownloadProgress(receivedBytes: finishedBytes, totalBytes: total,
                        completedAssets: finishedAssets, totalAssets: assets.count, filename: asset.name)
                    let base = finishedBytes
                    let completed = finishedAssets
                    let url: URL
                    if let transfer = self.transfer {
                        url = try await transfer(asset, repository.slug, release.id, token, self.root)
                    } else {
                        url = try await AssetDownloader().download(asset: asset, slug: repository.slug, releaseID: release.id,
                            token: token, root: self.root, mirrorPrefix: mirror) { [weak self] written, _ in
                            Task { @MainActor in
                                guard let self, self.generations[id] == generation else { return }
                                let received = base + min(max(0, written), max(0, asset.size))
                                guard received >= (self.progress[id]?.receivedBytes ?? 0),
                                      completed >= (self.progress[id]?.completedAssets ?? 0) else { return }
                                self.progress[id] = DownloadProgress(receivedBytes: received, totalBytes: total,
                                    completedAssets: completed, totalAssets: assets.count, filename: asset.name)
                            }
                        }
                    }
                    finishedBytes += max(0, asset.size)
                    finishedAssets += 1
                    guard self.generations[id] == generation else { return }
                    self.progress[id] = DownloadProgress(receivedBytes: finishedBytes, totalBytes: total,
                        completedAssets: finishedAssets, totalAssets: assets.count, filename: asset.name)
                    self.entries[id, default: DownloadEntry()].completed[key] = url.path
                    guard self.save() else { return }
                }
                self.entries[id]?.pending = nil
                self.entries[id]?.message = "下载完成（不会自动安装或运行）"
            } catch {
                guard self.generations[id] == generation else { return }
                let suffix = automatic ? ((self.entries[id]?.attempts ?? 0) >= 3
                    ? "；已达 3 次自动尝试上限，请手动重试。" : "；下次成功检查时重试。") : "；可手动重试。"
                self.entries[id]?.message = "下载失败：\(error.localizedDescription)\(suffix)"
            }
            self.save()
        }
    }

    @discardableResult private func save() -> Bool {
        guard writable else { return false }
        do {
            let data = try JSONEncoder().encode(entries)
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: stateURL, options: .atomic)
            storageError = nil
            return true
        } catch {
            storageError = "下载记录保存失败：\(error.localizedDescription)"
            return false
        }
    }
}
