import SwiftUI
import UIKit

struct StereoVideoLayer: UIViewRepresentable {
    @EnvironmentObject private var state: AppState

    func makeUIView(context: Context) -> StereoVideoView {
        let view = StereoVideoView()
        state.videoView = view
        view.separation = CGFloat(state.lensSeparation)
        view.zoom = CGFloat(state.lensZoom)
        view.verticalOffset = CGFloat(state.lensVertical)
        return view
    }

    func updateUIView(_ uiView: StereoVideoView, context: Context) {
        uiView.separation = CGFloat(state.lensSeparation)
        uiView.zoom = CGFloat(state.lensZoom)
        uiView.verticalOffset = CGFloat(state.lensVertical)
    }

    static func dismantleUIView(_ uiView: StereoVideoView, coordinator: ()) {
        uiView.flush()
    }
}

struct StreamView: View {
    @EnvironmentObject private var state: AppState

    private enum Panel {
        case none
        case quality
        case lens
    }

    @State private var controlsVisible = true
    @State private var panel: Panel = .none
    @State private var hideWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            StereoVideoLayer()
                .ignoresSafeArea()

            if isWaiting {
                waitingOverlay
            }

            if controlsVisible {
                controls
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                controlsVisible.toggle()
            }
            if controlsVisible { scheduleHide() }
        }
        .onAppear { scheduleHide() }
        .onDisappear { hideWorkItem?.cancel() }
    }

    private var isWaiting: Bool {
        !state.streamStatus.contains("✓") && !state.streamStatus.isEmpty
    }

    private var waitingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            Text(state.streamStatus)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface1.opacity(0.85))
        )
        .allowsHitTesting(false)
    }

    // MARK: - Controles

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if panel == .quality { qualityPanel }
            if panel == .lens { lensPanel }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Badge(text: state.streamStatus.isEmpty ? "stream" : state.streamStatus,
                  color: state.streamStatus.contains("✓") ? Theme.green : Theme.amber)

            Spacer()

            Button {
                togglePanel(.quality)
            } label: {
                Text("⚙ Calidad")
            }
            .buttonStyle(GhostButtonStyle())

            Button {
                togglePanel(.lens)
            } label: {
                Text("🔍 Lentes")
            }
            .buttonStyle(GhostButtonStyle())

            Button {
                state.recenter()
            } label: {
                Text("⟳ Recentrar")
            }
            .buttonStyle(GhostButtonStyle())

            Button {
                hideWorkItem?.cancel()
                state.stopStream()
            } label: {
                Text("✕ Cerrar")
            }
            .buttonStyle(GhostButtonStyle(tint: Theme.red))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var qualityPanel: some View {
        HStack(spacing: 12) {
            StepperControl(
                label: "Resolución",
                value: StreamQuality.resolutions[min(state.resolutionIndex, StreamQuality.resolutions.count - 1)].label,
                onMinus: {
                    state.resolutionIndex = max(0, state.resolutionIndex - 1)
                    state.applyQuality()
                },
                onPlus: {
                    state.resolutionIndex = min(StreamQuality.resolutions.count - 1, state.resolutionIndex + 1)
                    state.applyQuality()
                }
            )

            StepperControl(
                label: "Bitrate",
                value: String(format: "%.0f Mbps", state.bitrateMbps),
                onMinus: {
                    state.bitrateMbps = max(StreamQuality.bitrateMin, state.bitrateMbps - StreamQuality.bitrateStep)
                    state.applyQuality()
                },
                onPlus: {
                    state.bitrateMbps = min(StreamQuality.bitrateMax, state.bitrateMbps + StreamQuality.bitrateStep)
                    state.applyQuality()
                }
            )

            StepperControl(
                label: "FPS",
                value: "\(StreamQuality.fpsOptions[min(state.fpsIndex, StreamQuality.fpsOptions.count - 1)]) fps",
                onMinus: {
                    state.fpsIndex = max(0, state.fpsIndex - 1)
                    state.applyQuality()
                },
                onPlus: {
                    state.fpsIndex = min(StreamQuality.fpsOptions.count - 1, state.fpsIndex + 1)
                    state.applyQuality()
                }
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface1.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var lensPanel: some View {
        HStack(spacing: 12) {
            StepperControl(
                label: "Separación",
                value: String(format: "%.2f", state.lensSeparation),
                onMinus: { state.lensSeparation = max(-0.2, state.lensSeparation - 0.01) },
                onPlus: { state.lensSeparation = min(0.2, state.lensSeparation + 0.01) }
            )

            StepperControl(
                label: "Lupa",
                value: String(format: "%.2f×", state.lensZoom),
                onMinus: { state.lensZoom = max(0.5, state.lensZoom - 0.05) },
                onPlus: { state.lensZoom = min(2.0, state.lensZoom + 0.05) }
            )

            StepperControl(
                label: "Altura",
                value: String(format: "%.2f", state.lensVertical),
                onMinus: { state.lensVertical = max(-0.3, state.lensVertical - 0.01) },
                onPlus: { state.lensVertical = min(0.3, state.lensVertical + 0.01) }
            )

            Button {
                state.resetLens()
            } label: {
                Text("↺ Restablecer")
            }
            .buttonStyle(GhostButtonStyle())
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface1.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: - Utilidades

    private func togglePanel(_ target: Panel) {
        panel = panel == target ? .none : target
        hideWorkItem?.cancel()
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.25)) {
                controlsVisible = false
                panel = .none
            }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }
}
