import Foundation

/// 最小 ZIP 写入器：zlib raw deflate（method 8）、UTF-8 文件名、保留 Unix 权限。
/// 只负责把目录树打成标准 zip，供导出 IPA 使用。
final class ZipWriter {

    enum ZipError: LocalizedError {
        case open(String)
        case zlib(Int32, String)
        case tooLarge(String)
        case tooManyEntries
        case cancelled

        var errorDescription: String? {
            switch self {
            case .open(let path): return "无法写入文件：\(path)"
            case .zlib(let code, let name): return "压缩失败（\(name)，zlib \(code)）"
            case .tooLarge(let name): return "文件超过 4GB，ZIP 不支持：\(name)"
            case .tooManyEntries: return "文件数量超过 ZIP 上限（65535）"
            case .cancelled: return "已取消"
            }
        }
    }

    private struct Entry {
        let name: String
        let crc: UInt32
        let compressed: UInt64
        let uncompressed: UInt64
        let offset: UInt64
        let mode: UInt16
        let isDirectory: Bool
    }

    private let handle: FileHandle
    private var entries: [Entry] = []
    private var offset: UInt64 = 0
    private var closed = false
    private let chunkSize = 1 << 20
    private let outChunk = 1 << 16
    private let checkCancelled: () -> Bool

