// FarLink protocol checks, compiled with the pure-Foundation protocol code on the macOS CI runner:
//   swiftc ConeSetter/FarLink/Protocol/*.swift Tests/FarLinkHarness/main.swift -o farlink-harness
// Ported from the XCTest suite in the standalone FarLink repo.

import Foundation

var failures: [String] = []
func check(_ ok: Bool, _ message: String) {
    print((ok ? "  PASS " : "  FAIL ") + message)
    if !ok { failures.append(message) }
}

print("== FarLink protocol")

// Captured from the official app (system commands 0x05 and 0x0F).
check(FD.sys(.reset) == [0xAA, 0xC6, 0xA0, 0xA0, 0x88, 0x05, 0x04, 0xCC], "CRC matches captured reset frame")
let captured: [UInt8] = [0xAA, 0xC6, 0xA0, 0xA0, 0x88, 0x0F, 0x84, 0xCB]
check(FD.frameCRCValid(captured[...]), "captured frame CRC valid")

let legacy = FD.legacyCommand(0x13, 0x07, 0x5F, 0x5F)
check(legacy.count == 8 && legacy[2] == ~legacy[1] && legacy[7] == ~legacy[6]
      && legacy[6] == legacy[0..<6].reduce(UInt8(0)) { $0 &+ $1 }, "legacy command checksum")

do {
    var frame: [UInt8] = [0xAA, 0x80 | 1]                          // id 1 -> 0xE8 block
    frame += [0x18, 0x03, 0, 0, 0x90, 0x01, 0, 0, 0, 0, 0, 0]     // 79.2 V, 100 A
    let crc = FD.crc16(frame)
    frame += [UInt8(crc & 0xFF), UInt8(crc >> 8)]

    var p = FrameParser()
    check(p.feed([0x00, 0xAA, 0x13] + frame[0..<5]).isEmpty, "partial frame waits for the rest")
    let out = p.feed(frame[5...])
    check(out.count == 1 && out.first?.address == 0xE8, "parser reassembles a split, noisy stream")
    if let first = out.first {
        var m = ControllerMemory()
        m.apply(first)
        let t = Telemetry.decode(m)
        check(abs(t.voltage - 79.2) < 0.001 && abs(t.lineCurrent - 100) < 0.001, "telemetry decodes voltage and current")
    }
}

do {
    var frame: [UInt8] = [0xAA, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    let crc = FD.crc16(frame)
    frame += [UInt8(crc & 0xFF), UInt8(crc >> 8) ^ 0x01]
    var p = FrameParser()
    check(p.feed(frame).isEmpty, "corrupt frame rejected")
}

if let dir = ParamCatalog.all.first(where: { $0.name == "Motor direction" }),
   let hiThrottle = ParamCatalog.all.first(where: { $0.name == "Throttle high threshold" }),
   let line = ParamCatalog.all.first(where: { $0.name == "Max line (battery) current" }) {
    check(dir.encode(1, into: 0x1234) == 0x9234 && dir.encode(0, into: 0x9234) == 0x1234, "bit parameter keeps the other bits")
    check(hiThrottle.encode(4.2, into: 0x5411) == 0x5411 && hiThrottle.encode(4.0, into: 0x5411) == 0x5011, "byte parameter keeps the other byte")
    check(line.encode(120, into: 0) == 480 && line.displayValue(from: 480) == 120, "scaled parameter round trip")
} else {
    check(false, "parameter catalogue has the expected entries")
}

print(failures.isEmpty ? "\nALL FARLINK CHECKS PASSED" : "\n\(failures.count) FARLINK CHECK(S) FAILED")
exit(failures.isEmpty ? 0 : 1)
