import SwiftUI

@main
struct ConeSetterApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                HomeView()
                    .tabItem { Label("Cones", systemImage: "cone.fill") }
                SpeedHomeView()
                    .tabItem { Label("Speed", systemImage: "speedometer") }
            }
            .tint(.orange)
        }
    }
}
