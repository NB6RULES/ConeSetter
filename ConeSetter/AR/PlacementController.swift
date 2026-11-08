import Foundation
import ARKit
import RealityKit
import UIKit
import Combine

enum PlacementPhase: Equatable {
    case alignA, alignB, placing, finished
}

struct HUDState {
    var tracking = "Starting"
    var trackingGood = false
    var mapping = ""
    var hasLiDAR = false
    var crosshairHit = false
    var distanceToTarget: Double?
    var bearing: Double = 0
    var offsetForward: Double?
    var offsetLeft: Double?
    var offsetTotal: Double?
    var withinTolerance = false
    var fitRMS: Double?
    var worstResidual: Double?
    var measuredAB: Double?
    var cameraLayout: Vec2?
    var cameraHeadingLayout: Double?
}

/// Runs the AR session and the whole placement workflow:
/// 1. tap two taped reference points (A, B) to align the layout to the ground,
/// 2. walk to each ghost cone, put the real cone down, mark it,
/// 3. every marked cone becomes a new reference for the cones after it (chain mode).
@MainActor
final class PlacementController: NSObject, ObservableObject, ARSessionDelegate {
    let arView: ARView
    let layout: ConeLayout
    let sessionID: UUID

    @Published private(set) var phase: PlacementPhase = .alignA
    @Published private(set) var progress: [Int: ConeProgress]
    @Published private(set) var targetID: Int?
    @Published private(set) var hud = HUDState()
    @Published private(set) var toast: String?
    @Published var settings: PlacementSettings {
        didSet { settingsDidChange(from: oldValue) }
    }

    private let coneByID: [Int: PlannedCone]
    private var refAAnchor: UUID?
    private var refBAnchor: UUID?
    private var anchorPositions: [UUID: SIMD3<Float>] = [:]
    private var history: [Int] = []
    private var frameCounter = 0
    private var groundHit: SIMD3<Float>?
    private var lastWithin = false
    private var lastBand = 99
    private var toastWork: DispatchWorkItem?
    private var isResuming: Bool
    private var pendingWorldMap: ARWorldMap?
    private var started = false

    private let root: AnchorEntity
    private let crosshairDot: ModelEntity
    private let refAMarker: Entity
    private let refBMarker: Entity
    private var ghost: GhostEntity?
    private var markers: [Int: ModelEntity] = [:]
    private var markerKeys: [Int: String] = [:]

    init(layout: ConeLayout, resume: SavedSession?) {
        self.layout = layout
        self.coneByID = Dictionary(uniqueKeysWithValues: layout.cones.map { ($0.id, $0) })
        self.arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        self.root = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
        self.crosshairDot = EntityFactory.dot(color: .white, radius: 0.015)
        self.refAMarker = EntityFactory.refMarker(color: .systemPink)
        self.refBMarker = EntityFactory.refMarker(color: .systemTeal)

        if let s = resume {
            self.sessionID = s.id
            self.progress = s.progress.mapValues { p in
                var q = p
                q.anchorID = nil
                return q
            }
            self.settings = s.settings
            self.isResuming = true
            self.pendingWorldMap = SessionStore.shared.worldMap(for: s.id)
        } else {
            self.sessionID = UUID()
            self.progress = [:]
            self.settings = PlacementSettings()
            self.isResuming = false
            self.pendingWorldMap = nil
        }
        super.init()

        history = layout.cones.map(\.id).filter {
            let st = progress[$0]?.status
            return st == .placed || st == .accepted || st == .skipped
        }

        arView.session.delegate = self
        arView.renderOptions.insert(.disableMotionBlur)
        arView.renderOptions.insert(.disableDepthOfField)
        arView.scene.addAnchor(root)

        crosshairDot.isEnabled = false
        refAMarker.isEnabled = false
        refBMarker.isEnabled = false
        root.addChild(crosshairDot)
        root.addChild(refAMarker)
        root.addChild(refBMarker)

        for cone in layout.cones {
            let e = ModelEntity()
            e.isEnabled = false
            root.addChild(e)
            markers[cone.id] = e
        }

        let coach = ARCoachingOverlayView()
        coach.session = arView.session
        coach.goal = .horizontalPlane
        coach.activatesAutomatically = true
        coach.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.addSubview(coach)
    }

