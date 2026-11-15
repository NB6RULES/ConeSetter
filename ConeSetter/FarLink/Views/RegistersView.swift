import SwiftUI

struct FarLinkRegistersView: View {
    @Environment(FardriverLink.self) private var link
    @State private var mode = 0
    @State private var editAddr: RegisterAddress?
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    Text("Registers").tag(0)
                    Text("Traffic").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if mode == 0 { registerList } else { TrafficLog() }
            }
            .navigationTitle("Registers")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editAddr) { a in RawRegisterEditor(address: a.value) }
        }
    }

    private var registerList: some View {
        List {
            Section {
                ForEach(addresses, id: \.self) { a in
                    Button { if a < 0xD6 { editAddr = RegisterAddress(value: a) } } label: {
                        HStack {
                            Text(String(format: "0x%02X", a)).font(.body.monospaced()).foregroundStyle(.secondary)
                            Text(label(a)).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                            Spacer()
                            let w = link.memory.u16(a)
                            Text(String(format: "%04X", w)).font(.body.monospaced())
                            Text("\(Int16(bitPattern: w))").font(.caption.monospaced()).foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } footer: {
                Text("0x00–0xD5 are settings; 0xD6 and up are live status. Labels come from the community register map and some are guesses.")
            }
        }
        .listStyle(.plain)
        .searchable(text: $filter, prompt: "Address or name")
    }

    private var addresses: [UInt8] {
        (0...255).map { UInt8($0) }.filter { link.memory.has($0) }.filter { a in
            guard !filter.isEmpty else { return true }
            let q = filter.lowercased().replacingOccurrences(of: "0x", with: "")
            return String(format: "%02x", a).contains(q) || label(a).lowercased().contains(q)
        }
    }

    private func label(_ a: UInt8) -> String {
        let names = ParamCatalog.all.filter { $0.address == a }.map(\.name)
        if !names.isEmpty { return names.joined(separator: " / ") }
        return RegisterNames.map[a] ?? ""
    }
}

struct RegisterAddress: Identifiable { let value: UInt8; var id: UInt8 { value } }

enum RegisterNames {
    static let map: [UInt8: String] = [
        0x06: "anti-theft / 485 config", 0x07: "speed KI / KP", 0x09: "FAIF", 0x0A: "curve time",
        0x0C: "phase offset", 0x0F: "start/mid KI", 0x12: "LD (field weakening)", 0x13: "alarm delay",
        0x1B: "LQ", 0x1D: "internal resistance", 0x1E: "fw/re ratio + flags", 0x20: "custom code",
        0x21: "function enables", 0x26: "custom max line current", 0x27: "custom max phase current",
        0x2C: "free throttle", 0x2E: "speed analog", 0x32: "low/mid speed line current",
        0x34: "block time", 0x35: "speed pulse count", 0x63: "max line current 2", 0x64: "max phase current 2",
        0x67: "product max voltage", 0x69: "pin map", 0x6A: "pin map", 0x6B: "pin map", 0x6C: "limit speed",
        0x6D: "odometer low", 0x7C: "config word", 0x81: "odometer high", 0x82: "throttle voltage",
        0x83: "high voltage restore", 0x86: "CAN cfg / HW version", 0x87: "SW version",
        0xA0: "system command", 0xD0: "one-line comm", 0xD1: "avg power", 0xD2: "wheel ratio / radius",
        0xD3: "avg speed / wheel width", 0xD4: "speed ratio", 0xD5: "one-line config",
        0xD7: "state flags 1", 0xD8: "state flags 2", 0xD9: "state flags 3", 0xDA: "state flags 4",
        0xDB: "MOSFET temp", 0xE2: "gear / direction flags", 0xE3: "fault flags", 0xE4: "modulation",
        0xE5: "motor speed", 0xE6: "Iq?", 0xE7: "Id?", 0xE8: "battery voltage ×10", 0xE9: "per mille",
        0xEA: "line current ×4", 0xED: "throttle depth", 0xF0: "phase A current", 0xF1: "phase A/C current",
        0xF2: "phase C current", 0xF3: "voltage", 0xF4: "motor temp", 0xF5: "SOC", 0xF8: "exec total",
        0xF9: "exec single", 0xFC: "stop state", 0xFE: "running state",
    ]
}

struct RawRegisterEditor: View {
    @Environment(FardriverLink.self) private var link
    @Environment(\.dismiss) private var dismiss
    let address: UInt8
    @State private var hex = ""
    @State private var confirm = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Raw register writes bypass all safety ranges. Only change registers you understand, and note the original value first.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(FLTheme.danger)
                }
                Section("Current") {
                    LabeledContent("Hex", value: String(format: "0x%04X", link.memory.u16(address)))
                    LabeledContent("Unsigned", value: "\(link.memory.u16(address))")
                    LabeledContent("Signed", value: "\(link.memory.i16(address))")
                    LabeledContent("Bytes (lo, hi)", value: "\(link.memory.lo(address)), \(link.memory.hi(address))")
                }
                Section {
                    TextField("e.g. 01F4", text: $hex)
                        .font(.title3.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    if let v = parsed { Text("= \(v) unsigned, \(Int16(bitPattern: v)) signed").font(.caption).foregroundStyle(.secondary) }
                    Button("Write") { confirm = true }
                        .disabled(parsed == nil || !link.canWrite)
                } header: {
                    Text("New value (hex)")
                } footer: {
                    if let error { Text(error).foregroundStyle(FLTheme.danger) }
                    else if let p = link.pendingWrites[address] { Text(statusText(p.status)) }
                }
            }
            .navigationTitle(String(format: "Register 0x%02X", address))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { hex = String(format: "%04X", link.memory.u16(address)) }
            .confirmationDialog("Write raw value?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Write", role: .destructive) {
                    if let v = parsed { error = link.writeRegister(address, v) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var parsed: UInt16? {
        UInt16(hex.replacingOccurrences(of: "0x", with: "").trimmingCharacters(in: .whitespaces), radix: 16)
    }

    private func statusText(_ s: PendingWrite.Status) -> String {
        switch s {
        case .sending, .waiting: "Waiting for confirmation…"
        case .verified: "Confirmed by controller."
        case .mismatch(let v): String(format: "Controller reports 0x%04X instead.", v)
        case .timedOut: "No confirmation within 5 s."
        case .failed(let m): m
        }
    }
}

struct TrafficLog: View {
    @Environment(FardriverLink.self) private var link

    var body: some View {
        @Bindable var link = link
        VStack(spacing: 0) {
            HStack {
                Toggle("Pause", isOn: $link.logPaused).toggleStyle(.button)
                Button("Clear") { link.clearLog() }
                Spacer()
                ShareLink(item: exportText) { Image(systemName: "square.and.arrow.up") }
            }
            .padding(.horizontal).padding(.bottom, 8)

            ScrollViewReader { proxy in
                List(link.log) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Text(e.dir.rawValue).font(.caption2.monospaced().bold())
                            .foregroundStyle(e.dir == .tx ? FLTheme.warn : e.dir == .rx ? FLTheme.accent : .secondary)
                        Text(e.text).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                    .id(e.id)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                }
                .listStyle(.plain)
                .onChange(of: link.log.count) {
                    if !link.logPaused, let last = link.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var exportText: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        return link.log.map { "\(f.string(from: $0.time)) \($0.dir.rawValue) \($0.text)" }.joined(separator: "\n")
    }
}
