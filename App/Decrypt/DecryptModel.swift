import Foundation

/// 「应用砸壳」页的状态：导入 IPA、单次解密进度、日志与输出文件。
final class DecryptModel: ObservableObject {

    struct OutputIPA: Identifiable, Equatable {
        let url: URL
        let sizeBytes: Int64
        let date: Date
        var id: String { url.path }
        var name: String { url.lastPathComponent }
        var sizeText: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
        var dateText: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            return formatter.string(from: date)
        }
    }

    @Published var outputs: [OutputIPA] = []
    @Published var running = false
    @Published var progress: Double = 0
    @Published var status = "就绪"
    @Published var errorText: String?
    @Published var notice: String?
    @Published var logs: [String] = []
    @Published var elapsedText = ""
    @Published var currentName: String?
    @Published var lastResult: OutputIPA?

    private let queue = DispatchQueue(label: "wqtool.decrypt", qos: .userInitiated)

    var canStart: Bool { !running }

    // MARK: - 导入并开始

    func start(ipaURL: URL) {
        guard canStart else { return }
        guard !DecryptService.shared.isRunning else {
            errorText = DecryptError.busy.localizedDescription
            return
        }

        let scoped = ipaURL.startAccessingSecurityScopedResource()
        currentName = ipaURL.lastPathComponent
        running = true
        progress = 0
        logs = []
        errorText = nil
        notice = nil
        lastResult = nil
        elapsedText = ""
        status = "准备中…"
        let started = Date()

        queue.async {
            defer {
                if scoped { ipaURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let outcome = try DecryptService.shared.decrypt(
                    ipaURL: ipaURL,
                    progress: { fraction, text in
                        DispatchQueue.main.async {
                            self.progress = max(0, min(fraction, 1))
                            self.status = text
                        }
                    },
                    log: { line in self.append(line) }
                )
                let size = (try? FileManager.default
                    .attributesOfItem(atPath: outcome.ipaURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                let row = OutputIPA(url: outcome.ipaURL, sizeBytes: size, date: Date())
                DispatchQueue.main.async {
                    self.running = false
                    self.progress = 1
                    self.status = "完成"
                    self.elapsedText = String(format: "%.1f 秒", outcome.elapsed)
                    self.lastResult = row
                    self.notice = "已解密 \(outcome.decrypted) 个可执行文件，输出 \(row.name)"
                    self.loadOutputs()
                }
            } catch {
                let elapsed = Date().timeIntervalSince(started)
                DispatchQueue.main.async {
                    self.running = false
                    self.status = "失败"
                    self.elapsedText = String(format: "%.1f 秒", elapsed)
                    self.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.loadOutputs()
                }
            }
        }
    }

    func cancel() {
        DecryptService.shared.cancel()
        status = "正在取消…"
    }

    // MARK: - 输出文件

    func loadOutputs() {
        let directory = DecryptService.decryptedDirectory()
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            outputs = []
            return
        }
        outputs = items
            .filter { $0.pathExtension.lowercased() == "ipa" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return OutputIPA(url: url,
                                 sizeBytes: Int64(values?.fileSize ?? 0),
                                 date: values?.contentModificationDate ?? Date())
            }
            .sorted { $0.date > $1.date }
    }

    func delete(_ item: OutputIPA) {
        try? FileManager.default.removeItem(at: item.url)
        if lastResult?.url == item.url { lastResult = nil }
        loadOutputs()
    }

    // MARK: - 日志

    private func append(_ line: String) {
        DispatchQueue.main.async {
            self.logs.append(line)
            if self.logs.count > 400 {
                self.logs.removeFirst(self.logs.count - 400)
            }
        }
    }
}
