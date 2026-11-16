import Foundation
import SwiftUI

// MARK: - One selectable audio / temp file

struct MediaFile: Identifiable, Hashable {
    let path: String
    let name: String
    /// Path relative to the directory (or import root) it came from.
    let relative: String
    let bytes: Int64
    let mtime: TimeInterval
    /// Shown as a badge: bookmark title, directory name, or package name.
    let origin: String

    var id: String { path }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var dateText: String {
        guard mtime > 0 else { return "" }
        return Self.dateFormatter.string(from: Date(timeIntervalSince1970: mtime))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}

// MARK: - Replace-file tool state

/// Drives the 「替换文件」 tool: a bookmarked directory is scanned for
/// `*.aud_tmp` targets, and a `.aud` / `.amr` file from elsewhere (another
/// sandbox directory, an imported file, or an imported zip / ipa) is written
/// over a chosen target *under the target's own name*.
final class ReplaceFileModel: ObservableObject {

    /// Targets offered for replacement.
    static let targetSuffixes = [".aud_tmp"]
    /// Sources accepted for the replacement audio.
    static let sourceSuffixes = [".aud", ".amr"]

    // Target side
    @Published var targetDir: String?
    @Published var targetDirTitle = ""
    @Published var targets: [MediaFile] = []
    @Published var selectedTarget: String?
    @Published var targetRecursive = false

    // Source side (sandbox directory browsing)
    @Published var sourceDir: String?
    @Published var sourceDirTitle = ""
    @Published var sources: [MediaFile] = []
    @Published var selectedSource: String?
    @Published var recursive = true

    // Source side (imported files / packages)
    @Published var imported: [MediaFile] = []
    @Published var importLog: [String] = []

    // Status
    @Published var busy = false
    @Published var busyText = ""
    @Published var errorText: String?
    @Published var notice: String?
    @Published var result: ReplaceResult?

    struct ReplaceResult {
        let ok: Bool
        let title: String
        let detail: String
    }

    // MARK: Derived

    var selectedTargetFile: MediaFile? {
        guard let selectedTarget else { return nil }
        return targets.first { $0.path == selectedTarget }
    }

    var selectedSourceFile: MediaFile? {
        guard let selectedSource else { return nil }
        return (sources + imported).first { $0.path == selectedSource }
    }

    var canReplace: Bool {
        !busy && selectedTargetFile != nil && selectedSourceFile != nil
    }

    private var importedRoot: String {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSHomeDirectory()
        return (docs as NSString).appendingPathComponent("ReplaceInbox")
    }

    private var inboxDir: String { (importedRoot as NSString).appendingPathComponent("inbox") }
    private var packsDir: String { (importedRoot as NSString).appendingPathComponent("packs") }

    // MARK: Target directory

    func setTargetDirectory(path: String, title: String) {
        let normalized = BookmarkStore.normalized(path)
        targetDir = normalized
        targetDirTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (normalized as NSString).lastPathComponent
            : title
        selectedTarget = nil
        targets = []
        result = nil
        notice = nil
        errorText = nil
        loadTargets()
    }

    func loadTargets() {
        guard let dir = targetDir, !busy else { return }
        busy = true
        busyText = "读取目标目录…"
        errorText = nil
        let deep = targetRecursive
        DispatchQueue.global(qos: .userInitiated).async {
            var rows = XCTFileOps.listFiles(at: dir, suffixes: Self.targetSuffixes, recursive: deep)
            var autoDeep = false
            // Voice caches usually keep the temp audio one or two levels down,
            // so a shallow scan that comes back empty is worth one deeper pass
            // instead of telling the user "no files here".
            if rows.isEmpty && !deep {
                let deepRows = XCTFileOps.listFiles(at: dir, suffixes: Self.targetSuffixes, recursive: true)
                if !deepRows.isEmpty {
                    rows = deepRows
                    autoDeep = true
                }
            }
            let files = Self.newestFirst(rows, origin: "目标目录")
            DispatchQueue.main.async {
                self.busy = false
                self.targets = files
                if autoDeep { self.targetRecursive = true }
                if files.isEmpty {
                    self.notice = "这个目录里没有 .aud_tmp 文件"
                } else if autoDeep {
                    self.notice = "已在子目录中找到 \(files.count) 个 .aud_tmp"
                }
                // Newest first (see newestFirst). When several .aud_tmp files
                // exist, the most recently modified one is selected
                // automatically, so the common case needs no manual picking.
                if let current = self.selectedTarget,
                   files.contains(where: { $0.path == current }) {
                    // keep the user's choice
                } else {
                    self.selectedTarget = files.first?.path
                }
            }
        }
    }

