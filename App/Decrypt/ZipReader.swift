import Foundation

/// 最小 ZIP 读取器：支持 stored / deflate（method 0/8）、UTF-8 文件名、
/// 目录与符号链接条目。用于把导入的 IPA 解包到暂存区。
final class ZipReader {

    enum ZipError: LocalizedError {
        case invalidArchive
        case unsupported(String)
        case missingEntry(String)
        case checksum(String)
        case cancelled
        case unsafePath(String)

        var errorDescription: String? {
            switch self {
            case .invalidArchive: return "不是有效的 ZIP/IPA 文件"
            case .unsupported(let name): return "不支持的 ZIP 条目：\(name)"
            case .missingEntry(let name): return "压缩包缺少条目：\(name)"
            case .checksum(let name): return "CRC 校验失败：\(name)"
            case .cancelled: return "已取消"
            case .unsafePath(let path): return "压缩包含有非法路径：\(path)"
            }
        }
    }

    struct Entry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localOffset: UInt64
        let mode: UInt16
        var isDirectory: Bool { name.hasSuffix("/") }
        var isSymlink: Bool { (mode & 0xF000) == 0xA000 }
    }

    private let handle: FileHandle
    private let fileSize: UInt64
    private(set) var entries: [Entry] = []
    private var totalUncompressed: UInt64 = 0

    init(url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ZipError.invalidArchive
        }
        self.handle = handle
        let size = (try? handle.seekToEnd()) ?? 0
        self.fileSize = size
        guard size > 22 else { throw ZipError.invalidArchive }
        try parseCentralDirectory()
    }

    deinit {
        try? handle.close()
    }

    var uncompressedBytes: UInt64 { totalUncompressed }

    // MARK: - 中央目录

    private func parseCentralDirectory() throws {
        let tailLength = min(fileSize, 66_000)
        try handle.seek(toOffset: fileSize - tailLength)
        guard let tail = try? handle.read(upToCount: Int(tailLength)), !tail.isEmpty else {
            throw ZipError.invalidArchive
        }
        let bytes = [UInt8](tail)
        var eocd: Int?
        var index = bytes.count - 22
        while index >= 0 {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B,
               bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                eocd = index
                break
            }
            index -= 1
        }
        guard let end = eocd else { throw ZipError.invalidArchive }

        let entryCount = Int(readUInt16(bytes, end + 10))
        let centralSize = UInt64(readUInt32(bytes, end + 12))
        let centralOffset = UInt64(readUInt32(bytes, end + 16))
        guard centralOffset + centralSize <= fileSize, centralSize > 0 else {
            throw ZipError.invalidArchive
        }
        if entryCount == 0xFFFF || centralOffset == 0xFFFFFFFF {
            throw ZipError.unsupported("ZIP64")
        }

        try handle.seek(toOffset: centralOffset)
        guard let central = try? handle.read(upToCount: Int(centralSize)), !central.isEmpty else {
            throw ZipError.invalidArchive
        }
        let data = [UInt8](central)
        var cursor = 0
        var parsed: [Entry] = []
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count,
                  readUInt32(data, cursor) == 0x02014B50 else { break }
            let method = readUInt16(data, cursor + 10)
            let crc = readUInt32(data, cursor + 16)
            let compressed = UInt64(readUInt32(data, cursor + 20))
            let uncompressed = UInt64(readUInt32(data, cursor + 24))
            let nameLength = Int(readUInt16(data, cursor + 28))
            let extraLength = Int(readUInt16(data, cursor + 30))
            let commentLength = Int(readUInt16(data, cursor + 32))
            let external = readUInt32(data, cursor + 38)
            let localOffset = UInt64(readUInt32(data, cursor + 42))
            guard cursor + 46 + nameLength <= data.count else { break }
            let nameData = Data(data[(cursor + 46)..<(cursor + 46 + nameLength)])
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""
            let mode = UInt16((external >> 16) & 0xFFFF)
            if compressed == 0xFFFFFFFF || uncompressed == 0xFFFFFFFF {
                throw ZipError.unsupported(name)
            }
            parsed.append(Entry(name: name,
                                method: method,
                                crc: crc,
                                compressedSize: compressed,
                                uncompressedSize: uncompressed,
                                localOffset: localOffset,
                                mode: mode))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        guard !parsed.isEmpty else { throw ZipError.invalidArchive }
        entries = parsed
        totalUncompressed = parsed.reduce(0) { $0 &+ $1.uncompressedSize }
    }

    // MARK: - 解包

    /// 解包全部条目到 `directory`，回调参数为已写入的原始字节数。
    func extractAll(to directory: URL,
                    checkCancelled: () -> Bool,
                    progress: (UInt64) -> Void) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: UInt64 = 0

        for entry in entries {
            if checkCancelled() { throw ZipError.cancelled }
            let relative = try safeRelativePath(entry.name)
            let target = directory.appendingPathComponent(relative)
            if entry.isDirectory {
                try? manager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try manager.createDirectory(at: target.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)

            let dataOffset = try dataOffset(for: entry)
            if entry.isSymlink {
                let payload = try readRange(offset: dataOffset, length: entry.compressedSize)
                if let link = String(data: payload, encoding: .utf8) {
                    if manager.fileExists(atPath: target.path) { try? manager.removeItem(at: target) }
                    try? manager.createSymbolicLink(atPath: target.path, withDestinationPath: link)
                }
                written += entry.uncompressedSize
                progress(written)
                continue
            }

            if manager.fileExists(atPath: target.path) { try? manager.removeItem(at: target) }
            switch entry.method {
            case 0:
                try copyStored(entry: entry, offset: dataOffset, to: target)
            case 8:
                try inflateEntry(entry: entry, offset: dataOffset, to: target)
            default:
                throw ZipError.unsupported(entry.name)
            }
            applyMode(entry.mode, to: target)
            written += entry.uncompressedSize
            progress(written)
        }
    }

    private func safeRelativePath(_ name: String) throws -> String {
        if name.isEmpty || name.hasPrefix("/") || name.contains("..") {
            throw ZipError.unsafePath(name)
        }
        return name
    }

    // MARK: - 条目读取

    private func dataOffset(for entry: Entry) throws -> UInt64 {
        try handle.seek(toOffset: entry.localOffset)
        guard let header = try? handle.read(upToCount: 30), header.count == 30 else {
            throw ZipError.invalidArchive
        }
        let bytes = [UInt8](header)
        guard readUInt32(bytes, 0) == 0x04034B50 else { throw ZipError.invalidArchive }
        let nameLength = UInt64(readUInt16(bytes, 26))
        let extraLength = UInt64(readUInt16(bytes, 28))
        return entry.localOffset + 30 + nameLength + extraLength
    }

    private func readRange(offset: UInt64, length: UInt64) throws -> Data {
        try handle.seek(toOffset: offset)
        return (try? handle.read(upToCount: Int(length))) ?? Data()
    }

    private func copyStored(entry: Entry, offset: UInt64, to target: URL) throws {
        _ = FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        try handle.seek(toOffset: offset)
        var remaining = entry.compressedSize
        var crc = uLong(0)
        while remaining > 0 {
            let count = Int(min(remaining, 1 << 20))
            guard let chunk = try? handle.read(upToCount: count), !chunk.isEmpty else {
                throw ZipError.invalidArchive
            }
            try output.write(contentsOf: chunk)
            chunk.withUnsafeBytes { raw in
                if let base = raw.bindMemory(to: Bytef.self).baseAddress {
                    crc = crc32(crc, base, uInt(chunk.count))
                }
            }
            remaining -= UInt64(chunk.count)
        }
        if UInt32(truncatingIfNeeded: crc) != entry.crc {
            throw ZipError.checksum(entry.name)
        }
    }

    private func inflateEntry(entry: Entry, offset: UInt64, to target: URL) throws {
        _ = FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        try handle.seek(toOffset: offset)

        var stream = z_stream()
        let initResult = inflateInit2_(&stream, -15, zlibVersion(),
                                       Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { throw ZipError.unsupported(entry.name) }
        defer { inflateEnd(&stream) }

        var remaining = entry.compressedSize
        var crc = uLong(0)
        let outSize = 1 << 16
        var outputBuffer = Data(count: outSize)

        while remaining > 0 {
            let count = Int(min(remaining, 1 << 20))
            guard let chunk = try? handle.read(upToCount: count), !chunk.isEmpty else {
                throw ZipError.invalidArchive
            }
            remaining -= UInt64(chunk.count)
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
                if let base = raw.bindMemory(to: Bytef.self).baseAddress {
                    stream.next_in = UnsafeMutablePointer(mutating: base)
                }
                stream.avail_in = uInt(chunk.count)
                while stream.avail_in > 0 {
                    var produced = 0
                    try outputBuffer.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) -> Void in
                        stream.next_out = outRaw.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(outSize)
                        let rc = inflate(&stream, Z_NO_FLUSH)
                        guard rc == Z_OK || rc == Z_STREAM_END || rc == Z_BUF_ERROR else {
                            throw ZipError.unsupported(entry.name)
                        }
                        produced = outSize - Int(stream.avail_out)
                    }
                    if produced > 0 {
                        try output.write(contentsOf: outputBuffer.prefix(produced))
                        outputBuffer.prefix(produced).withUnsafeBytes { outRaw in
                            if let base = outRaw.bindMemory(to: Bytef.self).baseAddress {
                                crc = crc32(crc, base, uInt(produced))
                            }
                        }
                    }
                }
            }
        }

        var finished = false
        repeat {
            var produced = 0
            var rc: Int32 = Z_OK
            try outputBuffer.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) -> Void in
                stream.next_out = outRaw.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outSize)
                rc = inflate(&stream, Z_FINISH)
                produced = outSize - Int(stream.avail_out)
            }
            if produced > 0 {
                try output.write(contentsOf: outputBuffer.prefix(produced))
                outputBuffer.prefix(produced).withUnsafeBytes { outRaw in
                    if let base = outRaw.bindMemory(to: Bytef.self).baseAddress {
                        crc = crc32(crc, base, uInt(produced))
                    }
                }
            }
            finished = rc == Z_STREAM_END
            if rc == Z_BUF_ERROR { break }
        } while !finished

        if UInt32(truncatingIfNeeded: crc) != entry.crc {
            throw ZipError.checksum(entry.name)
        }
    }

    private func applyMode(_ mode: UInt16, to target: URL) {
        guard mode != 0 else { return }
        try? FileManager.default.setAttributes([.posixPermissions: mode & 0o7777],
                                               ofItemAtPath: target.path)
    }

    // MARK: - 小工具

    private func readUInt16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
        UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
    }

    private func readUInt32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(bytes[index]) | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16) | (UInt32(bytes[index + 3]) << 24)
    }
}
