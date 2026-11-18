import SwiftUI
import UIKit

// MARK: - Browser model

/// One row of a directory listing, as produced by
/// `XCTContainerBridge.listDirectory(path:)` (the same call the 文件 tab uses,
/// so the picker can reach every container the app can already read).
struct BrowseEntry: Identifiable, Hashable {
    let name: String
    let path: String
    let kind: String        // dir | file | link | other
    let bytes: Int64
    let mtime: Double

    var id: String { path }
    var isDirectoryLike: Bool { kind == "dir" || kind == "link" }

    var metaText: String {
        var parts: [String] = []
        if mtime > 0 {
            parts.append(Self.dayFormatter.string(from: Date(timeIntervalSince1970: mtime)))
        }
        if !isDirectoryLike {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}

/// Recently picked directories, so the picker opens where the user last was.
enum RecentDirectories {
    private static let key = "SandboxAccess.recentDirs.v1"

    static func load() -> [String] {
        (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
    }

    static func push(_ path: String) {
        let p = BookmarkStore.normalized(path)
        guard p.hasPrefix("/") else { return }
        var items = load().filter { $0 != p }
        items.insert(p, at: 0)
        UserDefaults.standard.set(Array(items.prefix(8)), forKey: key)
    }
}

// MARK: - Directory picker

/// Directory chooser used by 「替换文件」 (target + source).
///
/// Two modes:
///  * 浏览 — a real file browser: roots → app containers → any subdirectory,
///    with a thumb-reachable 「选择此目录」 bar pinned to the bottom.
///  * 收藏 — the bookmark list, one tap to pick.
struct DirectoryPickerSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case browse = "浏览"
        case favorites = "收藏"
        var id: String { rawValue }
    }

    let title: String
    var initialPath: String? = nil
    /// (absolute path, friendly title)
    let onPick: (String, String) -> Void

    @EnvironmentObject private var bookmarks: BookmarkStore
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .browse
    @State private var currentPath: String?
    @State private var entries: [BrowseEntry] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var query = ""
    @State private var showingApps = false
    @State private var apps: [AppRow] = []
    @State private var loadingApps = false
    @State private var recent: [String] = []

    private struct AppRow: Identifiable, Hashable {
        let id: String
        let name: String
        let path: String
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("模式", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 10)

                switch mode {
                case .favorites: favoritesList
                case .browse: browseList
                }
            }
            .background(Palette.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(Palette.ink)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if mode == .browse {
                    bottomBar
                }
            }
            .onAppear(perform: bootstrap)
            .onChange(of: mode) { _, newValue in
                if newValue == .browse && currentPath == nil && !showingApps {
                    loadApps()
                }
            }
        }
    }

    // MARK: Browse

    @ViewBuilder
    private var browseList: some View {
        ScrollView {
            VStack(spacing: 10) {
                if showingApps {
                    appsSection
                } else if let path = currentPath {
                    pathBar(path)
                    if let errorText {
                        errorCard(errorText)
                    } else if loading && entries.isEmpty {
                        loadingCard
                    } else {
                        let dirs = filteredDirs
                        if dirs.isEmpty {
                            hintCard("这个目录下没有子目录。可以直接「选择此目录」，或点左上角的 ↑ 返回上一层。")
                        }
                        ForEach(dirs) { entry in
                            entryRow(entry)
                        }
                        let fileCount = entries.count - entries.filter(\.isDirectoryLike).count
                        if fileCount > 0 {
                            Text("另有 \(fileCount) 个文件（此处只列出目录）")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 4)
                        }
                    }
                } else {
                    rootsSection
                }
            }
            .padding(16)
        }
    }

    private var filteredDirs: [BrowseEntry] {
        let dirs = entries.filter(\.isDirectoryLike)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return dirs }
        return dirs.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private func pathBar(_ path: String) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    goUp()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 30, height: 30)
                        .background(Palette.placeholder, in: Circle())
                }
                .buttonStyle(.plain)

                Text(path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.tertiary)
                TextField("筛选子目录", text: $query)
                    .font(.system(size: 12))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Palette.placeholder, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var rootsSection: some View {
        VStack(spacing: 10) {
            if !recent.isEmpty {
                groupLabel("最近使用")
                ForEach(recent, id: \.self) { path in
                    rowButton(icon: "clock",
                              title: (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent,
                              subtitle: path) {
                        open(path)
                    }
                }
            }

            groupLabel("快捷入口")
            rowButton(icon: "iphone", title: "本应用容器", subtitle: NSHomeDirectory()) {
                open(NSHomeDirectory())
            }
            if let group = groupContainerPath {
                rowButton(icon: "square.stack.3d.up", title: "App Group 容器", subtitle: group) {
                    open(group)
                }
            }
            rowButton(icon: "square.grid.2x2", title: loadingApps ? "读取 App 列表…" : "所有 App 的容器",
                      subtitle: "\(apps.count) 个可访问应用 · 进入后继续浏览") {
                showingApps = true
                loadApps()
            }
            rowButton(icon: "doc.on.clipboard", title: "从剪贴板粘贴路径", subtitle: "剪贴板里必须是以 / 开头的绝对路径") {
                pasteFromClipboard()
            }

            if !bookmarks.items.isEmpty {
                groupLabel("收藏夹")
                ForEach(bookmarks.items.prefix(6)) { item in
                    rowButton(icon: "star.fill", title: item.title, subtitle: item.path) {
                        commit(path: item.path, title: item.title)
                    }
                }
            }
        }
    }

    private var appsSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    showingApps = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 30, height: 30)
                        .background(Palette.placeholder, in: Circle())
                }
                .buttonStyle(.plain)
                Text("所有 App 的容器")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }

            if loadingApps && apps.isEmpty {
                loadingCard
            } else if apps.isEmpty {
                hintCard("没有读到可访问的应用容器。回到「文件」tab 刷新一次应用列表再试。")
            } else {
                ForEach(apps) { app in
                    rowButton(icon: "app", title: app.name, subtitle: app.path) {
                        open(app.path)
                    }
                }
            }
        }
    }

    // MARK: Favorites

    private var favoritesList: some View {
        Group {
            if bookmarks.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "star")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Palette.tertiary)
                    Text("收藏夹是空的。\n切到「浏览」直接进入目录选择，或在「文件」页点星标收藏。")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(bookmarks.items) { item in
                            Button {
                                commit(path: item.path, title: item.title)
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Palette.placeholder)
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Palette.ink)
                                    }
                                    .frame(width: 34, height: 34)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(Palette.ink)
                                            .lineLimit(1)
                                        Text(item.path)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(Palette.secondary)
                                            .lineLimit(2)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 6)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Palette.tertiary)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.card,
                                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            ThinSeparator()
            HStack(spacing: 10) {
                Button {
                    goUp()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                        Text("上一级")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Palette.placeholder, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(currentPath == nil && !showingApps)

                Button {
                    pickCurrent()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.checkmark")
                            .font(.system(size: 13, weight: .semibold))
                        Text(pickTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .background(Palette.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(currentPath == nil || loading)
                .opacity((currentPath == nil || loading) ? 0.35 : 1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
        .background(.bar)
    }

    private var pickTitle: String {
        guard let path = currentPath else { return "先选择目录" }
        return "选择「\(label(for: path))」"
    }

    // MARK: Rows

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.top, 4)
    }

    private func rowButton(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Palette.placeholder)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func entryRow(_ entry: BrowseEntry) -> some View {
        Button {
            open(entry.path)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Palette.selected)
                    Image(systemName: entry.kind == "link" ? "link" : "folder.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !entry.metaText.isEmpty {
                        Text(entry.metaText)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("读取目录…")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func hintCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(Palette.tertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func errorCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13))
                .foregroundStyle(Palette.warning)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("返回上一层") { goUp() }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Palette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Actions

    private func bootstrap() {
        recent = RecentDirectories.load()
        loadApps()
        if let p = initialPath, p.hasPrefix("/") {
            open(p)
        }
    }

    private func open(_ path: String) {
        let normalized = BookmarkStore.normalized(path)
        currentPath = normalized
        showingApps = false
        query = ""
        entries = []
        errorText = nil
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = XCTContainerBridge.listDirectory(path: normalized)
            let message = XCTContainerBridge.lastError()
            var list: [BrowseEntry] = []
            for row in rows {
                guard let name = row["name"] as? String,
                      let child = row["path"] as? String else { continue }
                if name == "." || name == ".." { continue }
                list.append(BrowseEntry(name: name,
                                        path: child,
                                        kind: (row["kind"] as? String) ?? "other",
                                        bytes: (row["bytes"] as? NSNumber)?.int64Value ?? 0,
                                        mtime: (row["mtime"] as? NSNumber)?.doubleValue ?? 0))
            }
            list.sort { a, b in
                if a.isDirectoryLike != b.isDirectoryLike { return a.isDirectoryLike }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            DispatchQueue.main.async {
                guard self.currentPath == normalized else { return }
                self.entries = list
                self.errorText = message
                self.loading = false
            }
        }
    }

    private func goUp() {
        if showingApps {
            showingApps = false
            return
        }
        guard let path = currentPath else { return }
        query = ""
        // An app's data container is a root of its own: jump back to roots
        // instead of trying to list .../Data/Application (which the sandbox
        // will not hand out).
        if apps.contains(where: { $0.path == path }) {
            currentPath = nil
            entries = []
            errorText = nil
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == "/" || parent == path {
            currentPath = nil
            entries = []
            errorText = nil
            return
        }
        open(parent)
    }

    private func pickCurrent() {
        guard let path = currentPath else { return }
        commit(path: path, title: label(for: path))
    }

    private func commit(path: String, title: String) {
        RecentDirectories.push(path)
        onPick(BookmarkStore.normalized(path), title)
        dismiss()
    }

    private func label(for path: String) -> String {
        if let app = apps.first(where: { $0.path == path }) {
            return app.name
        }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    private func loadApps() {
        guard apps.isEmpty, !loadingApps else { return }
        loadingApps = true
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = XCTContainerBridge.applications(refresh: false)
            var list: [AppRow] = []
            for row in rows {
                guard let name = row["name"], let path = row["path"] else { continue }
                list.append(AppRow(id: row["id"] ?? path, name: name, path: path))
            }
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self.apps = list
                self.loadingApps = false
            }
        }
    }

    private func pasteFromClipboard() {
        let raw = UIPasteboard.general.string ?? ""
        let normalized = BookmarkStore.normalized(raw)
        guard normalized.hasPrefix("/"), normalized.count > 1 else {
            errorText = "剪贴板内容不是绝对路径"
            return
        }
        errorText = nil
        open(normalized)
    }

    private var groupContainerPath: String? {
        let id = XCTContainerBridge.appGroup() ?? "group.local.xchat.transfer"
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)?.path
    }
}
