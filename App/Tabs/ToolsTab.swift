import SwiftUI
import UIKit

struct ToolsTab: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @State private var navPath = NavigationPath()
    @State private var jumpPath = ""
    @State private var showAdd = false
    @State private var editing = false
    @State private var renaming: Bookmark?
    @State private var notice: String?

    var body: some View {
        NavigationStack(path: $navPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // MARK: 收藏夹
                    HStack(spacing: 10) {
                        SectionLabel(text: "收藏夹 \(bookmarks.items.count)")
                        Spacer()
                        if !bookmarks.items.isEmpty {
                            HeaderIcon(system: editing ? "checkmark" : "slider.horizontal.3") {
                                editing.toggle()
                            }
                        }
                        HeaderIcon(system: "plus") {
                            showAdd = true
                        }
                    }

                    CardBox(radius: 20, padding: 0) {
                        if bookmarks.items.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "star")
                                    .font(.system(size: 26, weight: .light))
                                    .foregroundStyle(Palette.tertiary)
                                Text("还没有收藏。浏览目录时点星标，或用「+」直接写入路径。")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Palette.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                            .padding(.horizontal, 20)
                        } else {
                            ScrollView(.vertical, showsIndicators: bookmarks.items.count > 5) {
                                VStack(spacing: 0) {
                                    ForEach(bookmarks.items) { item in
                                        bookmarkRow(item, isLast: bookmarks.items.last?.id == item.id)
                                    }
                                }
                            }
                            .frame(height: bookmarkListHeight)
                            .scrollDisabled(bookmarks.items.count <= 5)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                    }

                    Text("收藏只保存路径与名称，不会复制目录内容。下次打开可直接跳转。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiary)

                    // MARK: 替换文件
                    SectionLabel(text: "文件替换")
                    CardBox(radius: 20, padding: 0) {
                        NavigationLink {
                            ReplaceFileView()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Palette.placeholder)
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Palette.ink)
                                }
                                .frame(width: 36, height: 36)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("替换文件")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Palette.ink)
                                    Text("用 .aud / .amr 覆盖收藏目录里的 .aud_tmp")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Palette.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // MARK: 音频转换
                    SectionLabel(text: "音频转换")
                    CardBox(radius: 20, padding: 0) {
                        NavigationLink {
                            AudioConvertView()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Palette.placeholder)
                                    Image(systemName: "waveform.badge.plus")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Palette.ink)
                                }
                                .frame(width: 36, height: 36)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("MP3 / MP4 转 .aud")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Palette.ink)
                                    Text("编码为微信语音同格式（SILK v3）")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Palette.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // MARK: 存储清理
                    SectionLabel(text: "存储清理")
                    CardBox(radius: 20, padding: 0) {
                        NavigationLink {
                            CacheCleanView()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Palette.placeholder)
                                    Image(systemName: "trash.circle")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Palette.ink)
                                }
                                .frame(width: 36, height: 36)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("缓存清理")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Palette.ink)
                                    Text("扫描并清空各应用的缓存、临时文件与日志")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Palette.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // MARK: 快速跳转
                    SectionLabel(text: "快速跳转")
                    CardBox {
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("/private/var/mobile/Containers/Data/Application/...", text: $jumpPath)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Palette.ink)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .padding(12)
                                .background(Palette.placeholder, in: RoundedRectangle(cornerRadius: 12))

                            HStack(spacing: 10) {
                                SmallPill(system: "arrow.right.circle", title: "打开") {
                                    open(BookmarkStore.normalized(jumpPath), title: nil)
                                }
                                SmallPill(system: "star.circle", title: "打开并收藏") {
                                    open(BookmarkStore.normalized(jumpPath), title: nil, bookmark: true)
                                }
                                SmallPill(system: "doc.on.clipboard", title: "粘贴") {
                                    if let clip = UIPasteboard.general.string, !clip.isEmpty { jumpPath = clip }
                                }
                            }
                        }
                    }

                    // MARK: 常用位置
                    SectionLabel(text: "常用位置")
                    CardBox(radius: 20, padding: 0) {
                        VStack(spacing: 0) {
                            QuickLink(title: "应用数据容器", path: "/private/var/mobile/Containers/Data/Application") { open($0, title: $1) }
                            ThinSeparator().padding(.leading, 16)
                            QuickLink(title: "App Group 容器", path: "/private/var/mobile/Containers/Shared/AppGroup") { open($0, title: $1) }
                            ThinSeparator().padding(.leading, 16)
                            QuickLink(title: "应用 Bundle", path: "/private/var/containers/Bundle/Application") { open($0, title: $1) }
                            ThinSeparator().padding(.leading, 16)
                            QuickLink(title: "本 App 沙盒", path: NSHomeDirectory()) { open($0, title: $1) }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    if let notice {
                        InlineNotice(text: notice)
                    }

                    Spacer(minLength: 120)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
            .background(Palette.background)
            .enableInteractivePop()
            .glassNavigationBar(title: "工具")
            .navigationDestination(for: PathRoute.self) { route in
                DirectoryView(route: route)
            }
            .navigationDestination(for: FileTarget.self) { target in
                FileView(target: target)
            }
            .sheet(isPresented: $showAdd) {
                BookmarkEditor(mode: .add)
            }
            .sheet(item: $renaming) { item in
                BookmarkEditor(mode: .rename(item))
            }
        }
    }

    /// 收藏夹固定窗口：最多完整显示 5 行，超出后区域内上下滚动。
    private var bookmarkListHeight: CGFloat {
        let visible = min(bookmarks.items.count, 5)
        return CGFloat(visible) * 60 + CGFloat(max(visible - 1, 0))
    }

    @ViewBuilder
    private func bookmarkRow(_ item: Bookmark, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            Group {
                if editing {
                    BookmarkControls(item: item,
                                     canMoveUp: (bookmarks.items.firstIndex(of: item) ?? 0) > 0,
                                     rename: { renaming = item },
                                     remove: { bookmarks.remove(id: item.id) },
                                     moveUp: moveUp)
                } else {
                    NavigationLink(value: PathRoute(path: item.path, title: item.title)) {
                        BookmarkRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 60)
            .padding(.horizontal, 16)

            if !isLast {
                ThinSeparator().padding(.leading, 16)
            }
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = item.path
            } label: { Label("复制路径", systemImage: "doc.on.doc") }
            Button {
                renaming = item
            } label: { Label("重命名", systemImage: "pencil") }
            Button(role: .destructive) {
                bookmarks.remove(id: item.id)
            } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func moveUp(_ item: Bookmark) {
        guard let index = bookmarks.items.firstIndex(of: item), index > 0 else { return }
        bookmarks.move(from: IndexSet(integer: index), to: index - 1)
    }

    private func open(_ path: String, title: String?, bookmark: Bool = false) {
        guard path.hasPrefix("/"), path.count > 1 else {
            notice = "路径必须是绝对路径"
            return
        }
        notice = nil
        if bookmark && !bookmarks.add(title: title ?? "", path: path) {
            notice = "该路径已在收藏夹中"
        }
        navPath.append(PathRoute(path: path, title: title ?? (path as NSString).lastPathComponent))
    }
}

// MARK: - Small components

private struct SmallPill: View {
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

private struct BookmarkRow: View {
    let item: Bookmark

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.placeholder)
                Image(systemName: "star.fill")
                    .font(.system(size: 14))
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
                    .textSelection(.enabled)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BookmarkControls: View {
    let item: Bookmark
    let canMoveUp: Bool
    let rename: () -> Void
    let remove: () -> Void
    let moveUp: (Bookmark) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(item.path).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            IconButton(system: "arrow.up") { moveUp(item) }.disabled(!canMoveUp).opacity(canMoveUp ? 1 : 0.35)
            IconButton(system: "pencil", action: rename)
            IconButton(system: "trash", tone: Palette.danger, action: remove)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IconButton: View {
    let system: String
    var tone: Color = Palette.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone)
                .frame(width: 30, height: 30)
                .background(Palette.placeholder, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct QuickLink: View {
    let title: String
    let path: String
    let action: (String, String) -> Void

    var body: some View {
        Button {
            action(BookmarkStore.normalized(path), title)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.ink)
                    Text(path).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Add / rename editor

private enum BookmarkEditorMode {
    case add
    case rename(Bookmark)
}

private struct BookmarkEditor: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @Environment(\.dismiss) private var dismiss
    let mode: BookmarkEditorMode

    @State private var title = ""
    @State private var path = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（可留空，自动取末级目录名）", text: $title)
                    TextField("绝对路径", text: $path)
                        .font(.system(size: 12, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button {
                        if let clip = UIPasteboard.general.string, !clip.isEmpty { path = clip }
                    } label: { Label("粘贴剪贴板路径", systemImage: "doc.on.clipboard") }
                } header: {
                    Text("收藏路径")
                } footer: {
                    Text("示例：/private/var/mobile/Containers/Data/Application/<UUID>/Documents")
                }

                if let errorText {
                    Section { Text(errorText).font(.footnote).foregroundStyle(Palette.danger) }
                }
            }
            .tint(Palette.ink)
            .navigationTitle(modeIsRename ? "重命名收藏" : "添加收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }.foregroundStyle(Palette.ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }.bold().foregroundStyle(Palette.ink)
                }
            }
            .onAppear {
                if case .rename(let item) = mode {
                    title = item.title
                    path = item.path
                }
            }
        }
    }

    private var modeIsRename: Bool {
        if case .rename = mode { return true }
        return false
    }

    private func save() {
        switch mode {
        case .add:
            let normalized = BookmarkStore.normalized(path)
            guard normalized.hasPrefix("/"), normalized.count > 1 else {
                errorText = "请输入以 / 开头的绝对路径"
                return
            }
            guard bookmarks.add(title: title, path: normalized) else {
                errorText = "该路径已收藏，或路径无效"
                return
            }
            dismiss()
        case .rename(let item):
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorText = "名称不能为空"
                return
            }
            bookmarks.rename(id: item.id, title: title)
            dismiss()
        }
    }
}
