import SwiftUI
import UIKit
import RealityKit

struct ARViewContainer: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }
}

extension View {
    func panel() -> some View { modifier(PanelBackground()) }
}

struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: 4) {
            if let s = systemImage { Image(systemName: s) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 1))
    }
}

struct FilledButtonStyle: ButtonStyle {
    var color: Color = .orange

    func makeBody(configuration: Configuration) -> some View {
        FilledButtonLabel(configuration: configuration, color: color)
    }

    private struct FilledButtonLabel: View {
        let configuration: ButtonStyleConfiguration
        let color: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let base = isEnabled ? color : Color.gray
            configuration.label
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 6)
                .background(
                    LinearGradient(colors: [base, base.opacity(0.78)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
                .foregroundStyle(.white)
                .opacity(isEnabled ? 1 : 0.55)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

struct CrosshairView: View {
    var hit: Bool
    var good: Bool

    var body: some View {
        let c: Color = good ? .green : (hit ? .white : .red)
        ZStack {
            Circle().stroke(c.opacity(0.35), lineWidth: 1).frame(width: 54, height: 54)
                .scaleEffect(good ? 0.72 : 1)
            Circle().stroke(c, lineWidth: 2.5).frame(width: 34, height: 34)
            ForEach(0..<4) { i in
                Capsule().fill(c).frame(width: 2.5, height: 9)
                    .offset(y: -22)
                    .rotationEffect(.degrees(Double(i) * 90))
            }
            Circle().fill(c).frame(width: 4, height: 4)
        }
        .shadow(color: .black.opacity(0.7), radius: 2)
        .shadow(color: good ? Color.green.opacity(0.8) : .clear, radius: 8)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: good)
        .allowsHitTesting(false)
    }
}

struct DirectionArrow: View {
    var bearing: Double

    var body: some View {
        Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 44))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Theme.accent)
            .shadow(color: Theme.accent.opacity(0.5), radius: 6)
            .rotationEffect(.radians(-bearing))
            .animation(.easeOut(duration: 0.15), value: bearing)
    }
}

struct ConeSwatch: View {
    let color: ConeColor
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: "triangle.fill")
            .font(.system(size: size))
            .foregroundStyle(color.color)
            .shadow(color: .black.opacity(0.4), radius: 1)
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
