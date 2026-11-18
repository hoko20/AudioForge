import Foundation

/// 一次砸壳的结果。
struct DecryptOutcome {
    let ipaURL: URL
    let decrypted: Int
    let plain: Int
    let machO: Int
    let elapsed: TimeInterval
}

enum DecryptError: LocalizedError {
    case busy
    case cancelled
    case noAppGroup
    case invalidIPA(String)
    case noPayload
    case noSpace(Int64, Int64)
    case packFailed(String)

    var errorDescription: String? {
        switch self {
        case .busy: return "已有砸壳任务在进行"
        case .cancelled: return "已取消"
        case .noAppGroup:
            return "没有可用的 App Group：fairplayd 只接受 App Group 容器，请确认签名带 App Group 权限"
        case .invalidIPA(let detail): return "IPA 无法读取：\(detail)"
        case .noPayload: return "IPA 里没有 Payload/*.app"
        case .noSpace(let free, let needed):
            return "空间不足：可用 \(free) 字节，需要 \(needed) 字节"
        case .packFailed(let detail): return "打包 IPA 失败：\(detail)"
        }
    }
}

/// 本机 FairPlay 砸壳：导入一个未解密的 IPA，解包到 App Group，
/// 逐个 Mach-O 调用 FairPlayCore（mremap_encrypted + fairplayd），
/// 去掉 _CodeSignature 后重新打包成 IPA。
///
/// 机制与 iPadn（mengangs/ipadn，GPL-2.0-or-later）一致：
/// 只对本机已有 FairPlay 授权的可执行文件有效，不联网、不接触 Apple 账号。
final class DecryptService {

    static let shared = DecryptService()

    private let stateLock = NSLock()
    private var cancelledFlag = false
    private var runningFlag = false

