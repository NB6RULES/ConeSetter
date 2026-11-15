import SwiftUI

struct FarLinkDashboardView: View {
    @Environment(FardriverLink.self) private var link

    var body: some View {
        let t = link.telemetry
        ScrollView {
            VStack(spacing: 14) {
                if !t.faults.isEmpty { FaultBanner(faults: t.faults) }

                VStack(spacing: 12) {
                    FLSpeedGauge(
                        value: link.speed ?? link.rpm,
                        unit: link.speed != nil ? link.speedUnit : "rpm",
                        fraction: min(1, max(0, link.rpm / max(1, Double(link.memory.u16(0x15))))),
                        sub: link.speed != nil ? String(format: "%.0f rpm", link.rpm) : nil,
                        gear: t.gear, reverse: t.reverse, brake: t.brake
                    )
                    PowerBar(watts: t.power)
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.surfaceHigh, Theme.surface], startPoint: .top, endPoint: .bottom))
                )
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)

                SectionTitle(text: "Live data", systemImage: "waveform.path.ecg")
                    .frame(maxWidth: .infinity, alignment: .leading)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    FLTile("Battery", String(format: "%.1f", t.voltage), "V")
                    FLTile("Current", String(format: "%.1f", t.lineCurrent), "A", color: t.lineCurrent < 0 ? FLTheme.regen : nil)
                    FLTile("SOC", socText(t), "%")
                    FLTile("Phase A", String(format: "%.0f", t.phaseA), "A")
                    FLTile("Phase C", String(format: "%.0f", t.phaseC), "A")
                    FLTile("Throttle", t.throttleVolts.map { String(format: "%.2f", $0) } ?? "–", "V")
                    FLTile("Controller", "\(t.mosTemp)", "°C", color: tempColor(t.mosTemp, limit: Int(link.memory.lo(0x85))))
                    FLTile("Motor", "\(t.motorTemp)", "°C", color: tempColor(t.motorTemp, limit: Int(link.memory.lo(0x84))))
                    FLTile("Modulation", String(format: "%.0f", t.modulation * 100), "%")
                }

                HStack {
                    Label(t.forward ? "Forward" : t.reverse ? "Reverse" : "Neutral",
                          systemImage: t.reverse ? "arrow.uturn.backward" : "arrow.up")
                    Spacer()
                    if let odo = t.odometerKm {
                        Text(link.settings.useMph ? String(format: "%.1f mi", odo * 0.621371) : String(format: "%.1f km", odo))
                    }
                    Spacer()
                    if let fw = t.firmware { Text("FW \(fw)") }
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

                if link.state.isLive && link.framesPerSecond == 0 && link.lastFrameAt == nil {
                    NoDataHint()
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private func socText(_ t: Telemetry) -> String {
        if let s = t.soc { return "\(s)" }
        if let s = t.socFromVoltage { return String(format: "%.0f", s) }
        return "–"
    }

    private func tempColor(_ v: Int, limit: Int) -> Color? {
        guard limit > 0 else { return nil }
        if v >= limit - 5 { return FLTheme.danger }
        if v >= limit - 20 { return FLTheme.warn }
        return nil
    }
}

struct FLSpeedGauge: View {
    let value: Double
    let unit: String
    let fraction: Double
    let sub: String?
    let gear: Int
    let reverse: Bool
    let brake: Bool

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.125, to: 0.875)
                .stroke(FLTheme.track, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(90))
            Circle()
                .trim(from: 0.125, to: 0.125 + 0.75 * fraction)
                .stroke(AngularGradient(colors: [Theme.accent, Theme.accent, Theme.accentDeep, Theme.accentDeep],
                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(360)),
                        style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(90))
                .animation(.easeOut(duration: 0.15), value: fraction)
            VStack(spacing: 0) {
                Text(String(format: "%.0f", value))
                    .font(.system(size: 76, weight: .heavy, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text(unit.uppercased())
                    .font(.system(size: 13, weight: .bold, design: .rounded)).tracking(1.5)
                    .foregroundStyle(.secondary)
                if let sub { Text(sub).font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.top, 4) }
            }
            VStack {
                Spacer()
                HStack(spacing: 16) {
                    Text(reverse ? "R" : "G\(gear)")
                        .font(.system(.title3, design: .rounded).weight(.heavy))
                        .foregroundStyle(reverse ? FLTheme.warn : FLTheme.accent)
                    if brake {
                        Text("BRAKE").font(.caption.weight(.heavy)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(FLTheme.danger, in: Capsule())
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .frame(height: 260)
        .padding(.horizontal, 20)
    }
}

struct PowerBar: View {
    let watts: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("POWER")
                    .font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(watts.magnitude >= 1000 ? String(format: "%.2f kW", watts / 1000) : String(format: "%.0f W", watts))
                    .font(.system(.headline, design: .rounded).weight(.bold)).monospacedDigit()
                    .foregroundStyle(watts < 0 ? FLTheme.regen : .primary)
            }
            GeometryReader { geo in
                let maxW = 10_000.0
                let f = min(1, abs(watts) / maxW)
                ZStack(alignment: watts < 0 ? .trailing : .leading) {
                    Capsule().fill(FLTheme.track)
                    Capsule().fill(watts < 0 ? AnyShapeStyle(FLTheme.regen) : AnyShapeStyle(Theme.accentGradient))
                        .frame(width: geo.size.width * f)
                }
            }
            .frame(height: 10)
        }
        .padding(.horizontal, 6)
    }
}

struct FLTile: View {
    let title: String, value: String, unit: String
    var color: Color?
    init(_ title: String, _ value: String, _ unit: String, color: Color? = nil) {
        self.title = title; self.value = value; self.unit = unit; self.color = color
    }
    var body: some View {
        // The same tile as the GPS tab, so both dashboards read alike.
        StatTile(title: title, value: value, unit: unit, tint: color ?? .primary)
    }
}

struct FaultBanner: View {
    let faults: [Fault]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Controller fault", systemImage: "exclamationmark.triangle.fill").font(.headline)
            ForEach(faults) { f in
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.name).font(.subheadline.weight(.semibold))
                    Text(f.detail).font(.caption).opacity(0.85)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(FLTheme.danger.opacity(0.22), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(FLTheme.danger.opacity(0.6), lineWidth: 1))
    }
}

struct NoDataHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connected, but no data yet").font(.headline)
            Text("Make sure the ignition is on and the official app is closed. If nothing arrives after a few seconds, try a different start-up handshake in Settings.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(FLTheme.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(FLTheme.warn.opacity(0.35), lineWidth: 1))
    }
}
