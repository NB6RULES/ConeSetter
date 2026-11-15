import Foundation
import CoreBluetooth
import Observation

struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    var rssi: Int
    var likelyFardriver: Bool
}

struct LogEntry: Identifiable {
    enum Direction: String { case rx = "RX", tx = "TX", info = "--" }
    let id = UUID()
    let time: Date
    let dir: Direction
    let text: String
}

struct PendingWrite: Equatable {
    enum Status: Equatable { case sending, waiting, verified, mismatch(UInt16), timedOut, failed(String) }
    let address: UInt8
    let value: UInt16
    let sentAt: Date
    var status: Status
}

enum LinkState: Equatable {
    case bluetoothOff, idle, scanning, connecting(String), connected(String), demo
    case failed(String)

    var isLive: Bool {
        switch self { case .connected, .demo: true; default: false }
    }
    var label: String {
        switch self {
        case .bluetoothOff: "Bluetooth off"
        case .idle: "Not connected"
        case .scanning: "Scanning…"
        case .connecting(let n): "Connecting to \(n)…"
        case .connected(let n): n
        case .demo: "Demo controller"
        case .failed(let m): m
        }
    }
}

/// Owns the BLE connection to a FarDriver controller, keeps a mirror of its registers,
/// and publishes decoded telemetry to the UI at ~10 Hz.
@Observable
final class FardriverLink: NSObject {

    // MARK: Published state
    private(set) var state: LinkState = .idle
    private(set) var devices: [DiscoveredDevice] = []
    private(set) var memory = ControllerMemory()
    private(set) var telemetry = Telemetry()
    private(set) var framesPerSecond: Double = 0
    private(set) var lastFrameAt: Date?
    private(set) var log: [LogEntry] = []
    private(set) var pendingWrites: [UInt8: PendingWrite] = [:]
    var logPaused = false

    let settings = FarLinkSettings.shared

