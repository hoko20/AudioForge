import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 「替换文件」 tool.
///
/// Flow: pick a bookmarked directory -> list only `*.aud_tmp` targets ->
/// pick a `.aud` / `.amr` source (browsed in another sandbox directory, or
/// imported as a single file / zip / ipa package) -> confirm -> the source
/// bytes are written over the target under the target's own file name.
///
/// Layout note: a voice-cache directory can easily hold 100+ candidates, so
/// every file list is height-capped and scrolls on its own (4 rows by
/// default, "展开全部" for the rest). The 「覆盖」 action is additionally
/// pinned in a floating dock above the tab bar, so confirming never requires
/// scrolling to the end of the page.
struct ReplaceFileView: View {
    @StateObject private var model = ReplaceFileModel()

    @State private var pickTarget = false
    @State private var pickSource = false
    @State private var showImporter = false
    @State private var confirmReplace = false
    @State private var manualPath = ""
    @State private var sourceMode: SourceMode = .directory
    @AppStorage("replacefile.intro.expanded") private var introExpanded = false
    @State private var showAllLogs = false

    private enum SourceMode: String, CaseIterable, Identifiable {
        case directory = "沙盒目录"
        case imported = "导入文件"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                introCard
                targetSection
                sourceSection
                actionSection

                if model.busy {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(model.busyText)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondary)
                    }
                }

                Spacer(minLength: hasSelection ? 168 : 120)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
        .background(Palette.background)
        .enableInteractivePop()
        .glassNavigationBar(title: "替换文件")
        .overlay(alignment: .bottom) {
            if hasSelection {
                replaceDock
                    .padding(.horizontal, 18)
                    .padding(.bottom, 88)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: hasSelection)
        .sheet(isPresented: $pickTarget) {
            DirectoryPickerSheet(title: "选择目标目录", initialPath: model.targetDir) { path, title in
                model.setTargetDirectory(path: path, title: title)
            }
        }
        .sheet(isPresented: $pickSource) {
            DirectoryPickerSheet(title: "选择源目录", initialPath: model.sourceDir) { path, title in
                model.setSourceDirectory(path: path, title: title)
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { outcome in
            switch outcome {
            case .success(let urls):
                sourceMode = .imported
                model.importFiles(urls)
            case .failure(let error):
                model.errorText = error.localizedDescription
            }
        }
        .onAppear { model.refreshImported() }
        // A bottom sheet keeps the confirmation right next to the thumb
        // (the system confirmationDialog anchored itself near the top of the
        // screen, far away from the button that opened it).
        .sheet(isPresented: $confirmReplace) {
            if let source = model.selectedSourceFile,
               let target = model.selectedTargetFile {
                ReplaceConfirmSheet(source: source, target: target) {
                    confirmReplace = false
                    model.replace()
                }
                .presentationDetents([.height(430)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
            }
        }
    }

    private var hasSelection: Bool {
        model.selectedTargetFile != nil || model.selectedSourceFile != nil
    }

    private var logRows: [String] {
        showAllLogs ? model.importLog : Array(model.importLog.prefix(3))
    }

    // MARK: - Intro

    private var introCard: some View {
        CardBox(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { introExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                        Text("用 .aud / .amr 覆盖 .aud_tmp")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                        Spacer(minLength: 4)
                        Text(introExpanded ? "收起" : "说明")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondary)
                        Image(systemName: introExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Palette.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if introExpanded {
                    Text("① 选目标目录（收藏夹 / 浏览任意 App 容器），只列 *.aud_tmp   ② 选一个源音频（可浏览沙盒目录，也可导入单文件或 zip / ipa 包）   ③ 确认后只替换文件内容，目标文件名保持原样 —— 例如 2..aud_tmp 覆盖后仍叫 2..aud_tmp。原文件会自动备份。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Target

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "① 目标 .aud_tmp")

            CardBox(radius: 20, padding: 0) {
                VStack(spacing: 0) {
                    Button {
                        pickTarget = true
                    } label: {
                        dirRow(icon: "folder.badge.minus",
                               title: model.targetDir == nil ? "选择目标目录" : model.targetDirTitle,
                               subtitle: model.targetDir ?? "可直接浏览文件列表进入任意目录")
                    }
                    .buttonStyle(.plain)

                    if model.targetDir != nil {
                        ThinSeparator().padding(.leading, 16)

                        HStack(spacing: 12) {
                            Toggle(isOn: Binding(get: { model.targetRecursive },
                                                 set: { _ in model.toggleTargetRecursive() })) {
                                Text("包含子目录")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Palette.ink)
                            }
                            .tint(Palette.ink)

                            Spacer(minLength: 4)

                            Text("\(model.targets.count)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.secondary)

                            Button {
                                UIPasteboard.general.string = model.targetDir ?? ""
                                model.notice = "路径已复制"
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.secondary)
                            }
                            .buttonStyle(.plain)

                            Button {
                                model.loadTargets()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.busy)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        if model.targets.isEmpty {
                            ThinSeparator().padding(.leading, 16)
                            emptyHint("这个目录里没有 .aud_tmp 文件。换一个收藏目录，或打开「包含子目录」再试。")
                        } else {
                            ThinSeparator().padding(.leading, 16)
                            BoundedMediaList(files: model.targets,
                                             selected: model.selectedTarget,
                                             badge: { _ in nil }) { file in
                                model.selectedTarget = file.path
                                model.result = nil
                                model.errorText = nil
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    // MARK: - Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "② 源文件 .aud / .amr")

            Picker("来源", selection: $sourceMode) {
                ForEach(SourceMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if sourceMode == .directory {
                directorySourceCard
            } else {
                importedSourceCard
            }
        }
    }

    private var directorySourceCard: some View {
        CardBox(radius: 20, padding: 0) {
            VStack(spacing: 0) {
                Button {
                    pickSource = true
                } label: {
                    dirRow(icon: "folder",
                           title: model.sourceDir == nil ? "选择源目录" : model.sourceDirTitle,
                           subtitle: model.sourceDir ?? "只显示 .aud / .amr 类型文件")
                }
                .buttonStyle(.plain)

                ThinSeparator().padding(.leading, 16)

                HStack(spacing: 8) {
                    TextField("或粘贴绝对路径", text: $manualPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(9)
                        .background(Palette.placeholder, in: RoundedRectangle(cornerRadius: 10))

                    Button {
                        loadManualSource()
                    } label: {
                        Text("加载")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Palette.selected, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if model.sourceDir != nil {
                    ThinSeparator().padding(.leading, 16)

                    HStack(spacing: 12) {
                        Toggle(isOn: Binding(get: { model.recursive },
                                             set: { _ in model.toggleRecursive() })) {
                            Text("包含子目录")
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.ink)
                        }
                        .tint(Palette.ink)

                        Spacer(minLength: 4)

                        Text("\(model.sources.count)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.secondary)

                        Button {
                            model.loadSources()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.busy)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    if model.sources.isEmpty {
                        ThinSeparator().padding(.leading, 16)
                        emptyHint("这个目录里没有 .aud / .amr 文件。试试打开「包含子目录」，或换一个目录。")
                    } else {
                        ThinSeparator().padding(.leading, 16)
                        BoundedMediaList(files: model.sources,
                                         selected: model.selectedSource,
                                         badge: { file in model.recursive ? file.relative : nil }) { file in
                            model.selectedSource = file.path
                            model.result = nil
                            model.errorText = nil
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var importedSourceCard: some View {
        CardBox(radius: 20, padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        showImporter = true
                    } label: {
                        pill("导入文件 / 压缩包", "square.and.arrow.down")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy)

                    Button {
                        model.refreshImported()
                    } label: {
                        pill("刷新", "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy)

                    Spacer(minLength: 4)

                    if !model.imported.isEmpty {
                        Button {
                            model.clearImported()
                        } label: {
                            pill("清空", "trash", tone: Palette.danger)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.busy)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                if model.imported.isEmpty {
                    ThinSeparator().padding(.leading, 16)
                    emptyHint("还没有导入。可以直接选 .aud / .amr 单文件，也可以选 zip / ipa 包 —— 会自动解出包内所有 .aud / .amr。")
                } else {
                    ThinSeparator().padding(.leading, 16)
                    BoundedMediaList(files: model.imported,
                                     selected: model.selectedSource,
                                     badge: { $0.origin }) { file in
                        model.selectedSource = file.path
                        model.result = nil
                        model.errorText = nil
                    }
                }

                if !model.importLog.isEmpty {
                    ThinSeparator().padding(.leading, 16)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(logRows.indices, id: \.self) { i in
                            Text(logRows[i])
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Palette.secondary)
                                .lineLimit(2)
                        }
                        if model.importLog.count > 3 {
                            Button {
                                showAllLogs.toggle()
                            } label: {
                                Text(showAllLogs ? "收起" : "更多 \(model.importLog.count - 3) 条")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Palette.ink)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    // MARK: - Action

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "③ 确认覆盖")

            CardBox {
                VStack(alignment: .leading, spacing: 12) {
                    summaryRow("源", model.selectedSourceFile)
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Palette.tertiary)
                        Text("以目标文件名写入，仅替换内容")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.tertiary)
                    }
                    .padding(.leading, 38)
                    summaryRow("目标", model.selectedTargetFile)

                    ThinSeparator()

                    Button {
                        confirmReplace = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 15, weight: .semibold))
                            Text("覆盖文件")
                                .font(.system(size: 16, weight: .semibold))
                            Spacer(minLength: 0)
                            Text(model.canReplace ? "就绪" : "待选择")
                                .font(.system(size: 12))
                                .opacity(0.65)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 15)
                        .frame(maxWidth: .infinity)
                        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canReplace)
                    .opacity(model.canReplace ? 1 : 0.38)
                }
            }

            if let error = model.errorText {
                InlineNotice(text: error, tone: Palette.danger)
            }
            if let result = model.result {
                resultCard(result)
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("覆盖走 wq_write_from_file：先备份目标，再截断并流式写入，因此目标路径、文件名和 inode 都不变，正在持有该文件的 App 也能读到新内容。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Floating confirm dock: stays one tap away no matter how long the
    /// candidate lists are.
    private var replaceDock: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.selectedTargetFile?.name ?? "未选择目标")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.selectedTargetFile == nil ? Palette.tertiary : Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.selectedSourceFile.map { "← " + $0.name } ?? "未选择源")
                    .font(.system(size: 10))
                    .foregroundStyle(model.selectedSourceFile == nil ? Palette.tertiary : Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            Button {
                confirmReplace = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                    Text("覆盖")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!model.canReplace)
            .opacity(model.canReplace ? 1 : 0.32)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.55), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.16), radius: 18, x: 0, y: 6)
    }

    // MARK: - Actions

    private func loadManualSource() {
        let normalized = BookmarkStore.normalized(manualPath)
        guard normalized.hasPrefix("/"), normalized.count > 1 else {
            model.errorText = "请输入以 / 开头的绝对路径"
            return
        }
        model.errorText = nil
        model.setSourceDirectory(path: normalized, title: "")
    }

    // MARK: - Small pieces

    private func dirRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.placeholder)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private func summaryRow(_ label: String, _ file: MediaFile?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .frame(width: 28, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                if let file {
                    Text(file.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(file.sizeText) · \(file.origin)")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                } else {
                    Text("未选择")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func emptyHint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 14))
                .foregroundStyle(Palette.tertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private func pill(_ title: String, _ system: String, tone: Color = Palette.ink) -> some View {
        HStack(spacing: 6) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Palette.placeholder, in: Capsule())
    }

    private func resultCard(_ result: ReplaceFileModel.ReplaceResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.ok ? "checkmark.seal" : "exclamationmark.triangle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(result.ok ? Palette.ink : Palette.danger)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(result.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background((result.ok ? Palette.ink : Palette.danger).opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Height-capped, self-scrolling list
//
// A target / source directory can hold 100+ audio files. Rendering them all
// inline turns the page into a multi-screen scroll where the confirm card is
// far away, so the list is capped at `collapsedRows` rows and gets its own
// scroll view. "展开全部" grows it inside the same card.
private struct BoundedMediaList: View {
    let files: [MediaFile]
    let selected: String?
    var badge: (MediaFile) -> String?
    let onPick: (MediaFile) -> Void

    @State private var expanded = false
    @State private var showSearch = false
    @State private var query = ""

    private let rowHeight: CGFloat = 50
    private let collapsedRows: Int = 4

    private var filtered: [MediaFile] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return files }
        return files.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.relative.localizedCaseInsensitiveContains(q)
        }
    }

    private var listHeight: CGFloat {
        if expanded { return 420 }
        return min(CGFloat(filtered.count) * rowHeight, CGFloat(collapsedRows) * rowHeight)
    }

    private var summaryText: String {
        if filtered.count != files.count {
            return "匹配 \(filtered.count) / \(files.count) 个"
        }
        return "按最新时间 · 共 \(files.count) 个"
    }

    var body: some View {
        VStack(spacing: 0) {
            if files.count > collapsedRows {
                header
            }

            if showSearch {
                searchField
            }

            if filtered.isEmpty {
                emptyRow
            } else {
                ScrollView(.vertical, showsIndicators: expanded) {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered.indices, id: \.self) { i in
                            if i > 0 {
                                ThinSeparator().padding(.leading, 16)
                            }
                            PickRow(file: filtered[i],
                                    selected: selected == filtered[i].path,
                                    badge: badge(filtered[i])) {
                                onPick(filtered[i])
                            }
                        }
                    }
                }
                .frame(height: listHeight)
                .scrollBounceBehavior(.basedOnSize)
                .clipped()
                .overlay(alignment: .bottom) {
                    if !expanded && filtered.count > collapsedRows && !showSearch {
                        LinearGradient(colors: [Color.white.opacity(0), Color.white.opacity(0.92)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 14)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(summaryText)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showSearch.toggle()
                    if !showSearch { query = "" }
                }
            } label: {
                Image(systemName: showSearch ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(showSearch ? Palette.ink : Palette.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(expanded ? "收起" : "展开全部")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Palette.placeholder, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.tertiary)
            TextField("按文件名筛选", text: $query)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.ink)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.placeholder, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var emptyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 13))
                .foregroundStyle(Palette.tertiary)
            Text("没有匹配「\(query)」的文件")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
    }
}

// MARK: - Selectable row

private struct PickRow: View {
    let file: MediaFile
    let selected: Bool
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? Palette.ink : Palette.tertiary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 5) {
                        Text(file.sizeText)
                        if !file.dateText.isEmpty {
                            Text("·")
                            Text(file.dateText)
                        }
                        if let badge, !badge.isEmpty, badge != file.name {
                            Text("·")
                            Text(badge)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 4)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.ink)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Confirm sheet
//
// Rendered as a short bottom sheet so the destructive button lands under the
// thumb instead of a system dialog anchored at the top of the screen.
private struct ReplaceConfirmSheet: View {
    let source: MediaFile
    let target: MediaFile
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("确认覆盖这个文件？")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                fileLine(label: "源", file: source, strong: false)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.tertiary)
                    Text("以目标文件名写入，仅替换内容")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiary)
                }
                .padding(.leading, 30)
                fileLine(label: "目标", file: target, strong: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.placeholder.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text("原文件会自动备份；目标路径、文件名和 inode 都不变。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)

            Spacer(minLength: 0)

            Button {
                dismiss()
                onConfirm()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 15, weight: .semibold))
                    Text("覆盖 \(target.name)")
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
                .frame(maxWidth: .infinity)
                .background(Palette.danger, in: Capsule())
            }
            .buttonStyle(.plain)

            Button("取消") { dismiss() }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Palette.card)
    }

    private func fileLine(label: String, file: MediaFile, strong: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .frame(width: 22, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 13.5, weight: strong ? .semibold : .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("\(file.sizeText) · \(file.origin)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}
