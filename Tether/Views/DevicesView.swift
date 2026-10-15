import SwiftUI

/// Devices: everything DiTether is connected to. This iPhone, the Apple Watch, and every DiTAG.
struct DevicesView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var showGuide = false

    private var manager: DiTagManager { model.diTag }
    private var tags: [DiTag] { manager.settings.tags }

    var body: some View {
        NavigationStack {
            CardPage {
                SectionTitle("Apple Watch")
                WatchCard()

                SectionTitle("This iPhone")
                PhoneCard()

                SectionTitle("DiTAGs", trailing: tags.isEmpty ? nil : "\(tags.count) of \(DiTagSettings.maxTags)")
                if manager.bluetooth != .ok {
                    bluetoothCard
                }
                if let phase = manager.setupPhase {
                    SetupProgressCard(phase: phase) { manager.cancelSetup() }
                }
                ForEach(tags) { tag in
                    NavigationLink(value: tag.id) {
                        DiTagCard(tag: tag, status: manager.status(tag.id))
                    }
                    .buttonStyle(TileButtonStyle())
                }
                if tags.isEmpty && manager.setupPhase == nil {
                    emptyTagsCard
                } else if manager.setupPhase == nil && manager.canAddMore {
                    addTagButton
                }
                if !tags.isEmpty {
                    VStack(spacing: 0) {
                        NavigationLink {
                            DiTagOptionsView()
                        } label: {
                            LinkRow(symbol: "slider.horizontal.3", title: "DiTAG options",
                                    subtitle: manager.settings.alarmSound ? "Sound + vibrate" : "Vibrate")
                        }
                        Divider().padding(.leading, 56)
                        NavigationLink {
                            DiTagActivityView()
                        } label: {
                            LinkRow(symbol: "list.bullet.rectangle", title: "Activity",
                                    subtitle: manager.activity.first?.text ?? "Nothing yet")
                        }
                        Divider().padding(.leading, 56)
                        NavigationLink {
                            PlacesView()
                        } label: {
                            LinkRow(symbol: "map.fill", title: "Places",
                                    subtitle: model.places.places.isEmpty ? "Press a DiTAG once to save a spot"
                                                                          : "\(model.places.places.count) saved")
                        }
                        Divider().padding(.leading, 56)
                        Button {
                            model.showCamera = true
                        } label: {
                            LinkRow(symbol: "camera.fill", title: "Camera", subtitle: "A DiTAG press takes the photo")
                        }
                    }
                    .buttonStyle(.plain)
                    .card(padding: 4)
                }
            }
            .navigationTitle("Devices")
            .navigationDestination(for: UUID.self) { id in
                DiTagDetailView(tagID: id)
            }
            .sheet(isPresented: $showGuide) {
                DiTagSetupGuide(startAtIntro: tags.isEmpty)
                    .environmentObject(model)
            }
        }
    }

    private var emptyTagsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                IconBadge(symbol: "key.fill", color: Theme.brand, size: 52, filled: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Protect your keys too")
                        .font(.headline)
                    Text("Attach a DiTAG to your keys, bag or wallet. Your iPhone alerts you when one is left behind.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Set up a DiTAG") { showGuide = true }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(manager.bluetooth == .unauthorized)
            if let message = manager.setupMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .card()
    }

    private var addTagButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showGuide = true
            } label: {
                Label("Add another DiTAG", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.brand)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .strokeBorder(Theme.brand.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    }
            }
            .buttonStyle(TileButtonStyle())
            .disabled(manager.bluetooth == .unauthorized)
            if let message = manager.setupMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var bluetoothCard: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: "exclamationmark.triangle.fill", color: .orange, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(manager.bluetooth == .unauthorized ? "Bluetooth is not allowed" : "Bluetooth is off")
                    .font(.subheadline.weight(.semibold))
                Text(manager.bluetooth == .unauthorized
                     ? "DiTether needs Bluetooth to connect to your DiTAGs."
                     : "Your DiTAGs reconnect by themselves when Bluetooth is back on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if manager.bluetooth == .unauthorized {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.top, 2)
                }
            }
        }
        .card(padding: 14)
    }
}

// MARK: - Watch

