import SwiftUI

@main
struct ConeSetterApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var router = AppRouter.shared

    var body: some Scene {
        WindowGroup {
            TabView(selection: $router.tab) {
                HomeView()
                    .tabItem { Label("Cones", systemImage: "cone.fill") }
                    .tag(AppRouter.Tab.cones)
                SpeedHomeView()
                    .tabItem { Label("Speed", systemImage: "speedometer") }
                    .tag(AppRouter.Tab.speed)
                ModelsHomeView()
                    .tabItem { Label("3D", systemImage: "cube.fill") }
                    .tag(AppRouter.Tab.models)
            }
            .tint(Theme.accent)
            .preferredColorScheme(.dark)
            .task { UpdateChecker.shared.checkIfDue() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { UpdateChecker.shared.checkIfDue() }
            }
            .onOpenURL { url in
                guard url.isFileURL else { return }
                router.open(url: url)
            }
        }
    }
}
