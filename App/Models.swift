import Foundation
import SwiftUI

// MARK: - Value types

struct AppRecord: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
}

struct DirEntry: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let kind: String
    let bytes: Int64
    let statOK: Bool
    /// Unix mtime, 0 when wq_stat could not read the entry.
    let mtime: TimeInterval
    let ext: String

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var sizeText: String {
        guard kind == "file" else { return "" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    var dateText: String {
        guard mtime > 0 else { return "" }
        return Self.dateFormatter.string(from: Date(timeIntervalSince1970: mtime))
    }

    var typeText: String {
        switch kind {
        case "dir": return "文件夹"
        case "link": return "链接"
        case "other": return "其它"
        default: return ext.isEmpty ? "文件" : ext.uppercased()
        }
    }
}

/// One navigation unit used by every tab, so bookmarks and quick-jump can
/// open the same directory browser as the app list.
///
/// `root` is the deepest path we know we have a sandbox extension for. Going
/// "up" is only allowed while the parent is still inside that root: the
/// `/Containers/Data/Application` directory itself is NOT granted, so pushing
/// it (or anything above it) produced an error and let the user keep pushing
/// forever. A route opened directly from a bookmark sets root == path, which
/// makes it a dead end upwards by construction.
struct PathRoute: Hashable {
    let path: String
    let root: String
    let title: String

    init(path: String, root: String? = nil, title: String) {
        self.path = BookmarkStore.normalized(path)
        self.root = BookmarkStore.normalized(root ?? path)
        self.title = title
    }
}

struct Bookmark: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var path: String
    var createdAt: Date = Date()
}

// MARK: - Persistent bookmarks