    init(url: URL, checkCancelled: @escaping () -> Bool = { false }) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            try? manager.removeItem(at: url)
        }
        guard manager.createFile(atPath: url.path, contents: nil) else {
            throw ZipError.open(url.path)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw ZipError.open(url.path)
        }
        self.handle = handle
        self.checkCancelled = checkCancelled
    }

    deinit {
        if !closed { try? handle.close() }
    }

    // MARK: - 添加条目

    func addDirectory(_ name: String, mode: UInt16 = 0o755) throws {
        var path = name
        if !path.hasSuffix("/") { path += "/" }
        let offset = self.offset
        let header = localHeader(name: path, crc: 0, compressed: 0, uncompressed: 0,
                                 method: 0, mode: mode, isDirectory: true)
        try write(header)
        entries.append(Entry(name: path, crc: 0, compressed: 0, uncompressed: 0,
                             offset: offset, mode: mode, isDirectory: true))
    }

    func addFile(at source: URL, as name: String) throws {
        if checkCancelled() { throw ZipError.cancelled }

        let attributes = (try? FileManager.default.attributesOfItem(atPath: source.path)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if size > UInt64(UInt32.max) {
            throw ZipError.tooLarge(name)
        }
        var mode: UInt16 = 0o644
        if let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value {
            mode = permissions & 0o7777
        }
        if mode & 0o111 != 0 {
            mode |= 0o755
        }

        guard let input = try? FileHandle(forReadingFrom: source) else {
            throw ZipError.open(source.path)
        }
        defer { try? input.close() }

        let localOffset = offset
        // 先写占位头，压缩完成后回填 CRC 与大小。
        try write(localHeader(name: name, crc: 0, compressed: 0, uncompressed: 0,
                              method: 8, mode: mode, isDirectory: false))

        var stream = z_stream()
        let initResult = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8,
                                       Z_DEFAULT_STRATEGY, zlibVersion(),
                                       Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else {
            throw ZipError.zlib(initResult, name)
        }
        defer { deflateEnd(&stream) }

        var crc = uLong(0)
        var uncompressed: UInt64 = 0
        var compressed: UInt64 = 0
        var output = Data(count: outChunk)

        while true {
            if checkCancelled() { throw ZipError.cancelled }
            let chunk = try input.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            uncompressed += UInt64(chunk.count)

            chunk.withUnsafeBytes { raw in
                if let base = raw.bindMemory(to: Bytef.self).baseAddress {
                    crc = crc32(crc, base, uInt(chunk.count))
                }
            }

            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
                if let base = raw.bindMemory(to: Bytef.self).baseAddress {
                    stream.next_in = UnsafeMutablePointer(mutating: base)
                }
                stream.avail_in = uInt(chunk.count)
                repeat {
                    var produced = 0
                    try output.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) -> Void in
                        stream.next_out = outRaw.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(outChunk)
                        let rc = deflate(&stream, Z_NO_FLUSH)
                        guard rc == Z_OK else { throw ZipError.zlib(rc, name) }
                        produced = outChunk - Int(stream.avail_out)
                    }
                    if produced > 0 {
                        try write(output.prefix(produced))
                        compressed += UInt64(produced)
                    }
                } while stream.avail_in > 0
            }
        }

        var finished = false
        repeat {
            var produced = 0
            var rc: Int32 = Z_OK
            try output.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) -> Void in
                stream.next_out = outRaw.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outChunk)
                rc = deflate(&stream, Z_FINISH)
                guard rc == Z_STREAM_END || rc == Z_OK else { throw ZipError.zlib(rc, name) }
                produced = outChunk - Int(stream.avail_out)
            }
            if produced > 0 {
                try write(output.prefix(produced))
                compressed += UInt64(produced)
            }
            finished = rc == Z_STREAM_END
        } while !finished

        if compressed > UInt64(UInt32.max) {
            throw ZipError.tooLarge(name)
        }
        let finalCRC = UInt32(truncatingIfNeeded: crc)

        // 回填本地头中的 CRC / 压缩后大小 / 原始大小。
        var patch = Data()
        appendUInt32(&patch, finalCRC)
        appendUInt32(&patch, UInt32(compressed))
        appendUInt32(&patch, UInt32(uncompressed))
        try handle.seek(toOffset: localOffset + 14)
        try handle.write(contentsOf: patch)
        _ = try handle.seekToEnd()

        entries.append(Entry(name: name, crc: finalCRC, compressed: compressed,
                             uncompressed: uncompressed, offset: localOffset,
                             mode: mode, isDirectory: false))
    }

    // MARK: - 收尾

    func finish() throws {
        if entries.count > 65535 { throw ZipError.tooManyEntries }
        let centralStart = offset
        var central = Data()
        for entry in entries {
            appendUInt32(&central, 0x02014b50)
            appendUInt16(&central, 0x0314)                 // made by: Unix, 2.0
            appendUInt16(&central, 20)                     // version needed
            appendUInt16(&central, 0x0800)                 // UTF-8 文件名
            appendUInt16(&central, entry.isDirectory ? 0 : 8)
            appendUInt16(&central, dosTime())
            appendUInt16(&central, dosDate())
            appendUInt32(&central, entry.crc)
            appendUInt32(&central, UInt32(entry.compressed))
            appendUInt32(&central, UInt32(entry.uncompressed))
            let nameBytes = Array(entry.name.utf8)
            appendUInt16(&central, UInt16(nameBytes.count))
            appendUInt16(&central, 0)                      // extra
            appendUInt16(&central, 0)                      // comment
            appendUInt16(&central, 0)                      // disk
            appendUInt16(&central, 0)                      // internal attrs
            var attrs = UInt32(entry.mode) << 16
            if entry.isDirectory { attrs |= 0x10 }
            appendUInt32(&central, attrs)
            appendUInt32(&central, UInt32(entry.offset))
            central.append(contentsOf: nameBytes)
        }
        let centralSize = UInt64(central.count)
        try write(central)

        var end = Data()
        appendUInt32(&end, 0x06054b50)
        appendUInt16(&end, 0)
        appendUInt16(&end, 0)
        appendUInt16(&end, UInt16(entries.count))
        appendUInt16(&end, UInt16(entries.count))
        appendUInt32(&end, UInt32(centralSize))
        appendUInt32(&end, UInt32(centralStart))
        appendUInt16(&end, 0)
        try write(end)
        try handle.synchronize()
        try handle.close()
        closed = true
    }

    // MARK: - 基础写入

    private func localHeader(name: String, crc: UInt32, compressed: UInt64,
                             uncompressed: UInt64, method: UInt16,
                             mode: UInt16, isDirectory: Bool) -> Data {
        var data = Data()
        appendUInt32(&data, 0x04034b50)
        appendUInt16(&data, 20)
        appendUInt16(&data, 0x0800)                        // UTF-8
        appendUInt16(&data, method)
        appendUInt16(&data, dosTime())
        appendUInt16(&data, dosDate())
        appendUInt32(&data, crc)
        appendUInt32(&data, UInt32(compressed))
        appendUInt32(&data, UInt32(uncompressed))
        let nameBytes = Array(name.utf8)
        appendUInt16(&data, UInt16(nameBytes.count))
        appendUInt16(&data, 0)
        data.append(contentsOf: nameBytes)
        return data
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    private func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func dosDate() -> UInt16 {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let year = max((c.year ?? 1980) - 1980, 0)
        return UInt16((year << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
    }

    private func dosTime() -> UInt16 {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        return UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
    }
}
