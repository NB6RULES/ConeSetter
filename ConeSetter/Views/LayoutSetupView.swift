import SwiftUI

struct LayoutSetupView: View {
    private let kind: LayoutKind
    private let custom: ConeLayout?

    @State private var skid = SkidpadParams()
    @State private var accel = AccelParams()
    @State private var name: String
    @State private var active: ConeLayout?
    @State private var share: ShareItem?

    init(kind: LayoutKind) {
        self.kind = kind
        self.custom = nil
        _name = State(initialValue: kind == .skidpad ? "Skidpad" : "Acceleration")
    }

    init(custom: ConeLayout) {
        self.kind = .custom
        self.custom = custom
        _name = State(initialValue: custom.name)
    }

    private var layout: ConeLayout {
        var l: ConeLayout
        switch kind {
        case .skidpad: l = LayoutFactory.skidpad(skid)
        case .acceleration: l = LayoutFactory.acceleration(accel)
        case .custom: l = custom ?? LayoutFactory.acceleration(accel)
        }
        l.name = name.isEmpty ? l.name : name
        return l
    }

    var body: some View {
        let l = layout
        Form {
            Section {
                LayoutPreview(layout: l)
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())
                    .background(Color.black.opacity(0.85))
            } footer: {
                Text("Forward is to the right. A and B are the two points you mark and tape on the ground.")
            }

            Section("Summary") {
                LabeledContent("Cones", value: "\(l.cones.count)")
                ForEach(l.colorCounts) { item in
                    HStack {
                        ConeSwatch(color: item.color, size: 14)
                        Text(item.color.label)
                        Spacer()
                        Text("\(item.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Footprint", value: String(format: "%.1f × %.1f m", l.extent.width, l.extent.depth))
                LabeledContent("A–B baseline", value: Fmt.metres(l.baselineLength))
            }

            Section("References to mark") {
                Label { Text(l.refAHint) } icon: { Text("A").bold().foregroundStyle(.pink) }
                Label { Text(l.refBHint) } icon: { Text("B").bold().foregroundStyle(.teal) }
            }

            switch kind {
            case .skidpad: skidpadSection
            case .acceleration: accelSection
            case .custom: EmptyView()
            }

            Section {
                TextField("Session name", text: $name)
            } header: {
                Text("Name")
            }

            Section {
                Button("Start placing cones") { active = layout }
                    .buttonStyle(FilledButtonStyle())
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                Text("Check dimensions against the current FS / FS-AI rules and handbook before a real test.")
            }
        }
        .navigationTitle(name.isEmpty ? "Layout" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(l.name.replacingOccurrences(of: " ", with: "_"))_layout.csv")
                    try? l.csv().write(to: url, atomically: true, encoding: .utf8)
                    share = ShareItem(url: url)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $share) { ActivityView(items: [$0.url]) }
        .fullScreenCover(item: $active) { layout in
            ARPlacementView(layout: layout, resume: nil)
        }
    }

    private var skidpadSection: some View {
        Section("Skidpad dimensions") {
            numberRow("Inner circle Ø", $skid.innerDiameter, "m")
            numberRow("Outer circle Ø", $skid.outerDiameter, "m")
            numberRow("Centre to centre", $skid.centreDistance, "m")
            Stepper("Inner cones per circle: \(skid.innerCount)", value: $skid.innerCount, in: 4...40)
            Stepper("Outer cones per circle: \(skid.outerCount)", value: $skid.outerCount, in: 4...40)
            numberRow("Entry lane length", $skid.entryLength, "m")
            numberRow("Exit lane length", $skid.exitLength, "m")
            numberRow("Lane cone spacing", $skid.laneSpacing, "m")
            Toggle("Big orange timing cones", isOn: $skid.timingCones)
            Button("Reset to FS defaults") { skid = SkidpadParams() }
        }
    }

    private var accelSection: some View {
        Section("Acceleration dimensions") {
            numberRow("Length", $accel.length, "m")
            numberRow("Track width", $accel.width, "m")
            numberRow("Cone spacing", $accel.spacing, "m")
            numberRow("Stop area length", $accel.stopLength, "m")
            numberRow("Stop area spacing", $accel.stopSpacing, "m")
            Toggle("Big orange timing cones", isOn: $accel.timingCones)
            Button("Reset to FS defaults") { accel = AccelParams() }
        }
    }

    private func numberRow(_ title: String, _ value: Binding<Double>, _ unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}
