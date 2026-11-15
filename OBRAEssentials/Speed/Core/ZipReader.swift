import Foundation
#if canImport(Compression)
import Compression
#endif

/// Minimal ZIP reader (stored + deflate, no ZIP64, no encryption): enough to read back the run
/// archives this app writes, including ones re-zipped by Files, Windows or macOS.
struct ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let localOffset: Int

        var isDirectory: Bool { name.hasSuffix("/") }
    }

    enum ZipError: LocalizedError {
        case notZip
        case unsupported(String)
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .notZip: return "This isn't a zip file."
            case .unsupported(let what): return "This zip uses \(what), which isn't supported."
            case .corrupt(let what): return "The zip is damaged (\(what))."
            }
        }
    }

    private let bytes: [UInt8]
    let entries: [Entry]

    init(_ data: Data) throws {
        let b = [UInt8](data)
        guard b.count >= 22 else { throw ZipError.notZip }

        // End-of-central-directory record: search backwards past any archive comment.
        var eocd = -1
        var i = b.count - 22
        let lowest = max(0, b.count - 22 - 65_535)
        while i >= lowest {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }

        let count = Int(Self.u16(b, eocd + 10))
        let cdOffset = Self.u32(b, eocd + 16)
        guard cdOffset != 0xFFFF_FFFF, count != 0xFFFF else { throw ZipError.unsupported("the ZIP64 format") }

        var list: [Entry] = []
        var p = Int(cdOffset)
        for _ in 0..<count {
            guard p + 46 <= b.count, Self.u32(b, p) == 0x0201_4B50 else { throw ZipError.corrupt("file list") }
            let flags = Self.u16(b, p + 8)
            let method = Self.u16(b, p + 10)
            let crc = Self.u32(b, p + 16)
            let compressed = Int(Self.u32(b, p + 20))
            let size = Int(Self.u32(b, p + 24))
            let nameLen = Int(Self.u16(b, p + 28))
            let extraLen = Int(Self.u16(b, p + 30))
            let commentLen = Int(Self.u16(b, p + 32))
            let local = Int(Self.u32(b, p + 42))
            guard p + 46 + nameLen <= b.count else { throw ZipError.corrupt("file name") }
            let nameBytes = Array(b[(p + 46)..<(p + 46 + nameLen)])
            let name = String(decoding: nameBytes, as: UTF8.self)
            if flags & 1 != 0 { throw ZipError.unsupported("password protection") }
            list.append(Entry(name: name, method: method, crc: crc, compressedSize: compressed, size: size, localOffset: local))
            p += 46 + nameLen + extraLen + commentLen
        }
        bytes = b
        entries = list
    }

    func read(_ e: Entry) throws -> Data {
        let b = bytes
        let h = e.localOffset
        guard h + 30 <= b.count, Self.u32(b, h) == 0x0403_4B50 else { throw ZipError.corrupt(e.name) }
        let start = h + 30 + Int(Self.u16(b, h + 26)) + Int(Self.u16(b, h + 28))
        guard start + e.compressedSize <= b.count else { throw ZipError.corrupt(e.name) }
        guard e.size <= 600_000_000 else { throw ZipError.unsupported("files this large") }

        let out: Data
        switch e.method {
        case 0:
            out = Data(b[start..<(start + e.compressedSize)])
        case 8:
            out = try Self.inflate(b, start: start, count: e.compressedSize, size: e.size, name: e.name)
        default:
            throw ZipError.unsupported("compression method \(e.method)")
        }
        guard out.count == e.size, CRC32.checksum(out) == e.crc else { throw ZipError.corrupt(e.name) }
        return out
    }

    private static func inflate(_ b: [UInt8], start: Int, count: Int, size: Int, name: String) throws -> Data {
        guard size > 0 else { return Data() }
        #if canImport(Compression)
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            b.withUnsafeBufferPointer { (src: UnsafeBufferPointer<UInt8>) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress, let s = src.baseAddress else { return 0 }
                return compression_decode_buffer(d, size, s + start, count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.corrupt(name) }
        return out
        #else
        throw ZipError.unsupported("compressed files on this platform")
        #endif
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
