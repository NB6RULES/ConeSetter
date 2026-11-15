import Foundation

/// How a setting is packed into its 16-bit register.
enum ParamEncoding: Hashable {
    /// Whole register; displayed = raw * scale.
    case word(scale: Double, signed: Bool)
    /// Low or high byte of the register; displayed = raw * scale.
    case lowByte(scale: Double)
    case highByte(scale: Double)
    /// A bit-field inside the register.
    case bits(shift: Int, width: Int)
}

enum ParamRisk: Int, Comparable {
    case low, medium, high
    static func < (a: ParamRisk, b: ParamRisk) -> Bool { a.rawValue < b.rawValue }
}

struct ParamDef: Identifiable, Hashable {
    var id: String { "\(address)-\(name)" }
    let group: String
    let name: String
    let address: UInt8
    let encoding: ParamEncoding
    let unit: String
    let range: ClosedRange<Double>
    let step: Double
    let options: [Int: String]?      // for enum-like bit fields
    let risk: ParamRisk
    let help: String

    init(_ group: String, _ name: String, _ address: UInt8, _ encoding: ParamEncoding,
         unit: String = "", range: ClosedRange<Double>, step: Double = 1,
         options: [Int: String]? = nil, risk: ParamRisk = .low, help: String) {
        self.group = group; self.name = name; self.address = address; self.encoding = encoding
        self.unit = unit; self.range = range; self.step = step; self.options = options
        self.risk = risk; self.help = help
    }

    // MARK: Encode / decode

    func displayValue(from word: UInt16) -> Double {
        switch encoding {
        case let .word(scale, signed):
            return (signed ? Double(Int16(bitPattern: word)) : Double(word)) * scale
        case let .lowByte(scale):
            return Double(word & 0xFF) * scale
        case let .highByte(scale):
            return Double(word >> 8) * scale
        case let .bits(shift, width):
            return Double((Int(word) >> shift) & ((1 << width) - 1))
        }
    }

    /// Returns the new full register value with this field replaced (read-modify-write).
    func encode(_ display: Double, into current: UInt16) -> UInt16 {
        let v = min(max(display, range.lowerBound), range.upperBound)
        switch encoding {
        case let .word(scale, signed):
            let raw = Int((v / scale).rounded())
            return signed ? UInt16(bitPattern: Int16(clamping: raw)) : UInt16(clamping: raw)
        case let .lowByte(scale):
            let raw = UInt16(UInt8(clamping: Int((v / scale).rounded())))
            return (current & 0xFF00) | raw
        case let .highByte(scale):
            let raw = UInt16(UInt8(clamping: Int((v / scale).rounded())))
            return (current & 0x00FF) | (raw << 8)
        case let .bits(shift, width):
            let mask = UInt16(((1 << width) - 1) << shift)
            let raw = (UInt16(Int(v)) << shift) & mask
            return (current & ~mask) | raw
        }
    }

    func format(_ v: Double) -> String {
        if let options, let label = options[Int(v)] { return label }
        let decimals = step < 1 ? (step < 0.1 ? 2 : 1) : 0
        let s = String(format: "%.\(decimals)f", v)
        return unit.isEmpty ? s : "\(s) \(unit)"
    }
}

