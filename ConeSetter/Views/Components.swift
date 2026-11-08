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
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
            configuration.label
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    (isEnabled ? color : Color.gray).opacity(configuration.isPressed ? 0.7 : 1),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .foregroundStyle(.white)
        }
    }
}

struct CrosshairView: View {
    var hit: Bool
    var good: Bool

    var body: some View {
        let c: Color = good ? .green : (hit ? .white : .red)
        ZStack {
            Circle().stroke(c, lineWidth: 2).frame(width: 34, height: 34)
            Rectangle().fill(c).frame(width: 2, height: 12)
            Rectangle().fill(c).frame(width: 12, height: 2)
        }
        .shadow(color: .black.opacity(0.7), radius: 2)
        .allowsHitTesting(false)
    }
}

struct DirectionArrow: View {
    var bearing: Double

    var body: some View {
        Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 44))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .orange)
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
