import Foundation
#if canImport(Compression)
import Compression
#endif

/// Minimal ZIP archive writer (store + raw deflate), enough for .xlsx packages.
struct ZipWriter {
    private struct Entry {
        let name: [UInt8]
        let crc: UInt32
        let method: UInt16
        let compressedSize: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var data = Data()
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(date: Date = Date()) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        let second: Int = c.second ?? 0
        let year: Int = max((c.year ?? 1980) - 1980, 0)
        let month: Int = c.month ?? 1
        let day: Int = c.day ?? 1
        let time: Int = (hour << 11) | (minute << 5) | (second / 2)
        let dateBits: Int = (year << 9) | (month << 5) | day
        dosTime = UInt16(truncatingIfNeeded: time)
        dosDate = UInt16(truncatingIfNeeded: dateBits)
    }

    mutating func add(_ path: String, _ content: Data, compress: Bool = true) {
        let crc = CRC32.checksum(content)
        var method: UInt16 = 0
        var payload = content
        if compress, content.count > 64, let deflated = Self.deflate(content), deflated.count < content.count {
            method = 8
            payload = deflated
        }
        let name = Array(path.utf8)
        let offset = UInt32(data.count)

        append32(0x0403_4B50)
        append16(20)
        append16(0x0800)
        append16(method)
        append16(dosTime)
        append16(dosDate)
        append32(crc)
        append32(UInt32(payload.count))
        append32(UInt32(content.count))
        append16(UInt16(name.count))
        append16(0)
        data.append(contentsOf: name)
        data.append(payload)

        entries.append(Entry(name: name, crc: crc, method: method,
                             compressedSize: UInt32(payload.count), size: UInt32(content.count), offset: offset))
    }

    mutating func add(_ path: String, _ text: String) {
        add(path, Data(text.utf8))
    }

    mutating func finish() -> Data {
        let cdStart = UInt32(data.count)
        for e in entries {
            append32(0x0201_4B50)
            append16(20)
            append16(20)
            append16(0x0800)
            append16(e.method)
            append16(dosTime)
            append16(dosDate)
            append32(e.crc)
            append32(e.compressedSize)
            append32(e.size)
            append16(UInt16(e.name.count))
            append16(0)
            append16(0)
            append16(0)
            append16(0)
            append32(0)
            append32(e.offset)
            data.append(contentsOf: e.name)
        }
        let cdSize = UInt32(data.count) - cdStart
        append32(0x0605_4B50)
        append16(0)
        append16(0)
        append16(UInt16(entries.count))
        append16(UInt16(entries.count))
        append32(cdSize)
        append32(cdStart)
        append16(0)
        return data
    }

    private mutating func append16(_ v: UInt16) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8(v >> 8))
    }

    private mutating func append32(_ v: UInt32) {
        for i in 0..<4 { data.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) }
    }

    /// Raw DEFLATE (no zlib header), as ZIP method 8 expects.
    static func deflate(_ input: Data) -> Data? {
        #if canImport(Compression)
        let capacity = input.count + input.count / 10 + 4096
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d, capacity, s, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
        #else
        return nil
        #endif
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}