private struct WatchCard: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        let status = model.protectionStatus
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                IconBadge(symbol: "applewatch", color: color(status), size: 52, filled: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple Watch")
                        .font(.headline)
                    StatusPill(text: title(status), color: color(status),
                               symbol: status == .protected ? "checkmark.shield.fill" : nil)
                }
                Spacer(minLength: 0)
                LiveDot(color: color(status), pulsing: status == .protected)
            }

            if model.connectivity.isPaired {
                VStack(spacing: 10) {
                    DetailRow(symbol: "dot.radiowaves.left.and.right", title: "Link to iPhone", value: linkText)
                    DetailRow(symbol: "clock", title: "Last contact", value: lastContactText)
                    DetailRow(symbol: "app.badge.checkmark", title: "DiTether on watch",
                              value: model.connectivity.isWatchAppInstalled ? "Installed" : "Not installed")
                }

                // Side by side when they fit, stacked on small iPhones or with large text.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { watchButtons }
                    VStack(spacing: 10) { watchButtons }
                }
                .font(.subheadline.weight(.semibold))
                .controlSize(.large)
            } else {
                Button("Open the Watch app") { model.launcher.openWatchAppOnPhone() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .card()
    }

    @ViewBuilder
    private var watchButtons: some View {
        Button {
            model.ringWatch()
        } label: {
            Label(ringTitle, systemImage: "speaker.wave.2.fill")
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.blue)
        .disabled(model.ringWatchState == .sending)

        Button {
            model.launcher.openOnWatch()
        } label: {
            Label("Open on watch", systemImage: "arrow.up.forward.app")
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private var ringTitle: String {
        switch model.ringWatchState {
        case .idle: return "Ring"
        case .sending: return "Ringing…"
        case .ringing: return "Ringing"
        case .failed: return "Not reachable"
        }
    }

    private var linkText: String {
        guard let status = model.watchStatus, status.isProtecting else {
            return model.connectivity.isReachable ? "Connected" : "Not connected"
        }
        if status.bluetoothLinked == true { return "Bluetooth, direct" }
        return model.connectivity.isReachable ? "Wi-Fi or iCloud" : "Not connected"
    }

    private var lastContactText: String {
        if model.connectivity.isReachable { return "Now" }
        guard let date = model.lastWatchContact else { return "Not yet" }
        return date.formatted(.relative(presentation: .named))
    }

    private func title(_ status: ProtectionStatus) -> String {
        switch status {
        case .protected: return "Protecting your iPhone"
        case .silenced: return "Silenced"
        case .off: return "Protection off"
        case .connecting: return "Connecting…"
        case .noWatch: return "Not paired"
        case .watchAppMissing: return "App not installed"
        case .watchNotSetUp: return "Needs setup"
        case .watchProblem: return "Needs attention"
        case .waitingForWatch: return "Starting…"
        }
    }

    private func color(_ status: ProtectionStatus) -> Color {
        switch status {
        case .protected: return .green
        case .silenced: return .indigo
        case .off, .connecting, .noWatch: return .gray
        default: return .orange
        }
    }
}

// MARK: - iPhone

private struct PhoneCard: View {
    @EnvironmentObject private var model: PhoneModel

    private var settings: TetherSettings { model.settings.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                IconBadge(symbol: "iphone", color: Theme.brandDeep, size: 52, filled: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("This iPhone")
                        .font(.headline)
                    StatusPill(text: settings.protectionEnabled ? "Visible to your watch" : "Resting",
                               color: settings.protectionEnabled ? Theme.brand : .gray)
                }
            }
            VStack(spacing: 10) {
                DetailRow(symbol: "antenna.radiowaves.left.and.right", title: "Bluetooth signal",
                          value: bluetoothText)
                DetailRow(symbol: "location.fill", title: "Location for watch",
                          value: model.location.isSharing ? "Sharing" : "Off")
                DetailRow(symbol: "tag.fill", title: "DiTAGs watched",
                          value: "\(model.diTag.settings.tags.filter(\.isEnabled).count)")
            }
        }
        .card()
    }

    private var bluetoothText: String {
        if !settings.bluetoothRangeEnabled { return "Off in Alert timing" }
        if model.beacon.isDenied { return "Not allowed" }
        if !model.beacon.isAllowed { return "Not set up" }
        return settings.protectionEnabled ? "On" : "Off with protection"
    }
}

// MARK: - DiTAG cards

/// One DiTAG on the Devices page.
struct DiTagCard: View {
    let tag: DiTag
    let status: DiTagManager.TagStatus

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: DiTagLook.icon(status.state), color: DiTagLook.color(status.state).badge,
                      size: 52, filled: status.state == .connected || status.state == .lost)
            VStack(alignment: .leading, spacing: 5) {
                Text(tag.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    StatusPill(text: DiTagLook.shortText(status.state), color: DiTagLook.color(status.state).badge)
                    if tag.isSnoozed() && tag.isEnabled {
                        StatusPill(text: "Snoozed", color: .indigo, symbol: "moon.zzz.fill")
                    }
                }
                if status.state == .lost, let lostAt = status.lostAt {
                    Text("Left \(lostAt, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if status.state == .quiet, let until = tag.quietUntil {
                    Text(tag.isQuietUntilTurnedOff ? "Until you turn it off"
                                                   : "Until \(until.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                if let signal = status.signal, status.state == .connected {
                    SignalBars(level: SignalBars.level(forRSSI: signal))
                }
                if let battery = status.battery, status.state != .off {
                    BatteryLabel(level: battery)
                }
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .card(padding: 14)
    }
}

/// Live progress while a DiTAG is being added outside the guide.
struct SetupProgressCard: View {
    let phase: DiTagManager.SetupPhase
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if phase == .confirming {
                IconBadge(symbol: "hand.tap.fill", color: Theme.brand, size: 44)
                    .symbolEffect(.pulse)
            } else {
                ProgressView()
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(phase == .confirming ? "Press the DiTAG button once" : "Looking for a new DiTAG…")
                    .font(.subheadline.weight(.semibold))
                Text(phase == .confirming ? "It just beeped, so you know which one." : "Hold it close to your iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: cancel)
                .font(.subheadline)
        }
        .card(padding: 14)
    }
}

// MARK: - Rows

/// Icon, label and value on one line, inside a device card.
struct DetailRow: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
    }
}

/// A navigation row inside a card.
struct LinkRow: View {
    let symbol: String
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol, color: Theme.brand, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .contentShape(Rectangle())
    }
}

private extension Color {
    /// `.secondary` is a text style, so badges and pills use grey instead.
    var badge: Color { self == .secondary ? .gray : self }
}