final class BookmarkStore: ObservableObject {
    @Published private(set) var items: [Bookmark] = []
    private let key = "SandboxAccess.bookmarks.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Bookmark].self, from: data) {
            items = saved
        }
    }

    static func normalized(_ raw: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("/var/") { p = "/private" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    func isBookmarked(path: String) -> Bool {
        let p = Self.normalized(path)
        return items.contains { $0.path == p }
    }

    @discardableResult
    func add(title: String, path: String) -> Bool {
        let p = Self.normalized(path)
        guard p.hasPrefix("/"), p.count > 1 else { return false }
        guard !items.contains(where: { $0.path == p }) else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? (p as NSString).lastPathComponent : trimmed
        items.insert(Bookmark(title: name, path: p), at: 0)
        save()
        return true
    }

    /// Add when absent, remove when already present. Returns the new state.
    @discardableResult
    func toggle(title: String, path: String) -> Bool {
        let p = Self.normalized(path)
        if let index = items.firstIndex(where: { $0.path == p }) {
            items.remove(at: index)
            save()
            return false
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        items.insert(Bookmark(title: trimmed.isEmpty ? (p as NSString).lastPathComponent : trimmed, path: p), at: 0)
        save()
        return true
    }

    func rename(id: UUID, title: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items[index].title = trimmed
        save()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Settings

final class AccessSettings: ObservableObject {
    private let key = "SandboxAccess.fullScan.v1"
    private let catalogKey = "SandboxAccess.catalogIcons.v1"

    @Published var fullScan: Bool {
        didSet {
            UserDefaults.standard.set(fullScan, forKey: key)
            XCTContainerBridge.setFullScanAllowed(fullScan)
        }
    }

    /// CoreUI extraction from Assets.car is what produces real icons on
    /// iOS 26; it can be disabled if a malformed catalog causes a crash.
    @Published var catalogIcons: Bool {
        didSet {
            UserDefaults.standard.set(catalogIcons, forKey: catalogKey)
            XCTContainerBridge.setCatalogIconsEnabled(catalogIcons)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        fullScan = defaults.object(forKey: key) as? Bool ?? true
        catalogIcons = defaults.object(forKey: catalogKey) as? Bool ?? true
        XCTContainerBridge.setFullScanAllowed(fullScan)
        XCTContainerBridge.setCatalogIconsEnabled(catalogIcons)
    }
}

// MARK: - Directory sorting (persisted, shared by every browser)

enum SortKey: String, CaseIterable, Identifiable {
    case name
    case size
    case date
    case type

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .size: return "大小"
        case .date: return "修改时间"
        case .type: return "类型"
        }
    }

    var system: String {
        switch self {
        case .name: return "textformat.abc"
        case .size: return "internaldrive"
        case .date: return "clock"
        case .type: return "doc.on.doc"
        }
    }
}

final class SortPreferences: ObservableObject {
    // Bumped to v2 so the new "newest first" default is not shadowed by the
    // preferences an earlier build already wrote to UserDefaults.
    private static let prefix = "SandboxAccess.sort.v2."

    @Published var key: SortKey {
        didSet { UserDefaults.standard.set(key.rawValue, forKey: Self.prefix + "key") }
    }
    @Published var ascending: Bool {
        didSet { UserDefaults.standard.set(ascending, forKey: Self.prefix + "ascending") }
    }
    @Published var foldersFirst: Bool {
        didSet { UserDefaults.standard.set(foldersFirst, forKey: Self.prefix + "foldersFirst") }
    }

    init() {
        let defaults = UserDefaults.standard
        // Default view: newest first, folders interleaved with files by date.
        key = SortKey(rawValue: defaults.string(forKey: Self.prefix + "key") ?? "") ?? .date
        ascending = defaults.object(forKey: Self.prefix + "ascending") as? Bool ?? false
        foldersFirst = defaults.object(forKey: Self.prefix + "foldersFirst") as? Bool ?? false
    }

    var summary: String {
        "\(key.title) · \(ascending ? "升序" : "降序")\(foldersFirst ? " · 文件夹优先" : "")"
    }

    /// Folders stay on top regardless of direction (standard file-manager
    /// behaviour); the chosen direction applies inside each group. Name is
    /// always the deterministic tiebreaker.
    func sorted(_ entries: [DirEntry]) -> [DirEntry] {
        entries.sorted { a, b in
            let aDir = a.kind == "dir", bDir = b.kind == "dir"
            if foldersFirst && aDir != bDir { return aDir }

            let result: ComparisonResult
            switch key {
            case .name:
                result = Self.compareName(a.name, b.name)
            case .size:
                result = a.bytes == b.bytes ? .orderedSame
                    : (a.bytes < b.bytes ? .orderedAscending : .orderedDescending)
            case .date:
                result = a.mtime == b.mtime ? .orderedSame
                    : (a.mtime < b.mtime ? .orderedAscending : .orderedDescending)
            case .type:
                result = Self.compareName(a.typeText, b.typeText)
            }

            if result == .orderedSame {
                return Self.compareName(a.name, b.name) == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func compareName(_ a: String, _ b: String) -> ComparisonResult {
        a.localizedStandardCompare(b)
    }
}

// MARK: - App list state

final class FileListModel: ObservableObject {
    @Published var apps: [AppRecord] = []
    @Published var busy = false
    @Published var status = "就绪"
    @Published var errorText: String?
    @Published var diagnostics = ""
    @Published var appGroup = "未检测"
    @Published var systemVersion = "未检测"
    @Published var supported = false
    @Published var containerCount = 0
    @Published var declined = false
    private var hasLoaded = false

    func refreshIfNeeded() {
        if !hasLoaded { refresh() }
    }

    func refresh() {
        guard !busy else { return }
        hasLoaded = true
        busy = true
        status = "正在获取应用容器…"
        errorText = nil
        appGroup = XCTContainerBridge.appGroup() ?? "未提供（签名缺少 App Group）"
        systemVersion = XCTContainerBridge.systemVersion()
        supported = XCTContainerBridge.containerAccessAvailable()

        DispatchQueue.global(qos: .userInitiated).async {
            let rows = XCTContainerBridge.applications(refresh: true)
            let message = XCTContainerBridge.lastError()
            let log = XCTContainerBridge.diagnostics()
            var records: [AppRecord] = rows.map { row in
                let id = row["id"] ?? ""
                return AppRecord(id: id, name: row["name"] ?? id, path: row["path"] ?? "")
            }
            records.sort {
                let a = Self.rank($0.id), b = Self.rank($1.id)
                if a != b { return a < b }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            let count = XCTContainerBridge.lastContainerCount()
            let wasDeclined = XCTContainerBridge.lastScanWasDeclined()
            DispatchQueue.main.async {
                self.apps = records
                self.diagnostics = log
                self.errorText = message
                self.containerCount = count
                self.declined = wasDeclined
                self.status = "\(records.count) 个可访问应用 / \(count) 个容器路径"
                self.busy = false
            }
        }
    }

    func stop() {
        XCTContainerBridge.stopFullScan()
        status = "已请求停止扫描"
    }

    private static func rank(_ id: String) -> Int {
        if id == "com.tencent.xin" { return 0 }
        if id == "com.tencent.qy.xin" { return 1 }
        if id.hasPrefix("com.tencent.xin") { return 2 }
        if id.hasPrefix("com.tencent.qy.xin") { return 3 }
        return id.hasPrefix("com.tencent") ? 4 : 5
    }
}

// MARK: - Per-app access types (Filza-style)

struct AccessTypeRecord: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let path: String
    let kind: String
    let readOnly: Bool
}

// MARK: - File pasteboard (copy / move between directories)

enum PasteMode: String { case copy, move }

final class ClipboardStore: ObservableObject {
    @Published var copiedPath: String?
    @Published var pasteMode: PasteMode = .copy

    func copy(_ path: String) { copiedPath = path; pasteMode = .copy }
    func cut(_ path: String) { copiedPath = path; pasteMode = .move }
    func clear() { copiedPath = nil }
    var has: Bool { copiedPath != nil }
    var fileName: String {
        (copiedPath as NSString?)?.lastPathComponent ?? ""
    }
}

// MARK: - File viewer target

struct FileTarget: Hashable {
    let path: String
    let name: String
    let kind: String
}
