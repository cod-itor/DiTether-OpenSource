import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        Group {
            if model.isSetUp {
                main
            } else {
                WatchIntroView()
            }
        }
        .fullScreenCover(item: testAlertBinding) { level in
            TestAlertView(level: level) { model.dismissTestAlert() }
        }
        .fullScreenCover(isPresented: ringingBinding) {
            WatchRingView { model.stopRingingWatch() }
        }
    }

    private var ringingBinding: Binding<Bool> {
        Binding(
            get: { model.isRingingWatch },
            set: { if !$0 { model.stopRingingWatch() } }
        )
    }

    private var testAlertBinding: Binding<TestAlertLevel?> {
        Binding(
            get: { model.testAlert },
            set: { if $0 == nil { model.dismissTestAlert() } }
        )
    }

    private var main: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    StatusCard(phase: model.engine.phase)
                    if model.engine.phase != .off, model.settings.settings.bluetoothRangeEnabled {
                        SignalView(signal: model.proximity.signal, rssi: model.proximity.rssi, problem: model.proximity.problem)
                    }
                    if isApart, let meters = model.engine.distanceFromSpot {
                        Label("\(Int(meters.rounded())) m from where you left it", systemImage: "location.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    actions
                    if let problem = model.keepAlive.lastError, model.settings.settings.protectionEnabled {
                        Text(problem)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                    if model.engine.phase != .off {
                        NavigationLink {
                            FinderView()
                        } label: {
                            Label("Find iPhone", systemImage: "location.magnifyingglass")
                        }
                    }
                    NavigationLink {
                        WatchTagsView()
                    } label: {
                        Label("DiTAGs", systemImage: "tag.fill")
                    }
                    // One tap to stop the background session (and its battery use) when you don't need it.
                    Toggle(isOn: model.binding(\.protectionEnabled)) {
                        Label("Protection", systemImage: "shield.fill")
                    }
                    .tint(.green)
                    NavigationLink {
                        WatchSettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle("DiTether")
        }
    }

    private var isApart: Bool {
        switch model.engine.phase {
        case .separated, .softAlerted, .strongAlerted, .muted:
            return true
        case .off, .starting, .watching:
            return false
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.engine.phase {
        case .off:
            EmptyView()   // the Protection switch below turns it on

        case .separated, .softAlerted, .strongAlerted:
            Button {
                model.snooze(minutes: 60)
            } label: {
                Label("Silence 1 hour", systemImage: "bell.slash.fill")
            }
            .tint(.orange)

        case .muted(_, let reason):
            if reason == "Snoozed" {
                Button {
                    model.resumeAlerts()
                } label: {
                    Label("Resume alerts", systemImage: "bell.fill")
                }
                .tint(.green)
            }

        case .starting, .watching:
            EmptyView()
        }
    }
}

struct StatusCard: View {
    let phase: ProtectionEngine.Phase

    private struct Look {
        var symbol: String
        var color: Color
        var title: String
        var detail: String?
        var since: Date?
    }

    private var look: Look {
        switch phase {
        case .off:
            return Look(symbol: "moon.zzz.fill", color: .gray, title: "Protection off",
                        detail: "DiTether is not watching.", since: nil)
        case .starting:
            return Look(symbol: "hourglass", color: .gray, title: "Starting",
                        detail: nil, since: nil)
        case .watching:
            return Look(symbol: "checkmark.shield.fill", color: .green, title: "iPhone nearby",
                        detail: "Watching the link.", since: nil)
        case .separated(let since):
            return Look(symbol: "antenna.radiowaves.left.and.right.slash", color: .orange, title: "Signal lost",
                        detail: "Apart for", since: since)
        case .softAlerted(let since):
            return Look(symbol: "exclamationmark.triangle.fill", color: .orange, title: "iPhone out of range",
                        detail: "Apart for", since: since)
        case .strongAlerted(let since):
            return Look(symbol: "exclamationmark.octagon.fill", color: .red, title: "iPhone left behind?",
                        detail: "Alerting for", since: since)
        case .muted(let since, let reason):
            return Look(symbol: "bell.slash.fill", color: .blue, title: "Quiet: \(reason)",
                        detail: "Apart for", since: since)
        }
    }

    var body: some View {
        let look = self.look
        VStack(spacing: 4) {
            Image(systemName: look.symbol)
                .font(.system(size: 34))
                .foregroundStyle(look.color)
            Text(look.title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let since = look.since {
                HStack(spacing: 4) {
                    if let detail = look.detail {
                        Text(detail)
                    }
                    Text(since, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else if let detail = look.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
