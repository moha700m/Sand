import SwiftUI

/// One small design system: consistent surfaces, icon tiles and spacing.
enum Theme {
    static let screenPad: CGFloat = 16
    static let gap: CGFloat = 12
    static let radius: CGFloat = 18
    static let hairline = Color.primary.opacity(0.07)
}

/// Rounded, tinted SF Symbol tile used across lists and cards.
struct IconTile: View {
    let icon: String
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [color.opacity(0.92), color], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
            )
    }
}

/// Standard row: icon tile, title, optional subtitle.
struct SettingsRow: View {
    let icon: String
    let color: Color
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            IconTile(icon: icon, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// Soft card surface with a hairline border instead of heavy shadows.
struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.hairline)
            )
    }
}
