import SwiftUI

struct ControlPanelView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            header

            HStack(alignment: .top, spacing: 10) {
                trackingCard
                handsCard
                sixDofCard
            }
            .frame(maxHeight: .infinity, alignment: .top)

            footer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("🥽 VR Viewer")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            Badge(text: "📶 \(state.connectedIP)", color: Theme.green)

            Spacer()

            Button {
                state.startStream()
            } label: {
                Text("▶ Abrir stream")
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                state.disconnect()
            } label: {
                Text("Desconectar")
            }
            .buttonStyle(GhostButtonStyle(tint: Theme.red))
        }
    }

    // MARK: - Tarjetas

    private var trackingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitle("HMD Tracking", color: Theme.indigo)

            SettingRow(title: "Giroscopio",
                       subtitle: "Orientación de la cabeza") {
                Toggle("", isOn: Binding(
                    get: { state.hmdEnabled },
                    set: { state.hmdEnabled = $0 }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Theme.indigo))
            }

            Button {
                state.recenter()
            } label: {
                Text("⟳ Recentrar HMD")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GhostButtonStyle())

            SettingRow(title: "Barrido de prueba",
                       subtitle: "Mueve el mundo solo (diagnóstico)") {
                Toggle("", isOn: Binding(
                    get: { state.sweepEnabled },
                    set: { state.sweepEnabled = $0 }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Theme.amber))
            }

            if !state.diagText.isEmpty {
                Text(state.diagText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var handsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitle("Tracking de manos", color: Theme.violet)

            SettingRow(title: "Manos",
                       subtitle: "Cámara trasera · Vision") {
                Toggle("", isOn: Binding(
                    get: { state.handsEnabled },
                    set: { state.setHandsEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Theme.violet))
            }

            SettingRow(title: "Invertir manos",
                       subtitle: "Si izquierda/derecha salen cruzadas") {
                Toggle("", isOn: Binding(
                    get: { state.swapHands },
                    set: { state.swapHands = $0 }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Theme.violet))
            }

            SettingRow(title: "Rotación de cámara",
                       subtitle: "Mano mal orientada") {
                StepperControl(
                    label: "Rotación de cámara",
                    value: "\(state.landmarkRotation * 90)°",
                    onMinus: { state.landmarkRotation = (state.landmarkRotation + 3) % 4 },
                    onPlus: { state.landmarkRotation = (state.landmarkRotation + 1) % 4 }
                )
            }

            SettingRow(title: "Cámara 0.5×",
                       subtitle: "Gran angular: más campo para las manos") {
                Toggle("", isOn: Binding(
                    get: { state.useUltraWide },
                    set: { state.useUltraWide = $0 }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Theme.violet))
            }

            SettingRow(title: "Ganancia manos",
                       subtitle: String(format: "%.1f× · espacio recorrido", state.handGain)) {
                StepperControl(
                    label: "Ganancia manos",
                    value: String(format: "%.1f", state.handGain),
                    onMinus: { state.handGain = max(0.5, state.handGain - 0.1) },
                    onPlus: { state.handGain = min(2.0, state.handGain + 0.1) }
                )
            }

            if !state.handStatus.isEmpty {
                Text(state.handStatus)
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sixDofCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitle("6DoF (posición real)", color: Theme.blue)

            SettingRow(title: "Tracking 6DoF",
                       subtitle: "ARKit · requiere luz y textura") {
                Toggle("", isOn: Binding(
                    get: { state.sixDofEnabled },
                    set: { state.setSixDofEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Theme.blue))
            }

            SettingRow(title: "Sensibilidad",
                       subtitle: String(format: "%.1f×", state.sensitivity)) {
                StepperControl(
                    label: "Sensibilidad",
                    value: String(format: "%.1f", state.sensitivity),
                    onMinus: { state.sensitivity = max(0.25, state.sensitivity - 0.1) },
                    onPlus: { state.sensitivity = min(3.0, state.sensitivity + 0.1) }
                )
            }

            Text("6DoF y manos comparten la cámara: si activas los dos, las manos se detectan sobre los frames de ARKit.")
                .font(.system(size: 9))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.green)
                .frame(width: 6, height: 6)
            Text(state.statusText)
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
            Spacer()
            Text(state.qualityText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface1)
        )
    }

    private func cardTitle(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 3, height: 12)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
        }
    }
}
