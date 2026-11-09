import Foundation
import SwiftUI
import UIKit

struct AppUpdate: Equatable {
    var version: String
    var build: Int
    var notes: String
    var downloadURL: URL?
}

/// Checks the SideStore source on GitHub for a newer build than the one installed.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let sourceURL = "https://raw.githubusercontent.com/NB6RULES/ConeSetter/main/source.json"
    static let releasesURL = URL(string: "https://github.com/NB6RULES/ConeSetter/releases/latest")!

    @Published private(set) var available: AppUpdate?
    @Published private(set) var checking = false
    @Published private(set) var status: String?

    private let defaults = UserDefaults.standard
    private let minInterval: TimeInterval = 3 * 3600

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }

    /// Update to show in the banner (nil if the user chose "Later" for this build).
    var banner: AppUpdate? {
        guard let u = available, u.build > defaults.integer(forKey: "updateDismissedBuild") else { return nil }
        return u
    }

    /// Automatic check: at launch and whenever the app comes back to the foreground,
    /// at most once every few hours.
    func checkIfDue() {
        let last = defaults.double(forKey: "updateLastCheck")
        guard Date().timeIntervalSince1970 - last > minInterval || available == nil && last == 0 else { return }
        Task { await check(manual: false) }
    }

    func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        if manual { status = nil }

        // The query string sidesteps GitHub's 5-minute raw-file cache.
        guard let url = URL(string: "\(Self.sourceURL)?t=\(Int(Date().timeIntervalSince1970))") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 12)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                if manual { status = "Couldn't reach the update server" }
                return
            }
            let source = try JSONDecoder().decode(Source.self, from: data)
            defaults.set(Date().timeIntervalSince1970, forKey: "updateLastCheck")
            let bundleID = Bundle.main.bundleIdentifier
            let app = source.apps.first { $0.bundleIdentifier == bundleID } ?? source.apps.first
            let newest = app?.versions?
                .compactMap { v -> AppUpdate? in
                    guard let b = Int(v.buildVersion ?? "") else { return nil }
                    return AppUpdate(version: v.version, build: b, notes: v.localizedDescription ?? "",
                                     downloadURL: v.downloadURL.flatMap(URL.init(string:)))
                }
                .max { $0.build < $1.build }

            if let n = newest, n.build > currentBuild {
                available = n
                if manual { defaults.set(0, forKey: "updateDismissedBuild") }
                status = "Version \(n.version) (build \(n.build)) is available"
            } else {
                available = nil
                status = "You're on the latest version"
            }
            objectWillChange.send()
        } catch {
            if manual { status = "Update check failed: \(error.localizedDescription)" }
        }
    }

    func later() {
        if let u = available { defaults.set(u.build, forKey: "updateDismissedBuild") }
        objectWillChange.send()
    }

    /// Hands the new IPA to SideStore; falls back to the release page if SideStore doesn't open.
    func install() {
        var target = URL(string: "sidestore://")
        if let ipa = available?.downloadURL,
           let encoded = ipa.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            target = URL(string: "sidestore://install?url=\(encoded)")
        }
        guard let url = target else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok {
                Task { @MainActor in UIApplication.shared.open(Self.releasesURL) }
            }
        }
    }

    private struct Source: Decodable {
        var apps: [App]

        struct App: Decodable {
            var bundleIdentifier: String?
            var versions: [Version]?
        }

        struct Version: Decodable {
            var version: String
            var buildVersion: String?
            var localizedDescription: String?
            var downloadURL: String?
        }
    }
}

/// Banner shown at the top of both tabs when a newer build exists.
struct UpdateBanner: View {
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        if let u = updater.banner {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Update available · \(u.version)")
                            .font(.headline)
                        Text("Build \(u.build) · you have \(updater.currentVersion) (\(updater.currentBuild))")
                            .font(.caption)
                            .opacity(0.85)
                    }
                    Spacer(minLength: 0)
                }
                if !u.notes.isEmpty {
                    Text(u.notes)
                        .font(.footnote)
                        .lineLimit(3)
                        .opacity(0.9)
                }
                HStack(spacing: 10) {
                    Button {
                        updater.install()
                    } label: {
                        Text("Update in SideStore")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(.white, in: Capsule())
                            .foregroundStyle(Theme.accentDeep)
                    }
                    Button {
                        withAnimation { updater.later() }
                    } label: {
                        Text("Later")
                            .font(.subheadline.weight(.semibold))
                            .padding(.vertical, 10)
                            .padding(.horizontal, 18)
                            .background(.white.opacity(0.2), in: Capsule())
                    }
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(16)
            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.35), radius: 14, y: 6)
        }
    }
}

/// Version line with a manual "check now" button.
struct VersionFooter: View {
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 6) {
            Text("Cone Setter \(updater.currentVersion) (build \(updater.currentBuild))")
                .font(.footnote.weight(.semibold))
            if let s = updater.status {
                Text(s).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await updater.check(manual: true) }
            } label: {
                HStack(spacing: 6) {
                    if updater.checking { ProgressView().controlSize(.small) }
                    Text(updater.checking ? "Checking…" : "Check for updates")
                }
                .font(.footnote.weight(.semibold))
            }
            .disabled(updater.checking)
            Text("Checks automatically when the app opens.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