    // MARK: Source directory

    func setSourceDirectory(path: String, title: String) {
        let normalized = BookmarkStore.normalized(path)
        sourceDir = normalized
        sourceDirTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (normalized as NSString).lastPathComponent
            : title
        selectedSource = nil
        sources = []
        loadSources()
    }

    func loadSources() {
        guard let dir = sourceDir, !busy else { return }
        busy = true
        busyText = "读取源目录…"
        errorText = nil
        let deep = recursive
        let label = sourceDirTitle
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = XCTFileOps.listFiles(at: dir, suffixes: Self.sourceSuffixes, recursive: deep)
            let files = Self.newestFirst(rows, origin: label)
            DispatchQueue.main.async {
                self.busy = false
                self.sources = files
                if files.isEmpty {
                    self.notice = "这个目录里没有 .aud / .amr 文件"
                }
                if let current = self.selectedSource,
                   !files.contains(where: { $0.path == current }) {
                    self.selectedSource = nil
                }
            }
        }
    }

    func toggleRecursive() {
        recursive.toggle()
        loadSources()
    }

    func toggleTargetRecursive() {
        targetRecursive.toggle()
        loadTargets()
    }

    // MARK: Imported files

    func refreshImported() {
        let root = importedRoot
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            let rows = XCTFileOps.listFiles(at: root, suffixes: Self.sourceSuffixes, recursive: true)
            let files = Self.newestFirst(rows, origin: "导入")
            DispatchQueue.main.async {
                self.imported = files
                if let current = self.selectedSource,
                   !files.contains(where: { $0.path == current }),
                   !self.sources.contains(where: { $0.path == current }) {
                    self.selectedSource = nil
                }
            }
        }
    }

    /// Copies picked files into our own container. `.zip` / `.ipa` are
    /// unpacked and only their `.aud` / `.amr` entries are kept, so a whole
    /// package becomes a flat, browsable list of replacement candidates.
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !busy else { return }
        busy = true
        busyText = "导入文件…"
        errorText = nil
        notice = nil
        result = nil

        let root = importedRoot
        let inbox = inboxDir
        let packs = packsDir

        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: inbox, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: packs, withIntermediateDirectories: true)

            var log: [String] = []
            var audioFound = 0

            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                let name = url.lastPathComponent
                let ext = url.pathExtension.lowercased()

                if ext == "zip" || ext == "ipa" {
                    let staged = (inbox as NSString).appendingPathComponent(name)
                    try? fm.removeItem(atPath: staged)
                    do {
                        try fm.copyItem(at: url, to: URL(fileURLWithPath: staged))
                    } catch {
                        log.append("✗ \(name)：无法读取该包")
                        continue
                    }
                    let dest = (packs as NSString).appendingPathComponent((name as NSString).deletingPathExtension)
                    try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
                    let outcome = XCTFileOps.unzipArchive(at: staged, into: dest, suffixes: Self.sourceSuffixes)
                    if let files = outcome["files"] as? [String], !files.isEmpty {
                        log.append("✓ \(name)：解出 \(files.count) 个音频")
                        audioFound += files.count
                    } else {
                        let reason = outcome["error"] as? String ?? "包内没有 .aud / .amr"
                        log.append("✗ \(name)：\(reason)")
                    }
                    try? fm.removeItem(atPath: staged)
                } else {
                    let dest = (inbox as NSString).appendingPathComponent(name)
                    try? fm.removeItem(atPath: dest)
                    do {
                        try fm.copyItem(at: url, to: URL(fileURLWithPath: dest))
                        log.append("✓ \(name)：已导入")
                        audioFound += 1
                    } catch {
                        log.append("✗ \(name)：导入失败")
                    }
                }
            }

            let rows = XCTFileOps.listFiles(at: root, suffixes: Self.sourceSuffixes, recursive: true)
            let files = Self.newestFirst(rows, origin: "导入")

            DispatchQueue.main.async {
                self.busy = false
                self.importLog = log
                self.imported = files
                self.notice = audioFound > 0
                    ? "导入完成，共 \(files.count) 个可选音频"
                    : "没有导入任何音频"
                if let first = files.first, self.selectedSource == nil {
                    self.selectedSource = first.path
                }
            }
        }
    }

    func clearImported() {
        let root = importedRoot
        busy = true
        busyText = "清空导入…"
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            if let children = try? fm.contentsOfDirectory(atPath: root) {
                for child in children {
                    try? fm.removeItem(atPath: (root as NSString).appendingPathComponent(child))
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.imported = []
                self.importLog = []
                self.notice = "已清空导入的文件"
                if let current = self.selectedSource,
                   !self.sources.contains(where: { $0.path == current }) {
                    self.selectedSource = nil
                }
            }
        }
    }

    // MARK: Replace

    /// Writes `source` over `target` byte-for-byte. The target keeps its own
    /// name (`2..aud_tmp` stays `2..aud_tmp`); only the content changes.
    func replace() {
        guard let source = selectedSourceFile,
              let target = selectedTargetFile,
              !busy else { return }

        busy = true
        busyText = "正在覆盖 \(target.name)…"
        errorText = nil
        notice = nil
        result = nil

        let sourcePath = source.path
        let targetPath = target.path
        let sourceName = source.name
        let targetName = target.name

        DispatchQueue.global(qos: .userInitiated).async {
            let failure = XCTFileOps.overwriteFile(at: targetPath, withFileAt: sourcePath)
            let attrs = XCTFileOps.attributes(at: targetPath)
            DispatchQueue.main.async {
                self.busy = false
                if let failure {
                    self.errorText = failure
                    self.result = ReplaceResult(ok: false,
                                                title: "覆盖失败",
                                                detail: "\(sourceName) → \(targetName)\n\(failure)")
                } else {
                    let size = attrs["大小"] ?? ""
                    self.result = ReplaceResult(ok: true,
                                                title: "已覆盖 \(targetName)",
                                                detail: "来源 \(sourceName)（\(source.sizeText)）\n目标现在 \(size)，文件名保持不变")
                }
                self.loadTargets()
            }
        }
    }

    // MARK: Helpers

    /// The app default is "newest first", so every list this tool shows uses
    /// the same order as the file browser.
    private static func newestFirst(_ rows: [[String: Any]], origin: String) -> [MediaFile] {
        rows.map { row -> MediaFile in
            let file = media(from: row, fallbackOrigin: origin)
            guard origin == "导入" else { return file }
            // ReplaceInbox/packs/<包名>/... -> badge shows which package it
            // came from, so a dozen imported packages stay distinguishable.
            let parts = file.relative.components(separatedBy: "/")
            let tag = (parts.count >= 3 && parts[0] == "packs") ? parts[1] : "导入"
            return MediaFile(path: file.path,
                             name: file.name,
                             relative: file.relative,
                             bytes: file.bytes,
                             mtime: file.mtime,
                             origin: tag)
        }
        .sorted { a, b in
            if a.mtime != b.mtime { return a.mtime > b.mtime }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private static func media(from row: [String: Any], fallbackOrigin: String) -> MediaFile {
        let path = row["path"] as? String ?? ""
        let name = row["name"] as? String
            ?? (path as NSString).lastPathComponent
        let relative = row["relative"] as? String ?? name
        let bytes = (row["bytes"] as? NSNumber)?.int64Value ?? 0
        let mtime = (row["mtime"] as? NSNumber)?.doubleValue ?? 0
        return MediaFile(path: path,
                         name: name,
                         relative: relative,
                         bytes: bytes,
                         mtime: mtime,
                         origin: fallbackOrigin)
    }
}
