import Foundation
import Observation

enum Handshake: String, CaseIterable, Identifiable {
    case openAndKeepAlive = "Open + keep-alive"
    case dataGather = "Data-gather command"
    case listenOnly = "Listen only"
    var id: String { rawValue }

    var detail: String {
        switch self {
        case .openAndKeepAlive: "Sends the session-open command, then a keep-alive every few seconds. Works on most controllers."
        case .dataGather: "Sends system command 0x06 (start data gathering) once after connecting. Try this if no data arrives."
        case .listenOnly: "Sends nothing on connect. Use if the official app is also running or to sniff traffic."
        }
    }
}

@Observable
final class FarLinkSettings {
    static let shared = FarLinkSettings()
    private let d = UserDefaults.standard

    var handshake: Handshake {
        didSet { d.set(handshake.rawValue, forKey: "handshake") }
    }
    var keepAliveSeconds: Double {
        didSet { d.set(keepAliveSeconds, forKey: "keepAlive") }
    }
    var useMph: Bool {
        didSet { d.set(useMph, forKey: "useMph") }
    }
    /// If > 0, overrides the controller's wheel config: speed = rpm * circumference.
    var wheelCircumferenceMm: Double {
        didSet { d.set(wheelCircumferenceMm, forKey: "wheelCirc") }
    }
    /// Divide the controller's raw speed value by this to get motor rpm (1 on most firmwares).
    var rpmDivisor: Double {
        didSet { d.set(rpmDivisor, forKey: "rpmDiv") }
    }
    var allowWritesWhileMoving: Bool {
        didSet { d.set(allowWritesWhileMoving, forKey: "writeMoving") }
    }
    var autoReconnect: Bool {
        didSet { d.set(autoReconnect, forKey: "autoReconnect") }
    }
    var lastPeripheralID: String? {
        didSet { d.set(lastPeripheralID, forKey: "lastPeripheral") }
    }

    private init() {
        let d = UserDefaults.standard
        handshake = Handshake(rawValue: d.string(forKey: "handshake") ?? "") ?? .openAndKeepAlive
        keepAliveSeconds = d.object(forKey: "keepAlive") as? Double ?? 2
        useMph = d.bool(forKey: "useMph")
        wheelCircumferenceMm = d.object(forKey: "wheelCirc") as? Double ?? 0
        rpmDivisor = d.object(forKey: "rpmDiv") as? Double ?? 1
        allowWritesWhileMoving = d.bool(forKey: "writeMoving")
        autoReconnect = d.object(forKey: "autoReconnect") as? Bool ?? true
        lastPeripheralID = d.string(forKey: "lastPeripheral")
    }
}
