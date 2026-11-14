import SwiftUI

struct ConnectView: View {
    @EnvironmentObject private var state: AppState

    @State private var manualIP = ""
    @State private var cableIP = ""
    @State private var selectedTab = 0
    @FocusState private var focusedField: Int?

    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            titleColumn
            connectCard
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 16)
        .onAppear {
            if state.discovered.isEmpty { state.startDiscovery() }
        }
        .onDisappear { state.stopDiscovery() }
    }

    // MARK: - Columna izquierda

    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Text("🥽")
                    .font(.system(size: 34))
                VStack(alignment: .leading, spacing: 2) {
                    Text("VR Viewer")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Conecta tu PC con SteamVR")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
            }

            statusLine

            Spacer(minLength: 0)

            Text("WiFi o cable · iPhone en landscape dentro del visor")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            if state.connection == .connecting {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.7)
            } else {
                Circle()
                    .fill(state.connection == .connected ? Theme.green : Theme.textTertiary)
                    .frame(width: 7, height: 7)
            }

            Text(state.statusText)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface1)
        )
    }

    // MARK: - Tarjeta de conexión

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                tabButton(title: "📶 WiFi", index: 0)
                tabButton(title: "🔌 Cable", index: 1)
            }

            if selectedTab == 0 {
                wifiTab
            } else {
                cableTab
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 380)
        .frame(maxHeight: .infinity)
        .cardBackground(Theme.surface1.opacity(0.92))
    }

    private func tabButton(title: String, index: Int) -> some View {
        Button {
            selectedTab = index
            focusedField = nil
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(selectedTab == index ? Theme.textPrimary : Theme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selectedTab == index ? Theme.indigo.opacity(0.35) : Theme.surface2)
                )
        }
        .buttonStyle(.plain)
    }

    private var wifiTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Detección automática")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Button {
                    state.startDiscovery()
                } label: {
                    Text("Buscar de nuevo")
                }
                .buttonStyle(GhostButtonStyle())
            }

            ScrollView {
                VStack(spacing: 6) {
                    if state.discovered.isEmpty {
                        Text(state.scanStatus.isEmpty ? "Esperando anuncios del PC…" : state.scanStatus)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(state.discovered) { pc in
                            Button {
                                state.connect(to: pc.ip)
                            } label: {
                                HStack {
                                    Text(pc.name)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(Theme.textPrimary)
                                    Spacer()
                                    Text(pc.ip)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(Theme.textTertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Theme.surface2)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: 90)

            Text("O introduce la IP manualmente")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)

            HStack(spacing: 8) {
                TextField("192.168.1.X", text: $manualIP)
                    .focused($focusedField, equals: 0)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Theme.surface2)
                    )

                Button {
                    focusedField = nil
                    state.connect(to: manualIP)
                } label: {
                    Text("Conectar")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(state.connection == .connecting)
            }
        }
    }

    private var cableTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cómo conectar por cable")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 5) {
                bullet("Conecta el iPhone a la PC con el cable USB.")
                bullet("Activa «Compartir conexión» en Ajustes → Punto de acceso personal.")
                bullet("La PC recibe la IP 172.20.10.2 (el iPhone hace de router).")
            }

            HStack(spacing: 8) {
                TextField("172.20.10.2", text: $cableIP)
                    .focused($focusedField, equals: 1)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Theme.surface2)
                    )

                Button {
                    focusedField = nil
                    state.connect(to: cableIP)
                } label: {
                    Text("🔌 Conectar")
                }
                .buttonStyle(PrimaryButtonStyle(color: Theme.amber))
            }

            Text("No requiere WiFi")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
            Text(text)
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
