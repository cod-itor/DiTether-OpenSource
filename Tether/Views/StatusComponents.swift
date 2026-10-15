import SwiftUI

/// The big card at the top of Home: one clear answer, an animated shield, and the one thing to do.
struct ProtectionHero: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.colorScheme) private var scheme
    let status: ProtectionStatus

    private struct Look {
        var symbol: String
        var color: Color
        var title: String
        var detail: String
        var action: (title: String, run: () -> Void)?
    }

    private var look: Look {
        switch status {
        case .connecting:
            return Look(symbol: "hourglass", color: .gray,
                        title: "Connecting to your watch",
                        detail: "This only takes a moment.")
        case .noWatch:
            return Look(symbol: "applewatch.slash", color: .gray,
                        title: "No Apple Watch paired",
                        detail: "DiTether runs on your Apple Watch. Pair one in the Watch app to get started.",
                        action: ("Open Watch app", { model.launcher.openWatchAppOnPhone() }))
        case .watchAppMissing:
            return Look(symbol: "arrow.down.app.fill", color: .orange,
                        title: "Install DiTether on your watch",
                        detail: "In the Watch app, scroll to Available Apps and tap Install next to DiTether.",
                        action: ("Open Watch app", { model.launcher.openWatchAppOnPhone() }))
        case .off:
            return Look(symbol: "moon.zzz.fill", color: .gray,
                        title: "Protection is off",
                        detail: "Your watch is not checking for your iPhone.",
                        action: ("Turn on protection", { model.edit { $0.protectionEnabled = true } }))
        case .watchNotSetUp:
            return Look(symbol: "applewatch", color: .orange,
                        title: "Finish setup on your watch",
                        detail: "Tap Get started on your watch and allow what it asks for.",
                        action: ("Open on watch", { model.launcher.openOnWatch() }))
        case .watchProblem(let problem):
            return Look(symbol: "exclamationmark.triangle.fill", color: .orange,
                        title: "Your watch needs attention",
                        detail: problem,
                        action: ("Open on watch", { model.launcher.openOnWatch() }))
        case .waitingForWatch:
            return Look(symbol: "applewatch.radiowaves.left.and.right", color: .orange,
                        title: "Starting on your watch",
                        detail: "If this does not change in a minute, open DiTether on your watch.",
                        action: ("Open on watch", { model.launcher.openOnWatch() }))
        case .silenced(let until):
            return Look(symbol: "bell.slash.fill", color: .indigo,
                        title: "Alerts silenced",
                        detail: "Until \(until.formatted(date: .omitted, time: .shortened)). Your watch keeps checking quietly.",
                        action: ("Resume alerts", { model.resumeAlerts() }))
        case .protected:
            return Look(symbol: "checkmark.shield.fill", color: .green,
                        title: "You're protected",
                        detail: "Your watch taps you the moment your iPhone gets left behind.")
        }
    }

    var body: some View {
        let look = self.look
        VStack(spacing: 14) {
            PulsingShield(symbol: look.symbol, color: look.color, isLive: status == .protected)
                .padding(.top, 6)
            VStack(spacing: 6) {
                Text(look.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(look.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action = look.action {
                Button(action.title, action: action.run)
                    .buttonStyle(PrimaryButtonStyle(color: look.color == .gray ? nil : look.color))
                    .padding(.top, 2)
            }
            if let message = model.launcher.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Theme.wash(look.color))
        }
        .overlay {
            if scheme == .dark {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(look.color.opacity(0.25), lineWidth: 1)
            }
        }
        .shadow(color: look.color.opacity(scheme == .dark ? 0.25 : 0.15), radius: 16, y: 6)
        .animation(.snappy, value: status)
    }
}

/// The status symbol inside rings that ripple outwards while protection is live.
struct PulsingShield: View {
    let symbol: String
    let color: Color
    var isLive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isLive && !reduceMotion {
                ForEach(0..<2, id: \.self) { ring in
                    RippleCircle(color: color.opacity(0.35), delay: Double(ring) * 1.2)
                }
            }
            Circle()
                .fill(color.opacity(0.16))
            Circle()
                .fill(color.gradient)
                .padding(14)
                .shadow(color: color.opacity(0.4), radius: 10, y: 4)
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 108, height: 108)
        .accessibilityHidden(true)
    }
}

/// The one rule that causes false alarms when it is broken, as a compact tip.
struct KeepOpenCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: "hand.raised.fill", color: .orange, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("Keep DiTether in the background")
                    .font(.subheadline.weight(.semibold))
                Text("Don't swipe it away in the app switcher, or your watch and DiTAGs lose touch with it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(padding: 14)
    }
}

/// One line of the setup checklist, used on Home and in the intro.
struct SetupStepRow: View {
    let step: SetupStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(step.isDone ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(step.title)
                        .font(.headline)
                        .strikethrough(step.isDone, color: .secondary)
                        .foregroundStyle(step.isDone ? .secondary : .primary)
                    if step.isOptional && !step.isDone {
                        Text("Optional")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                if !step.isDone {
                    Text(step.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .animation(.default, value: step.isDone)
    }
}
