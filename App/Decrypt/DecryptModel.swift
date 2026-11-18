import Foundation
import UIKit

/// 「应用砸壳」页的状态：应用列表、单次解密进度、日志与输出文件。
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

    @Published var apps: [DecryptAppRef] = []
    @Published var outputs: [OutputIPA] = []
    @Published var loading = false
    @Published var running = false
    @Published var progress: Double = 0
    @Published var status = "就绪"
    @Published var errorText: String?
    @Published var notice: String?
    @Published var logs: [String] = []
    @Published var elapsedText = ""
    @Published var currentApp: DecryptAppRef?
    @Published var lastResult: OutputIPA?

    private let queue = DispatchQueue(label: "wqtool.decrypt", qos: .userInitiated)
    private var hasLoadedApps = false

    var canStart: Bool { !running && !loading }

    // MARK: - 应用列表

    func loadAppsIfNeeded() {
        loadOutputs()
        guard !hasLoadedApps else { return }
        loadApps()
    }

    func loadApps() {
        guard !loading, !running else { return }
        hasLoadedApps = true
        loading = true
        status = "正在读取已安装应用…"
        queue.async {
            let rows = XCTContainerBridge.applications(refresh: false)
            let list = rows.compactMap { row -> DecryptAppRef? in
                guard let id = row["id"], !id.isEmpty else { return nil }
                let name = row["name"]?.isEmpty == false ? row["name"]! : id
                return DecryptAppRef(id: id, name: name)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self.apps = list
                self.loading = false
                self.status = list.isEmpty ? "没有可访问的应用" : "\(list.count) 个应用"
            }
        }
    }

    // MARK: - 开始砸壳

    func start(_ app: DecryptAppRef) {
        guard canStart else { return }
        guard !DecryptService.shared.isRunning else {
            errorText = DecryptError.busy.localizedDescription
            return
        }

        currentApp = app
        running = true
        progress = 0
        logs = []
        errorText = nil
        notice = nil
        lastResult = nil
        elapsedText = ""
        status = "定位应用包…"
        let started = Date()

        queue.async {
            guard let path = XCTContainerBridge.bundlePath(bundleID: app.id) else {
                DispatchQueue.main.async {
                    self.running = false
                    self.status = "未开始"
                    self.errorText = "找不到 \(app.name) 的应用包路径"
                }
                return
            }
            self.append("应用：\(app.name)（\(app.id)）")
            self.append("Bundle：\(path)")

            do {
                let outcome = try DecryptService.shared.decrypt(
                    bundlePath: path,
                    appName: app.name,
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