    // MARK: - Lifecycle

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .none
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            hud.hasLiDAR = true
        }
        if !started, let map = pendingWorldMap {
            config.initialWorldMap = map
        }
        let options: ARSession.RunOptions = started ? [] : [.resetTracking, .removeExistingAnchors]
        arView.session.run(config, options: options)
        started = true
        applyViewOptions()
        LocationService.shared.start()
        if isResuming, pendingWorldMap != nil {
            show("Looking for the saved map — walk around the start area, or just tap A and B again")
        }
    }

    func pause() {
        arView.session.pause()
        LocationService.shared.stop()
    }

    // MARK: - ARSessionDelegate (delivered on the main queue)

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { self.handleFrame(frame) }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        MainActor.assumeIsolated { self.handleAdded(anchors) }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { self.show("AR error: \(message)") }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated { self.show("AR paused") }
    }

    // MARK: - Public actions

    var currentCone: PlannedCone? { targetID.flatMap { coneByID[$0] } }

    func cone(_ id: Int) -> PlannedCone? { coneByID[id] }

    var doneCount: Int {
        progress.values.filter { $0.status == .placed || $0.status == .accepted }.count
    }

    func setReference() {
        guard let hit = groundHit else {
            show("Aim the crosshair at the mark on the ground")
            Haptics.error()
            return
        }
        isResuming = false
        let isA = phase == .alignA
        let anchor = ARAnchor(name: isA ? "ref-A" : "ref-B", transform: simd_float4x4(translation: hit))
        if let old = isA ? refAAnchor : refBAnchor { removeAnchor(old) }
        arView.session.add(anchor: anchor)
        anchorPositions[anchor.identifier] = hit
        Haptics.tap()

        if isA {
            refAAnchor = anchor.identifier
            phase = .alignB
        } else {
            refBAnchor = anchor.identifier
            finishAlignment()
        }
    }

    func restartAlignment() {
        if let a = refAAnchor { removeAnchor(a) }
        if let b = refBAnchor { removeAnchor(b) }
        refAAnchor = nil
        refBAnchor = nil
        isResuming = false
        phase = .alignA
        ghost?.root.isEnabled = false
    }

    func markPlaced() {
        guard phase == .placing, let tid = targetID, let cone = coneByID[tid], let global = globalFit() else { return }
        let near = targetFit(for: cone, global: global).apply(cone.pos)

        let measured: SIMD3<Float>?
        switch settings.markMode {
        case .tip:
            measured = tipMarkedPosition(coneHeight: cone.color.height, near: near)
        case .ground:
            measured = groundHit
        }
        guard let p = measured else {
            show(settings.markMode == .tip
                 ? "Couldn't measure — look down at the cone and put the crosshair on its tip"
                 : "Aim the crosshair at the ground where the cone sits")
            Haptics.error()
            return
        }
        let err = dist2(p.ground2D, near)
        guard err < 1.0 else {
            show("That spot is \(Fmt.distance(err)) from the target — aim at the cone you just placed")
            Haptics.error()
            return
        }

        if let old = progress[tid]?.anchorID { removeAnchor(old) }
        let anchor = ARAnchor(name: "cone-\(tid)", transform: simd_float4x4(translation: p))
        arView.session.add(anchor: anchor)
        anchorPositions[anchor.identifier] = p

        var pr = progress[tid] ?? ConeProgress()
        pr.status = .placed
        pr.anchorID = anchor.identifier
        pr.measuredLayout = global.inverse(p.ground2D)
        progress[tid] = pr
        history.append(tid)

        if err * 100 <= settings.toleranceCM {
            Haptics.success()
        } else {
            Haptics.warning()
        }
        show("Cone \(tid + 1) marked · \(Fmt.cm(err)) from target")
        advance()
    }

    func acceptAsPlanned() {
        guard phase == .placing, let tid = targetID else { return }
        var pr = progress[tid] ?? ConeProgress()
        pr.status = .accepted
        progress[tid] = pr
        history.append(tid)
        Haptics.tap()
        advance()
    }

    func skip() {
        guard phase == .placing, let tid = targetID else { return }
        var pr = progress[tid] ?? ConeProgress()
        pr.status = .skipped
        progress[tid] = pr
        history.append(tid)
        advance()
    }

    func undo() {
        guard let last = history.popLast() else { return }
        if let a = progress[last]?.anchorID { removeAnchor(a) }
        progress[last] = ConeProgress()
        if phase == .finished { phase = .placing }
        setTarget(last)
        show("Undid cone \(last + 1)")
    }

    func selectTarget(_ id: Int) {
        guard phase == .placing || phase == .finished, coneByID[id] != nil else { return }
        if phase == .finished { phase = .placing }
        setTarget(id)
    }

    func saveSession(then done: (() -> Void)? = nil) {
        refreshMeasuredLayout()
        let loc = LocationService.shared.location
        let snapshot = SavedSession(
            id: sessionID,
            name: layout.name,
            savedAt: Date(),
            layout: layout,
            progress: progress,
            settings: settings,
            latitude: loc?.coordinate.latitude,
            longitude: loc?.coordinate.longitude,
            horizontalAccuracy: loc?.horizontalAccuracy
        )
        arView.session.getCurrentWorldMap { map, _ in
            let data: Data? = map.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
            Task { @MainActor [weak self] in
                SessionStore.shared.save(snapshot, worldMapData: data)
                self?.show(data == nil
                           ? "Saved · AR map wasn't ready, so tap A and B again next time"
                           : "Saved with AR map")
                done?()
            }
        }
    }

    func exportCSV() -> URL? {
        let global = globalFit()
        var lines = ["id,group,colour,plan_x_m,plan_y_m,status,measured_x_m,measured_y_m,error_cm"]
        for c in layout.cones {
            let pr = progress[c.id] ?? ConeProgress()
            var measured: Vec2?
            if let aid = pr.anchorID, let w = anchorPositions[aid], let g = global {
                measured = g.inverse(w.ground2D)
            } else {
                measured = pr.measuredLayout
            }
            var row = "\(c.id + 1),\(c.group),\(c.color.rawValue)," + String(format: "%.3f,%.3f", c.x, c.y) + ",\(pr.status.rawValue)"
            if let m = measured {
                row += String(format: ",%.3f,%.3f,%.1f", m.x, m.y, dist2(m, c.pos) * 100)
            } else {
                row += ",,,"
            }
            lines.append(row)
        }
        let safe = layout.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ConeSetter_\(safe).csv")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            show("Export failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Frame loop

    private func handleFrame(_ frame: ARFrame) {
        frameCounter &+= 1
        guard frameCounter % 3 == 0 else { return }

        var h = hud
        describeTracking(frame, into: &h)

        for a in frame.anchors where a.name != nil {
            anchorPositions[a.identifier] = a.transform.position
        }

        let camT = frame.camera.transform
        let camPos = camT.position
        let fwd3 = SIMD3<Float>(-camT.columns.2.x, -camT.columns.2.y, -camT.columns.2.z)
        var f2 = fwd3.ground2D
        let fl = norm2(f2)
        f2 = fl > 1e-4 ? f2 / fl : Vec2(0, 1)

        groundHit = raycastGround()
        h.crosshairHit = groundHit != nil
        if let g = groundHit {
            crosshairDot.position = g + SIMD3<Float>(0, 0.004, 0)
            crosshairDot.isEnabled = true
        } else {
            crosshairDot.isEnabled = false
        }
        updateRefMarkers()

        switch phase {
        case .alignA, .alignB:
            ghost?.root.isEnabled = false
            if phase == .alignB, let a = refAPosition, let g = groundHit {
                h.measuredAB = dist2(a.ground2D, g.ground2D)
            } else {
                h.measuredAB = nil
            }
            h.distanceToTarget = nil
            h.offsetTotal = nil
            h.offsetForward = nil
            h.offsetLeft = nil
            h.withinTolerance = false

        case .placing, .finished:
            guard let global = globalFit() else { break }
            h.cameraLayout = global.inverse(camPos.ground2D)
            let hv = global.inverseVector(f2)
            h.cameraHeadingLayout = atan2(hv.y, hv.x)

            let qa = updateMarkers(global: global)
            h.fitRMS = qa.rms
            h.worstResidual = qa.worst

            if let cone = currentCone {
                let t2 = targetFit(for: cone, global: global).apply(cone.pos)
                let gy = groundHeight(at: t2)
                ghost?.root.position = worldPoint(t2, height: gy)
                ghost?.root.isEnabled = true

                let v = t2 - camPos.ground2D
                h.distanceToTarget = norm2(v)
                h.bearing = atan2(cross2(f2, v), dot2(f2, v))

                if let g = groundHit {
                    let d = t2 - g.ground2D
                    h.offsetForward = dot2(d, f2)
                    h.offsetLeft = cross2(f2, d)
                    h.offsetTotal = norm2(d)
                } else {
                    h.offsetForward = nil
                    h.offsetLeft = nil
                    h.offsetTotal = nil
                }
                let within = (h.offsetTotal ?? .infinity) <= settings.toleranceCM / 100
                h.withinTolerance = within
                feedback(within: within, offset: h.offsetTotal)
            } else {
                ghost?.root.isEnabled = false
                h.distanceToTarget = nil
                h.offsetTotal = nil
                h.withinTolerance = false
            }
        }
        hud = h
    }

    private func describeTracking(_ frame: ARFrame, into h: inout HUDState) {
        switch frame.camera.trackingState {
        case .normal:
            h.tracking = "Tracking"
            h.trackingGood = true
        case .notAvailable:
            h.tracking = "No tracking"
            h.trackingGood = false
        case .limited(let reason):
            h.trackingGood = false
            switch reason {
            case .initializing: h.tracking = "Starting up"
            case .excessiveMotion: h.tracking = "Move slower"
            case .insufficientFeatures: h.tracking = "Low detail"
            case .relocalizing: h.tracking = "Relocalising"
            @unknown default: h.tracking = "Limited"
            }
        }
        switch frame.worldMappingStatus {
        case .mapped: h.mapping = "Mapped"
        case .extending: h.mapping = "Mapping"
        case .limited: h.mapping = "Map limited"
        case .notAvailable: h.mapping = "No map"
        @unknown default: h.mapping = ""
        }
    }

    private func handleAdded(_ anchors: [ARAnchor]) {
        for a in anchors {
            guard let name = a.name else { continue }
            anchorPositions[a.identifier] = a.transform.position
            guard isResuming else { continue }
            if name == "ref-A", refAAnchor == nil {
                refAAnchor = a.identifier
            } else if name == "ref-B", refBAnchor == nil {
                refBAnchor = a.identifier
            } else if name.hasPrefix("cone-"), let id = Int(name.dropFirst(5)),
                      progress[id]?.status == .placed, progress[id]?.anchorID == nil {
                progress[id]?.anchorID = a.identifier
            }
        }
        if isResuming, phase == .alignA || phase == .alignB, refAAnchor != nil, refBAnchor != nil {
            isResuming = false
            show("Found the saved map — carry on placing")
            Haptics.success()
            phase = .placing
            advance()
        }
    }

    // MARK: - Alignment & fitting

    private var refAPosition: SIMD3<Float>? { refAAnchor.flatMap { anchorPositions[$0] } }
    private var refBPosition: SIMD3<Float>? { refBAnchor.flatMap { anchorPositions[$0] } }

    private func finishAlignment() {
        guard let a = refAPosition, let b = refBPosition else { return }
        let measured = dist2(a.ground2D, b.ground2D)
        let plan = layout.baselineLength
        if abs(measured - plan) > 0.10 {
            show(String(format: "A–B measures %.2f m but the plan says %.2f m — check the tape marks", measured, plan))
            Haptics.warning()
        } else {
            show(String(format: "Aligned · A–B %.2f m (plan %.2f m)", measured, plan))
            Haptics.success()
        }

        // Re-create anchors for cones placed in an earlier session.
        if let base = baselineFit() {
            for (id, pr) in progress where pr.status == .placed && pr.anchorID == nil {
                guard let m = pr.measuredLayout else { continue }
                let w2 = base.apply(m)
                let p = worldPoint(w2, height: interpolatedHeight(at: w2))
                let anchor = ARAnchor(name: "cone-\(id)", transform: simd_float4x4(translation: p))
                arView.session.add(anchor: anchor)
                anchorPositions[anchor.identifier] = p
                progress[id]?.anchorID = anchor.identifier
            }
        }

        phase = .placing
        advance()
    }

    private func baselineFit() -> Transform2D? {
        guard let a = refAPosition, let b = refBPosition else { return nil }
        return RigidFit.fit([
            FitPair(layout: layout.refA, world: a.ground2D, weight: 1),
            FitPair(layout: layout.refB, world: b.ground2D, weight: 1),
        ])
    }

    /// Whole-layout fit from both references and every measured cone.
    private func globalFit() -> Transform2D? {
        guard let a = refAPosition, let b = refBPosition else { return nil }
        var pairs = [
            FitPair(layout: layout.refA, world: a.ground2D, weight: 2),
            FitPair(layout: layout.refB, world: b.ground2D, weight: 2),
        ]
        for (id, pr) in progress where pr.status == .placed {
            guard let aid = pr.anchorID, let w = anchorPositions[aid], let c = coneByID[id] else { continue }
            pairs.append(FitPair(layout: c.pos, world: w.ground2D, weight: 1))
        }
        return RigidFit.fit(pairs)
    }

    /// Chain mode: a fit weighted towards the cones nearest the target, so each new cone is
    /// set out from the real cones next to it rather than from references far away.
    private func localFit(for p: Vec2) -> Transform2D? {
        guard let a = refAPosition, let b = refBPosition else { return nil }
        let radius = 4.0
        func weight(_ q: Vec2, _ base: Double) -> Double {
            let d = dist2(q, p) / radius
            return base / (1 + d * d)
        }
        var pairs = [
            FitPair(layout: layout.refA, world: a.ground2D, weight: weight(layout.refA, 3)),
            FitPair(layout: layout.refB, world: b.ground2D, weight: weight(layout.refB, 3)),
        ]
        for (id, pr) in progress where pr.status == .placed {
            guard let aid = pr.anchorID, let w = anchorPositions[aid], let c = coneByID[id] else { continue }
            pairs.append(FitPair(layout: c.pos, world: w.ground2D, weight: weight(c.pos, 1)))
        }
        return RigidFit.fit(pairs)
    }

    private func targetFit(for cone: PlannedCone, global: Transform2D) -> Transform2D {
        settings.chainMode ? (localFit(for: cone.pos) ?? global) : global
    }

    private func refreshMeasuredLayout() {
        guard let g = globalFit() else { return }
        for (id, pr) in progress where pr.status == .placed {
            if let aid = pr.anchorID, let w = anchorPositions[aid] {
                progress[id]?.measuredLayout = g.inverse(w.ground2D)
            }
        }
    }

    // MARK: - Ground height & raycasts

    private func raycastGround() -> SIMD3<Float>? {
        guard arView.bounds.width > 0 else { return nil }
        let c = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        if let r = arView.raycast(from: c, allowing: .estimatedPlane, alignment: .horizontal).first {
            return r.worldTransform.position
        }
        if let r = arView.raycast(from: c, allowing: .existingPlaneInfinite, alignment: .horizontal).first {
            return r.worldTransform.position
        }
        return nil
    }

    /// Inverse-distance-weighted ground height from the references and measured cones.
    private func interpolatedHeight(at p: Vec2) -> Float {
        var samples: [SIMD3<Float>] = []
        if let a = refAPosition { samples.append(a) }
        if let b = refBPosition { samples.append(b) }
        for pr in progress.values where pr.status == .placed {
            if let aid = pr.anchorID, let w = anchorPositions[aid] { samples.append(w) }
        }
        if samples.isEmpty {
            return (arView.session.currentFrame?.camera.transform.position.y ?? 1.4) - 1.4
        }
        var sw = 0.0
        var sy = 0.0
        for s in samples {
            let d = dist2(s.ground2D, p)
            let w = 1 / (d * d + 0.25)
            sw += w
            sy += w * Double(s.y)
        }
        return Float(sy / sw)
    }

    private func groundHeight(at p: Vec2) -> Float {
        let guess = interpolatedHeight(at: p)
        let origin = SIMD3<Float>(Float(p.x), guess + 1.0, Float(-p.y))
        let query = ARRaycastQuery(origin: origin, direction: SIMD3<Float>(0, -1, 0),
                                   allowing: .existingPlaneGeometry, alignment: .horizontal)
        if let hit = arView.session.raycast(query).first {
            let y = hit.worldTransform.columns.3.y
            if abs(y - guess) < 0.25 { return y }
        }
        return guess
    }

    /// Intersects the crosshair ray with a horizontal plane at cone-tip height. Looking down at
    /// a cone, its tip is straight above the base centre, so this gives the base position
    /// without needing the depth sensor to see under the cone.
    private func tipMarkedPosition(coneHeight: Float, near p: Vec2) -> SIMD3<Float>? {
        let c = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let ray = arView.ray(through: c) else { return nil }
        let gy = groundHeight(at: p)
        let planeY = gy + coneHeight
        guard ray.direction.y < -0.08 else { return nil }
        let t = (planeY - ray.origin.y) / ray.direction.y
        guard t > 0.05, t < 8 else { return nil }
        let hit = ray.origin + ray.direction * t
        return SIMD3<Float>(hit.x, gy, hit.z)
    }

    // MARK: - Scene updates

    private func updateRefMarkers() {
        if let a = refAPosition {
            refAMarker.position = a
            refAMarker.isEnabled = true
        } else {
            refAMarker.isEnabled = false
        }
        if let b = refBPosition {
            refBMarker.position = b
            refBMarker.isEnabled = true
        } else {
            refBMarker.isEnabled = false
        }
    }

    private func updateMarkers(global: Transform2D) -> (rms: Double?, worst: Double?) {
        let tol = settings.toleranceCM / 100
        var sumSq = 0.0
        var n = 0
        var worst = 0.0

        for cone in layout.cones {
            guard let e = markers[cone.id] else { continue }
            let pr = progress[cone.id] ?? ConeProgress()
            let key: String
            let pos: SIMD3<Float>

            if pr.status == .placed, let aid = pr.anchorID, let w = anchorPositions[aid] {
                let r = dist2(w.ground2D, global.apply(cone.pos))
                sumSq += r * r
                n += 1
                worst = max(worst, r)
                key = r > max(2 * tol, 0.05) ? "flag" : "placed-\(cone.color.rawValue)"
                pos = w
            } else {
                let p2 = global.apply(cone.pos)
                pos = worldPoint(p2, height: interpolatedHeight(at: p2))
                key = "\(pr.status.rawValue)-\(cone.color.rawValue)"
            }

            if cone.id == targetID {
                e.isEnabled = false
                continue
            }
            e.isEnabled = settings.showAllMarkers || pr.status != .pending
            if markerKeys[cone.id] != key {
                e.model = EntityFactory.markerModel(key: key, color: cone.color)
                markerKeys[cone.id] = key
            }
            e.position = pos + SIMD3<Float>(0, EntityFactory.markerYOffset(key: key), 0)
        }
        guard n > 0 else { return (nil, nil) }
        return ((sumSq / Double(n)).squareRoot(), worst)
    }

    private func advance() {
        let pending = layout.cones.filter { (progress[$0.id]?.status ?? .pending) == .pending }
        guard !pending.isEmpty else {
            targetID = nil
            rebuildGhost()
            phase = .finished
            Haptics.success()
            return
        }
        let next: PlannedCone?
        switch settings.order {
        case .sequential:
            next = pending.first
        case .nearest:
            let from = history.last.flatMap { coneByID[$0]?.pos } ?? hud.cameraLayout ?? layout.refA
            next = pending.min { dist2($0.pos, from) < dist2($1.pos, from) }
        }
        setTarget(next?.id)
    }

    private func setTarget(_ id: Int?) {
        targetID = id
        lastWithin = false
        lastBand = 99
        rebuildGhost()
    }

    private func rebuildGhost() {
        ghost?.root.removeFromParent()
        ghost = nil
        guard let cone = currentCone else { return }
        let g = GhostEntity(color: cone.color, tolerance: Float(settings.toleranceCM / 100))
        g.root.isEnabled = false
        root.addChild(g.root)
        ghost = g
    }

    private func feedback(within: Bool, offset: Double?) {
        if within && !lastWithin { Haptics.success() }
        lastWithin = within
        guard let o = offset else {
            lastBand = 99
            return
        }
        let thresholds: [Double] = [1.0, 0.5, 0.25, 0.1]
        let band = thresholds.firstIndex(where: { o > $0 }) ?? thresholds.count
        if lastBand != 99, band > lastBand, !within { Haptics.tick() }
        lastBand = band
    }

    private func removeAnchor(_ id: UUID) {
        if let anchor = arView.session.currentFrame?.anchors.first(where: { $0.identifier == id }) {
            arView.session.remove(anchor: anchor)
        }
        anchorPositions.removeValue(forKey: id)
    }

    private func settingsDidChange(from old: PlacementSettings) {
        if old.toleranceCM != settings.toleranceCM { rebuildGhost() }
        if old.showMesh != settings.showMesh || old.occlusion != settings.occlusion { applyViewOptions() }
        if old.order != settings.order, phase == .placing { advance() }
    }

    private func applyViewOptions() {
        if settings.showMesh {
            arView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            arView.debugOptions.remove(.showSceneUnderstanding)
        }
        if settings.occlusion {
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        } else {
            arView.environment.sceneUnderstanding.options.remove(.occlusion)
        }
    }

    private func show(_ message: String) {
        toast = message
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }
}
