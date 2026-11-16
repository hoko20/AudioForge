import SwiftUI
import UIKit
import ImageIO
import PDFKit
import AVKit
import CoreFoundation

/// Type-aware viewer for a single file opened from `DirectoryView`.
///
/// The sandbox path we hold is NOT readable by UIKit directly (it lives in
/// another app's container, reached only through the worse_query extension), so
/// every byte goes through `XCTFileOps`: raw data via `readData`, text via
/// `readText`. Decoders that need a real file (PDFKit / AVPlayer / sqlite3) get
/// a copy in our own temp directory first.
///
/// Routing mirrors Filza: images preview, plist/JSON render as a structured
/// tree, SQLite databases open as a table browser, PDFs open in PDFKit, audio
/// and video play inline, text is editable (read-only inside `.app`).
struct FileView: View {
    let target: FileTarget

    @State private var phase: LoadPhase = .loading
    @State private var rawText = ""
    @State private var editableText = ""
    @State private var edited = false
    @State private var errorText: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var showInfo = false
    @State private var infoDict: [String: String]?
    @State private var showShare = false
    @State private var shareURL: URL?
    @State private var plistMode = 0          // 0 = 结构树, 1 = 原始文本
    @State private var tempFile: URL?

    // MARK: - Derived

    private var writable: Bool {
        let parts = (target.path as NSString).pathComponents
        return !parts.contains(where: { $0.hasSuffix(".app") })
    }