    // MARK: Internals (not observed)
    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var characteristic: CBCharacteristic?
    @ObservationIgnored private var parser = FrameParser()
    @ObservationIgnored private var liveMemory = ControllerMemory()
    @ObservationIgnored private var pendingLog: [LogEntry] = []
    @ObservationIgnored private var framesSinceTick = 0
    @ObservationIgnored private var lastRateCalc = Date()
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var publishTimer: Timer?
    @ObservationIgnored private var keepAliveTimer: Timer?
    @ObservationIgnored private var demo: DemoController?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.publish() }
        RunLoop.main.add(t, forMode: .common)   // keep updating while the user scrolls
        publishTimer = t
    }

    // MARK: Derived

    var motorStopped: Bool { telemetry.rawSpeed == 0 && !telemetry.moving }
    var canWrite: Bool {
        guard state.isLive else { return false }
        return settings.allowWritesWhileMoving || motorStopped
    }

    /// Motor rpm after the user's divisor.
    var rpm: Double { Double(telemetry.rawSpeed) / max(settings.rpmDivisor, 0.0001) }

    /// Road speed in the user's units, preferring their own wheel size if set.
    var speed: Double? {
        let kmh: Double?
        if settings.wheelCircumferenceMm > 0 {
            kmh = rpm * settings.wheelCircumferenceMm / 1_000_000 * 60
        } else {
            kmh = telemetry.speedKmh
        }
        guard let kmh else { return nil }
        return settings.useMph ? kmh * 0.621371 : kmh
    }
    var speedUnit: String { settings.useMph ? "mph" : "km/h" }

    // MARK: Scanning

    func startScan() {
        guard central.state == .poweredOn else { state = .bluetoothOff; return }
        stopDemo()
        devices.removeAll()
        state = .scanning
        // No service filter: HM-10 modules often don't advertise FFE0.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            if self?.state == .scanning { self?.stopScan() }
        }
    }

    func stopScan() {
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    func connect(_ id: UUID) {
        guard let p = peripherals[id] else { return }
        central.stopScan()
        disconnect(clearState: false)
        peripheral = p
        p.delegate = self
        state = .connecting(p.name ?? "Controller")
        central.connect(p, options: nil)
        info("Connecting to \(p.name ?? id.uuidString)")
    }

    func disconnect(clearState: Bool = true) {
        keepAliveTimer?.invalidate(); keepAliveTimer = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        characteristic = nil
        if clearState {
            settings.lastPeripheralID = nil
            state = .idle
        }
    }

    // MARK: Demo

    func startDemo() {
        disconnect()
        resetSession()
        state = .demo
        let d = DemoController()
        d.onBytes = { [weak self] bytes in self?.ingest(Data(bytes)) }
        d.start()
        demo = d
        info("Demo controller started")
    }

    func stopDemo() {
        guard demo != nil else { return }
        demo?.stop(); demo = nil
        if state == .demo { state = .idle }
    }

    // MARK: Writing

    /// Writes a catalog parameter using read-modify-write on its register.
    @discardableResult
    func write(_ def: ParamDef, displayValue: Double) -> String? {
        let current = liveMemory.u16(def.address)
        let newWord = def.encode(displayValue, into: current)
        return writeRegister(def.address, newWord)
    }

    /// Writes a raw 16-bit register. Returns an error message, or nil if sent.
    @discardableResult
    func writeRegister(_ addr: UInt8, _ value: UInt16) -> String? {
        guard state.isLive else { return "Not connected." }
        guard settings.allowWritesWhileMoving || motorStopped else { return "Stop the motor before changing settings." }
        guard addr < 0xD6 else { return "Registers 0xD6 and above are live status, not settings." }
        let packet = FD.writeRegister(addr, value: value)
        pendingWrites[addr] = PendingWrite(address: addr, value: value, sentAt: Date(), status: .sending)
        send(packet, note: String(format: "write 0x%02X = 0x%04X (%d)", addr, value, value))
        pendingWrites[addr]?.status = .waiting
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, var p = self.pendingWrites[addr], p.status == .waiting else { return }
            p.status = .timedOut
            self.pendingWrites[addr] = p
        }
        return nil
    }

    func resetController() -> String? {
        guard state.isLive else { return "Not connected." }
        guard motorStopped else { return "Stop the motor first." }
        send(FD.sys(.reset), note: "system: reset")
        return nil
    }

    func sendRaw(_ bytes: [UInt8]) {
        send(bytes, note: "manual")
    }

    private func send(_ bytes: [UInt8], note: String) {
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        appendLog(.tx, "\(hex)  \(note)")
        if let demo {
            demo.receive(bytes)
            return
        }
        guard let p = peripheral, let c = characteristic else { return }
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data(bytes), for: c, type: type)
    }

    // MARK: Session

    private func resetSession() {
        parser.reset()
        liveMemory = ControllerMemory()
        memory = liveMemory
        telemetry = Telemetry()
        pendingWrites.removeAll()
        lastFrameAt = nil
        framesPerSecond = 0
    }

    private func startHandshake() {
        switch settings.handshake {
        case .openAndKeepAlive:
            send(FD.openSession, note: "open session")
            keepAliveTimer?.invalidate()
            keepAliveTimer = Timer.scheduledTimer(withTimeInterval: max(0.5, settings.keepAliveSeconds), repeats: true) { [weak self] _ in
                self?.send(FD.keepAlive, note: "keep-alive")
            }
        case .dataGather:
            send(FD.sys(.startDataGathering), note: "system: start data gathering")
        case .listenOnly:
            break
        }
    }

    // MARK: Incoming

    private func ingest(_ data: Data) {
        let frames = parser.feed(data)
        let now = Date()
        for f in frames {
            liveMemory.apply(f, at: now)
            framesSinceTick += 1
            if !logPaused {
                let hex = f.raw.map { String(format: "%02X", $0) }.joined(separator: " ")
                pendingLog.append(LogEntry(time: now, dir: .rx, text: String(format: "[%02X] ", f.address) + hex))
            }
            verifyPending(f)
        }
        if !frames.isEmpty { lastFrameAt = now; dirty = true }
    }

    private func verifyPending(_ f: StatusFrame) {
        for i in 0..<6 {
            let a = UInt8(Int(f.address) + i)
            guard var p = pendingWrites[a], p.status == .waiting,
                  Date().timeIntervalSince(p.sentAt) > 0.15 else { continue }
            p.status = f.words[i] == p.value ? .verified : .mismatch(f.words[i])
            pendingWrites[a] = p
        }
    }

    private func publish() {
        let now = Date()
        let dt = now.timeIntervalSince(lastRateCalc)
        if dt >= 1 {
            framesPerSecond = Double(framesSinceTick) / dt
            framesSinceTick = 0
            lastRateCalc = now
        }
        if !pendingLog.isEmpty {
            log.append(contentsOf: pendingLog)
            pendingLog.removeAll()
            if log.count > 400 { log.removeFirst(log.count - 400) }
        }
        guard dirty else { return }
        dirty = false
        memory = liveMemory
        telemetry = Telemetry.decode(liveMemory)
    }

    private func appendLog(_ dir: LogEntry.Direction, _ text: String) {
        pendingLog.append(LogEntry(time: Date(), dir: dir, text: text))
    }

    private func info(_ text: String) { appendLog(.info, text) }

    func clearLog() { log.removeAll(); pendingLog.removeAll() }
}

