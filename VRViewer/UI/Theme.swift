import SwiftUI

enum Theme {
    static let bg = Color(hex: 0x0A0A0F)
    static let surface1 = Color(hex: 0x15151C)
    static let surface2 = Color(hex: 0x1D1D26)
    static let surface3 = Color(hex: 0x26262F)
    static let stroke = Color.white.opacity(0.08)
    static let strokeStrong = Color.white.opacity(0.15)

    static let indigo = Color(hex: 0x6366F1)
    static let indigoDark = Color(hex: 0x4338CA)
    static let violet = Color(hex: 0x8B5CF6)
    static let blue = Color(hex: 0x3B82F6)
    static let green = Color(hex: 0x22C55E)
    static let amber = Color(hex: 0xF59E0B)
    static let red = Color(hex: 0xEF4444)

    static let textPrimary = Color(hex: 0xF5F5F7)
    static let textSecondary = Color(hex: 0xA1A1AA)
    static let textTertiary = Color(hex: 0x71717A)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: 1.0)
    }
}

extension View {
    func cardBackground(_ color: Color = Theme.surface1) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.indigo

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(configuration.isPressed ? color.opacity(0.7) : color)
            )
    }
}

struct GhostButtonStyle: ButtonStyle {
    var tint: Color = Theme.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface2.opacity(configuration.isPressed ? 0.9 : 0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }
}

/// Fila con título, subtítulo y un control a la derecha.
struct SettingRow<Content: View>: View {
    let title: String
    var subtitle: String?
    let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .cardBackground()
    }
}

/// Selector numérico con − / + (mismo patrón que el panel del Android).
struct StepperControl: View {
    let label: String
    let value: String
    let onMinus: () -> Void
    let onPlus: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onMinus) {
                Text("−")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(GhostButtonStyle())

            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .frame(minWidth: 62)

            Button(action: onPlus) {
                Text("+")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(GhostButtonStyle())
        }
        .accessibilityLabel(label)
    }
}

struct Badge: View {
    let text: String
    var color: Color = Theme.green

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(color.opacity(0.18))
        )
    }
}
