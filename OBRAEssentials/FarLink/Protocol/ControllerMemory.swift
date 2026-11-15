import Foundation

/// Mirror of the controller's 256 x 16-bit register space, filled in as status frames arrive.
struct ControllerMemory: Equatable {
    private(set) var words = [UInt16](repeating: 0, count: 256)
    private(set) var seen = [Bool](repeating: false, count: 256)
    private(set) var lastUpdate = [Date?](repeating: nil, count: 256)

    mutating func apply(_ frame: StatusFrame, at time: Date = Date()) {
        for (i, w) in frame.words.enumerated() {
            let a = Int(frame.address) + i
            guard a < 256 else { break }
            words[a] = w
            seen[a] = true
            lastUpdate[a] = time
        }
    }

    mutating func setLocal(_ addr: UInt8, _ value: UInt16) {
        words[Int(addr)] = value
        seen[Int(addr)] = true
        lastUpdate[Int(addr)] = Date()
    }

    func has(_ a: UInt8) -> Bool { seen[Int(a)] }
    func u16(_ a: UInt8) -> UInt16 { words[Int(a)] }
    func i16(_ a: UInt8) -> Int16 { Int16(bitPattern: words[Int(a)]) }
    func lo(_ a: UInt8) -> UInt8 { UInt8(words[Int(a)] & 0xFF) }
    func hi(_ a: UInt8) -> UInt8 { UInt8(words[Int(a)] >> 8) }

    var seenCount: Int { seen.filter { $0 }.count }

    /// True once every configuration block streamed by the controller has been received at least once.
    var configComplete: Bool {
        Set(FD.flashReadAddr).allSatisfy { has($0) }
    }
}

// MARK: - Live telemetry

struct Telemetry: Equatable {
    var voltage: Double = 0            // V
    var lineCurrent: Double = 0        // A (negative = regen)
    var power: Double { voltage * lineCurrent }  // W
    var phaseA: Double = 0             // A rms
    var phaseC: Double = 0             // A rms
    var rawSpeed: Int = 0              // controller "MeasureSpeed" (motor rpm on most firmwares)
    var speedKmh: Double?              // from controller's own wheel config, if available
    var gear: Int = 0                  // 1...3 (low/mid/high)
    var forward = false
    var reverse = false
    var moving = false
    var brake = false
    var modulation: Double = 0         // 0...1
    var mosTemp: Int = 0               // °C
    var motorTemp: Int = 0             // °C
    var soc: Int?                      // % from controller
    var socFromVoltage: Double?        // % from ZeroBatt/FullBatt coefficients
    var throttleVolts: Double?
    var odometerKm: Double?
    var faults: [Fault] = []
    var firmware: String?

