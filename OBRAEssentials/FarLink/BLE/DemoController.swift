import Foundation

/// A fake controller that speaks the real wire protocol, so the whole decode/verify path
/// can be exercised without hardware. Writes sent to it are applied and streamed back.
final class DemoController {
    var onBytes: (([UInt8]) -> Void)?

    private var regs = [UInt16](repeating: 0, count: 256)
    private var timer: Timer?
    private var nextID = 0
    private var t: Double = 0

    init() {
        func set(_ a: Int, _ v: UInt16) { regs[a] = v }
        func setLoHi(_ a: Int, _ lo: UInt8, _ hi: UInt8) { regs[a] = UInt16(lo) | (UInt16(hi) << 8) }
        set(0x0D, 630); set(0x0E, 840)                // 63.0 V empty, 84.0 V full
        set(0x0B, 0x0000)                             // direction normal
        setLoHi(0x08, 17, 84)                         // throttle 0.85 V – 4.2 V
        setLoHi(0x14, 4, 0x59)                        // 4 pole pairs
        set(0x15, 6000); set(0x16, 3000); set(0x17, 720)
        set(0x18, 5000); set(0x19, 120 * 4)           // 120 A line
        setLoHi(0x1A, 0x04, 0)                        // Sport
        set(0x1C, 40); set(0x1F, 630); set(0x25, 900)
        set(0x28, 1500); set(0x29, 2500); set(0x2A, 4000)
        set(0x2B, 64); set(0x2D, 300 * 4); set(0x2F, 64)
        set(0x30, 20); set(0x31, 60)
        setLoHi(0x84, 120, 100); setLoHi(0x85, 90, 75)
        setLoHi(0x86, 0, UInt8(ascii: "H")); setLoHi(0x87, UInt8(ascii: "7"), 4)
        set(0x6D, 12345); set(0x81, 0)
        setLoHi(0xD2, 0, 10); setLoHi(0xD3, 0, 0); set(0xD4, 2400) // wheel config ≈ 0.02 km/h per rpm
    }

    func start() {
        let tm = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Bytes "written" by the app.
    func receive(_ p: [UInt8]) {
        guard p.count == 8, p[0] == 0xAA, p[1] == 0xC6, p[2] == p[3],
              FD.frameCRCValid(p[...]) else { return }
        let addr = Int(p[2])
        let value = UInt16(p[4]) | (UInt16(p[5]) << 8)
        if addr == 0xA0 { return }    // system command: accept silently
        regs[addr] = value
    }

    private func tick() {
        t += 0.02
        simulate()
        let id = nextID
        nextID = (nextID + 1) % FD.flashReadAddr.count
        let base = Int(FD.flashReadAddr[id])
        var f: [UInt8] = [0xAA, UInt8(0x80 | id)]
        for i in 0..<6 {
            let w = base + i < 256 ? regs[base + i] : 0
            f.append(UInt8(w & 0xFF)); f.append(UInt8(w >> 8))
        }
        let crc = FD.crc16(f)
        f.append(UInt8(crc & 0xFF)); f.append(UInt8(crc >> 8))
        // Deliver in HM-10 sized chunks to exercise reassembly.
        let cut = 7 + (id % 6)
        onBytes?(Array(f[0..<cut]))
        onBytes?(Array(f[cut...]))
    }

    private func simulate() {
        let cycle = (sin(t / 3) + 1) / 2                 // 0…1 accelerating/decelerating
        let throttle = max(0, sin(t / 3 + 0.4))
        let rpm = Int(cycle * 4200)
        let amps = throttle * 90 - (1 - throttle) * 8
        let volts = 79.5 - amps * 0.04

        var e2: UInt16 = 0x01 | (2 << 2) | 0x80        // forward, gear 3, phone OK
        if rpm > 0 { e2 |= 0x20 }
        regs[0xE2] = e2
        regs[0xE3] = 0
        regs[0xE4] = UInt16(min(127, Int(throttle * 120)))
        regs[0xE5] = UInt16(rpm)
        regs[0xE8] = UInt16(Int(volts * 10))
        regs[0xEA] = UInt16(bitPattern: Int16(amps * 4))
        let phase = UInt32(pow(max(0, amps * 2.2) / 1.953125, 2))
        regs[0xF0] = UInt16((phase >> 16) & 0xFF) | UInt16((phase >> 8) & 0xFF) << 8
        regs[0xF1] = UInt16(phase & 0xFF) | UInt16((phase >> 16) & 0xFF) << 8
        regs[0xF2] = UInt16((phase >> 8) & 0xFF) | UInt16(phase & 0xFF) << 8
        regs[0xDB] = UInt16(38 + Int(throttle * 6))
        regs[0xF4] = UInt16(52 + Int(cycle * 10))
        regs[0xF5] = UInt16(72) << 8
        regs[0x82] = UInt16(85 + throttle * 335)
    }
}
