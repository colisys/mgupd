import AppKit
import Security

import SwiftUI
import UpdateCore
import UserNotifications

@main
struct MGUpdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("MGUpd · 更新管理", id: "control") {
            ControlCenterView(model: model)
        }
        .defaultSize(width: 960, height: 700)
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11.5, weight: .medium))
                .symbolRenderingMode(.hierarchical)
            Text("\(model.unreadCount)")
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
        }
        .help("\(model.unreadCount) 个仓库有未读更新")
        .accessibilityLabel("MGUpd，\(model.unreadCount) 个仓库有未读更新")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let value = response.notification.request.content.userInfo["releaseURL"] as? String,
           let url = URL(string: value), url.scheme == "https", url.host == "github.com" {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}

private struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(model.unreadCount) 个仓库有未读更新")
        Button("管理仓库…") {
            openWindow(id: "control")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(model.busy ? "正在检查…" : "立即检查") {
            Task { await model.checkNow() }
        }
        .disabled(model.busy)
        Divider()
        Button("退出 MGUpd") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var repositories: [Repository] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var lastCheck: Date?
    @Published private(set) var notificationStatus = "正在读取通知权限…"
    @Published private(set) var loginEnabled = false
    @Published private(set) var hasToken = false
    @Published var settings = AppSettings()

    var unreadCount: Int { repositories.filter(\.unread).count }

    let downloads = DownloadManager()

    func downloadLatest(_ id: UUID) async {
        guard let repository = repositories.first(where: { $0.id == id }) else { return }
        do {
            downloads.downloadLatest(repository: repository, token: try TokenStore.read())
        } catch {
            downloads.report(error.localizedDescription, for: id)
        }
    }

    private let store: StateStore
    private let client = GitHubClient()
    private var pollingTask: Task<Void, Never>?
    private var storageAvailable = true
    private var changingNotifications = false

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = StateStore(url: base.appendingPathComponent("MGUpd/state.json"))
        do {
            let state = try store.load()
            repositories = state.repositories
            settings = state.settings
        } catch {
            storageAvailable = false
            self.error = "无法读取保存的数据；为保护原文件，本次不会写入：\(error.localizedDescription)"
        }
        do { hasToken = try TokenStore.exists() }
        catch { self.error = error.localizedDescription }
        pollingTask = Task { [weak self] in
            await self?.refreshSystemStatus()
            while !Task.isCancelled {
                if let self, !self.busy,
                   self.lastCheck == nil || Date().timeIntervalSince(self.lastCheck!) >= Double(max(15, self.settings.intervalMinutes)) * 60 {
                    await self.checkNow()
                }
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { break }
            }
        }
    }

    deinit { pollingTask?.cancel() }

    func addRepository(_ input: String, includePrereleases: Bool) throws {
        let slug = try RepositoryInput.normalize(input)
        guard !repositories.contains(where: { $0.slug.caseInsensitiveCompare(slug) == .orderedSame }) else {
            throw AppFailure("此仓库已添加。")
        }
        repositories.append(Repository(slug: slug, includePrereleases: includePrereleases))
        persist()
        Task { await checkNow() }
    }

    func removeRepository(_ id: UUID) {
        downloads.remove(id)
        repositories.removeAll { $0.id == id }
        persist()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = index(for: id) else { return }
        if !enabled { downloads.cancel(id) }
        repositories[index].enabled = enabled
        persist()
    }

    func setPrereleases(_ id: UUID, _ enabled: Bool) {
        guard let index = index(for: id) else { return }
        downloads.cancel(id)
        repositories[index].includePrereleases = enabled
        if !enabled, repositories[index].latest?.prerelease == true {
            repositories[index].latest = nil
        }
        persist()
    }

    func markRead(_ id: UUID) {
        guard let index = index(for: id) else { return }
        repositories[index].unread = false
        persist()
    }

    func markAllRead() {
        for index in repositories.indices { repositories[index].unread = false }
        persist()
    }

    func checkNow() async {
        guard !busy else { return }
        busy = true
        if storageAvailable { error = nil }
        defer { busy = false; lastCheck = Date() }
        let token: String?
        do { token = try TokenStore.read() }
        catch { self.error = error.localizedDescription; return }
        let targets = repositories.filter(\.enabled)
        for target in targets {
            do {
                let releases = try await client.releases(for: target.slug, token: token)
                // A repository may be removed or disabled while the request is in flight.
                guard let index = index(for: target.id), repositories[index].enabled else { continue }
                let discovered = repositories[index].apply(releases, at: Date())
                persist()
                downloads.process(repository: repositories[index], discovered: discovered, token: token)
                if settings.notificationsEnabled, let release = discovered.first {
                    await notify(slug: target.slug, release: release)
                }
            } catch {
                guard let index = index(for: target.id), repositories[index].enabled else { continue }
                repositories[index].error = error.localizedDescription
                self.error = "\(target.slug)：\(error.localizedDescription)"
                persist()
            }
        }
    }

    func saveSettings() {
        if ![15, 30, 60, 180, 360, 1440].contains(settings.intervalMinutes) {
            settings.intervalMinutes = 30
        }
        persist()
    }

    func setNotifications(_ enabled: Bool) async {
        guard !changingNotifications else { return }
        changingNotifications = true
        defer { changingNotifications = false }
        if enabled {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                settings.notificationsEnabled = granted
                if !granted { error = "通知权限未开启，请在系统设置的“通知”中允许 MGUpd。" }
            } catch {
                settings.notificationsEnabled = false
                self.error = "请求通知权限失败：\(error.localizedDescription)"
            }
        } else {
            settings.notificationsEnabled = false
        }
        persist()
        await refreshSystemStatus()
    }

    func setLoginEnabled(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled, executable: Bundle.main.executableURL?.path)
        } catch { self.error = "修改登录项失败：\(error.localizedDescription)" }
        loginEnabled = LoginItem.isEnabled(executable: Bundle.main.executableURL?.path)
    }

    func saveToken(_ value: String) throws {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains("\n"), !token.contains("\r") else {
            throw AppFailure("请输入非空且不含换行的访问令牌。")
        }
        try TokenStore.save(token)
        hasToken = true
    }

    func deleteToken() throws {
        try TokenStore.delete()
        hasToken = false
    }

    func refreshSystemStatus() async {
        loginEnabled = LoginItem.isEnabled(executable: Bundle.main.executableURL?.path)
        do { hasToken = try TokenStore.exists() }
        catch { self.error = error.localizedDescription }
        let status = await UNUserNotificationCenter.current().notificationSettings()
        switch status.authorizationStatus {
        case .notDetermined: notificationStatus = "尚未请求通知权限"
        case .denied: notificationStatus = "系统已拒绝通知，请在系统设置中开启"
        case .authorized: notificationStatus = "系统已允许通知"
        case .provisional: notificationStatus = "系统允许静默通知"
        case .ephemeral: notificationStatus = "系统临时允许通知"
        @unknown default: notificationStatus = "未知通知权限状态"
        }
    }

    private func index(for id: UUID) -> Int? { repositories.firstIndex { $0.id == id } }

    private func persist() {
        guard storageAvailable else { return }
        var state = StoredState()
        state.repositories = repositories
        state.settings = settings
        do { try store.save(state) }
        catch { self.error = "保存失败：\(error.localizedDescription)" }
    }

    private func notify(slug: String, release: Release) async {
        let content = UNMutableNotificationContent()
        content.title = "\(slug) 有新版本"
        content.body = release.name ?? release.tagName
        content.sound = .default
        content.userInfo = ["releaseURL": release.htmlURL.absoluteString]
        let request = UNNotificationRequest(identifier: "\(slug)-\(release.id)", content: content, trigger: nil)
        do { try await UNUserNotificationCenter.current().add(request) }
        catch { self.error = "发送通知失败：\(error.localizedDescription)" }
    }
}

private struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private enum TokenStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "MGUpd.GitHub",
         kSecAttrAccount as String: "access-token"]
    }

    static func exists() throws -> Bool {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(request as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        try validate(status)
        return true
    }

    static func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try validate(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw AppFailure("钥匙串中的令牌无法读取，请重新保存。")
        }
        return value
    }

    static func save(_ value: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try validate(SecItemAdd(item as CFDictionary, nil))
        } else { try validate(status) }
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try validate(status) }
    }

    private static func validate(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "错误码 \(status)"
            throw AppFailure("钥匙串操作失败：\(message)")
        }
    }
}
