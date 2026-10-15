import SwiftUI

/// DiTether's look: one brand gradient, rounded cards on the grouped background, and a small set
/// of building blocks (cards, icon badges, pills, gauges) shared by every screen.
enum Theme {
    static let brand = Color(red: 0.10, green: 0.72, blue: 0.62)
    static let brandDeep = Color(red: 0.11, green: 0.42, blue: 0.85)
    static let brandGradient = LinearGradient(colors: [brand, brandDeep],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)

    static let cardRadius: CGFloat = 22
    static let spacing: CGFloat = 16
    static let pagePadding: CGFloat = 16

    /// A soft wash of a status colour, for hero cards.
    static func wash(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color.opacity(0.28), color.opacity(0.06)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Appearance

/// Light, dark, or follow the iPhone. Chosen in Settings, applied to the whole app.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "ditether.appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Set on the window rather than with `preferredColorScheme`, which on iOS 17 and 18 does not
    /// always switch back to System. Sheets and full-screen covers follow the window.
    static func apply(_ rawValue: String) {
        let style = (AppAppearance(rawValue: rawValue) ?? .system).interfaceStyle
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}

// MARK: - Card

/// Light mode: white cards with a soft shadow. Dark mode: raised grey cards with a hairline edge
/// instead, because shadows disappear on black.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 16
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: shape)
            .overlay {
                if scheme == .dark {
                    shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.05), radius: 10, y: 4)
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

/// A page of cards on the grouped background, as used by Home and Devices.
struct CardPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                content
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
    }
}

/// A small title above a group of cards.
struct SectionTitle: View {
    let title: String
    var trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.bold())
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 4)
    }
}

// MARK: - Badges and pills

/// An SF Symbol on a rounded, tinted square, like Settings icons but softer.
struct IconBadge: View {
    let symbol: String
    var color: Color = Theme.brand
    var size: CGFloat = 44
    var filled = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(filled ? .white : color)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(filled ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(scheme == .dark ? 0.22 : 0.15)))
            }
    }
}

/// A short status label in a capsule, for example "With you" in green.
struct StatusPill: View {
    let text: String
    var color: Color
    var symbol: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        // Darker text on light backgrounds: plain green or orange on a pale wash is hard to read.
        .foregroundStyle(color)
        .brightness(scheme == .dark ? 0 : -0.2)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(scheme == .dark ? 0.2 : 0.14), in: Capsule())
    }
}

/// A coloured dot that softly pulses while something is live.
struct LiveDot: View {
    var color: Color
    var pulsing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if pulsing && !reduceMotion {
                RippleCircle(color: color.opacity(0.35), filled: true, from: 0.6, to: 1.6, duration: 1.6)
                    .frame(width: 16, height: 16)
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// A circle that grows and fades, over and over. It starts its own animation when it is
/// inserted, so it also works when it only appears later (for example once protection is live).
struct RippleCircle: View {
    var color: Color
    var filled = false
    var lineWidth: CGFloat = 2
    var from: CGFloat = 0.9
    var to: CGFloat = 1.55
    var duration: Double = 2.4
    var delay: Double = 0

    @State private var expanded = false

    var body: some View {
        Group {
            if filled {
                Circle().fill(color)
            } else {
                Circle().stroke(color, lineWidth: lineWidth)
            }
        }
        .scaleEffect(expanded ? to : from)
        .opacity(expanded ? 0 : 1)
        .onAppear {
            withAnimation(.easeOut(duration: duration).repeatForever(autoreverses: false).delay(delay)) {
                expanded = true
            }
        }
    }
}

// MARK: - Gauges

/// A small battery icon with its percentage, red when low.
struct BatteryLabel: View {
    let level: Int

    private var symbol: String {
        switch level {
        case 76...: return "battery.100"
        case 51...75: return "battery.75"
        case 26...50: return "battery.50"
        case 11...25: return "battery.25"
        default: return "battery.0"
        }
    }

    var body: some View {
        Label("\(level)%", systemImage: symbol)
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(level <= 15 ? Color.red : Color.secondary)
            .labelStyle(.titleAndIcon)
    }
}

/// Four bars like the cellular signal icon. `level` 0...4.
struct SignalBars: View {
    let level: Int
    var color: Color = Theme.brand

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index < level ? color : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: CGFloat(5 + index * 3))
            }
        }
        .accessibilityLabel("Signal \(level) of 4")
    }

    /// Bars for a Bluetooth reading in dBm.
    static func level(forRSSI rssi: Int) -> Int {
        switch rssi {
        case (-60)...: return 4
        case (-70)..<(-60): return 3
        case (-80)..<(-70): return 2
        default: return 1
        }
    }
}

// MARK: - Buttons

/// Full-width rounded button with the brand gradient.
struct PrimaryButtonStyle: ButtonStyle {
    var color: Color?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(color.map { AnyShapeStyle($0.gradient) } ?? AnyShapeStyle(Theme.brandGradient))
                // Deepens bright fills (green, orange) so the white label stays readable.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.18))
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A square tile with an icon and a short label, for the quick actions grid.
struct ActionTile: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var color: Color = Theme.brand
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ActionTileContent(symbol: symbol, title: title, subtitle: subtitle, color: color, isBusy: isBusy)
        }
        .buttonStyle(TileButtonStyle())
    }
}

struct TileButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
