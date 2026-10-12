import SwiftUI

/// The big card at the top of the Status screen: one clear answer plus the one thing to do about it.
struct StatusHero: View {
    @EnvironmentObject private var model: PhoneModel
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
                        action: ("Turn on", { model.edit { $0.protectionEnabled = true } }))
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
            return Look(symbol: "bell.slash.fill", color: .blue,
                        title: "Alerts silenced",
                        detail: "Until \(until.formatted(date: .omitted, time: .shortened)). Your watch keeps checking quietly.",
                        action: ("Resume alerts", { model.resumeAlerts() }))
        case .protected:
            return Look(symbol: "checkmark.shield.fill", color: .green,
                        title: "You're protected",
                        detail: "Your watch will tap you if you leave your iPhone behind.")
        }
    }

    var body: some View {
        let look = self.look
        VStack(spacing: 12) {
            Image(systemName: look.symbol)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(look.color)
                .frame(width: 84, height: 84)
                .background(look.color.opacity(0.15), in: Circle())
            Text(look.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(look.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let action = look.action {
                Button(action.title, action: action.run)
                    .buttonStyle(.borderedProminent)
                    .tint(look.color == .gray ? .accentColor : look.color)
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
        .padding(.vertical, 12)
        .animation(.default, value: status)
    }
}

/// The one rule that causes false alarms when it is broken, so it gets its own card.
struct KeepOpenCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Keep DiTether open")
                    .font(.headline)
                Text("Don't swipe it away in the app switcher. If you do, your watch thinks your iPhone was left behind.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// One line of the setup checklist, used on the Status screen and in the intro.
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
