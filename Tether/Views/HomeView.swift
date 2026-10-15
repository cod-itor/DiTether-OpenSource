import SwiftUI

/// Home: am I protected, what's with me, and the few things you do most.
struct HomeView: View {
    @EnvironmentObject private var model: PhoneModel
    /// Switches to the Devices tab.
    let openDevices: () -> Void
    @State private var showGuide = false

    private var settings: TetherSettings { model.settings.settings }
    private var tags: [DiTag] { model.diTag.settings.tags }

    var body: some View {
        let status = model.protectionStatus
        let openSteps = model.setupSteps.filter { !$0.isDone }

        NavigationStack {
            CardPage {
                ProtectionHero(status: status)

                protectionSwitch

                if !openSteps.isEmpty {
                    SectionTitle("Finish setting up", trailing: "\(openSteps.filter { !$0.isOptional }.count) left")
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(openSteps) { step in
                            SetupStepLink(step: step)
                        }
                    }
                    .card()
                }

                SectionTitle("With you")
                deviceStrip

                SectionTitle("Quick actions")
                quickActions

                KeepOpenCard()

                if let latest = model.events.events.first {
                    SectionTitle("Latest alert")
                    NavigationLink {
                        EventDetailView(event: latest)
                    } label: {
                        EventRow(event: latest)
                            .card(padding: 14)
                    }
                    .buttonStyle(TileButtonStyle())
                }
            }
            .navigationTitle("DiTether")
            .sheet(isPresented: $showGuide) {
                DiTagSetupGuide(startAtIntro: tags.isEmpty)
                    .environmentObject(model)
            }
        }
    }

    // MARK: Protection

    private var protectionSwitch: some View {
        Toggle(isOn: model.binding(\.protectionEnabled)) {
            HStack(spacing: 12) {
                IconBadge(symbol: settings.protectionEnabled ? "shield.lefthalf.filled" : "shield.slash",
                          color: settings.protectionEnabled ? .green : .gray, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Protection")
                        .font(.headline)
                    Text(settings.protectionEnabled ? "Watch is checking for your iPhone" : "Off to save watch battery")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(.green)
        .card(padding: 14)
    }

    // MARK: Devices at a glance

    private var deviceStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Button(action: openDevices) {
                    DeviceChip(symbol: "applewatch", name: "Apple Watch",
                               state: watchChipState.text, color: watchChipState.color)
                }
                ForEach(tags) { tag in
                    let status = model.diTag.status(tag.id)
                    Button(action: openDevices) {
                        DeviceChip(symbol: "tag.fill", name: tag.displayName,
                                   state: DiTagLook.shortText(status.state), color: DiTagLook.color(status.state),
                                   battery: status.state == .off ? nil : status.battery)
                    }
                }
                Button {
                    showGuide = true
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Theme.brand)
                            .frame(width: 44, height: 44)
                            .background(Theme.brand.opacity(0.12), in: Circle())
                        Text("Add DiTAG")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.brand)
                    }
                    .frame(width: 112, height: 132)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .strokeBorder(Theme.brand.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    }
                }
                .disabled(!model.diTag.canAddMore)
            }
            .buttonStyle(TileButtonStyle())
            .padding(.vertical, 4)
            .padding(.horizontal, 1)
        }
        .scrollClipDisabled()
    }

    private var watchChipState: (text: String, color: Color) {
        switch model.protectionStatus {
        case .protected: return ("Protecting", .green)
        case .silenced: return ("Silenced", .indigo)
        case .off: return ("Off", .secondary)
        case .connecting: return ("Connecting…", .secondary)
        case .noWatch: return ("Not paired", .secondary)
        default: return ("Needs setup", .orange)
        }
    }

    // MARK: Quick actions

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ActionTile(symbol: "applewatch.radiowaves.left.and.right",
                           title: "Ring my watch",
                           subtitle: ringSubtitle,
                           color: .blue,
                           isBusy: model.ringWatchState == .sending) {
                    model.ringWatch()
                }

                Menu {
                    Button {
                        model.sendTestAlert(.firstReminder)
                    } label: {
                        Label("First reminder", systemImage: "hand.tap.fill")
                    }
                    Button {
                        model.sendTestAlert(.loud)
                    } label: {
                        Label("Loud alert", systemImage: "bell.and.waves.left.and.right.fill")
                    }
                } label: {
                    ActionTileContent(symbol: "bell.badge.fill", title: "Test alert",
                                      subtitle: testSubtitle, color: .orange,
                                      isBusy: model.testAlertState == .sending)
                }
                .buttonStyle(TileButtonStyle())

                if settings.isSnoozed() {
                    ActionTile(symbol: "bell.fill", title: "Resume alerts",
                               subtitle: settings.snoozedUntil.map { "Silenced until \($0.formatted(date: .omitted, time: .shortened))" },
                               color: .green) {
                        model.resumeAlerts()
                    }
                } else {
                    Menu {
                        Button("30 minutes") { model.snooze(minutes: 30) }
                        Button("1 hour") { model.snooze(minutes: 60) }
                        Button("3 hours") { model.snooze(minutes: 180) }
                        Button("8 hours") { model.snooze(minutes: 480) }
                    } label: {
                        ActionTileContent(symbol: "moon.zzz.fill", title: "Silence watch",
                                          subtitle: "Pause iPhone alerts", color: .indigo)
                    }
                    .buttonStyle(TileButtonStyle())
                }

                NavigationLink {
                    SafePlacesView()
                } label: {
                    ActionTileContent(symbol: "house.fill", title: "Safe places",
                                      subtitle: placesSubtitle, color: Theme.brand)
                }
                .buttonStyle(TileButtonStyle())
            }
            if let feedback = testFeedback {
                feedback
                    .font(.caption)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var ringSubtitle: String {
        switch model.ringWatchState {
        case .idle, .sending: return "Find it by sound"
        case .ringing: return "Ringing now"
        case .failed: return "Can't reach it"
        }
    }

    private var testSubtitle: String {
        switch model.testAlertState {
        case .idle, .sending: return "See it on your watch"
        case .sent: return "Sent, check your watch"
        case .failed: return "Couldn't reach watch"
        }
    }

    private var testFeedback: Text? {
        guard model.testAlertState == .failed else { return nil }
        return Text("Make sure your watch is nearby and unlocked, open DiTether on it, then try again.")
            .foregroundColor(.orange)
    }

    private var placesSubtitle: String {
        let count = settings.safePlaces.count
        return count == 0 ? "Add your home" : "\(count) saved"
    }
}

/// The inside of an action tile, for tiles that are menus or links rather than buttons.
struct ActionTileContent: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var color: Color = Theme.brand
    var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                IconBadge(symbol: symbol, color: color, size: 36)
                Spacer()
                if isBusy { ProgressView() }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(subtitle ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .card(padding: 14)
    }
}

/// A small card in the "With you" strip.
struct DeviceChip: View {
    let symbol: String
    let name: String
    let state: String
    let color: Color
    var battery: Int?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                IconBadge(symbol: symbol, color: color == .secondary ? .gray : color, size: 40)
                Spacer(minLength: 0)
                LiveDot(color: color == .secondary ? .gray : color, pulsing: color == .green)
            }
            Spacer(minLength: 0)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(state)
                    .font(.caption)
                    .foregroundStyle(color)
                    .lineLimit(1)
                if let battery {
                    Spacer(minLength: 0)
                    Text("\(battery)%")
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(battery <= 15 ? Color.red : Color.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 140, height: 132, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            if scheme == .dark {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.05), radius: 10, y: 4)
    }
}
