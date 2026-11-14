import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            switch state.connection {
            case .idle, .connecting:
                ConnectView()
            case .connected:
                if state.showStream {
                    StreamView()
                } else {
                    ControlPanelView()
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                state.handleBackground()
            }
        }
    }
}
