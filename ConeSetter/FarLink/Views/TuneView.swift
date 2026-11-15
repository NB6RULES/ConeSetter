import SwiftUI

struct FarLinkTuneView: View {
    @Environment(FardriverLink.self) private var link
    @State private var editing: ParamDef?
    @State private var confirmReset = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                if !link.state.isLive {
                    Section { Text("Connect to a controller to read and change settings.").foregroundStyle(.secondary) }
                } else if !link.memory.configComplete {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Reading settings… \(link.memory.seenCount) / 256 registers")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if link.state.isLive && !link.motorStopped && !link.settings.allowWritesWhileMoving {
                    Section {
                        Label("Motor is turning — editing is locked until it stops.", systemImage: "lock.fill")
                            .foregroundStyle(FLTheme.warn)
                    }
                }

                ForEach(ParamCatalog.groups, id: \.self) { group in
                    Section(group) {
                        ForEach(ParamCatalog.all.filter { $0.group == group }) { def in
                            Button { editing = def } label: { ParamRow(def: def) }
                                .foregroundStyle(.primary)
                                .disabled(!link.memory.has(def.address))
                        }
                    }
                }

                Section {
                    Button("Reset controller to apply changes") { confirmReset = true }
                        .disabled(!link.state.isLive)
                } footer: {
                    Text("Some settings (direction, rated voltage, pole pairs) only take effect after a reset. Afterwards, power-cycle the controller and reconnect to confirm the new values were kept.")
                }
            }
            .themedList()
            .navigationTitle("Tune")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editing) { def in ParamEditSheet(def: def) }
            .confirmationDialog("Reset the controller?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset now", role: .destructive) { message = link.resetController() }
            } message: {
                Text("The motor will be disabled for a moment. Only do this with the vehicle stationary and supported.")
            }
            .alert("Couldn't reset", isPresented: .constant(message != nil)) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
        }
    }
}

struct ParamRow: View {
    @Environment(FardriverLink.self) private var link
    let def: ParamDef

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(def.name)
                    if def.risk == .high {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(FLTheme.warn)
                    }
                }
            }
            Spacer()
            if link.memory.has(def.address) {
                Text(def.format(def.displayValue(from: link.memory.u16(def.address))))
                    .font(.body.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text("–").foregroundStyle(.tertiary)
            }
            WriteStatusIcon(status: link.pendingWrites[def.address]?.status)
        }
    }
}

struct WriteStatusIcon: View {
    let status: PendingWrite.Status?
    var body: some View {
        switch status {
        case .none: EmptyView()
        case .sending?, .waiting?: ProgressView().controlSize(.small)
        case .verified?: Image(systemName: "checkmark.circle.fill").foregroundStyle(FLTheme.ok)
        case .mismatch?, .timedOut?, .failed?: Image(systemName: "xmark.octagon.fill").foregroundStyle(FLTheme.danger)
        }
    }
}

struct ParamEditSheet: View {
    @Environment(FardriverLink.self) private var link
    @Environment(\.dismiss) private var dismiss
    let def: ParamDef

    @State private var value: Double = 0
    @State private var original: Double = 0
    @State private var text = ""
    @State private var confirm = false
    @State private var error: String?
    @State private var sent = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(def.help).font(.callout)
                    if def.risk != .low {
                        Label(def.risk == .high ? "High risk — wrong values can damage the motor, controller or battery."
                                                : "Changes how the vehicle drives. Test carefully.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(def.risk == .high ? FLTheme.danger : FLTheme.warn)
                    }
                }

                Section("Value") {
                    LabeledContent("On controller", value: def.format(currentDisplay))
                    if let options = def.options {
                        Picker("New value", selection: Binding(get: { Int(value) }, set: { value = Double($0) })) {
                            ForEach(options.keys.sorted(), id: \.self) { k in Text(options[k]!).tag(k) }
                        }
                        .pickerStyle(.segmented)
                    } else {
                        HStack {
                            TextField("Value", text: $text)
                                .keyboardType(.decimalPad)
                                .font(.title2.monospacedDigit())
                                .onChange(of: text) { _, s in
                                    if let v = Double(s.replacingOccurrences(of: ",", with: ".")) { value = v }
                                }
                            Text(def.unit).foregroundStyle(.secondary)
                        }
                        Stepper("Adjust", value: Binding(get: { value }, set: { value = $0; text = trimmed($0) }),
                                in: def.range, step: def.step)
                        Text("Allowed \(trimmed(def.range.lowerBound)) – \(trimmed(def.range.upperBound)) \(def.unit)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !def.range.contains(value) {
                        Text("Out of range — will be clamped.").font(.caption).foregroundStyle(FLTheme.warn)
                    }
                    if isBigIncrease {
                        Text("That's more than 20% above the current value.").font(.caption).foregroundStyle(FLTheme.warn)
                    }
                }

                Section {
                    Button {
                        if def.risk == .low { doWrite() } else { confirm = true }
                    } label: {
                        Text("Write to controller").frame(maxWidth: .infinity).fontWeight(.semibold)
                    }
                    .disabled(!link.canWrite || value == original)
                    if !link.canWrite && link.state.isLive {
                        Text("Stop the motor to write.").font(.caption).foregroundStyle(FLTheme.warn)
                    }
                } footer: {
                    statusFooter
                }

                Section("Register") {
                    LabeledContent("Address", value: String(format: "0x%02X", def.address))
                    LabeledContent("Raw", value: String(format: "0x%04X", link.memory.u16(def.address)))
                }
            }
            .themedList()
            .navigationTitle(def.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear {
                original = currentDisplay
                value = original
                text = trimmed(original)
            }
            .confirmationDialog("Write \(def.format(value)) to \(def.name)?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Write", role: .destructive) { doWrite() }
            } message: {
                Text("Currently \(def.format(original)). Make sure the vehicle is stationary and the wheel is off the ground for the first test.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var currentDisplay: Double { def.displayValue(from: link.memory.u16(def.address)) }

    private var isBigIncrease: Bool {
        def.risk == .high && original > 0 && value > original * 1.2
    }

    @ViewBuilder private var statusFooter: some View {
        if let error {
            Text(error).foregroundStyle(FLTheme.danger)
        } else if sent, let p = link.pendingWrites[def.address] {
            switch p.status {
            case .sending, .waiting: Text("Sent — waiting for the controller to report the new value…")
            case .verified: Text("Controller confirmed the new value.").foregroundStyle(FLTheme.ok)
            case .mismatch(let got): Text("Controller still reports \(def.format(def.displayValue(from: got))). It may have rejected the value.").foregroundStyle(FLTheme.danger)
            case .timedOut: Text("No confirmation within 5 s. Check the value after reconnecting.").foregroundStyle(FLTheme.warn)
            case .failed(let m): Text(m).foregroundStyle(FLTheme.danger)
            }
        }
    }

    private func doWrite() {
        error = link.write(def, displayValue: value)
        sent = error == nil
        if sent { original = value }
    }

    private func trimmed(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.2f", v)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }
}
