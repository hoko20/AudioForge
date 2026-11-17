import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PhotosUI

/// 固定 Swift 侧名称，避免依赖 ObjC 枚举 case 的自动导入名。
/// 对应 AudioConverter.h：0 = AMR-NB，1 = AMR-WB（silk 是 AudioOutputFormatSilk
/// 的原生导入名，无需重复定义）。
private extension AudioOutputFormat {
    static let nb = AudioOutputFormat(rawValue: 0)!
    static let wb = AudioOutputFormat(rawValue: 1)!
}

/// 「音频转换」工具：把 mp3 / mp4 等带音轨的媒体转成 AMR-NB / AMR-WB（.amr）
/// 或 SILK v3（.aud，微信 / QQ 语音格式）。产物统一落在本 App 文档目录的
/// AudioForge 下，并以下方文件列表展示，支持滑动重命名 / 删除。
struct AudioConvertView: View {
    @State private var inputPath = ""
    @State private var format: AudioOutputFormat = .silk
    @State private var busy = false
    @State private var importing = false
    @State private var busyText = ""
    @State private var progress: Double = 0
    @State private var errorText: String?
    @State private var notice: String?

    @State private var files: [OutputFile] = []
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var renameTarget: OutputFile?
    @State private var playTarget: OutputFile?
    @State private var renameText = ""
    @State private var showRename = false
    @State private var noticeToken = UUID()
    @State private var errorToken = UUID()

    private struct OutputFile: Identifiable, Equatable {
        let url: URL
        let sizeBytes: Int64
        let date: Date

        var id: String { url.path }
        var name: String { url.lastPathComponent }

        var sizeText: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }

        var dateText: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            return formatter.string(from: date)
        }
    }

    private var isBusy: Bool { busy || importing }

    var body: some View {
        List {
            Section {
                sourceCard.cardRow(top: 12)
            }

            Section {
                formatCard.cardRow()
            }

            Section {
                convertButton.cardRow()
            }

            if let errorText {
                Section {
                    InlineNotice(text: errorText, tone: Palette.danger).cardRow()
                }
            }
            if let notice {
                Section {
                    InlineNotice(text: notice, tone: Palette.secondary).cardRow()
                }
            }

            Section {
                if files.isEmpty {
                    emptyRow
                } else {
                    ForEach(files) { file in
                        fileRow(file)
                    }
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "输出文件")
                    Spacer()
                    Text(files.isEmpty ? "AudioForge 目录" : "共 \(files.count) 个 · 点按播放 · 右滑管理")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiary)
                }
                .textCase(nil)
                .padding(.horizontal, 20)
                .padding(.top, 6)
            }

            Section {
                Text("AMR-NB：12.2 kbps / 8 kHz，兼容性最好；AMR-WB：23.85 kbps / 16 kHz，更清晰；SILK .aud：25 kbps / 24 kHz，微信 / QQ 语音格式。源文件不会被修改。")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
                    .cardRow()
            }

            Section {
                Color.clear
                    .frame(height: 70)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .background(Palette.background)
        .refreshable { loadFiles() }
        .enableInteractivePop()
        .glassNavigationBar(title: "音频转换")
        .onAppear { loadFiles() }
        .onChange(of: notice) { _, value in
            guard value != nil else { return }
            noticeToken = UUID()
            let token = noticeToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if noticeToken == token {
                    withAnimation(.easeInOut(duration: 0.25)) { notice = nil }
                }
            }
        }
        .onChange(of: errorText) { _, value in
            guard value != nil else { return }
            errorToken = UUID()
            let token = errorToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if errorToken == token {
                    withAnimation(.easeInOut(duration: 0.25)) { errorText = nil }
                }
            }
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentPicker { url in
                showFilePicker = false
                guard let url else { return }
                setInput(url.path)
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker(onStart: {
                showPhotoPicker = false
                importing = true
                busyText = "正在导入视频…"
            }, onPick: { url in
                importing = false
                busyText = ""
                guard let url else {
                    notice = "没有选中视频或视频无法读取"
                    return
                }
                setInput(url.path)
            })
        }
        .sheet(item: $playTarget) { file in
            AudioPlayerSheet(url: file.url)
        }
        .alert("重命名", isPresented: $showRename) {
            TextField("文件名", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("确定") { commitRename() }
        } message: {
            Text("仅修改文件名，扩展名保持不变")
        }
    }

    // MARK: - 源文件

    private var sourceCard: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(text: "源文件")

                HStack(spacing: 10) {
                    PickButton(system: "folder", title: "文件") {
                        showFilePicker = true
                    }
                    .disabled(isBusy)

                    PickButton(system: "photo.on.rectangle", title: "相册") {
                        showPhotoPicker = true
                    }
                    .disabled(isBusy)

                    PickButton(system: "doc.on.clipboard", title: "粘贴路径") {
                        if let clip = UIPasteboard.general.string?
                            .trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
                            setInput(clip)
                        } else {
                            notice = "剪贴板里没有路径"
                        }
                    }
                    .disabled(isBusy)
                }

                TextField("mp3 / mp4 路径，或点上方按钮选择", text: $inputPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(12)
                    .background(Palette.placeholder, in: RoundedRectangle(cornerRadius: 12))
                    .disabled(isBusy)
                    .onSubmit { convert() }

                if !inputPath.isEmpty {
                    Text("源：\(inputPath)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - 输出格式

    private var formatCard: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "输出格式")

                Picker("输出格式", selection: $format) {
                    Text("AMR-NB (.amr)").tag(AudioOutputFormat.nb)
                    Text("AMR-WB (.amr)").tag(AudioOutputFormat.wb)
                    Text("微信 .aud").tag(AudioOutputFormat.silk)
                }
                .pickerStyle(.segmented)
                .tint(Palette.ink)
                .disabled(isBusy)

                Text(formatHint)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
            }
        }
    }

    private var formatHint: String {
        switch format {
        case .nb: return "AMR-NB 12.2 kbps / 8 kHz 单声道，微信语音同参数，兼容性最好"
        case .wb: return "AMR-WB 23.85 kbps / 16 kHz 单声道，音质明显更清晰"
        case .silk: return "SILK v3 25 kbps / 24 kHz 单声道，微信 / QQ 的 .aud 语音格式"
        @unknown default: return "未知格式"
        }
    }

    // MARK: - 转换按钮

    private var convertButton: some View {
        Button {
            convert()
        } label: {
            VStack(spacing: isBusy ? 12 : 0) {
                HStack(spacing: 8) {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Palette.ink)
                    } else {
                        Image(systemName: "waveform.badge.plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    Text(convertTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .contentTransition(.numericText())
                }
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity)

                if isBusy {
                    Group {
                        if progress > 0 {
                            ProgressView(value: progress)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                    }
                    .tint(Palette.ink)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color.black.opacity(0.035), radius: 12, x: 0, y: 4)
            .opacity(canConvert || isBusy ? 1 : 0.45)
            .animation(.easeInOut(duration: 0.2), value: isBusy)
        }
        .buttonStyle(.plain)
        .disabled(!canConvert)
    }

    /// 按钮文案跟随状态变化，不再弹出居中的加载浮层。
    private var convertTitle: String {
        if importing { return "正在导入视频…" }
        if busy {
            if progress > 0 {
                return "正在编码 \(Int((progress * 100).rounded()))%"
            }
            return busyText.isEmpty ? "正在转换…" : busyText
        }
        return "开始转换"
    }

    private var canConvert: Bool {
        !isBusy && inputPath.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
    }

    // MARK: - 输出文件列表

    private var emptyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 15))
                .foregroundStyle(Palette.tertiary)
            Text("还没有生成的文件，转换后会出现在这里")
                .font(.system(size: 12))
                .foregroundStyle(Palette.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .cardRow()
    }

    private func fileRow(_ file: OutputFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 36, height: 36)
                .background(Palette.placeholder, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(file.sizeText) · \(file.dateText)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
            }

            Spacer(minLength: 0)

            Image(systemName: "play.circle")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(Palette.warning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { playTarget = file }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(role: .destructive) {
                delete(file)
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                beginRename(file)
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            .tint(Palette.warning)
        }
        .contextMenu {
            Button {
                playTarget = file
            } label: {
                Label("播放", systemImage: "play.circle")
            }
            Button {
                UIPasteboard.general.string = file.url.path
                notice = "已复制路径"
            } label: {
                Label("复制路径", systemImage: "doc.on.doc")
            }
            Button {
                beginRename(file)
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) {
                delete(file)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .cardRow(top: 5, bottom: 5)
    }

    // MARK: - 文件列表读写

    private var documentsAudioForgeDir: String {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSHomeDirectory()
        return (docs as NSString).appendingPathComponent("AudioForge")
    }

    private func loadFiles() {
        let dir = documentsAudioForgeDir
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        let allowed: Set<String> = ["aud", "amr"]

        var found: [OutputFile] = []
        for name in names where allowed.contains((name as NSString).pathExtension.lowercased()) {
            let path = (dir as NSString).appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let date = (attrs?[.modificationDate] as? Date) ?? .distantPast
            found.append(OutputFile(url: URL(fileURLWithPath: path), sizeBytes: size, date: date))
        }
        files = found.sorted { $0.date > $1.date }
    }

    private func beginRename(_ file: OutputFile) {
        renameTarget = file
        renameText = (file.name as NSString).deletingPathExtension
        showRename = true
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        var newName = renameText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !newName.isEmpty else {
            errorText = "文件名不能为空"
            renameTarget = nil
            return
        }
        let ext = target.url.pathExtension
        if (newName as NSString).pathExtension.isEmpty, !ext.isEmpty {
            newName += "." + ext
        }
        let dest = target.url.deletingLastPathComponent().appendingPathComponent(newName)
        if dest.path != target.url.path, FileManager.default.fileExists(atPath: dest.path) {
            errorText = "同名文件已存在"
            renameTarget = nil
            return
        }
        do {
            try FileManager.default.moveItem(at: target.url, to: dest)
            notice = "已重命名为 \(newName)"
            errorText = nil
            loadFiles()
        } catch {
            errorText = "重命名失败：\(error.localizedDescription)"
        }
        renameTarget = nil
    }

    private func delete(_ file: OutputFile) {
        do {
            try FileManager.default.removeItem(at: file.url)
            notice = "已删除 \(file.name)"
            errorText = nil
            loadFiles()
        } catch {
            errorText = "删除失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 输入处理

    private func setInput(_ path: String) {
        inputPath = path
        errorText = nil
        notice = nil
        progress = 0
    }

    private func uniqueDestination(base: String, ext: String) -> String {
        let dir = documentsAudioForgeDir
        let fm = FileManager.default
        let name = base.isEmpty ? "audio" : base
        var candidate = "\(dir)/\(name).\(ext)"
        var index = 2
        while fm.fileExists(atPath: candidate) {
            candidate = "\(dir)/\(name) \(index).\(ext)"
            index += 1
        }
        return candidate
    }

    // MARK: - 转换

    private func convert() {
        guard canConvert else { return }
        let sourcePath = inputPath.trimmingCharacters(in: .whitespacesAndNewlines)

        busy = true
        busyText = "准备中…"
        progress = 0
        errorText = nil
        notice = nil

        let baseName = ((sourcePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let ext = AudioConverter.fileExtension(for: format)

        // 本 App 沙盒内的文件（文件 / 相册选择的都在 tmp 里）直接交给 AVFoundation，
        // 不再整份读进内存再写一遍——那样又慢又容易在大视频上失败。
        let isLocal = sourcePath.hasPrefix(NSHomeDirectory())
            || sourcePath.hasPrefix("/private" + NSHomeDirectory())

        func finish(error: String) {
            DispatchQueue.main.async {
                busy = false
                progress = 0
                busyText = ""
                errorText = error
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let targetDir = documentsAudioForgeDir
            try? fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

            let dir = fm.temporaryDirectory
                .appendingPathComponent("aud-convert-\(UUID().uuidString)", isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                finish(error: "无法创建临时目录：\(error.localizedDescription)")
                return
            }
            defer { try? fm.removeItem(at: dir) }

            let inputURL: URL
            if isLocal {
                inputURL = URL(fileURLWithPath: sourcePath)
            } else {
                DispatchQueue.main.async { busyText = "读取源文件…" }
                let raw = XCTFileOps.readData(at: sourcePath, maxBytes: 500_000_000)
                guard let data = raw["data"] as? Data else {
                    finish(error: raw["error"] as? String ?? "读取源文件失败")
                    return
                }
                let tempInput = dir.appendingPathComponent((sourcePath as NSString).lastPathComponent)
                do {
                    try data.write(to: tempInput)
                } catch {
                    finish(error: "临时文件写入失败：\(error.localizedDescription)")
                    return
                }
                inputURL = tempInput
            }

            let tempOutput = dir.appendingPathComponent("out.bin")
            DispatchQueue.main.async { busyText = "正在编码…" }

            do {
                try AudioConverter.convertMedia(at: inputURL, to: tempOutput,
                                                format: format, progress: { value in
                    DispatchQueue.main.async { progress = value }
                })
            } catch {
                finish(error: error.localizedDescription)
                return
            }

            let destPath = uniqueDestination(base: baseName, ext: ext)
            do {
                try fm.copyItem(at: tempOutput, to: URL(fileURLWithPath: destPath))
            } catch {
                finish(error: "写入输出文件失败：\(error.localizedDescription)")
                return
            }

            let bytes = (try? fm.attributesOfItem(atPath: destPath))?[.size] as? NSNumber
            let size = ByteCountFormatter.string(fromByteCount: bytes?.int64Value ?? 0, countStyle: .file)
            let name = (destPath as NSString).lastPathComponent

            DispatchQueue.main.async {
                busy = false
                progress = 1
                busyText = ""
                notice = "已生成 \(name) · \(size)"
                loadFiles()
            }
        }
    }
}

// MARK: - 行样式

private extension View {
    func cardRow(top: CGFloat = 6, bottom: CGFloat = 6) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 20, bottom: bottom, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

// MARK: - 源选择按钮

private struct PickButton: View {
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

// MARK: - 文件选择（UIDocumentPicker，asCopy 直接拿到本地副本）

private struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.audio, .movie, .audiovisualContent],
            asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: DocumentPicker

        init(_ parent: DocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onPick(nil)
        }
    }
}

// MARK: - 相册视频选择（PHPicker，无需相册权限）

private struct PhotoPicker: UIViewControllerRepresentable {
    let onStart: () -> Void
    let onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        // .current 直接取原文件，避免系统转码导出（大视频能快好几倍）
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoPicker

        init(_ parent: PhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.onStart()

            guard let provider = results.first?.itemProvider,
                  provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else {
                DispatchQueue.main.async { self.parent.onPick(nil) }
                return
            }

            // loadFileRepresentation 提供的 URL 只在回调内有效，必须当场复制出来
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                var copied: URL?
                if let url {
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("pick-\(UUID().uuidString)-\(url.lastPathComponent)")
                    if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                        copied = dest
                    }
                }
                DispatchQueue.main.async { self.parent.onPick(copied) }
            }
        }
    }
}