/// Curated set of settings whose register location and scaling are well documented.
/// Anything else is still reachable from the Registers tab.
enum ParamCatalog {
    static let all: [ParamDef] = [
        // Motor
        ParamDef("Motor", "Motor direction", 0x0B, .bits(shift: 15, width: 1),
                 range: 0...1, options: [0: "Normal", 1: "Reversed"], risk: .medium,
                 help: "Flips which way the motor spins for forward. Takes effect after a controller reset."),
        ParamDef("Motor", "Pole pairs", 0x14, .lowByte(scale: 1), range: 1...60, risk: .high,
                 help: "Motor pole pairs. Normally set by self-learning; a wrong value breaks speed readings and control."),
        ParamDef("Motor", "Rated speed", 0x18, .word(scale: 1, signed: false), unit: "rpm", range: 100...20000, step: 10, risk: .medium,
                 help: "Motor speed at rated voltage. Detected during self-learning."),
        ParamDef("Motor", "Max speed", 0x15, .word(scale: 1, signed: false), unit: "rpm", range: 100...20000, step: 10, risk: .medium,
                 help: "Speed cap. Going above rated speed uses field weakening — keep (max − rated)/rated under ~50% for hub motors."),
        ParamDef("Motor", "Reverse speed", 0x28, .word(scale: 1, signed: false), unit: "rpm", range: 0...10000, step: 10,
                 help: "Maximum speed in reverse."),
        ParamDef("Motor", "Rated power", 0x16, .word(scale: 1, signed: false), unit: "W", range: 100...30000, step: 50,
                 help: "Nameplate motor power. Mostly affects power display."),

        // Current limits
        ParamDef("Current", "Max line (battery) current", 0x19, .word(scale: 0.25, signed: false), unit: "A", range: 1...1000, step: 1, risk: .high,
                 help: "Battery bus current limit — sets peak power. Do not exceed your battery's or BMS discharge rating."),
        ParamDef("Current", "Max phase current", 0x2D, .word(scale: 0.25, signed: false), unit: "A", range: 1...2000, step: 1, risk: .high,
                 help: "Motor phase current limit — sets peak torque. Never exceed the controller's factory value; that is how controllers burn."),
        ParamDef("Current", "Regen stop current", 0x30, .word(scale: 1, signed: false), range: 0...2000, risk: .medium,
                 help: "Regenerative braking current when braking (raw units as stored)."),
        ParamDef("Current", "Max regen current", 0x31, .word(scale: 1, signed: false), range: 0...2000, risk: .medium,
                 help: "Maximum regenerative current (raw units as stored)."),

        // Throttle & response
        ParamDef("Throttle", "Throttle response", 0x1A, .bits(shift: 2, width: 2),
                 range: 0...2, options: [0: "Linear", 1: "Sport", 2: "ECO"],
                 help: "Throttle curve shape."),
        ParamDef("Throttle", "Acceleration sensitivity", 0x2F, .word(scale: 1, signed: false), range: 8...224,
                 help: "Higher = faster throttle response. ~32 for road use, 64–128 sporty, 224 track."),
        ParamDef("Throttle", "Deceleration sensitivity", 0x2B, .word(scale: 1, signed: false), range: 16...224,
                 help: "Higher = less lag when you roll off the throttle."),
        ParamDef("Throttle", "Throttle low threshold", 0x08, .lowByte(scale: 0.05), unit: "V", range: 0...5, step: 0.05,
                 help: "Throttle voltage treated as zero. Typical twist grip idle 0.8–0.9 V."),
        ParamDef("Throttle", "Throttle high threshold", 0x08, .highByte(scale: 0.05), unit: "V", range: 0...5, step: 0.05,
                 help: "Throttle voltage treated as full. Typical twist grip 4.1–4.3 V."),
        ParamDef("Throttle", "Low gear speed", 0x29, .word(scale: 1, signed: false), range: 0...20000, step: 10,
                 help: "Speed limit in low gear (raw value as stored — compare with the official app before changing)."),
        ParamDef("Throttle", "Mid gear speed", 0x2A, .word(scale: 1, signed: false), range: 0...20000, step: 10,
                 help: "Speed limit in mid gear (raw value as stored — compare with the official app before changing)."),

        // Battery
        ParamDef("Battery", "Rated voltage", 0x17, .word(scale: 0.1, signed: false), unit: "V", range: 12...120, step: 0.1, risk: .medium,
                 help: "Nominal pack voltage. Cannot exceed the controller's factory voltage. Valid after reset."),
        ParamDef("Battery", "Low-voltage cutoff", 0x1F, .word(scale: 0.1, signed: false), unit: "V", range: 10...120, step: 0.1, risk: .medium,
                 help: "Under-voltage protection point. e.g. 72 V Li-ion ≈ 63 V."),
        ParamDef("Battery", "High-voltage cutoff", 0x25, .word(scale: 0.1, signed: false), unit: "V", range: 10...140, step: 0.1, risk: .medium,
                 help: "Over-voltage protection point."),
        ParamDef("Battery", "Empty voltage (0% SOC)", 0x0D, .word(scale: 0.1, signed: true), unit: "V", range: 0...140, step: 0.1,
                 help: "Voltage shown as 0% battery."),
        ParamDef("Battery", "Full voltage (100% SOC)", 0x0E, .word(scale: 0.1, signed: true), unit: "V", range: 0...140, step: 0.1,
                 help: "Voltage shown as 100% battery."),
        ParamDef("Battery", "Battery capacity", 0x1C, .word(scale: 1, signed: false), unit: "Ah", range: 0...1000,
                 help: "Rated pack capacity."),

        // Protection
        ParamDef("Protection", "Motor temp limit", 0x84, .lowByte(scale: 1), unit: "°C", range: 40...180, risk: .medium,
                 help: "Motor temperature at which the controller cuts power."),
        ParamDef("Protection", "Motor temp restore", 0x84, .highByte(scale: 1), unit: "°C", range: 30...170, risk: .medium,
                 help: "Motor temperature at which power returns."),
        ParamDef("Protection", "Controller temp limit", 0x85, .lowByte(scale: 1), unit: "°C", range: 40...120, risk: .high,
                 help: "MOSFET temperature at which the controller cuts power. Raising this risks the controller."),
        ParamDef("Protection", "Controller temp restore", 0x85, .highByte(scale: 1), unit: "°C", range: 30...110, risk: .medium,
                 help: "MOSFET temperature at which power returns."),
    ]

    static var groups: [String] {
        var seen = Set<String>()
        return all.map(\.group).filter { seen.insert($0).inserted }
    }
}
