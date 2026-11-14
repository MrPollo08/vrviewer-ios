import SwiftUI

@main
struct VRViewerApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
                .statusBar(hidden: true)
        }
    }
}
