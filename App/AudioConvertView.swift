import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PhotosUI

/// 「音频转换」工具：把 mp3 / mp4 等带音轨的媒体转成 AMR-NB / AMR-WB（.amr）
/// 或 SILK v3（.aud，微信 / QQ 语音格式），与「替换文件」工具配套。
/// 源文件支持三种来源：粘贴路径、文件选择器、相册选视频。
struct AudioConvertView: View {
    @State private var inputPath = ""
    @State private var outputPath = ""
    @State private var outputEdited = false
    @State private var format: AudioOutputFormat = .silk
    @State private var busy = false
    @State private var busyText = ""
    @State private var progress: Double = 0
    @State private var errorText: String?
    @State private var notice: String?
    @State private var result: ConvertResult?
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false

    struct ConvertResult {
        let path: String
        let sizeText: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                sourceCard
                formatCard
                outputCard
                convertCard

                if let result {
                    resultCard(result)
                }
                if let notice {
                    InlineNotice(text: notice, tone: Palette.secondary)
                }
                if let errorText {
                    InlineNotice(text: errorText, tone: Palette.danger)
                }

                Text("AMR-NB：12.2 kbps / 8 kHz，兼容性最好；AMR-WB：23.85 kbps / 16 kHz，更清晰；SILK .aud：25 kbps / 24 kHz，微信 / QQ 语音格式。源文件不会被修改。")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)

                Spacer(minLength: 120)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .background(Palette.background)
        .enableInteractivePop()
        .glassNavigationBar(title: "音频转换")
        .overlay(alignment: .center) {
            if busy {
                VStack(spacing: 12) {
                    ProgressView(value: progress)
                        .frame(width: 220)
                    Text(busyText)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.audio, .movie],
                      allowMultipleSelection: false) { result in
            handleFilePick(result)
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker { picked in
                showPhotoPicker = false
                if let url = picked {
                    setInput(url.path)
                    notice = nil
                } else {
                    notice = "没有选中视频"
                }
            }
        }
    }