    private var ext: String {
        (target.path as NSString).pathExtension.lowercased()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard

                if let errorText {
                    InlineNotice(text: errorText, tone: Palette.danger)
                }
                if let notice {
                    InlineNotice(text: notice, tone: Palette.secondary)
                }

                contentBody

                Spacer(minLength: 120)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .background(Palette.background)
        .enableInteractivePop()
        .glassNavigationBar(title: target.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    if writable && edited {
                        Button {
                            saveText()
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .foregroundStyle(Palette.ink)
                        }
                        .disabled(busy)
                    }
                    Button {
                        loadInfo()
                    } label: {
                        Image(systemName: "info.circle").foregroundStyle(Palette.ink)
                    }
                }
            }
        }
        .overlay(alignment: .center) {
            if busy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在保存…")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
            }
        }
        .sheet(isPresented: $showInfo) { infoSheet }
        .sheet(isPresented: $showShare) {
            if let url = shareURL { ShareSheet(items: [url]) }
        }
        .task { loadContent() }
    }

    // MARK: - Header

    private var headerCard: some View {
        CardBox(radius: 20, padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Palette.placeholder)
                        Image(systemName: phase.symbol)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Palette.ink)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(target.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(2)
                        Text(kindLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.tertiary)
                    }
                    Spacer(minLength: 6)

                    if !writable {
                        Text("只读")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.warning)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Palette.warning.opacity(0.1), in: Capsule())
                    }
                }

                ThinSeparator()

                Text(target.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(4)
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    SmallAction(system: "doc.on.doc", title: "复制路径") {
                        UIPasteboard.general.string = target.path
                        notice = "路径已复制"
                    }
                    SmallAction(system: "square.and.arrow.up", title: "导出") { export() }
                    SmallAction(system: "info.circle", title: "信息") { loadInfo() }
                }
            }
        }
    }

    private var kindLabel: String {
        switch phase {
        case .image: return "图片"
        case .pdf: return "PDF 文档"
        case .media(_, let video): return video ? "视频" : "音频"
        case .plist(_, _): return "属性列表 / JSON"
        case .sqlite(let tables): return "SQLite 数据库 · \(tables.count) 张表"
        case .text: return "文本"
        case .binary: return "二进制"
        case .failed: return "无法预览"
        case .loading: return "读取中"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentBody: some View {
        switch phase {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("正在读取文件…")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
            }
            .padding(16)

        case .image(let img):
            VStack(alignment: .leading, spacing: 8) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("\(Int(img.size.width)) × \(Int(img.size.height)) pt")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
            }

        case .pdf(let url):
            PDFKitView(url: url)
                .frame(height: 560)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .background(Palette.card)

        case .media(let url, let video):
            MediaPlayerView(url: url)
                .frame(height: video ? 320 : 110)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .background(Palette.card)

        case .plist(let node, let raw):
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $plistMode) {
                    Text("结构").tag(0)
                    Text("文本").tag(1)
                }
                .pickerStyle(.segmented)

                if plistMode == 0 {
                    PlistTreeView(root: node)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    editorOrText(raw)
                }
            }

        case .sqlite(let tables):
            VStack(alignment: .leading, spacing: 12) {
                if tables.isEmpty {
                    EmptyCard(text: "没有可读取的表，或这不是一个 SQLite 数据库。")
                } else {
                    ForEach(tables) { SQLiteTableView(table: $0) }
                }
            }

        case .text(let truncated):
            VStack(alignment: .leading, spacing: 10) {
                editorOrText(rawText)
                if truncated {
                    Text("已显示前 1 MB，超出部分被截断。")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiary)
                }
            }

        case .binary:
            EmptyCard(text: "二进制文件，无法直接预览。可通过「导出」保存后用其它 App 打开。")

        case .failed(let msg):
            EmptyCard(text: msg)
        }
    }

    @ViewBuilder
    private func editorOrText(_ text: String) -> some View {
        if writable {
            TextEditor(text: $editableText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .frame(minHeight: 340)
                .padding(8)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onChange(of: editableText) { newValue in
                    if newValue != rawText { edited = true }
                }
        } else {
            ScrollView {
                Text(text)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 340)
            .padding(12)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Loading

    private func loadContent() {
        let path = target.path
        DispatchQueue.global(qos: .userInitiated).async {
            var kind = Self.kind(for: path)
            if kind == .binary {
                // Sniff a header so extension-less files still route correctly.
                if let head = XCTFileOps.readData(at: path, maxBytes: 64)["data"] as? Data {
                    if head.starts(with: Array("SQLite format 3\0".utf8)) { kind = .sqlite }
                    else if head.starts(with: Array("%PDF".utf8)) { kind = .pdf }
                    else if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { kind = .image }
                    else if head.starts(with: [0xFF, 0xD8, 0xFF]) { kind = .image }
                    else if head.starts(with: Array("GIF8".utf8)) { kind = .image }
                }
            }
            switch kind {
            case .image: self.loadImage(path)
            case .pdf: self.loadDoc(path, pdf: true)
            case .audio, .video: self.loadDoc(path, pdf: false)
            case .sqlite: self.loadSQLite(path)
            case .plist: self.loadPlist(path)
            case .json: self.loadJSON(path)
            case .text: self.loadText(path)
            case .binary: self.loadBinary(path)
            }
        }
    }

    private func loadImage(_ path: String) {
        let raw = XCTFileOps.readData(at: path, maxBytes: 200_000_000)
        guard let data = raw["data"] as? Data else {
            fail(raw["error"] as? String ?? "读取失败")
            return
        }
        if let img = Self.decodeImage(data) {
            DispatchQueue.main.async { self.phase = .image(img) }
        } else {
            DispatchQueue.main.async {
                self.errorText = "无法解码图片（文件可能损坏或格式不受支持）"
                self.phase = .binary
            }
        }
    }

    private func loadDoc(_ path: String, pdf: Bool) {
        let raw = XCTFileOps.readData(at: path, maxBytes: 300_000_000)
        guard let data = raw["data"] as? Data else {
            fail(raw["error"] as? String ?? "读取失败")
            return
        }
        guard let url = Self.writeTemp(data, name: target.name) else {
            fail("无法写入临时文件")
            return
        }
        let video = Self.isVideoExt(ext)
        DispatchQueue.main.async {
            self.tempFile = url
            self.phase = pdf ? .pdf(url) : .media(url, video: video)
        }
    }

    private func loadSQLite(_ path: String) {
        let raw = XCTFileOps.readData(at: path, maxBytes: 150_000_000)
        guard let data = raw["data"] as? Data else {
            fail(raw["error"] as? String ?? "读取失败（数据库可能过大）")
            return
        }
        guard let url = Self.writeTemp(data, name: target.name) else {
            fail("无法写入临时文件")
            return
        }
        let tables = SQLiteReader.read(url: url)
        DispatchQueue.main.async {
            self.tempFile = url
            self.phase = .sqlite(tables)
        }
    }

    private func loadPlist(_ path: String) {
        let raw = XCTFileOps.readData(at: path, maxBytes: 32_000_000)
        guard let data = raw["data"] as? Data else {
            fail(raw["error"] as? String ?? "读取失败")
            return
        }
        if let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            let node = buildPlistNode(obj)
            var rawText = ""
            if let xml = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0) {
                rawText = String(data: xml, encoding: .utf8) ?? ""
            }
            DispatchQueue.main.async {
                self.rawText = rawText
                self.editableText = rawText
                self.edited = false
                self.plistMode = 0
                self.phase = .plist(node, rawText)
            }
        } else {
            loadText(path)
        }
    }

    private func loadJSON(_ path: String) {
        let raw = XCTFileOps.readData(at: path, maxBytes: 32_000_000)
        guard let data = raw["data"] as? Data else {
            fail(raw["error"] as? String ?? "读取失败")
            return
        }
        if let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            let node = buildPlistNode(obj)
            let prettyData = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
            )
            let pretty = prettyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                self.rawText = pretty
                self.editableText = pretty
                self.edited = false
                self.plistMode = 0
                self.phase = .plist(node, pretty)
            }
        } else {
            loadText(path)
        }
    }

    private func loadText(_ path: String) {
        let result = XCTFileOps.readText(at: path, maxBytes: 1_000_000)
        if let err = result["error"] {
            fail(err)
            return
        }
        if let text = result["text"] {
            let truncated = text.count >= 1_000_000
            DispatchQueue.main.async {
                self.rawText = text
                self.editableText = text
                self.edited = false
                self.phase = .text(truncated: truncated)
            }
        } else {
            fail("未知读取错误")
        }
    }

    private func loadBinary(_ path: String) {
        DispatchQueue.main.async { self.phase = .binary }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { self.phase = .failed(message) }
    }

    // MARK: - Save

    private func saveText() {
        guard writable, edited else { return }
        busy = true
        let path = target.path
        let text = editableText
        DispatchQueue.global(qos: .userInitiated).async {
            let err = XCTFileOps.writeText(at: path, text: text)
            DispatchQueue.main.async {
                self.busy = false
                if let err = err {
                    self.notice = "保存失败：\(err)"
                } else {
                    self.rawText = text
                    self.edited = false
                    self.notice = "已保存"
                }
            }
        }
    }

    // MARK: - Info

    private func loadInfo() {
        let p = target.path
        infoDict = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let raw = XCTFileOps.attributes(at: p)
            var dict: [String: String] = [:]
            for (k, v) in raw { dict[k] = v as? String ?? "" }
            DispatchQueue.main.async {
                self.infoDict = dict
                self.showInfo = true
            }
        }
    }

    // MARK: - Export

    private func export() {
        busy = true
        let path = target.path
        let name = target.name
        DispatchQueue.global(qos: .userInitiated).async {
            let raw = XCTFileOps.readData(at: path, maxBytes: 500_000_000)
            DispatchQueue.main.async {
                self.busy = false
                guard let data = raw["data"] as? Data else {
                    self.notice = raw["error"] as? String ?? "导出失败"
                    return
                }
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                do {
                    try data.write(to: tmp)
                    self.shareURL = tmp
                    self.showShare = true
                } catch {
                    self.notice = "导出写入失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Info sheet

    @ViewBuilder
    private var infoSheet: some View {
        NavigationStack {
            ScrollView {
                if let dict = infoDict {
                    VStack(alignment: .leading, spacing: 12) {
                        if let message = dict["error"], dict.count <= 1 {
                            InlineNotice(text: message, tone: Palette.danger)
                            SmallAction(system: "arrow.clockwise", title: "重试") { loadInfo() }
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(dict.filter { $0.key != "error" }.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(k).font(.system(size: 14)).foregroundStyle(Palette.secondary)
                                            .frame(width: 92, alignment: .leading)
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

    // MARK: - Helpers

    private static func decodeImage(_ data: Data) -> UIImage? {
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return UIImage(cgImage: cg)
        }
        return UIImage(data: data)
    }

    private static func writeTemp(_ data: Data, name: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fv-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name.isEmpty ? "file" : name)
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private static func isVideoExt(_ e: String) -> Bool {
        ["mp4", "mov", "m4v", "3gp", "avi", "mkv", "webm"].contains(e)
    }

    private static func kind(for path: String) -> FileKind {
        let e = (path as NSString).pathExtension.lowercased()
        switch e {
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "bmp",
             "tif", "tiff", "ico", "icns", "avif":
            return .image
        case "plist", "mobileconfig", "strings", "entitlements", "xcent", "pbxproj":
            return .plist
        case "json", "geojson", "json5":
            return .json
        case "sqlite", "sqlite3", "db", "database", "sqlitedb":
            return .sqlite
        case "pdf":
            return .pdf
        case "mp3", "m4a", "wav", "aac", "caf", "aiff", "aif", "flac", "ogg", "opus":
            return .audio
        case "mp4", "mov", "m4v", "3gp", "avi", "mkv", "webm":
            return .video
        case "txt", "md", "markdown", "xml", "html", "htm", "css", "js", "mjs",
             "ts", "swift", "h", "m", "mm", "c", "cc", "cpp", "hpp", "py", "rb",
             "go", "rs", "java", "kt", "kts", "sh", "bash", "zsh", "yml", "yaml",
             "toml", "ini", "conf", "cfg", "log", "csv", "tsv", "sql", "rtf",
             "gitignore", "properties", "env":
            return .text
        default:
            return .binary
        }
    }
}

// MARK: - Phase

enum FileKind {
    case image, plist, json, sqlite, pdf, audio, video, text, binary
}

enum LoadPhase {
    case loading
    case image(UIImage)
    case pdf(URL)
    case media(URL, video: Bool)
    case plist(PlistNode, String)
    case sqlite([SQLiteTable])
    case text(truncated: Bool)
    case binary
    case failed(String)

    var symbol: String {
        switch self {
        case .loading: return "doc"
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .media(_, let video): return video ? "play.rectangle" : "music.note"
        case .plist: return "list.bullet.rectangle"
        case .sqlite: return "cylinder.split.1x2"
        case .text: return "doc.text"
        case .binary: return "lock.doc"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

// MARK: - Property list / JSON tree

indirect enum PlistNode {
    case string(String)
    case number(String)
    case bool(Bool)
    case date(String)
    case data(Int)
    case array([PlistNode])
    case dict([(String, PlistNode)])
}

func buildPlistNode(_ any: Any) -> PlistNode {
    if any is NSNull { return .string("null") }
    if let dict = any as? [String: Any] {
        return .dict(dict.keys.sorted().map { ($0, buildPlistNode(dict[$0]!)) })
    }
    if let arr = any as? [Any] {
        return .array(arr.map(buildPlistNode))
    }
    if let num = any as? NSNumber {
        if CFGetTypeID(num) == CFBooleanGetTypeID() { return .bool(num.boolValue) }
        return .number(num.stringValue)
    }
    if let s = any as? String { return .string(s) }
    if let d = any as? Date {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return .date(f.string(from: d))
    }
    if let data = any as? Data { return .data(data.count) }
    return .string(String(describing: any))
}

struct PlistTreeView: View {
    let root: PlistNode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PlistNodeRow(label: nil, node: root, depth: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PlistNodeRow: View {
    let label: String?
    let node: PlistNode
    let depth: Int

    var body: some View {
        switch node {
        case .dict(let items):
            group(title: label ?? "根", subtitle: "字典 \(items.count) 项") {
                ForEach(Array(items.enumerated()), id: \.offset) { entry in
                    PlistNodeRow(label: entry.element.0, node: entry.element.1, depth: depth + 1)
                }
            }
        case .array(let items):
            group(title: label ?? "根", subtitle: "数组 \(items.count) 项") {
                ForEach(Array(items.enumerated()), id: \.offset) { entry in
                    PlistNodeRow(label: "[\(entry.offset)]", node: entry.element, depth: depth + 1)
                }
            }
        default:
            scalar
        }
    }

    @ViewBuilder
    private func group<Content: View>(title: String, subtitle: String,
                                      @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.leading, 10)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.tertiary)
                Spacer(minLength: 4)
            }
            .padding(.vertical, 4)
        }
        .tint(Palette.secondary)
        .padding(.leading, CGFloat(depth) * 6)
    }

    private var scalar: some View {
        HStack(alignment: .top, spacing: 8) {
            if let label {
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
                    .frame(minWidth: 70, alignment: .leading)
            }
            Text(scalarText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(scalarColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .padding(.leading, CGFloat(depth) * 6 + 2)
    }

    private var scalarText: String {
        switch node {
        case .string(let s): return "\"\(s)\""
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .date(let d): return d
        case .data(let c): return "<\(c) 字节数据>"
        default: return ""
        }
    }

    private var scalarColor: Color {
        switch node {
        case .string: return Palette.ink
        case .number: return Color(red: 0.10, green: 0.45, blue: 0.80)
        case .bool: return Color(red: 0.72, green: 0.28, blue: 0.60)
        case .date: return Color(red: 0.20, green: 0.55, blue: 0.35)
        default: return Palette.secondary
        }
    }
}

// MARK: - SQLite browser

struct SQLiteTable: Identifiable {
    let id = UUID()
    let name: String
    let sql: String
    let columns: [String]
    let rows: [[String]]
    let truncated: Bool
}

enum SQLiteReader {
    static func read(url: URL, maxRows: Int = 200) -> [SQLiteTable] {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }

        var out: [SQLiteTable] = []
        var stmt: OpaquePointer?
        let listSQL = "SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
        guard sqlite3_prepare_v2(db, listSQL, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var defs: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            defs.append((colText(stmt, 0), colText(stmt, 1)))
        }
        sqlite3_finalize(stmt)

        for (name, sql) in defs {
            out.append(readTable(db: db, name: name, sql: sql, maxRows: maxRows))
        }
        return out
    }

    private static func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return "NULL" }
        guard let c = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: c)
    }

    private static func readTable(db: OpaquePointer?, name: String, sql: String, maxRows: Int) -> SQLiteTable {
        var columns: [String] = []
        var info: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\"\(name)\");", -1, &info, nil) == SQLITE_OK {
            while sqlite3_step(info) == SQLITE_ROW {
                columns.append(colText(info, 1))
            }
            sqlite3_finalize(info)
        }

        var rows: [[String]] = []
        var truncated = false
        var q: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT * FROM \"\(name)\" LIMIT \(maxRows + 1);", -1, &q, nil) == SQLITE_OK {
            let n = Int(sqlite3_column_count(q))
            while sqlite3_step(q) == SQLITE_ROW {
                if rows.count >= maxRows { truncated = true; break }
                var row: [String] = []
                for i in 0..<n {
                    var s = colText(q, Int32(i))
                    if s.count > 512 { s = String(s.prefix(512)) + "…" }
                    row.append(s)
                }
                rows.append(row)
            }
            sqlite3_finalize(q)
        }
        return SQLiteTable(name: name, sql: sql, columns: columns, rows: rows, truncated: truncated)
    }
}

struct SQLiteTableView: View {
    let table: SQLiteTable
    @State private var expanded = false
    private let cellWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: expanded ? "tablecells.fill" : "tablecells")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(table.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text("\(table.columns.count) 列 · \(table.rows.count)\(table.truncated ? "+" : "") 行")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondary)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ThinSeparator().padding(.leading, 16)
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(table.columns, id: \.self) { col in
                                Text(col)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.ink)
                                    .frame(width: cellWidth, alignment: .leading)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 10)
                            }
                        }
                        .background(Palette.placeholder)

                        ForEach(Array(table.rows.enumerated()), id: \.offset) { rowEntry in
                            HStack(spacing: 0) {
                                ForEach(Array(rowEntry.element.enumerated()), id: \.offset) { cellEntry in
                                    Text(cellEntry.element)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Palette.ink)
                                        .frame(width: cellWidth, alignment: .leading)
                                        .padding(.vertical, 6)
                                        .padding(.horizontal, 10)
                                        .textSelection(.enabled)
                                }
                            }
                            ThinSeparator()
                        }

                        if table.rows.isEmpty {
                            Text("（空表）")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.tertiary)
                                .padding(12)
                        }
                    }
                }

                if !table.sql.isEmpty {
                    Text(table.sql)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.placeholder.opacity(0.4))
                }
            }
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - PDF / media

struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = UIColor(Palette.card)
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

struct MediaPlayerView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Reusable small action button

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
