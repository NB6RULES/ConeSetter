import Foundation

/// Nanjing FarDriver controller protocol over the HM-10 style BLE serial bridge.
///
/// Sources (reverse-engineered, community documented):
///  - github.com/jackhumbert/fardriver-controllers (frame layout, CRC, register map)
///  - github.com/bobecek79/ESP32-Fardriver-BLE-Reader (hardware-tested BLE decode)
///
/// Everything is little-endian unless noted.
enum FD {

    // MARK: BLE identifiers
    static let serviceUUID = "FFE0"
    static let characteristicUUID = "FFEC"   // notify + write on the same characteristic

    // MARK: Status frame (controller -> phone)
    //
    //  B0      0xAA
    //  B1      id (bits 0-5) | flags (bits 6-7, == 2 for status)
    //  B2..13  12 bytes = 6 consecutive 16-bit registers starting at flashReadAddr[id]
    //  B14..15 CRC (low byte first)
    static let frameLength = 16
    static let magic: UInt8 = 0xAA

    /// id -> first register address of the 6-register block carried by the frame.
    static let flashReadAddr: [UInt8] = [
        0xE2, 0xE8, 0xEE, 0x00, 0x06, 0x0C, 0x12,
        0xE2, 0xE8, 0xEE, 0x18, 0x1E, 0x24, 0x2A,
        0xE2, 0xE8, 0xEE, 0x30, 0x5D, 0x63, 0x69,
        0xE2, 0xE8, 0xEE, 0x7C, 0x82, 0x88, 0x8E,
        0xE2, 0xE8, 0xEE, 0x94, 0x9A, 0xA0, 0xA6,
        0xE2, 0xE8, 0xEE, 0xAC, 0xB2, 0xB8, 0xBE,
        0xE2, 0xE8, 0xEE, 0xC4, 0xCA, 0xD0,
        0xE2, 0xE8, 0xEE, 0xD6, 0xDC, 0xF4, 0xFA,
    ]

    // MARK: CRC
    //
    // CRC-16/MODBUS polynomial (reflected 0xA001) with FarDriver's non-standard seed 0x7F3C.
    // Result is appended low byte first. Verified against captured frames
    // `AA C6 A0 A0 88 05 | 04 CC` and `AA C6 A0 A0 88 0F | 84 CB`.
    static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0x7F3C
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    static func frameCRCValid(_ f: ArraySlice<UInt8>) -> Bool {
        guard f.count >= 3 else { return false }
        let body = f.prefix(f.count - 2)
        let crc = crc16(body)
        let lo = f[f.endIndex - 2], hi = f[f.endIndex - 1]
        return lo == UInt8(crc & 0xFF) && hi == UInt8(crc >> 8)
    }

    // MARK: Outgoing packets

    /// "New app" register write: `AA C6 addr addr lo hi crcLo crcHi`.
    /// 0xC6 = 0xC0 + 6 (bytes before CRC); matches captures from the official app.
    static func writeRegister(_ addr: UInt8, value: UInt16) -> [UInt8] {
        var p: [UInt8] = [magic, 0xC6, addr, addr, UInt8(value & 0xFF), UInt8(value >> 8)]
        let crc = crc16(p)
        p.append(UInt8(crc & 0xFF))
        p.append(UInt8(crc >> 8))
        return p
    }

    /// "Old" 8-byte command form: `AA cmd ~cmd sub v1 v2 sum ~sum`.
    static func legacyCommand(_ cmd: UInt8, _ sub: UInt8, _ v1: UInt8, _ v2: UInt8) -> [UInt8] {
        var p: [UInt8] = [magic, cmd, ~cmd, sub, v1, v2]
        let sum = p.reduce(UInt8(0)) { $0 &+ $1 }
        p.append(sum)
        p.append(~sum)
        return p
    }

    /// Sent by the official tools right after the link opens; starts status streaming.
    static let openSession = legacyCommand(0x13, 0x07, 0x01, 0xF1)
    /// Periodic poke that keeps the controller streaming.
    static let keepAlive = legacyCommand(0x13, 0x07, 0x5F, 0x5F)
}

extension FD {
    /// System commands (register 0xA0 = 0x88 XX). Byte order on the wire is `88 XX`,
    /// i.e. low byte 0x88, high byte = command.
    enum SysCmd: UInt8 {
        case nonFollowing = 0x01
        case startDataGathering = 0x06
        case reset = 0x05
    }

    static func sys(_ cmd: SysCmd) -> [UInt8] {
        writeRegister(0xA0, value: UInt16(0x88) | (UInt16(cmd.rawValue) << 8))
    }
}

/// A decoded status frame: six registers starting at `address`.
struct StatusFrame: Equatable {
    let id: UInt8
    let address: UInt8
    let words: [UInt16]   // 6 values
    let raw: [UInt8]      // 16 bytes
}

/// Re-assembles 16-byte frames from BLE notifications, which may arrive split or merged
/// (HM-10 modules forward UART bytes in ~20 byte chunks with no framing of their own).
struct FrameParser {
    private var buffer: [UInt8] = []
    private(set) var accepted = 0
    private(set) var rejected = 0

    mutating func feed<C: Collection>(_ data: C) -> [StatusFrame] where C.Element == UInt8 {
        buffer.append(contentsOf: data)
        if buffer.count > 4096 { buffer.removeFirst(buffer.count - 4096) }

        var out: [StatusFrame] = []
        var i = 0
        while buffer.count - i >= FD.frameLength {
            guard buffer[i] == FD.magic else { i += 1; continue }
            let f = buffer[i..<(i + FD.frameLength)]
            let b1 = f[f.startIndex + 1]
            let id = b1 & 0x3F
            if (b1 >> 6) == 2, Int(id) < FD.flashReadAddr.count, FD.frameCRCValid(f) {
                var words: [UInt16] = []
                words.reserveCapacity(6)
                for w in 0..<6 {
                    let lo = UInt16(f[f.startIndex + 2 + w * 2])
                    let hi = UInt16(f[f.startIndex + 3 + w * 2])
                    words.append(lo | (hi << 8))
                }
                out.append(StatusFrame(id: id, address: FD.flashReadAddr[Int(id)], words: words, raw: Array(f)))
                accepted += 1
                i += FD.frameLength
            } else {
                rejected += 1
                i += 1
            }
        }
        if i > 0 { buffer.removeFirst(i) }
        return out
    }

    mutating func reset() { buffer.removeAll() }
}
