import SwiftUI
import UIKit

/// Shared look: dark, high-contrast, orange accent.
enum Theme {
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.07)
    static let accentDeep = Color(red: 0.93, green: 0.16, blue: 0.22)
    static let surface = Color(red: 0.105, green: 0.11, blue: 0.13)
    static let surfaceHigh = Color(red: 0.15, green: 0.155, blue: 0.18)
    static let stroke = Color.white.opacity(0.08)

    static let accentGradient = LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let background = LinearGradient(
        colors: [Color(red: 0.07, green: 0.075, blue: 0.09), Color(red: 0.03, green: 0.03, blue: 0.04)],
        startPoint: .top, endPoint: .bottom)

    static let corner: CGFloat = 20
}

struct CardStyle: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View { modifier(CardStyle(padding: padding)) }

    /// Standard screen background for lists and scroll views.
    func themedList() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
    }

    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct SectionTitle: View {
    var text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let s = systemImage {
                Image(systemName: s).foregroundStyle(Theme.accent)
            }
            Text(text.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Small icon in a tinted rounded square.
struct IconBadge: View {
    var systemImage: String
    var tint: Color = Theme.accent
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct ProgressRing: View {
    var fraction: Double
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 4)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded()))")
                .font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
    }
}
