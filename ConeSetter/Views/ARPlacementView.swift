import SwiftUI

struct ARPlacementView: View {
    @StateObject private var ctrl: PlacementController
    @StateObject private var location = LocationService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showMap = true
    @State private var showSettings = false
    @State private var share: ShareItem?
    @State private var confirmExit = false

    init(layout: ConeLayout, resume: SavedSession?) {
        _ctrl = StateObject(wrappedValue: PlacementController(layout: layout, resume: resume))
    }

    var body: some View {
        ZStack {
            ARViewContainer(arView: ctrl.arView)
                .ignoresSafeArea()

            CrosshairView(hit: ctrl.hud.crosshairHit, good: ctrl.hud.withinTolerance)

            VStack(spacing: 10) {
                topBar
                HStack(alignment: .top) {
                    statusColumn
                    Spacer()
                    if showMap { miniMap }
                }
                Spacer()
                if let t = ctrl.toast {
                    Text(t)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity)
                }
                bottomPanel
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .animation(.easeInOut(duration: 0.2), value: ctrl.toast)
        .onAppear {
            ctrl.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            ctrl.pause()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(isPresented: $showSettings) {
            PlacementSettingsView(settings: $ctrl.settings)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $share) { ActivityView(items: [$0.url]) }
        .confirmationDialog("Leave this layout?", isPresented: $confirmExit, titleVisibility: .visible) {
            Button("Save and exit") { ctrl.saveSession { dismiss() } }
            Button("Exit without saving", role: .destructive) { dismiss() }
            Button("Keep placing", role: .cancel) {}
        }
        .statusBarHidden()
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                confirmExit = true
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .tint(.primary)

            Text(ctrl.layout.name)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Text("\(ctrl.doneCount)/\(ctrl.layout.cones.count)")
                .font(.headline.monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())

            Menu {
                Button { showSettings = true } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                Button { showMap.toggle() } label: { Label(showMap ? "Hide map" : "Show map", systemImage: "map") }
                Button { ctrl.undo() } label: { Label("Undo last cone", systemImage: "arrow.uturn.backward") }
                Button { ctrl.saveSession() } label: { Label("Save session", systemImage: "square.and.arrow.down") }
                Button {
                    if let url = ctrl.exportCSV() { share = ShareItem(url: url) }
                } label: {
                    Label("Export CSV", systemImage: "tablecells")
                }
                Button(role: .destructive) { ctrl.restartAlignment() } label: {
                    Label("Re-align (tap A and B again)", systemImage: "scope")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .tint(.primary)
        }
    }

    private var statusColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chip(text: ctrl.hud.tracking,
                 systemImage: ctrl.hud.trackingGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                 tint: ctrl.hud.trackingGood ? .green : .yellow)
            if ctrl.hud.hasLiDAR {
                Chip(text: "LiDAR · \(ctrl.hud.mapping)", systemImage: "dot.radiowaves.left.and.right")
            }
            if let loc = location.location {
                Chip(text: String(format: "GPS ±%.0f m", loc.horizontalAccuracy), systemImage: "location.fill")
            }
            if let rms = ctrl.hud.fitRMS {
                Chip(text: "Fit RMS \(Fmt.cm(rms))", systemImage: "chart.dots.scatter",
                     tint: rms * 100 <= ctrl.settings.toleranceCM ? .green : .orange)
            }
        }
    }

    private var miniMap: some View {
        LayoutPreview(
            layout: ctrl.layout,
            progress: ctrl.progress,
            targetID: ctrl.targetID,
            live: true,
            camera: ctrl.hud.cameraLayout,
            cameraHeading: ctrl.hud.cameraHeadingLayout,
            onTapCone: { ctrl.selectTarget($0) }
        )
        .frame(width: 150, height: 150)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.2)))
    }

    // MARK: Bottom

    @ViewBuilder
    private var bottomPanel: some View {
        switch ctrl.phase {
        case .alignA, .alignB:
            alignPanel
        case .placing:
            placingPanel
        case .finished:
            finishedPanel
        }
    }

    private var alignPanel: some View {
        let isA = ctrl.phase == .alignA
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(isA ? "A" : "B")
                    .font(.title2.bold())
                    .frame(width: 40, height: 40)
                    .background(isA ? Color.pink : Color.teal, in: Circle())
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isA ? "Step 1 · Reference A" : "Step 2 · Reference B").font(.headline)
                    Text(isA ? ctrl.layout.refAHint : ctrl.layout.refBHint).font(.subheadline)
                }
            }
            Text("Stand next to the mark, put the crosshair on it and tap Set.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !isA, let m = ctrl.hud.measuredAB {
                let plan = ctrl.layout.baselineLength
                Text(String(format: "Crosshair is %.2f m from A · plan %.2f m", m, plan))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(abs(m - plan) < 0.05 ? .green : .primary)
            }
            HStack(spacing: 10) {
                if !isA {
                    Button("Redo A") { ctrl.restartAlignment() }
                        .buttonStyle(FilledButtonStyle(color: .gray))
                        .frame(width: 110)
                }
                Button(isA ? "Set A" : "Set B") { ctrl.setReference() }
                    .buttonStyle(FilledButtonStyle(color: isA ? .pink : .teal))
                    .disabled(!ctrl.hud.crosshairHit)
            }
        }
        .panel()
    }

    private var placingPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let cone = ctrl.currentCone {
                HStack(spacing: 12) {
                    ConeSwatch(color: cone.color, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cone \(cone.id + 1) · \(cone.color.label)").font(.headline)
                        Text(cone.group).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let d = ctrl.hud.distanceToTarget {
                        VStack(spacing: 2) {
                            DirectionArrow(bearing: ctrl.hud.bearing)
                            Text(Fmt.distance(d)).font(.caption.monospacedDigit().weight(.semibold))
                        }
                    }
                }

                offsetReadout

                HStack(spacing: 8) {
                    Button("Skip") { ctrl.skip() }
                        .buttonStyle(FilledButtonStyle(color: .gray))
                        .frame(width: 74)
                    Button("As planned") { ctrl.acceptAsPlanned() }
                        .buttonStyle(FilledButtonStyle(color: .indigo))
                        .frame(width: 118)
                    Button("Mark placed") { ctrl.markPlaced() }
                        .buttonStyle(FilledButtonStyle(color: .green))
                }
                Text(ctrl.settings.markMode == .tip
                     ? "Put the cone inside the ghost, then look down and put the crosshair on its tip."
                     : "Put the cone inside the ghost, then put the crosshair on the ground at its centre.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Pick a cone on the map").font(.headline)
            }
        }
        .panel()
    }

    @ViewBuilder
    private var offsetReadout: some View {
        if let total = ctrl.hud.offsetTotal, let f = ctrl.hud.offsetForward, let l = ctrl.hud.offsetLeft {
            let ok = ctrl.hud.withinTolerance
            HStack(spacing: 10) {
                Image(systemName: ok ? "checkmark.seal.fill" : "scope")
                    .font(.title2)
                    .foregroundStyle(ok ? .green : .orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ok ? "Crosshair is on the spot" : "Spot is \(Fmt.cm(total)) from crosshair")
                        .font(.subheadline.weight(.semibold))
                    if !ok {
                        Text("\(Fmt.cm(f)) \(f >= 0 ? "ahead" : "behind") · \(Fmt.cm(l)) \(l >= 0 ? "left" : "right")")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((ok ? Color.green : Color.orange).opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        } else {
            Text("Point the crosshair at the ground near the ghost cone")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var finishedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("All cones done", systemImage: "flag.checkered")
                .font(.title3.bold())
            if let rms = ctrl.hud.fitRMS, let worst = ctrl.hud.worstResidual {
                Text("Fit RMS \(Fmt.cm(rms)) · worst cone \(Fmt.cm(worst)) off. Red markers show cones outside tolerance — tap them on the map to redo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Export CSV") {
                    if let url = ctrl.exportCSV() { share = ShareItem(url: url) }
                }
                .buttonStyle(FilledButtonStyle(color: .indigo))
                Button("Save") { ctrl.saveSession() }
                    .buttonStyle(FilledButtonStyle(color: .green))
            }
        }
        .panel()
    }
}

struct PlacementSettingsView: View {
    @Binding var settings: PlacementSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Tolerance", selection: $settings.toleranceCM) {
                        ForEach([1.0, 2.0, 3.0, 5.0, 10.0], id: \.self) { v in
                            Text("\(Int(v)) cm").tag(v)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Placement tolerance")
                } footer: {
                    Text("The crosshair turns green and the phone buzzes inside this radius.")
                }

                Section {
                    Toggle("Chain from placed cones", isOn: $settings.chainMode)
                    Picker("Next cone", selection: $settings.order) {
                        ForEach(OrderMode.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Marking", selection: $settings.markMode) {
                        ForEach(MarkMode.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Workflow")
                } footer: {
                    Text("Chain mode sets each cone out from the real cones nearest to it, so tracking drift doesn't build up along the track.")
                }

                Section("Display") {
                    Toggle("Show all cone markers", isOn: $settings.showAllMarkers)
                    Toggle("Show LiDAR mesh", isOn: $settings.showMesh)
                    Toggle("Hide ghosts behind real objects", isOn: $settings.occlusion)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
