import SwiftUI

@main
struct ConeSetterApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                HomeView()
                    .tabItem { Label("Cones", systemImage: "cone.fill") }
                SpeedHomeView()
                    .tabItem { Label("Speed", systemImage: "speedometer") }
            }
            .tint(Theme.accent)
            .preferredColorScheme(.dark)
            .task { UpdateChecker.shared.checkIfDue() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { UpdateChecker.shared.checkIfDue() }
            }
        }
    }
}