// MARK: - CBCentralManagerDelegate

extension FardriverLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if state == .bluetoothOff { state = .idle }
            reconnectToLast()
        case .poweredOff, .unauthorized, .unsupported:
            if state != .demo { state = .bluetoothOff }
        default: break
        }
    }

    private func reconnectToLast() {
        guard settings.autoReconnect, let s = settings.lastPeripheralID, let id = UUID(uuidString: s),
              let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        peripherals[id] = p
        connect(id)
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        guard let name, !name.isEmpty else { return }
        peripherals[p.identifier] = p
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let upper = name.uppercased()
        let likely = services.contains(CBUUID(string: FD.serviceUUID))
            || ["CONTROLDM", "FARDRIVER", "FD-", "ND7", "ND8", "ND9", "ND6", "HMSOFT", "BT05"].contains { upper.contains($0) }
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) {
            devices[i].rssi = RSSI.intValue
        } else {
            devices.append(DiscoveredDevice(id: p.identifier, name: name, rssi: RSSI.intValue, likelyFardriver: likely))
            devices.sort { ($0.likelyFardriver ? 1 : 0, $0.rssi) > ($1.likelyFardriver ? 1 : 0, $1.rssi) }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        info("Connected, discovering services")
        p.discoverServices([CBUUID(string: FD.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        state = .failed("Couldn't connect: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        keepAliveTimer?.invalidate(); keepAliveTimer = nil
        characteristic = nil
        info("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        guard peripheral?.identifier == p.identifier else { return }
        if settings.autoReconnect, error != nil {
            state = .connecting(p.name ?? "Controller")
            central.connect(p, options: nil)   // iOS keeps this pending until the controller is back in range
        } else {
            state = .idle
        }
    }
}

// MARK: - CBPeripheralDelegate

extension FardriverLink: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == CBUUID(string: FD.serviceUUID) }) else {
            state = .failed("This device has no FFE0 serial service — not a FarDriver BLE module?")
            central.cancelPeripheralConnection(p)
            return
        }
        p.discoverCharacteristics(nil, for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        let c = chars.first { $0.uuid == CBUUID(string: FD.characteristicUUID) }
            ?? chars.first { $0.uuid == CBUUID(string: "FFE1") }
            ?? chars.first { $0.properties.contains(.notify) }
        guard let c else {
            state = .failed("Serial characteristic not found")
            return
        }
        characteristic = c
        info("Using characteristic \(c.uuid.uuidString)")
        p.setNotifyValue(true, for: c)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error {
            state = .failed("Notify failed: \(error.localizedDescription)")
            return
        }
        resetSession()
        state = .connected(p.name ?? "FarDriver")
        settings.lastPeripheralID = p.identifier.uuidString
        startHandshake()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let v = c.value else { return }
        ingest(v)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error { info("Write error: \(error.localizedDescription)") }
    }
}
