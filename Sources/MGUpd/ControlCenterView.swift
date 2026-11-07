import AppKit
import SwiftUI
import UpdateCore

private enum ControlPage: String, CaseIterable, Identifiable {
    case overview, repositories, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "概览"
        case .repositories: return "仓库"
        case .settings: return "设置"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .repositories: return "shippingbox"
        case .settings: return "gearshape"
        }
    }
}

struct ControlCenterView: View {
    @ObservedObject var model: AppModel
    @State private var page = ControlPage.overview
    @State private var showingAdd = false
    @State private var toastMessage: String?
    @State private var toastID = UUID()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        content
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                StatusBar(model: model)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    Label(toastMessage, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
                        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 72)
                        .allowsHitTesting(false)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: 860, minHeight: 600)
        .buttonStyle(ControlButtonStyle())
        .sheet(isPresented: $showingAdd) { AddRepositorySheet(model: model) }
        .task { await model.refreshSystemStatus() }
        .task(id: toastID) {
            guard toastMessage != nil else { return }
            do { try await Task.sleep(nanoseconds: 3_000_000_000) }
            catch { return }
            withAnimation(.easeInOut(duration: 0.2)) { toastMessage = nil }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await model.refreshSystemStatus() } }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("MGUpd", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            ForEach(ControlPage.allCases) { item in
                Button { page = item } label: {
                    Label(item.title, systemImage: item.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .foregroundColor(page == item ? .accentColor : .primary)
                        .background(page == item ? Color.accentColor.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == item ? .isSelected : [])
            }
            Spacer()
            Text("\(model.unreadCount) 个未读更新")
                .font(.caption).foregroundStyle(.secondary).padding(10)
            Text("关闭窗口后仍会检查更新")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10)
        }
        .padding(12)
        .frame(maxHeight: .infinity)
        .background(SidebarMaterial())
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(page.title).font(.title2.bold())
                Text("关注 GitHub Release，不错过新版本。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if page != .settings {
                Button { showingAdd = true } label: {
                    Label("添加仓库", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .overview: RepositoryList(model: model, overview: true)
        case .repositories: RepositoryList(model: model, overview: false)
        case .settings:
            SettingsPage(model: model) { message in
                withAnimation(.easeInOut(duration: 0.2)) {
                    toastMessage = message
                    toastID = UUID()
                }
            }
        }
    }
}

private struct RepositoryList: View {
    @ObservedObject var model: AppModel
    let overview: Bool
    @State private var search = ""
    @State private var unreadOnly = true
    @State private var deleting: Repository?

    private var filtered: [Repository] {
        model.repositories.filter {
            (!overview || !unreadOnly || $0.unread) &&
            (search.isEmpty || $0.slug.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if overview { summary }
            HStack {
                TextField("搜索仓库", text: $search)
                    .textFieldStyle(.roundedBorder)
                if overview {
                    Picker("显示", selection: $unreadOnly) {
                        Text("未读更新").tag(true)
                        Text("全部仓库").tag(false)
                    }
                    .pickerStyle(.segmented).frame(width: 200)
                }
            }
            if filtered.isEmpty {
                ControlPanel {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
                        Text(model.repositories.isEmpty ? "尚未添加仓库" : "没有符合条件的仓库")
                        Text(model.repositories.isEmpty ? "添加 owner/repo 或 GitHub 仓库地址开始关注。首次检查仅建立基线，不发送通知。" : "尝试查看全部仓库或调整搜索条件。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            }
            LazyVStack(spacing: 16) {
                ForEach(filtered) { repository in
                    RepositoryCard(model: model, repository: repository, management: !overview) {
                        deleting = repository
                    }
                }
            }
        }
        .alert("删除仓库？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let repository = deleting { model.removeRepository(repository.id) }
                deleting = nil
            }
        } message: {
            Text("将移除 \(deleting?.slug ?? "") 及其本地检查记录，不会删除 GitHub 上的仓库。")
        }
    }

    private var summary: some View {
        ControlPanel {
            HStack(spacing: 24) {
                summaryValue("未读更新", value: model.unreadCount)
                Divider()
                summaryValue("全部仓库", value: model.repositories.count)
                Spacer()
                Button("全部标为已读") { model.markAllRead() }
                    .disabled(model.unreadCount == 0)
            }
        }
    }

    private func summaryValue(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(.title.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct RepositoryCard: View {
    @ObservedObject var model: AppModel
    let repository: Repository
    let management: Bool
    let onDelete: () -> Void

    var body: some View {
        ControlPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(repository.slug).font(.headline).textSelection(.enabled)
                    if repository.unread {
                        Text("未读").font(.caption.bold()).foregroundStyle(Color.accentColor)
                    }
                    if !repository.enabled { Text("已暂停").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if repository.unread {
                        Button("标为已读") { model.markRead(repository.id) }
                    }
                    if management {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                        }
                        .help("删除仓库").accessibilityLabel("删除 \(repository.slug)")
                    }
                }
                if management { controls }
                if let release = repository.latest {
                    ReleaseContent(release: release)
                } else {
                    Text(repository.initialized ? "暂无符合条件的版本，可立即检查刷新。" : "尚未检查；首次检查将建立静默基线。")
                        .foregroundStyle(.secondary).font(.callout)
                }
                RepositoryDownloads(manager: model.downloads, repository: repository, management: management) {
                    Task { await model.downloadLatest(repository.id) }
                }
                if let error = repository.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if let date = repository.lastChecked {
                    Text("上次成功检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            Toggle("启用检查", isOn: Binding(get: { repository.enabled }, set: { model.setEnabled(repository.id, $0) }))
            Toggle("包含预发布", isOn: Binding(get: { repository.includePrereleases }, set: { model.setPrereleases(repository.id, $0) }))
            Spacer()
        }
        .toggleStyle(.checkbox)
    }
}

private struct RepositoryDownloads: View {
    @ObservedObject var manager: DownloadManager
    let repository: Repository
    let management: Bool
    let download: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if management {
                Toggle("自动下载新版本匹配附件", isOn: Binding(
                    get: { manager.configuration(for: repository.id).automatic },
                    set: { manager.setAutomatic($0, for: repository.id) }
                ))
                .toggleStyle(.checkbox)
                Text("文件名匹配规则").font(.caption)
                    .help("每行一个 pattern；* 匹配任意字符，? 匹配一个字符")
                TextEditor(text: Binding(
                    get: { manager.configuration(for: repository.id).rule },
                    set: { manager.setRule($0, for: repository.id) }
                ))
                .font(.system(.body, design: .monospaced)).frame(height: 62)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                Text("每行一个，例如 *macos*arm64*.dmg")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let release = repository.latest {
                AttachmentPreview(release: release, patterns: manager.configuration(for: repository.id).rule)
            }
            if let message = manager.selectionMessage(for: repository) {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            if let progress = manager.progress[repository.id] {
                ProgressView(value: progress.fraction)
                Text("\(Int(progress.fraction * 100))% · \(ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)) · 已完成 \(progress.completedAssets)/\(progress.totalAssets) · \(progress.filename)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if manager.active.contains(repository.id) { ProgressView().controlSize(.small) }
                Text(manager.status(for: repository.id)).font(.caption).textSelection(.enabled)
                Spacer()
                if manager.active.contains(repository.id) {
                    Button("取消下载") { manager.cancel(repository.id) }
                } else {
                    Button("下载附件 / 重试", action: download)
                        .disabled(repository.latest == nil || manager.selectionMessage(for: repository) != nil)
                        .help(manager.selectionMessage(for: repository) ?? "下载最新版本中匹配 pattern 的附件")
                }
                Button("在 Finder 中打开") {
                    if let folder = manager.folder(for: repository), FileManager.default.fileExists(atPath: folder.path) {
                        NSWorkspace.shared.open(folder)
                    } else if FileManager.default.fileExists(atPath: manager.root.path) {
                        NSWorkspace.shared.open(manager.root)
                    } else {
                        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
                    }
                }
            }
            if let error = manager.storageError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }
}

private struct AttachmentPreview: View {
    let release: Release
    let patterns: String
    @State private var expanded = false

    private var selectedIDs: Set<Int64> {
        Set(((try? DownloadSelection.select(release.assets, patterns: patterns)) ?? []).map(\.id))
    }

    var body: some View {
        DisclosureGroup("附件（\(release.assets.count)）", isExpanded: $expanded) {
            if release.assets.isEmpty {
                Text("暂无附件").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(release.assets) { asset in
                        HStack(spacing: 8) {
                            Image(systemName: selectedIDs.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIDs.contains(asset.id) ? Color.accentColor : Color.secondary)
                                .help(selectedIDs.contains(asset.id) ? "将下载" : "未选中")
                            Text(verbatim: asset.name)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
                .padding(.vertical, 8)
            }
        }
    }
}

private struct ReleaseContent: View {
    let release: Release
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(release.name?.isEmpty == false ? release.name! : release.tagName)
                    .font(.title3.weight(.semibold)).textSelection(.enabled)
                Spacer()
                Link("打开 Release ↗", destination: release.htmlURL)
            }
            HStack(spacing: 12) {
                Text(release.tagName)
                if release.prerelease { Text("预发布").foregroundStyle(.orange) }
                if let date = release.publishedAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let body = release.body, !body.isEmpty {
                DisclosureGroup("发布说明", isExpanded: $expanded) {
                    // Render untrusted release notes literally, never as Markdown or HTML.
                    Text(verbatim: body)
                        .font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
            } else {
                Text("此版本未提供发布说明。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AddRepositorySheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var prereleases = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加仓库").font(.title2.bold())
            TextField("owner/repo 或 https://github.com/owner/repo", text: $input)
                .textFieldStyle(.roundedBorder).onSubmit(add)
            Toggle("包含预发布版本", isOn: $prereleases)
            Text("首次检查只记录已有版本，不产生未读更新或通知。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加", action: add).keyboardShortcut(.defaultAction)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 480)
    }

    private func add() {
        do {
            try model.addRepository(input, includePrereleases: prereleases)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct DownloadMirrorPanel: View {
    @ObservedObject var manager: DownloadManager
    @State private var prefix = ""
    let showToast: (String) -> Void

    var body: some View {
        ControlPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("附件下载镜像").font(.headline)
                TextField("HTTPS 镜像前缀；留空直连", text: $prefix).textFieldStyle(.roundedBorder)

                Text("使用 Token 时直连；请仅使用可信镜像。")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("镜像前缀后拼接完整 GitHub 下载地址，仅用于公开附件。第三方镜像可见下载地址和 IP，不会收到 Token；API 元数据始终直连。")
                Button("保存镜像设置") {
                    manager.setMirror(prefix)
                    if manager.mirrorError == nil {
                        showToast("镜像设置已保存")
                    }
                }
                if let error = manager.mirrorError { Text(error).font(.caption).foregroundStyle(.red) }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { prefix = manager.mirrorPrefix }
    }
}

private struct SettingsPage: View {
    @ObservedObject var model: AppModel
    let showToast: (String) -> Void
    @State private var token = ""
    @State private var tokenMessage: String?
    @State private var tokenFailed = false
    @State private var changingNotifications = false

    var body: some View {
        VStack(spacing: 18) {
            ControlPanel {
                VStack(alignment: .leading, spacing: 18) {
                    Text("检查与系统").font(.headline)
                    Picker("自动检查间隔", selection: $model.settings.intervalMinutes) {
                        ForEach([15, 30, 60, 180, 360, 1440], id: \.self) { minutes in
                            Text(intervalLabel(minutes)).tag(minutes)
                        }
                    }
                    .onChange(of: model.settings.intervalMinutes) { _ in model.saveSettings() }
                    Toggle("发送新版本通知", isOn: notificationBinding)
                        .disabled(changingNotifications)
                    Text(model.notificationStatus).font(.caption).foregroundStyle(.secondary)
                    Toggle("登录时启动 MGUpd", isOn: Binding(get: { model.loginEnabled }, set: model.setLoginEnabled))
                        .help("移动应用后需重新开启登录启动")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            tokenPanel
            DownloadMirrorPanel(manager: model.downloads, showToast: showToast)
        }
    }

    private var notificationBinding: Binding<Bool> {
        Binding(get: { model.settings.notificationsEnabled }, set: { enabled in
            changingNotifications = true
            Task {
                await model.setNotifications(enabled)
                changingNotifications = false
            }
        })
    }

    private var tokenPanel: some View {
        ControlPanel {
            VStack(alignment: .leading, spacing: 14) {
                Text("GitHub 访问令牌").font(.headline)
                Text(model.hasToken ? "已保存令牌（不显示明文）" : "未保存令牌，使用匿名请求")
                    .font(.callout).foregroundStyle(.secondary)
                SecureField("输入新令牌", text: $token).textFieldStyle(.roundedBorder)
                Text("安全存于钥匙串，用于私有仓库或提高请求额度。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("保存令牌") {
                        performTokenAction("令牌已安全保存。") { try model.saveToken(token) }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("输入访问令牌后即可保存")
                    Button("删除令牌", role: .destructive) {
                        performTokenAction("令牌已删除。") { try model.deleteToken() }
                    }
                    .disabled(!model.hasToken)
                    .help(model.hasToken ? "删除钥匙串中的访问令牌" : "尚未保存访问令牌")
                }
                if let tokenMessage {
                    Text(tokenMessage).font(.caption).foregroundColor(tokenFailed ? .red : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear { token = "" }
    }

    private func performTokenAction(_ success: String, action: () throws -> Void) {
        do {
            try action()
            token = ""
            tokenFailed = false
            tokenMessage = success
        } catch {
            tokenFailed = true
            tokenMessage = error.localizedDescription
        }
    }

    private func intervalLabel(_ minutes: Int) -> String {
        minutes < 60 ? "每 \(minutes) 分钟" : "每 \(minutes / 60) 小时"
    }
}

private struct StatusBar: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            if model.busy { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 2) {
                if let error = model.error {
                    Text(error).foregroundStyle(.red).lineLimit(2).help(error)
                } else if model.busy {
                    Text("正在检查 GitHub 更新…").foregroundStyle(.secondary)
                } else {
                    Text("就绪 · 每 \(model.settings.intervalMinutes) 分钟检查").foregroundStyle(.secondary)
                }
                if let date = model.lastCheck {
                    Text("最近检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            Spacer(minLength: 12)
            Button { Task { await model.checkNow() } } label: {
                Label("立即检查", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent).disabled(model.busy)
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
        .frame(minHeight: 54)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Keep disabled labels legible on material backgrounds in both appearances.
private struct ControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration)
    }

    private struct ButtonBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled

        private var tint: Color { configuration.role == .destructive ? .red : .accentColor }

        var body: some View {
            configuration.label
                .font(.body.weight(.medium))
                .foregroundColor(isEnabled ? tint : Color(nsColor: .secondaryLabelColor))
                                .environment(\.isEnabled, true)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isEnabled ? tint.opacity(configuration.isPressed ? 0.24 : 0.12) : Color.primary.opacity(0.05))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(isEnabled ? tint.opacity(0.35) : Color.primary.opacity(0.12), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct ControlPanel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.primary.opacity(0.07), lineWidth: 1)
            }
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
