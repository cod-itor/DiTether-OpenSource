import SwiftUI

/// The DiTAG tab: every DiTAG at a glance, adding new ones, and the options they share.
struct DiTagView: View {
    @EnvironmentObject private var model: PhoneModel

    private var manager: DiTagManager { model.diTag }
    private var settings: DiTagSettings { manager.settings }

    var body: some View {
        NavigationStack {
            Form {
                if manager.bluetooth != .ok {
                    bluetoothSection
                }
                if !settings.hasTags && manager.setupPhase == nil {
                    introSection
                }
                if !settings.tags.isEmpty {
                    Section {
                        ForEach(settings.tags) { tag in
                            NavigationLink(value: tag.id) {
                                DiTagRow(tag: tag, status: manager.status(tag.id))
                            }
                        }
                    } header: {
                        Text("Your DiTAGs")
                    } footer: {
                        Text("Keep DiTether in the background. Swiping it away stops the DiTAG alerts.")
                    }
                }
                addSection
                if settings.hasTags {
                    sharedOptionsSection
                }
            }
            .navigationTitle("DiTAG")
            .navigationDestination(for: UUID.self) { id in
                DiTagDetailView(tagID: id)
            }
        }
    }

    private var bluetoothSection: some View {
        Section {
            Label(manager.bluetooth == .unauthorized ? "Bluetooth is not allowed" : "Bluetooth is off",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(manager.bluetooth == .unauthorized
                 ? "DiTether needs Bluetooth to connect to your DiTAGs."
                 : "Your DiTAGs reconnect by themselves when Bluetooth is back on.")
                .foregroundStyle(.secondary)
            if manager.bluetooth == .unauthorized {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
    }

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "tag.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                Text("Never leave your keys behind")
                    .font(.title3.bold())
                Text("Attach a DiTAG to your keys, bag or wallet. Your iPhone vibrates and alerts you, also on your watch, when one is left behind.")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var addSection: some View {
        if let phase = manager.setupPhase {
            Section {
                HStack(spacing: 14) {
                    if phase == .confirming {
                        Image(systemName: "hand.tap.fill")
                            .font(.title)
                            .foregroundStyle(.tint)
                            .symbolEffect(.pulse)
                    } else {
                        ProgressView()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase == .confirming ? "Press the DiTAG button once" : "Looking for a new DiTAG…")
                            .font(.headline)
                        Text(phase == .confirming ? "It just beeped, so you know which one." : "Hold the new one close to your iPhone.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                Button("Cancel", role: .cancel) { manager.cancelSetup() }
            }
        } else {
            Section {
                Button {
                    model.requestNotificationPermission()
                    manager.startSetup()
                } label: {
                    Label(settings.hasTags ? "Add another DiTAG" : "Set up DiTAG", systemImage: "plus.circle.fill")
                        .font(.headline)
                }
                .disabled(!manager.canAddMore || manager.bluetooth == .unauthorized)
            } footer: {
                if let message = manager.setupMessage {
                    Text(message).foregroundStyle(.orange)
                } else if !manager.canAddMore {
                    Text("Up to \(DiTagSettings.maxTags) DiTAGs. iOS only keeps a few Bluetooth connections at once.")
                } else {
                    Text("Turn the new DiTAG on (hold its button 3–5 s until it beeps twice) and close iSearching or nRF Connect. Only one DiTAG at a time should be near the iPhone while adding.")
                }
            }
        }
    }

    private var sharedOptionsSection: some View {
        Section {
            Toggle("Ring iPhone on double-press", isOn: manager.binding(\.ringOnDoublePress))
            Toggle("Save where it was left", isOn: Binding(
                get: { settings.saveLocation },
                set: { on in
                    manager.edit { $0.saveLocation = on }
                    if on && !model.location.isAuthorized { model.location.requestSharingAuthorization() }
                }))
            Stepper(value: manager.binding(\.graceSeconds), in: DiTagSettings.graceRange) {
                LabeledContent("Alert after", value: settings.graceSeconds == 0 ? "Right away" : "\(settings.graceSeconds) s")
            }
        } header: {
            Text("All DiTAGs")
        } footer: {
            Text("A short wait keeps a blip at the edge of range quiet. Quiet hours and safe places from Settings apply to every DiTAG.")
        }
    }
}

/// One DiTAG in the list.
private struct DiTagRow: View {
    let tag: DiTag
    let status: DiTagManager.TagStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: DiTagLook.icon(status.state))
                .font(.title2)
                .foregroundStyle(DiTagLook.color(status.state))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(tag.displayName)
                    .font(.headline)
                DiTagLook.text(status, snoozed: tag.isSnoozed())
                    .font(.subheadline)
                    .foregroundStyle(DiTagLook.color(status.state))
            }
            Spacer()
            if let battery = status.battery, status.state != .off {
                Label("\(battery)%", systemImage: DiTagLook.batteryIcon(battery))
                    .font(.caption)
                    .foregroundStyle(battery <= 15 ? Color.red : Color.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
    }
}

/// One DiTAG: find it, snooze it, rename it, switch it off or forget it.
struct DiTagDetailView: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    let tagID: UUID

    @State private var confirmForget = false
    @State private var nameDraft = ""
    @FocusState private var editingName: Bool

    private var manager: DiTagManager { model.diTag }

    var body: some View {
        Group {
            if let tag = manager.settings.tag(tagID) {
                form(tag, status: manager.status(tagID))
            } else {
                ContentUnavailableView("DiTAG removed", systemImage: "tag.slash")
            }
        }
        .onAppear { manager.setSignalWanted(tagID, true) }
        .onDisappear { manager.setSignalWanted(tagID, false) }
    }

    private func form(_ tag: DiTag, status: DiTagManager.TagStatus) -> some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { tag.isEnabled }, set: { manager.setEnabled(tagID, $0) })) {
                    HStack(spacing: 12) {
                        Image(systemName: DiTagLook.icon(status.state))
                            .font(.title2)
                            .foregroundStyle(DiTagLook.color(status.state))
                            .frame(width: 32)
                        DiTagLook.text(status, snoozed: tag.isSnoozed())
                            .font(.headline)
                            .foregroundStyle(DiTagLook.color(status.state))
                    }
                }
                if tag.isEnabled {
                    if let battery = status.battery {
                        LabeledContent("Battery") {
                            Label("\(battery)%", systemImage: DiTagLook.batteryIcon(battery))
                                .foregroundStyle(battery <= 15 ? Color.red : Color.secondary)
                        }
                    }
                    if let proximity = status.proximity, status.state == .connected {
                        LabeledContent("Distance", value: proximity.title)
                    }
                }
            } footer: {
                if !tag.isEnabled {
                    Text("Off: DiTether is not connected to this DiTAG and nothing runs for it.")
                }
            }

