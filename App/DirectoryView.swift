import SwiftUI
import UIKit

struct DirectoryView: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var sort: SortPreferences
    @EnvironmentObject private var clipboard: ClipboardStore
    @Environment(\.dismiss) private var dismiss
    let route: PathRoute

    @State private var entries: [DirEntry] = []
    @State private var errorText: String?
    @State private var busy = false
    @State private var showLog = false
    @State private var notice: String?

    // Operation sheets / alerts
    @State private var renameTarget: DirEntry?
    @State private var renameText = ""
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var newFileName = ""
    @State private var showNewFile = false
    @State private var deleteTarget: DirEntry?
    @State private var infoTarget: DirEntry?
    @State private var infoDict: [String: String]?
    @State private var infoPath: String?
    @State private var showInfo = false
    @State private var zipTarget: DirEntry?
    @State private var zipName = ""

    private var canGoUp: Bool {
        guard route.path != route.root else { return false }
        let parent = (route.path as NSString).deletingLastPathComponent
        return parent == route.root || parent.hasPrefix(route.root + "/")
    }

    private var breadcrumb: String {
        route.path == route.root ? "/" : String(route.path.dropFirst(route.root.count))
    }

    private var starred: Bool { bookmarks.isBookmarked(path: route.path) }
    private var sortedEntries: [DirEntry] { sort.sorted(entries) }
    private var writable: Bool { !route.path.hasSuffix(".app") }

    private func detailText(_ entry: DirEntry) -> String {
        switch sort.key {
        case .date: return entry.dateText
        case .type: return entry.typeText
        case .size: return entry.kind == "dir" ? "文件夹" : entry.sizeText
        case .name: return ""
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CardBox(radius: 20, padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("当前目录")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Palette.secondary)
                            Spacer()
                            Text("\(entries.count) 项")
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.tertiary)
                        }

                        Text(breadcrumb)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(3)
                            .textSelection(.enabled)

                        Text(route.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.tertiary)
                            .lineLimit(3)
                            .textSelection(.enabled)

                        ThinSeparator()

                        HStack(spacing: 12) {
                            SmallAction(system: "doc.on.doc", title: "复制路径") {
                                UIPasteboard.general.string = route.path
                                notice = "路径已复制"
                            }
                            SmallAction(system: starred ? "star.fill" : "star",
                                        title: starred ? "取消收藏" : "收藏") {
                                let added = bookmarks.toggle(title: route.title, path: route.path)
                                notice = added ? "已收藏当前目录" : "已取消收藏"
                            }
                            if canGoUp {
                                SmallAction(system: "arrow.turn.up.left", title: "上级目录") {
                                    dismiss()
                                }
                            }
                        }
                    }
                }

                if let errorText {
                    InlineNotice(text: errorText, tone: Palette.danger)
                }
                if let notice {
                    InlineNotice(text: notice, tone: Palette.secondary)
                }

                HStack(spacing: 10) {
                    SectionLabel(text: "内容")
                    Spacer()
                    Menu {
                        ForEach(SortKey.allCases) { key in
                            Button {
                                sort.key = key
                            } label: {
                                if sort.key == key {
                                    Label(key.title, systemImage: "checkmark")
                                } else {
                                    Label(key.title, systemImage: key.system)
                                }
                            }
                        }
                        Divider()
                        Button {
                            sort.foldersFirst.toggle()
                        } label: {
                            Label(sort.foldersFirst ? "文件夹优先：开" : "文件夹优先：关",
                                  systemImage: "folder")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                            Text(sort.key.title)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(Palette.card, in: Capsule())
                    }
                    Button {
                        sort.ascending.toggle()
                    } label: {
                        Image(systemName: sort.ascending ? "arrow.up" : "arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 32, height: 32)
                            .background(Palette.card, in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                Text("排序：\(sort.summary)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)

                if entries.isEmpty && !busy {
                    EmptyCard(text: errorText == nil
                              ? "目录为空，或尚未取得该目录的沙盒扩展。"
                              : "无法读取此目录，请返回或查看日志。")
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(sortedEntries) { entry in
                            entryRow(entry)
                        }
                    }
                }

                Spacer(minLength: 120)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .background(Palette.background)
        .enableInteractivePop()
        .refreshable { reload() }
        .task { reload() }
        .glassNavigationBar(title: route.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        let added = bookmarks.toggle(title: route.title, path: route.path)
                        notice = added ? "已收藏当前目录" : "已取消收藏"
                    } label: {
                        Image(systemName: starred ? "star.fill" : "star")
                            .foregroundStyle(Palette.ink)
                    }
                    Button { showLog = true } label: {
                        Image(systemName: "doc.text").foregroundStyle(Palette.ink)
                    }
                    Button { reload() } label: {
                        Image(systemName: "arrow.clockwise").foregroundStyle(Palette.ink)
                    }
                    .disabled(busy)
                    Menu {
                        Button {
                            newFolderName = ""
                            showNewFolder = true
                        } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                        Button {
                            newFileName = ""
                            showNewFile = true
                        } label: { Label("新建文件", systemImage: "doc.badge.plus") }
                        if clipboard.has {
                            Button {
                                pasteFromClipboard()
                            } label: { Label("粘贴 \(clipboard.fileName)", systemImage: "doc.on.clipboard") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(Palette.ink)
                    }
                }
            }
        }
        .overlay(alignment: .center) {
            if busy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取目录…")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
            }
        }
        .sheet(isPresented: $showLog) {
            DiagnosticsView(text: XCTContainerBridge.diagnostics())
        }
        .sheet(isPresented: $showInfo) {
            infoSheet
        }
        .alert("重命名", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("新名称", text: $renameText)
            Button("确定") { commitRename() }
            Button("取消", role: .cancel) { renameTarget = nil }
        } message: {
            if let t = renameTarget { Text(t.name) } else { Text("") }
        }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("创建") { commitNewFolder() }
            Button("取消", role: .cancel) {}
        } message: { Text(route.path) }
        .alert("新建文件", isPresented: $showNewFile) {
            TextField("文件名称", text: $newFileName)
            Button("创建") { commitNewFile() }
            Button("取消", role: .cancel) {}
        } message: { Text(route.path) }
        .alert("打包为 ZIP", isPresented: Binding(get: { zipTarget != nil }, set: { if !$0 { zipTarget = nil } })) {
            TextField("文件名", text: $zipName)
            Button("打包") { commitZip() }
            Button("取消", role: .cancel) { zipTarget = nil }
        } message: {
            if let t = zipTarget { Text("将 \(t.name) 打包成 ZIP 保存到当前目录") } else { Text("") }
        }
        .confirmationDialog("删除项目", isPresented: Binding(get: { deleteTarget != nil },
                                                           set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { commitDelete() }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            if let t = deleteTarget { Text("确定要删除 \(t.name) 吗？此操作会直接修改对方应用的数据。") }
            else { Text("") }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: DirEntry) -> some View {
        if entry.kind == "dir" {
            NavigationLink(value: PathRoute(path: entry.path, root: route.root, title: entry.name)) {
                EntryCard(entry: entry, detail: detailText(entry))
            }
            .buttonStyle(.plain)
            .contextMenu { entryMenu(entry) }
        } else {
            NavigationLink(value: FileTarget(path: entry.path, name: entry.name, kind: entry.kind)) {
                EntryCard(entry: entry, detail: detailText(entry))
            }
            .buttonStyle(.plain)
            .contextMenu { entryMenu(entry) }
        }
    }

    @ViewBuilder
    private var infoSheet: some View {
        NavigationStack {
            ScrollView {
                if let dict = infoDict {
                    VStack(alignment: .leading, spacing: 12) {
                        if let message = dict["error"], dict.count <= 1 {
                            InlineNotice(text: message, tone: Palette.danger)
                            Button {
                                if let p = infoPath { infoDict = nil; loadInfo(p) }
                            } label: {
                                Label("重试", systemImage: "arrow.clockwise")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Palette.ink)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(dict.filter { $0.key != "error" }.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(k).font(.system(size: 14)).foregroundStyle(Palette.secondary).frame(width: 92, alignment: .leading)
                                        Text(v).font(.system(size: 14)).foregroundStyle(Palette.ink)
                                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    ThinSeparator().padding(.leading, 16)
                                }
                            }
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                    }
                } else {
                    EmptyCard(text: "正在读取属性…")
                }
                Spacer(minLength: 40)
            }
            .padding(20)
            .background(Palette.background)
            .navigationTitle("信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showInfo = false }.foregroundStyle(Palette.ink)
                }
            }
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func entryMenu(_ entry: DirEntry) -> some View {
        Button {
            UIPasteboard.general.string = entry.path
            notice = "路径已复制"
        } label: { Label("复制路径", systemImage: "doc.on.doc") }

        Button {
            renameText = entry.name
            renameTarget = entry
        } label: { Label("重命名", systemImage: "pencil") }

        Button {
            clipboard.copy(entry.path)
            notice = "已复制：\(entry.name)"
        } label: { Label("复制项目", systemImage: "doc.on.doc.fill") }

        Button {
            clipboard.cut(entry.path)
            notice = "已剪切：\(entry.name)"
        } label: { Label("移动到此处", systemImage: "scissors") }

        if !entry.statOK {
            // nothing extra
        } else if entry.kind == "file" {
            Button {
                showInfoEntry(entry)
            } label: { Label("查看信息", systemImage: "info.circle") }

            Button {
                zipName = entry.name + ".zip"
                zipTarget = entry
            } label: { Label("打包为 ZIP", systemImage: "doc.zipper") }

            Button {
                UIPasteboard.general.string = entry.path
                if bookmarks.add(title: entry.name, path: entry.path) {
                    notice = "已收藏 \(entry.name)"
                } else {
                    notice = "该路径已在收藏夹中"
                }
            } label: { Label("加入收藏夹", systemImage: "star") }
        }

        Button(role: .destructive) {
            deleteTarget = entry
        } label: { Label("删除", systemImage: "trash") }
    }

    // MARK: - Operations

    private func showInfoEntry(_ entry: DirEntry) {
        infoPath = entry.path
        loadInfo(entry.path)
    }

    private func loadInfo(_ path: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let raw = XCTFileOps.attributes(at: path)
            var dict: [String: String] = [:]
            for (k, v) in raw { dict[k] = v as? String ?? "" }
            DispatchQueue.main.async {
                self.infoDict = dict
                self.showInfo = true
            }
        }
    }

    private func commitRename() {
        guard let t = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !name.isEmpty, name != t.name else { return }
        runOp("重命名") {
            XCTFileOps.renameItem(at: t.path, toName: name)
        }
    }

    private func commitNewFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let dest = (route.path as NSString).appendingPathComponent(name)
        runOp("新建文件夹") {
            XCTFileOps.createDirectory(at: dest)
        }
    }

    private func commitNewFile() {
        let name = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let dest = (route.path as NSString).appendingPathComponent(name)
        runOp("新建文件") {
            XCTFileOps.createFile(at: dest, text: "")
        }
    }

    private func pasteFromClipboard() {
        guard let src = clipboard.copiedPath, !src.isEmpty else { return }
        let name = (src as NSString).lastPathComponent
        let dest = (route.path as NSString).appendingPathComponent(name)
        let mode = clipboard.pasteMode
        runOp(mode == .move ? "移动" : "复制") {
            if mode == .move {
                let e = XCTFileOps.moveItem(at: src, toDirectory: route.path)
                if e == nil { DispatchQueue.main.async { self.clipboard.clear() } }
                return e
            } else {
                return XCTFileOps.copyItem(at: src, toPath: dest)
            }
        }
    }

    private func commitDelete() {
        guard let t = deleteTarget else { return }
        let p = t.path
        deleteTarget = nil
        runOp("删除") {
            XCTFileOps.deleteItem(at: p)
        }
    }

    private func commitZip() {
        guard let t = zipTarget else { return }
        let name = zipName.trimmingCharacters(in: .whitespacesAndNewlines)
        let dest = (route.path as NSString).appendingPathComponent(name.hasSuffix(".zip") ? name : name + ".zip")
        let src = t.path
        zipTarget = nil
        runOp("打包") {
            XCTFileOps.zipItems(atPaths: [src], to: dest)
        }
    }

    /// Runs a bridge call off the main thread, surfaces the error (if any) and
    /// refreshes the listing. `error` nil means success.
    private func runOp(_ label: String, work: @escaping () -> String?) {
        guard writable else {
            notice = "该位置（安装包）为只读，无法修改。"
            return
        }
        busy = true
        errorText = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let err = work()
            DispatchQueue.main.async {
                self.busy = false
                if let err = err {
                    self.notice = "\(label)失败：\(err)"
                } else {
                    self.notice = "\(label)完成"
                    self.reload()
                }
            }
        }
    }

    private func reload() {
        guard !busy else { return }
        busy = true
        errorText = nil
        let target = route.path
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = XCTContainerBridge.listDirectory(path: target)
            let message = XCTContainerBridge.lastError()
            let items: [DirEntry] = rows.compactMap { row in
                guard let name = row["name"] as? String,
                      let child = row["path"] as? String else { return nil }
                return DirEntry(
                    name: name,
                    path: child,
                    kind: (row["kind"] as? String) ?? "other",
                    bytes: (row["bytes"] as? NSNumber)?.int64Value ?? 0,
                    statOK: (row["stat"] as? String) == "YES",
                    mtime: (row["mtime"] as? NSNumber)?.doubleValue ?? 0,
                    ext: (row["ext"] as? String) ?? ""
                )
            }
            DispatchQueue.main.async {
                self.entries = items
                self.errorText = message
                self.busy = false
            }
        }
    }
}