    static func decode(_ m: ControllerMemory) -> Telemetry {
        var t = Telemetry()

        // 0xE2 block: state bits, faults, modulation, speed
        let e2 = m.lo(0xE2)
        t.forward = e2 & 0x01 != 0
        t.reverse = e2 & 0x02 != 0
        t.gear = Int((e2 >> 2) & 0x03) + 1
        t.moving = e2 & 0x20 != 0

        let errLo = m.lo(0xE3), errHi = m.hi(0xE3)
        t.brake = errHi & 0x80 != 0
        t.faults = Fault.decode(lo: errLo, hi: errHi)

        t.modulation = Double(m.lo(0xE4)) / 128.0
        t.rawSpeed = Int(m.i16(0xE5))

        // 0xE8 block: voltage, line current
        t.voltage = Double(m.i16(0xE8)) / 10.0
        t.lineCurrent = Double(m.i16(0xEA)) / 4.0

        // 0xEE block: phase currents, 24-bit big-endian, amps = 1.953125 * sqrt(raw)
        if m.has(0xF0) {
            let b4 = UInt32(m.lo(0xF0)), b5 = UInt32(m.hi(0xF0)), b6 = UInt32(m.lo(0xF1))
            let b7 = UInt32(m.hi(0xF1)), b8 = UInt32(m.lo(0xF2)), b9 = UInt32(m.hi(0xF2))
            let a = (b4 << 16) | (b5 << 8) | b6
            let c = (b7 << 16) | (b8 << 8) | b9
            t.phaseA = 1.953125 * Double(a).squareRoot()
            t.phaseC = 1.953125 * Double(c).squareRoot()
        }

        // Temperatures
        if m.has(0xDB) { t.mosTemp = Int(m.i16(0xDB)) }
        if m.has(0xF4) { t.motorTemp = Int(m.i16(0xF4)) }

        // SOC reported by controller (signed byte, high half of 0xF5)
        if m.has(0xF5) {
            let s = Int(Int8(bitPattern: m.hi(0xF5)))
            if (0...100).contains(s) { t.soc = s }
        }
        if m.has(0x0D) && m.has(0x0E) {
            let zero = Double(m.i16(0x0D)), full = Double(m.i16(0x0E))
            if full > zero {
                let p = 100 * (Double(m.i16(0xE8)) - zero) / (full - zero)
                t.socFromVoltage = min(100, max(0, p))
            }
        }

        // Speed using the controller's own wheel configuration (same formula as the official app)
        if m.has(0xD2) && m.has(0xD4) {
            let wheelRatio = Double(m.lo(0xD2)), wheelRadius = Double(m.hi(0xD2))
            let wheelWidth = Double(m.hi(0xD3))
            let rateRatio = Double(m.u16(0xD4))
            if rateRatio > 0 {
                t.speedKmh = Double(t.rawSpeed) * 0.00376991136 * (wheelRadius * 1270 + wheelWidth * wheelRatio) / rateRatio
            }
        }

        if m.has(0x82) { t.throttleVolts = Double(m.u16(0x82)) * 0.01 }
        if m.has(0x6D) && m.has(0x81) {
            let raw = (UInt32(m.u16(0x81)) << 16) | UInt32(m.u16(0x6D))
            t.odometerKm = Double(raw) / 10.0
        }
        if m.has(0x86) && m.has(0x87) {
            let hw = Character(UnicodeScalar(m.hi(0x86)))
            let major = Character(UnicodeScalar(m.lo(0x87)))
            let minor = m.hi(0x87)
            if hw.isLetter || hw.isNumber { t.firmware = "\(hw)\(major).\(minor)" }
        }
        return t
    }
}

// MARK: - Faults (register 0xE3)

struct Fault: Identifiable, Hashable {
    let id: Int
    let name: String
    let detail: String

    static let table: [(Int, String, String)] = [
        (0, "Motor hall error", "Hall sensor signal missing or out of sequence."),
        (1, "Throttle error", "Throttle signal out of range at power-up, or throttle lost."),
        (2, "Current protection restart", "Over-current tripped and the controller restarted the stage."),
        (3, "Phase current surge", "Sudden phase current spike detected."),
        (4, "Voltage protection", "Battery voltage outside the low/high protection window."),
        (5, "Alarm / anti-theft", "Anti-theft alarm input active."),
        (6, "Motor over-temperature", "Motor temperature above the protection threshold."),
        (7, "Controller over-temperature", "MOSFET temperature above the protection threshold."),
        (8, "Phase current overflow", "Phase current exceeded the hardware limit."),
        (9, "Phase zero error", "Phase current sensor zero-offset fault."),
        (10, "Phase short", "Phase-to-phase short circuit detected."),
        (11, "Line current zero error", "Bus current sensor zero-offset fault."),
        (12, "MOSFET high side", "High-side MOSFET fault."),
        (13, "MOSFET low side", "Low-side MOSFET fault."),
        (14, "MOE current protection", "Hardware over-current shutdown (MOE)."),
        // bit 15 is the brake input, reported separately
    ]

    static func decode(lo: UInt8, hi: UInt8) -> [Fault] {
        let bits = UInt16(lo) | (UInt16(hi) << 8)
        return table.compactMap { bit, name, detail in
            bits & (1 << bit) != 0 ? Fault(id: bit, name: name, detail: detail) : nil
        }
    }
}