    private init() {}

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runningFlag
    }

    func cancel() {
        stateLock.lock()
        cancelledFlag = true
        stateLock.unlock()
    }

    private var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelledFlag
    }

    // MARK: - 主流程

    func decrypt(ipaURL: URL,
                 progress: @escaping (Double, String) -> Void,
                 log: @escaping (String) -> Void) throws -> DecryptOutcome {

        stateLock.lock()
        if runningFlag {
            stateLock.unlock()
            throw DecryptError.busy
        }
        runningFlag = true
        cancelledFlag = false
        stateLock.unlock()
        defer {
            stateLock.lock()
            runningFlag = false
            stateLock.unlock()
        }

        let started = Date()
        guard let stagingRoot = Self.groupContainer() else {
            throw DecryptError.noAppGroup
        }
        let manager = FileManager.default
        let work = stagingRoot.appendingPathComponent("fpwork-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }

        log("IPA：\(ipaURL.lastPathComponent)")

        // 1. 读取 zip 目录。
        let reader: ZipReader
        do {
            reader = try ZipReader(url: ipaURL)
        } catch {
            throw DecryptError.invalidIPA(error.localizedDescription)
        }
        log("解包：\(reader.entries.count) 个条目 · \(Self.bytesText(Int64(reader.uncompressedBytes)))")

        let free = Self.freeSpace(at: stagingRoot)
        let needed = Int64(reader.uncompressedBytes) + 64 * 1024 * 1024
        if free > 0 && free < needed {
            throw DecryptError.noSpace(free, needed)
        }

        // 2. 解包到 App Group 暂存区（fairplayd 只认 App Group 路径）。
        progress(0.02, "解包 IPA…")
        let extractRoot = work.appendingPathComponent("ipa", isDirectory: true)
        do {
            try reader.extractAll(to: extractRoot,
                                  checkCancelled: { [weak self] in self?.isCancelled ?? false },
                                  progress: { written in
                let total = max(reader.uncompressedBytes, 1)
                let fraction = min(Double(written) / Double(total), 1)
                progress(0.02 + fraction * 0.33, "解包 IPA \(Int(fraction * 100))%")
            })
        } catch let zipError as ZipReader.ZipError {
            if case .cancelled = zipError { throw DecryptError.cancelled }
            throw DecryptError.invalidIPA(zipError.localizedDescription)
        }
        try checkCancelled()

        // 3. 找到 Payload 里的 .app。
        guard let appURL = Self.firstApp(in: extractRoot) else {
            throw DecryptError.noPayload
        }
        let appName = appURL.deletingPathExtension().lastPathComponent
        log("应用包：\(appURL.lastPathComponent)")

        // 4. 扫描 Mach-O。
        progress(0.36, "扫描可执行文件…")
        let binaries = scanMachO(in: appURL)
        let encrypted = binaries.filter { $0.encrypted }
        log("Mach-O：\(binaries.count) 个，其中加密 \(encrypted.count) 个")
        guard !binaries.isEmpty else {
            throw DecryptError.noPayload
        }

        // 5. 逐个解密。
        var decryptedCount = 0
        var processed = 0
        for binary in encrypted {
            try checkCancelled()
            let name = binary.url.lastPathComponent
            progress(0.36 + 0.4 * Double(processed) / Double(max(encrypted.count, 1)),
                     "解密 \(name)")
            log("解密 \(name) …")

            guard ensureSINF(for: binary.url, appRoot: appURL, log: log) else {
                log("  [失败] 缺少 SC_Info/\(name).sinf")
                processed += 1
                continue
            }

            let box = LogBox { line in log("  \(line)") }
            let context = Unmanaged.passUnretained(box).toOpaque()
            let result = binary.url.path.withCString { pointer in
                fp_decrypt_file(pointer, pointer, coreLogTrampoline, context)
            }
            if result == 0 {
                decryptedCount += 1
                log("  [完成] \(name)")
            } else if result == 1 {
                log("  [跳过] \(name) 未加密")
            } else {
                log("  [失败] \(name)")
            }
            processed += 1
        }
        try checkCancelled()

        // 6. 去签名。
        progress(0.78, "移除旧签名…")
        removeCodeSignatures(in: appURL, log: log)

        // 7. 校验 cryptid。
        let remaining = scanMachO(in: appURL).filter { $0.encrypted }.count
        if remaining > 0 {
            log("仍有 \(remaining) 个加密 Mach-O（可能缺少对应 SC_Info）")
        }

        // 8. 打包 IPA。
        progress(0.82, "打包 IPA…")
        let outputDirectory = Self.decryptedDirectory()
        try manager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = Self.uniqueOutputURL(in: outputDirectory, name: "\(appName)-decrypted")
        let total = Self.treeSize(appURL.path)
        var written: Int64 = 0
        do {
            let writer = try ZipWriter(url: outputURL, checkCancelled: { [weak self] in
                self?.isCancelled ?? false
            })
            try addDirectoryTree(appURL, relativeTo: appURL,
                                 zipPrefix: "Payload/\(appURL.lastPathComponent)",
                                 writer: writer, totalBytes: total,
                                 written: &written) { fraction in
                progress(0.82 + fraction * 0.16, "打包 IPA \(Int(fraction * 100))%")
            }
            try writer.finish()
        } catch let zipError as ZipWriter.ZipError {
            try? manager.removeItem(at: outputURL)
            if case .cancelled = zipError { throw DecryptError.cancelled }
            throw DecryptError.packFailed(zipError.localizedDescription)
        } catch {
            try? manager.removeItem(at: outputURL)
            throw DecryptError.packFailed(error.localizedDescription)
        }

        progress(0.99, "完成")
        let size = (try? manager.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        log("已生成：\(outputURL.lastPathComponent) · \(Self.bytesText(size))")

        return DecryptOutcome(ipaURL: outputURL,
                              decrypted: decryptedCount,
                              plain: binaries.count - encrypted.count,
                              machO: binaries.count,
                              elapsed: Date().timeIntervalSince(started))
    }

    // MARK: - 目录

    static func groupContainer() -> URL? {
        guard let group = XCTContainerBridge.appGroup(), !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    static func decryptedDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Decrypted", isDirectory: true)
    }

    private static func uniqueOutputURL(in directory: URL, name: String) -> URL {
        let manager = FileManager.default
        var candidate = directory.appendingPathComponent("\(name).ipa")
        var index = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) \(index).ipa")
            index += 1
        }
        return candidate
    }

    private static func firstApp(in root: URL) -> URL? {
        let payload = root.appendingPathComponent("Payload", isDirectory: true)
        if let items = try? FileManager.default.contentsOfDirectory(
            at: payload,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            if let app = items.first(where: { $0.pathExtension.lowercased() == "app" }) {
                return app
            }
        }
        // 有些 IPA 不按标准放 Payload，递归找第一个 .app。
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return nil }
        while let item = walker.nextObject() as? URL {
            if item.pathExtension.lowercased() == "app" {
                walker.skipDescendants()
                return item
            }
        }
        return nil
    }

    private func checkCancelled() throws {
        if isCancelled { throw DecryptError.cancelled }
    }

    // MARK: - 体积

    static func treeSize(_ path: String) -> Int64 {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: path)
        guard let walker = manager.enumerator(at: root,
                                              includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                              options: [],
                                              errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        while let item = walker.nextObject() as? URL {
            if let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private static func freeSpace(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        if let capacity = values?.volumeAvailableCapacity {
            return Int64(capacity)
        }
        return 0
    }

    static func bytesText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Mach-O 扫描

    struct MachOFile {
        let url: URL
        let encrypted: Bool
    }

    private func scanMachO(in root: URL) -> [MachOFile] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: root,
                                              includingPropertiesForKeys: [.isRegularFileKey],
                                              options: [],
                                              errorHandler: { _, _ in true }) else { return [] }
        var rows: [MachOFile] = []
        while let item = walker.nextObject() as? URL {
            if isCancelled { break }
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            guard fp_is_macho(item.path) else { continue }
            let slices = parseSlices(item.path)
            let encrypted = slices.contains { $0.has_enc && $0.cryptid != 0 }
            rows.append(MachOFile(url: item, encrypted: encrypted))
        }
        return rows
    }

    private func parseSlices(_ path: String) -> [fp_slice_t] { Self.parseSlices(path) }

    private static func parseSlices(_ path: String) -> [fp_slice_t] {
        var buffer = [fp_slice_t](repeating: fp_slice_t(), count: Int(FP_MAX_SLICES))
        var count: Int32 = 0
        var error = [CChar](repeating: 0, count: 256)
        let rc = path.withCString { pointer -> Int32 in
            buffer.withUnsafeMutableBufferPointer { slices in
                fp_parse(pointer, slices.baseAddress, Int32(FP_MAX_SLICES), &count, &error, 256)
            }
        }
        guard rc == 0, count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }

    // MARK: - SC_Info

    private func ensureSINF(for binary: URL, appRoot: URL, log: (String) -> Void) -> Bool {
        let manager = FileManager.default
        let name = binary.lastPathComponent
        let directory = binary.deletingLastPathComponent()
        let targetDirectory = directory.appendingPathComponent("SC_Info", isDirectory: true)
        let target = targetDirectory.appendingPathComponent("\(name).sinf")
        if manager.fileExists(atPath: target.path) { return true }

        let candidates = [
            appRoot.appendingPathComponent("SC_Info/\(name).sinf"),
            appRoot.appendingPathComponent("SC_Info/\(name).supp"),
        ]
        for candidate in candidates {
            if manager.isReadableFile(atPath: candidate.path) {
                try? manager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
                if (try? manager.copyItem(at: candidate, to: target)) != nil { return true }
            }
        }

        // 退回到应用内任意一个 .sinf，fairplayd 只按文件名取授权。
        let rootSCInfo = appRoot.appendingPathComponent("SC_Info", isDirectory: true)
        if let items = try? manager.contentsOfDirectory(at: rootSCInfo, includingPropertiesForKeys: nil),
           let first = items.first(where: { $0.pathExtension.lowercased() == "sinf" || $0.pathExtension.lowercased() == "supp" }) {
            try? manager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            if (try? manager.copyItem(at: first, to: target)) != nil {
                log("  SC_Info 回退：\(first.lastPathComponent) → \(name).sinf")
                return true
            }
        }
        return false
    }

    // MARK: - 去签名

    private func removeCodeSignatures(in app: URL, log: (String) -> Void) {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: app,
                                              includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [],
                                              errorHandler: { _, _ in true }) else { return }
        var targets: [URL] = []
        while let item = walker.nextObject() as? URL {
            if item.lastPathComponent == "_CodeSignature" { targets.append(item) }
        }
        for target in targets {
            try? manager.removeItem(at: target)
        }
        if !targets.isEmpty {
            log("移除 \(targets.count) 个 _CodeSignature")
        }
    }

    // MARK: - 打包

    private func addDirectoryTree(_ root: URL, relativeTo base: URL, zipPrefix: String,
                                  writer: ZipWriter, totalBytes: Int64,
                                  written: inout Int64,
                                  progress: (Double) -> Void) throws {
        let manager = FileManager.default
        try writer.addDirectory(zipPrefix)
        guard let walker = manager.enumerator(at: root,
                                              includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                                              options: [],
                                              errorHandler: { _, _ in true }) else {
            throw DecryptError.packFailed("无法枚举 \(root.path)")
        }
        while let item = walker.nextObject() as? URL {
            try checkCancelled()
            let relative = item.path.replacingOccurrences(of: base.path + "/", with: "")
            let name = "\(zipPrefix)/\(relative)"
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isDirectory == true {
                try writer.addDirectory(name)
                continue
            }
            if values?.isSymbolicLink == true {
                continue
            }
            guard values?.isRegularFile == true else { continue }
            try writer.addFile(at: item, as: name)
            written += Int64(values?.fileSize ?? 0)
            let fraction = totalBytes > 0 ? min(Double(written) / Double(totalBytes), 0.999) : 1
            progress(fraction)
        }
    }
}

// MARK: - C 日志回调

private final class LogBox {
    let handler: (String) -> Void
    init(_ handler: @escaping (String) -> Void) { self.handler = handler }
}

private let coreLogTrampoline: fp_log_t = { context, message in
    guard let context, let message else { return }
    let box = Unmanaged<LogBox>.fromOpaque(context).takeUnretainedValue()
    box.handler(String(cString: message))
}