// MARK: - Rows

private struct SmallAction: View {
    let system: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: system).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Palette.placeholder, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct EntryCard: View {
    let entry: DirEntry
    var detail: String = ""

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(entry.kind == "dir" ? Palette.selected : Palette.placeholder)
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(entry.kind == "dir" ? Palette.ink : Palette.secondary)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                if !entry.statOK {
                    Text("元信息不可读")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.warning)
                } else if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if !entry.sizeText.isEmpty {
                Text(entry.sizeText)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
            }
            if entry.kind == "dir" {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.03), radius: 8, x: 0, y: 2)
    }

    private var symbol: String {
        switch entry.kind {
        case "dir": return "folder.fill"
        case "link": return "link"
        case "file": return "doc"
        default: return "questionmark"
        }
    }
}

// MARK: - Shared diagnostics sheet

struct DiagnosticsView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LogTextView(text: text.isEmpty ? "暂无日志" : text)
                .background(Palette.background)
                .navigationTitle("访问日志")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") { dismiss() }.foregroundStyle(Palette.ink)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("复制") { UIPasteboard.general.string = text }
                            .foregroundStyle(Palette.ink)
                    }
                }
        }
    }
}

// 长日志交给 UITextView：TextKit 直接负责排版和选择，避免 SwiftUI 的 Text
// 加上 textSelection 在几万行日志上排版造成的卡死。
private struct LogTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = UIColor(Palette.ink)
        view.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 28, right: 14)
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