            if tag.isEnabled {
                Section {
                    if status.isBeeping {
                        Button {
                            manager.stopBeep(tagID)
                        } label: {
                            Label("Stop sound", systemImage: "speaker.slash.fill")
                        }
                    } else {
                        Button {
                            manager.beep(tagID)
                        } label: {
                            Label("Play sound", systemImage: "speaker.wave.3.fill")
                        }
                        .disabled(status.state != .connected)
                    }
                } header: {
                    Text("Find")
                } footer: {
                    Text(status.state == .connected
                         ? "Double-press the DiTAG button to ring this iPhone, even on silent."
                         : "It can play a sound once it's back in range.")
                }

                Section {
                    if tag.snoozedUntilBack {
                        LabeledContent("Silenced", value: "Until it's back")
                        Button("Resume alerts") { manager.resumeAlerts(tagID) }
                    } else if tag.isSnoozed(), let until = tag.snoozedUntil {
                        LabeledContent("Silenced until", value: until.formatted(date: .omitted, time: .shortened))
                        Button("Resume alerts") { manager.resumeAlerts(tagID) }
                    } else {
                        Menu {
                            Button("Until it's back with me") { manager.snoozeUntilBack(tagID) }
                            Button("30 minutes") { manager.snooze(tagID, minutes: 30) }
                            Button("1 hour") { manager.snooze(tagID, minutes: 60) }
                            Button("3 hours") { manager.snooze(tagID, minutes: 180) }
                            Button("8 hours") { manager.snooze(tagID, minutes: 480) }
                        } label: {
                            Label("Leave it here for a while…", systemImage: "moon.zzz.fill")
                        }
                    }
                } header: {
                    Text("Snooze")
                } footer: {
                    Text("\"Until it's back\" turns alerts on again by itself when this DiTAG is back in range.")
                }
            }

            Section("Name") {
                TextField("Keys", text: $nameDraft)
                    .focused($editingName)
                    .submitLabel(.done)
                    .onSubmit(saveName)
                    .onAppear { nameDraft = tag.name }
                    .onChange(of: editingName) { _, editing in
                        if !editing { saveName() }
                    }
            }

            Section {
                Button("Forget DiTAG", role: .destructive) { confirmForget = true }
            }
        }
        .navigationTitle(tag.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Forget \(tag.displayName)?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget DiTAG", role: .destructive) {
                dismiss()
                manager.forget(tagID)
            }
        } message: {
            Text("DiTether disconnects and stops watching it. You can add it again any time.")
        }
    }

    private func saveName() {
        manager.rename(tagID, to: nameDraft)
        nameDraft = manager.settings.tag(tagID)?.displayName ?? nameDraft
    }
}

/// Icons, colours and wording shared by the list and the detail screen.
private enum DiTagLook {
    static func icon(_ state: DiTagManager.TagState) -> String {
        switch state {
        case .connected: return "tag.fill"
        case .lost: return "exclamationmark.triangle.fill"
        case .off: return "tag.slash"
        case .connecting: return "tag"
        }
    }

    static func color(_ state: DiTagManager.TagState) -> Color {
        switch state {
        case .connected: return .green
        case .lost: return .orange
        default: return .secondary
        }
    }

    static func text(_ status: DiTagManager.TagStatus, snoozed: Bool) -> Text {
        switch status.state {
        case .connected:
            return Text(snoozed ? "With you · snoozed" : "With you")
        case .lost:
            if let lostAt = status.lostAt {
                return Text("Left behind · \(lostAt, style: .relative) ago")
            }
            return Text("Out of range")
        case .off:
            return Text("Off")
        case .connecting:
            return Text("Connecting…")
        }
    }

    static func batteryIcon(_ level: Int) -> String {
        switch level {
        case 76...: return "battery.100"
        case 51...75: return "battery.75"
        case 26...50: return "battery.50"
        case 11...25: return "battery.25"
        default: return "battery.0"
        }
    }
}