    // MARK: - Source card

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "源文件")

            HStack(spacing: 10) {
                PickButton(system: "folder", title: "文件") {
                    showFilePicker = true
                }
                PickButton(system: "photo.on.rectangle", title: "相册") {
                    showPhotoPicker = true
                }
                PickButton(system: "doc.on.clipboard", title: "粘贴路径") {
                    if let clip = UIPasteboard.general.string, !clip.isEmpty {
                        setInput(clip.trimmingCharacters(in: .whitespacesAndNewlines))
                    } else {
                        notice = "剪贴板里没有路径"
                    }
                }
            }

            TextField("/path/to/voice.mp3 或 .mp4", text: $inputPath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(12)
                .background(Palette.placeholder, in: RoundedRectangle(cornerRadius: 12))
                .disabled(busy)
                .onChange(of: inputPath) { _, newValue in
                    if !outputEdited { autoFillOutput(from: newValue) }
                }

            if !inputPath.isEmpty {
                Text("源：\(inputPath)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.035), radius: 12, x: 0, y: 4)
    }

    // MARK: - Format card

    private var formatCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "输出格式")
            Picker("输出格式", selection: $format) {
                Text("AMR-NB (.amr)").tag(AudioOutputFormat.nb)
                Text("AMR-WB (.amr)").tag(AudioOutputFormat.wb)
                Text("微信 .aud").tag(AudioOutputFormat.silk)
            }
            .pickerStyle(.segmented)
            .tint(Palette.ink)
            .disabled(busy)
            .onChange(of: format) { _, _ in
                if !outputEdited { autoFillOutput(from: inputPath) }
            }

            Text(formatHint)
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.035), radius: 12, x: 0, y: 4)
    }

    private var formatHint: String {
        switch format {
        case .nb: return "AMR-NB 12.2 kbps / 8 kHz 单声道，微信语音同参数，兼容性最好"
        case .wb: return "AMR-WB 23.85 kbps / 16 kHz 单声道，音质明显更清晰"
        case .silk: return "SILK v3 25 kbps / 24 kHz 单声道，微信 / QQ 的 .aud 语音格式"
        }
    }

    // MARK: - Output card

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "输出路径")
            TextField("/path/to/voice.aud", text: $outputPath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(12)
                .background(Palette.placeholder, in: RoundedRectangle(cornerRadius: 12))
                .disabled(busy)
                .onChange(of: outputPath) { _, _ in outputEdited = true }

            Text(outputEdited ? "输出路径已手动修改" : "自动输出：粘贴的源文件写回同目录；从文件 / 相册选择的写入本 App 文档目录")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.035), radius: 12, x: 0, y: 4)
    }

    private var convertCard: some View {
        Button {
            convert()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.plus")
                Text("开始转换")
                Spacer()
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Palette.ink)
        }
        .buttonStyle(.plain)
        .disabled(busy || inputPath.isEmpty)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.035), radius: 12, x: 0, y: 4)
    }

    private func resultCard(_ result: ConvertResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(hex: 0x3E7D4E))
                Text("转换完成")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            Text("输出 \(result.sizeText)")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
            Text(result.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.tertiary)
                .lineLimit(4)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                SmallAction(system: "doc.on.doc", title: "复制路径") {
                    UIPasteboard.general.string = result.path
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.035), radius: 12, x: 0, y: 4)
    }

    // MARK: - Input handling

    private func setInput(_ path: String) {
        inputPath = path
        outputEdited = false
        autoFillOutput(from: path)
        clearResult()
    }

    private func handleFilePick(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorText = "选择文件失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("pick-\(UUID().uuidString)-\(url.lastPathComponent)")
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                setInput(dest.path)
                notice = nil
            } catch {
                errorText = "无法读取所选文件：\(error.localizedDescription)"
            }
        }
    }

    private func clearResult() {
        result = nil
        errorText = nil
        notice = nil
        progress = 0
    }

    private func autoFillOutput(from input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return }
        let ext = AudioConverter.fileExtension(for: format)
        let output: String

        if trimmed.hasPrefix(tempPrefix) {
            // 文件 / 相册选择进来的临时文件 → 输出到本 App 文档目录
            let name = ((trimmed as NSString).lastPathComponent as NSString).deletingPathExtension
            output = documentsAudioForgeDir + "/\(name).\(ext)"
        } else {
            // 粘贴的沙盒路径 → 写回同目录
            let base = (trimmed as NSString).deletingPathExtension
            output = ((base as NSString).appendingPathExtension(ext) ?? base + "." + ext)
        }
        outputEdited = false
        outputPath = output
    }

    private var tempPrefix: String { FileManager.default.temporaryDirectory.path }
    private var documentsAudioForgeDir: String {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSHomeDirectory()
        return (docs as NSString).appendingPathComponent("AudioForge")
    }

    // MARK: - Convert

    private func convert() {
        guard !busy else { return }
        let input = inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard input.hasPrefix("/"), input.count > 1 else {
            errorText = "源文件必须是 / 开头的绝对路径"
            return
        }
        guard output.hasPrefix("/") else {
            errorText = "输出路径必须是 / 开头的绝对路径"
            return
        }
        if output == input {
            errorText = "输出路径不能与源文件相同"
            return
        }

        busy = true
        busyText = "读取源文件…"
        progress = 0
        errorText = nil
        notice = nil
        result = nil

        let sourcePath = input
        let destPath = output
        let sourceName = (sourcePath as NSString).lastPathComponent
        let inOwnSandbox = destPath.hasPrefix(NSHomeDirectory())

        func finish(error: String) {
            DispatchQueue.main.async {
                busy = false
                progress = 0
                errorText = error
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // 沙盒外的文件 AVFoundation 读不到，先经桥接把字节复制到本沙盒。
            let raw = XCTFileOps.readData(at: sourcePath, maxBytes: 500_000_000)
            guard let data = raw["data"] as? Data else {
                finish(error: raw["error"] as? String ?? "读取源文件失败")
                return
            }

            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("aud-convert-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                finish(error: "无法创建临时目录：\(error.localizedDescription)")
                return
            }
            defer { try? FileManager.default.removeItem(at: dir) }

            let tempInput = dir.appendingPathComponent(sourceName.isEmpty ? "source" : sourceName)
            let tempOutput = dir.appendingPathComponent("out.bin")
            do {
                try data.write(to: tempInput)
            } catch {
                finish(error: "临时文件写入失败：\(error.localizedDescription)")
                return
            }

            DispatchQueue.main.async { busyText = "正在编码…" }

            do {
                try AudioConverter.convertMedia(at: tempInput, to: tempOutput,
                                                format: format, progress: { value in
                    DispatchQueue.main.async { progress = value }
                })
            } catch {
                finish(error: error.localizedDescription)
                return
            }

            // 目标目录：本 App 文档目录需要先创建
            if inOwnSandbox {
                try? FileManager.default.createDirectory(
                    atPath: (destPath as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true)
            }

            // 写入目标：自己沙盒直接写；外部容器先建空壳再覆盖（保持权限）。
            do {
                if inOwnSandbox {
                    try FileManager.default.removeItem(atPath: destPath)
                    try FileManager.default.copyItem(at: tempOutput, to: URL(fileURLWithPath: destPath))
                } else {
                    if !FileManager.default.fileExists(atPath: destPath) {
                        if let err = XCTFileOps.createFile(at: destPath, text: "") {
                            finish(error: "无法在目标目录创建文件：\(err)")
                            return
                        }
                    }
                    if let err = XCTFileOps.overwriteFile(at: destPath, withFileAt: tempOutput.path) {
                        finish(error: "写入输出文件失败：\(err)")
                        return
                    }
                }
            } catch {
                finish(error: "写入输出文件失败：\(error.localizedDescription)")
                return
            }

            let attrs = XCTFileOps.attributes(at: destPath)
            let size = attrs["大小"] ?? "-"
            DispatchQueue.main.async {
                busy = false
                progress = 1
                self.result = ConvertResult(path: destPath, sizeText: size)
            }
        }
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

// MARK: - 本页专用小按钮

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

// MARK: - 相册视频选择（PHPicker，无需相册权限）

private struct PhotoPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker

        init(_ parent: PhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else {
                DispatchQueue.main.async { self.parent.onPick(nil) }
                return
            }
            let type = UTType.movie.identifier
            if provider.hasItemConformingToTypeIdentifier(type) {
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                    var copied: URL?
                    if let url {
                        let dest = FileManager.default.temporaryDirectory
                            .appendingPathComponent("pick-\(UUID().uuidString)-\(url.lastPathComponent)")
                        try? FileManager.default.copyItem(at: url, to: dest)
                        copied = dest
                    }
                    DispatchQueue.main.async { self.parent.onPick(copied) }
                }
            } else {
                DispatchQueue.main.async { self.parent.onPick(nil) }
            }
        }
    }
}
