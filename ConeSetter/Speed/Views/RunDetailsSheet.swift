import SwiftUI

/// Sheet for labelling a run: name, driver, run type and notes.
struct RunDetailsSheet: View {
    @State var details: RunDetails
    let onSave: (RunDetails) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("recentDrivers") private var recentDriversRaw = ""

    private var recentDrivers: [String] {
        recentDriversRaw.split(separator: "\n").map(String.init)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Run name") {
                    TextField("Name", text: $details.name)
                }
                Section("Driver") {
                    TextField("Driver name", text: $details.driver)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    if !recentDrivers.isEmpty {
                        picks(recentDrivers, current: details.driver) { details.driver = $0 }
                    }
                }
                Section("Run type") {
                    TextField("e.g. Skidpad", text: $details.runType)
                        .textInputAutocapitalization(.sentences)
                    picks(RunType.presets, current: details.runType) { details.runType = $0 }
                }
                Section {
                    TextEditor(text: $details.notes)
                        .frame(minHeight: 130)
                } header: {
                    Text("Notes")
                } footer: {
                    Text("Tyres and pressures, setup changes, weather, what happened on the run. Driver, type and notes go into the Excel export and the zip index.")
                }
            }
            .themedList()
            .navigationTitle("Run details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        rememberDriver(details.driver)
                        onSave(details)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(details.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .tint(Theme.accent)
    }

    private func picks(_ options: [String], current: String, pick: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    let on = option.caseInsensitiveCompare(current.trimmingCharacters(in: .whitespaces)) == .orderedSame
                    Button { pick(on ? "" : option) } label: {
                        Text(option)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .background(on ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceHigh), in: Capsule())
                            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
    }

    private func rememberDriver(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        var list = recentDrivers.filter { $0.caseInsensitiveCompare(n) != .orderedSame }
        list.insert(n, at: 0)
        recentDriversRaw = list.prefix(8).joined(separator: "\n")
    }
}

/// Driver and run-type tags shown on run rows and the run page.
struct RunTags: View {
    var driver: String?
    var runType: String?

    var body: some View {
        HStack(spacing: 6) {
            if let d = driver, !d.isEmpty { tag(d, "person.fill") }
            if let t = runType, !t.isEmpty { tag(t, "flag.fill") }
        }
    }

    private func tag(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.accent.opacity(0.14), in: Capsule())
    }
}
