import SwiftUI

/// 「音频转换」工具：把 mp3 / mp4 等带音轨的媒体转成 .aud
/// （SILK v3，微信 / QQ 语音格式），可直接用于「替换文件」工具。
struct AudioConvertView: View {
    /// 输出目录可写、但 .aud 尚不存在时，先建空文件再覆盖写入。
    private let acceptedExts = [
        "mp3", "mp4", "m4a", "mov", "m4v", "wav", "aac",
        "flac", "aiff", "aif", "caf", "3gp", "ogg", "opus"
    ]

    @State private var inputPath = ""
    @State private var outputPath = ""
    @State private var outputEdited = false
    @State private var busy = false
    @State private var busyText = ""
    @State private var progress: Double = 0
    @State private var errorText: String?
    @State private var result: ConvertResult?

    struct ConvertResult {
        let path: String
        let sizeText: String
        let seconds: TimeInterval
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                inputCard
                outputCard
                convertCard

                if let result {
                    resultCard(result)
                }
                if let errorText {
                    InlineNotice(text: errorText, tone: Palette.danger)
                }

                Text("转换输出 24 kHz 单声道 SILK v3（25 kbps），与微信 .aud / .aud_tmp 同格式。源文件不会被修改。")
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
    }

    // MARK: - Cards

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "源文件")
            TextField("/path/to/voice.mp3 或 .mp4", text: $inputPath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(12)
                .background(Palette.placeholder, in: RoundedRectangle(cornerRadius: 12))
                .disabled(busy)
                .onChange(of: inputPath) { newValue in
                    if !outputEdited { autoFillOutput(from: newValue) }
                }

            HStack(spacing: 10) {
                SmallAction(system: "doc.on.clipboard", title: "粘贴") {
                    if let clip = UIPasteboard.general.string, !clip.isEmpty {
                        inputPath = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                SmallAction(system: "arrow.clockwise", title: "清空结果") {
                    clearResult()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.035), radius: 12, x: 0, y: 4)
    }

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
                .onChange(of: outputPath) { _ in outputEdited = true }

            Text(outputEdited ? "输出路径已手动修改" : "留空或未改动时，自动输出到源文件同目录、同名 .aud")
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
            Text("时长 \(Self.durationText(result.seconds)) · 输出 \(result.sizeText)")
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

    // MARK: - Logic

    private func autoFillOutput(from input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return }
        let dir = (trimmed as NSString).deletingPathExtension
        outputPath = ((dir as NSString).appendingPathExtension("aud") ?? dir + ".aud")
    }

    private func clearResult() {
        result = nil
        errorText = nil
        progress = 0
    }

    private func convert() {
        guard !busy else { return }
        let input = inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        var output = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (input as NSString).pathExtension.lowercased()

        guard input.hasPrefix("/"), input.count > 1 else {
            errorText = "源文件必须是 / 开头的绝对路径"
            return
        }
        guard acceptedExts.contains(ext) else {
            errorText = "不支持的扩展名 .\(ext)（支持：\(acceptedExts.joined(separator: " / "))）"
            return
        }
        if output.isEmpty {
            autoFillOutput(from: input)
            output = outputPath
        }
        if output == input {
            errorText = "输出路径不能与源文件相同"
            return
        }

        busy = true
        busyText = "读取源文件…"
        progress = 0
        errorText = nil
        result = nil

        let sourcePath = input
        let destPath = output
        let sourceName = (sourcePath as NSString).lastPathComponent

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
            let tempOutput = dir.appendingPathComponent("out.aud")
            do {
                try data.write(to: tempInput)
            } catch {
                finish(error: "临时文件写入失败：\(error.localizedDescription)")
                return
            }

            DispatchQueue.main.async { busyText = "正在编码…" }

            var encodeError: NSError?
            let started = Date()
            let ok = AudEncoder.convertMedia(at: tempInput, to: tempOutput,
                                             progress: { value in
                DispatchQueue.main.async { progress = value }
            }, error: &encodeError)
            guard ok else {
                finish(error: encodeError?.localizedDescription ?? "转换失败")
                return
            }

            // 目标文件不存在时先建空壳，再原样覆盖内容（保持目录内权限）。
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

            let size = XCTFileOps.attributes(at: destPath)["大小"] ?? "-"
            let seconds = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                busy = false
                progress = 1
                result = ConvertResult(path: destPath, sizeText: size, seconds: seconds)
            }
        }
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 本页专用小按钮（FileView 的 SmallAction 是 file-private，不能复用）。
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
