import Foundation
import CoreLocation
import CoreMotion
import UIKit
import simd

struct TrailPoint: Equatable {
    var coordinate: CLLocationCoordinate2D
    var speed: Double

    static func == (a: TrailPoint, b: TrailPoint) -> Bool {
        a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude && a.speed == b.speed
    }
}

/// Records a speed run: Core Location (best-for-navigation, ~1 Hz) + Core Motion (100 Hz),
/// fused by `FusionEngine`. Keeps running with the screen locked (background location).
@MainActor
final class SpeedRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = SpeedRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var speed: Double = 0
    @Published private(set) var longAccel: Double = 0
    @Published private(set) var latAccel: Double = 0
    @Published private(set) var distance: Double = 0
    @Published private(set) var topSpeed: Double = 0
    @Published private(set) var altitude: Double?
    @Published private(set) var gpsAccuracy: Double?
    @Published private(set) var gpsAge: Double = .infinity
    @Published private(set) var imuState: IMUState = .off
    @Published private(set) var trail: [TrailPoint] = []
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastSavedRun: SpeedRun?

    var useIMU: Bool {
        get { UserDefaults.standard.object(forKey: "speedUseIMU") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "speedUseIMU"); objectWillChange.send() }
    }

    var motionAvailable: Bool { motion.isDeviceMotionAvailable }

    private let manager = CLLocationManager()
    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private var engine: FusionEngine?
    private var startDate = Date()
    private var startUptime: TimeInterval = 0
    private var uiTimer: Timer?
    private var lastLocationTime: Date?
    private var previewCount = 0
    private var bgSession: AnyObject?
    private var lastCheckpoint: Double = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
    }

    // MARK: - Preview (GPS warm-up while the Speed tab is open)

    func beginPreview() {
        previewCount += 1
        requestAuthIfNeeded()
        manager.startUpdatingLocation()
        startUITimer()
    }

    func endPreview() {
        previewCount = max(0, previewCount - 1)
        if previewCount == 0 && !isRecording {
            manager.stopUpdatingLocation()
            stopUITimer()
        }
    }

    // MARK: - Recording

    func start() {
        guard !isRecording else { return }
        requestAuthIfNeeded()
        let useIMU = self.useIMU && motion.isDeviceMotionAvailable
        engine = FusionEngine(useIMU: useIMU)
        startDate = Date()
        startUptime = ProcessInfo.processInfo.systemUptime
        trail = []
        elapsed = 0
        distance = 0
        topSpeed = 0
        lastCheckpoint = 0
        isRecording = true
        imuState = engine?.state ?? .off

        if Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") != nil {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        bgSession = CLBackgroundActivitySession()
        manager.startUpdatingLocation()

        if useIMU {
            motion.deviceMotionUpdateInterval = 1.0 / 100.0
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] dm, _ in
                guard let dm else { return }
                MainActor.assumeIsolated { self?.handleMotion(dm) }
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                MainActor.assumeIsolated { self?.handleAltitude(data) }
            }
        }
        UIApplication.shared.isIdleTimerDisabled = true
        startUITimer()
        Haptics.success()
    }

    /// Stops and saves. Returns the saved run (nil if nothing was recorded).
    @discardableResult
    func stop() -> SpeedRun? {
        guard isRecording, let engine else { return nil }
        isRecording = false
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        (bgSession as? CLBackgroundActivitySession)?.invalidate()
        bgSession = nil
        manager.allowsBackgroundLocationUpdates = false
        if previewCount == 0 { manager.stopUpdatingLocation() }
        UIApplication.shared.isIdleTimerDisabled = false
        Haptics.success()

        let samples = engine.finalize()
        self.engine = nil
        imuState = .off
        RunStore.shared.clearCheckpoint()
        guard samples.count >= 2 else { return nil }

        let df = DateFormatter()
        df.dateFormat = "d MMM HH:mm"
        let run = SpeedRun(id: UUID(), name: "Run · \(df.string(from: startDate))", startDate: startDate,
                           samples: samples, fixes: engine.fixes, imuUsed: engine.useIMU, baro: engine.baro)
        RunStore.shared.save(run)
        lastSavedRun = run
        return run
    }

    func discard() {
        guard isRecording else { return }
        isRecording = false
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        (bgSession as? CLBackgroundActivitySession)?.invalidate()
        bgSession = nil
        manager.allowsBackgroundLocationUpdates = false
        if previewCount == 0 { manager.stopUpdatingLocation() }
        UIApplication.shared.isIdleTimerDisabled = false
        engine = nil
        imuState = .off
        RunStore.shared.clearCheckpoint()
    }

    // MARK: - Sensor callbacks

    private func handleMotion(_ dm: CMDeviceMotion) {
        guard isRecording, let engine else { return }
        let t = dm.timestamp - startUptime
        let g = dm.gravity, a = dm.userAcceleration, w = dm.rotationRate
        engine.addMotion(t: t,
                         gravity: SIMD3(g.x, g.y, g.z),
                         userAccel: SIMD3(a.x, a.y, a.z),
                         rotationRate: SIMD3(w.x, w.y, w.z))
    }

    private func handleAltitude(_ data: CMAltitudeData) {
        guard isRecording, let engine else { return }
        engine.addBaro(t: data.timestamp - startUptime, rel: data.relativeAltitude.doubleValue)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            for loc in locations { self.handleLocation(loc) }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            self.authorization = manager.authorizationStatus
            if self.previewCount > 0 || self.isRecording { manager.startUpdatingLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func handleLocation(_ loc: CLLocation) {
        lastLocationTime = loc.timestamp
        gpsAccuracy = loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil
        if !isRecording {
            speed = max(0, loc.speed)
            altitude = loc.verticalAccuracy >= 0 ? loc.altitude : nil
            return
        }
        guard let engine, loc.timestamp >= startDate.addingTimeInterval(-0.5) else { return }
        let fix = GPSFix(
            t: loc.timestamp.timeIntervalSince(startDate),
            lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, alt: loc.altitude,
            hAcc: loc.horizontalAccuracy, vAcc: loc.verticalAccuracy,
            speed: loc.speed, speedAcc: loc.speedAccuracy,
            course: loc.course, courseAcc: loc.courseAccuracy)
        let before = engine.fixes.count
        engine.addFix(fix)
        if engine.fixes.count > before {
            trail.append(TrailPoint(coordinate: loc.coordinate, speed: max(0, loc.speed)))
        }
    }

    // MARK: - UI refresh

    private func startUITimer() {
        guard uiTimer == nil else { return }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func stopUITimer() {
        uiTimer?.invalidate()
        uiTimer = nil
    }

    private func refresh() {
        gpsAge = lastLocationTime.map { Date().timeIntervalSince($0) } ?? .infinity
        guard isRecording, let engine else { return }
        elapsed = Date().timeIntervalSince(startDate)
        speed = engine.liveSpeed
        longAccel = engine.liveLongAccel
        latAccel = engine.liveLatAccel
        distance = engine.liveDistance
        topSpeed = engine.topSpeed
        altitude = engine.liveAltitude
        imuState = engine.state

        if elapsed - lastCheckpoint > 30 {
            lastCheckpoint = elapsed
            RunStore.shared.writeCheckpoint(SpeedRun(
                id: UUID(), name: "Run", startDate: startDate,
                samples: engine.samples, fixes: engine.fixes, imuUsed: engine.useIMU, baro: engine.baro))
        }
    }

    private func requestAuthIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }
}
