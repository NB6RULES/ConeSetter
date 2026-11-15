import SwiftUI

struct FarLinkSettingsView: View {
    @Environment(FardriverLink.self) private var link

    var body: some View {
        @Bindable var s = link.settings
        NavigationStack {
            Form {
                Section {
                    Picker("Start-up handshake", selection: $s.handshake) {
                        ForEach(Handshake.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if s.handshake == .openAndKeepAlive {
                        Stepper(String(format: "Keep-alive every %.1f s", s.keepAliveSeconds),
                                value: $s.keepAliveSeconds, in: 0.5...10, step: 0.5)
                    }
                    Toggle("Reconnect automatically", isOn: $s.autoReconnect)
                } header: { Text("Connection") } footer: {
                    Text(s.handshake.detail + " Changes apply on the next connection.")
                }

                Section {
                    Toggle("Show mph", isOn: $s.useMph)
                    HStack {
                        Text("Wheel circumference")
                        Spacer()
                        TextField("auto", value: $s.wheelCircumferenceMm, format: .number)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
                        Text("mm").foregroundStyle(.secondary)
                    }
                    Stepper(String(format: "RPM divisor: %.0f", s.rpmDivisor), value: $s.rpmDivisor, in: 1...64)
                } header: { Text("Display") } footer: {
                    Text("Leave wheel circumference at 0 to use the controller's own wheel settings. If the rpm reading looks too high, set the divisor (some firmwares report ×4 or × pole pairs). Include any gear/chain ratio in the circumference for mid-drives.")
                }

                Section {
                    Toggle("Allow writes while moving", isOn: $s.allowWritesWhileMoving)
                } header: { Text("Safety") } footer: {
                    Text("Off by default. Changing current or speed limits while the motor is under load can cause sudden jumps in torque.")
                }

                Section("About") {
                    LabeledContent("Protocol", value: "FarDriver BLE (FFE0 / FFEC)")
                    LabeledContent("Frames accepted", value: "\(link.memory.seenCount) registers known")
                    Text("Built on community reverse-engineering of the FarDriver protocol (jackhumbert/fardriver-controllers). Not affiliated with Nanjing FarDriver.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .themedList()
            .navigationTitle("FarLink settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
