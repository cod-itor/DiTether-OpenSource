import AppIntents
import MapKit
import SwiftUI

/// One DiTAG: a live header, find it, see where it was left, snooze, rename, switch off or forget.
struct DiTagDetailView: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    let tagID: UUID

    @State private var confirmForget = false
    /// Forgotten once the screen has gone, so the pop animation never shows an empty page.
    @State private var forgetOnLeave = false
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
        .task { nameDraft = manager.settings.tag(tagID)?.displayName ?? "" }
        .onAppear { manager.setSignalWanted(tagID, true) }
        .onDisappear {
            manager.setSignalWanted(tagID, false)
            if forgetOnLeave { manager.forget(tagID) }
        }
    }

    private func form(_ tag: DiTag, status: DiTagManager.TagStatus) -> some View {
        Form {
            Section {
                header(tag, status: status)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                Toggle(isOn: Binding(get: { tag.isEnabled }, set: { manager.setEnabled(tagID, $0) })) {
                    Label("Watch this DiTAG", systemImage: "dot.radiowaves.left.and.right")
                }
                .tint(.green)
            } footer: {
                Text(tag.isEnabled
                     ? "Your iPhone alerts you the moment it goes out of range."
                     : "Off: not connected, and nothing runs for it.")
            }

            if status.state == .lost, let fix = tag.lastLeftFix {
                lastSeenSection(tag, fix: fix)
            }

            if tag.isEnabled {
                quietSection(tag)
            }

            if tag.isEnabled && !tag.isQuiet() {
                Section {
                    findButton(status)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
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
                    Text("Snooze keeps it connected but silences your iPhone. \"Until it's back\" turns alerts on again by itself when this DiTAG is back in range.")
                }
            }

            Section("Name") {
                TextField("Keys", text: $nameDraft)
                    .focused($editingName)
                    .submitLabel(.done)
                    .onSubmit(saveName)
                    .onChange(of: editingName) { _, editing in
                        if !editing { saveName() }
                    }
                NameSuggestions(selection: tag.displayName) { name in
                    nameDraft = name
                    saveName()
                }
            }

            Section {
                NavigationLink {
                    DiTagDiagnosticsView(tagID: tagID)
                } label: {
                    Label("Test and diagnostics", systemImage: "stethoscope")
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
                forgetOnLeave = true
                dismiss()
            }
        } message: {
            Text("DiTether disconnects and stops watching it. You can add it again any time.")
        }
    }

    /// Big icon, name, live status, battery and signal.
    private func header(_ tag: DiTag, status: DiTagManager.TagStatus) -> some View {
        let color = DiTagLook.color(status.state) == .secondary ? Color.gray : DiTagLook.color(status.state)
        return VStack(spacing: 12) {
            PulsingShield(symbol: DiTagLook.icon(status.state), color: color,
                          isLive: status.state == .connected)
            Text(tag.displayName)
                .font(.title.bold())
            DiTagLook.text(status, snoozed: tag.isSnoozed())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            if tag.isEnabled {
                HStack(spacing: 10) {
                    StatTile(title: "Battery",
                             value: status.battery.map { "\($0)%" } ?? "–",
                             color: (status.battery ?? 100) <= 15 ? .red : .primary)
                    StatTile(title: "Distance",
                             value: status.state == .connected ? (status.proximity?.title ?? "…") : "–",
                             color: .primary,
                             bars: status.state == .connected ? status.signal.map(SignalBars.level(forRSSI:)) : nil)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// Quiet mode: disconnects on purpose, so leaving it somewhere makes no noise.
    @ViewBuilder
    private func quietSection(_ tag: DiTag) -> some View {
        Section {
            if tag.isQuiet(), let until = tag.quietUntil {
                LabeledContent("Quiet", value: tag.isQuietUntilTurnedOff
                               ? "Until you turn it off"
                               : "Until \(until.formatted(date: .omitted, time: .shortened))")
                Button {
                    manager.endQuiet([tagID])
                } label: {
                    Label("Resume", systemImage: "bell.fill")
                }
            } else {
                Menu {
                    Button("1 hour") { manager.startQuiet([tagID], until: Date().addingTimeInterval(3600)) }
                    Button("3 hours") { manager.startQuiet([tagID], until: Date().addingTimeInterval(3 * 3600)) }
                    Button("Until tomorrow 7:00") { manager.startQuiet([tagID], until: Self.tomorrowSeven) }
                    Button("Until I turn it off") { manager.startQuiet([tagID], until: nil) }
                } label: {
                    Label("Quiet mode…", systemImage: "moon.zzz.fill")
                }
            }
        } header: {
            Text("Quiet mode")
        } footer: {
            switch manager.settings.politeDisconnectSilent {
            case .some(false):
                Text("Disconnects on purpose so your iPhone stays quiet. This DiTAG still beeps when disconnected: to keep it silent too, hold its button for 5 seconds to switch it off.")
            case .some(true):
                Text("Disconnects on purpose, so neither your iPhone nor the DiTAG makes noise while you leave it somewhere, like a locker.")
            case .none:
                Text("Disconnects on purpose so your iPhone stays quiet while you leave it somewhere. Run the test in Test and diagnostics to see if the DiTAG stays silent too.")
            }
        }
    }

    private static var tomorrowSeven: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return calendar.date(bySettingHour: 7, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    @ViewBuilder
    private func findButton(_ status: DiTagManager.TagStatus) -> some View {
        if status.isBeeping {
            Button {
                manager.stopBeep(tagID)
            } label: {
                Label("Stop sound", systemImage: "speaker.slash.fill")
            }
            .buttonStyle(PrimaryButtonStyle(color: .orange))
        } else {
            Button {
                manager.beep(tagID)
            } label: {
                Label("Play sound", systemImage: "speaker.wave.3.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(status.state != .connected)
            .opacity(status.state == .connected ? 1 : 0.45)
        }
    }

    /// Where the iPhone was when the DiTAG went out of range: it is within about 25 m of there.
    private func lastSeenSection(_ tag: DiTag, fix: GeoFix) -> some View {
        let coordinate = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
        return Section {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate,
                                                            latitudinalMeters: 300,
                                                            longitudinalMeters: 300))) {
                Marker(tag.displayName, systemImage: "tag.fill", coordinate: coordinate)
                    .tint(.orange)
                UserAnnotation()
            }
            .frame(height: 200)
            .listRowInsets(EdgeInsets())

            if let at = tag.lastLeftAt {
                Label {
                    Text("Left here \(at, style: .relative) ago")
                } icon: {
                    Image(systemName: "mappin.and.ellipse")
                }
            }
            Link(destination: mapsURL(tag, fix: fix)) {
                Label("Open in Maps", systemImage: "map")
            }
        } header: {
            Text("Where it was left")
        } footer: {
            Text("Where your iPhone was when the DiTAG went out of range, accurate to about \(Int(fix.accuracy)) m. It's usually within 25 m of here.")
        }
    }

    private func mapsURL(_ tag: DiTag, fix: GeoFix) -> URL {
        let query = tag.displayName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "DiTAG"
        return URL(string: "https://maps.apple.com/?ll=\(fix.latitude),\(fix.longitude)&q=\(query)")
            ?? URL(string: "https://maps.apple.com")!
    }

    private func saveName() {
        manager.rename(tagID, to: nameDraft)
        nameDraft = manager.settings.tag(tagID)?.displayName ?? nameDraft
    }
}

/// The "disconnect politely" test and the tag's read-only values.
struct DiTagDiagnosticsView: View {
    @EnvironmentObject private var model: PhoneModel
    let tagID: UUID

    private var manager: DiTagManager { model.diTag }

    var body: some View {
        let status = manager.status(tagID)
        let values = manager.diagnostics[tagID] ?? [:]
        Form {
            Section {
                if manager.politeTestAwaitingAnswer == tagID {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Listening… did the DiTAG beep?", systemImage: "ear.fill")
                            .font(.headline)
                        Text("It reconnects by itself in a few seconds.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("It stayed silent") { manager.answerPoliteTest(silent: true) }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                            Button("It beeped") { manager.answerPoliteTest(silent: false) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        manager.testPoliteDisconnect(tagID)
                    } label: {
                        Label("Test: disconnect politely", systemImage: "antenna.radiowaves.left.and.right.slash")
                    }
                    .disabled(status.state != .connected)
                    if let silent = manager.settings.politeDisconnectSilent {
                        LabeledContent("Last result", value: silent ? "Stays silent" : "Beeps")
                    }
                }
            } header: {
                Text("Quiet mode test")
            } footer: {
                Text("Keep the DiTAG next to you. DiTether disconnects on purpose for 8 seconds; tell it whether the DiTAG beeped. This decides what Quiet mode can promise.")
            }

            Section {
                Button("Read values") { manager.readDiagnostics(tagID) }
                    .disabled(status.state != .connected)
                ForEach(["FFE3", "FFE6", "FFE7"], id: \.self) { key in
                    LabeledContent(key, value: values[key] ?? "–")
                        .monospaced()
                }
            } header: {
                Text("Unknown values")
            } footer: {
                Text("Read only. DiTether never writes to these; their meaning is unknown.")
            }

            Section("Battery and signal") {
                LabeledContent("Battery", value: status.battery.map { "\($0)%" } ?? "–")
                LabeledContent("Signal", value: status.signal.map { "\($0) dBm" } ?? "–")
            }
        }
        .navigationTitle("Test and diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { manager.setSignalWanted(tagID, true) }
        .onDisappear { manager.setSignalWanted(tagID, false) }
    }
}

/// A small figure in the DiTAG header.
private struct StatTile: View {
    let title: String
    let value: String
    var color: Color
    var bars: Int?

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(value)
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(color)
                if let bars {
                    SignalBars(level: bars)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// One-tap names, so most people never type.
struct NameSuggestions: View {
    let selection: String
    let choose: (String) -> Void

    static let names = ["Keys", "Bag", "Wallet", "Backpack", "Car", "Bike", "Laptop"]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.names, id: \.self) { name in
                    let isSelected = name.caseInsensitiveCompare(selection) == .orderedSame
                    Button(name) { choose(name) }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(isSelected ? .white : Theme.brand)
                        .background(isSelected ? AnyShapeStyle(Theme.brandDeep) : AnyShapeStyle(Theme.brand.opacity(0.12)),
                                    in: Capsule())
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Options shared by every DiTAG.
struct DiTagOptionsView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var showGuide = false

    private var manager: DiTagManager { model.diTag }
    private var settings: DiTagSettings { manager.settings }

    var body: some View {
        Form {
            Section {
                Picker("When left behind", selection: manager.binding(\.alarmSound)) {
                    Text("Vibrate").tag(false)
                    Text("Sound + vibrate").tag(true)
                }
                Toggle("Early warning", isOn: Binding(get: { settings.earlyWarning },
                                                      set: { manager.setEarlyWarning($0) }))
            } header: {
                Text("Alerts")
            } footer: {
                Text("Your iPhone alerts the moment a DiTAG disconnects. Sound plays at full volume, also on silent, for up to 30 s. Early warning taps once when the signal gets weak, while DiTether is open or awake.")
            }

            Section {
                Toggle(isOn: manager.binding(\.singlePressSavesSpot)) {
                    Label("Press once: save my spot", systemImage: "mappin.and.ellipse")
                }
                Toggle(isOn: manager.binding(\.ringOnDoublePress)) {
                    Label("Press twice: ring iPhone", systemImage: "iphone.radiowaves.left.and.right")
                }
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Double-press speed",
                                   value: String(format: "%.1f s", settings.doublePressWindow))
                    Slider(value: manager.binding(\.doublePressWindow), in: DiTagSettings.doublePressRange, step: 0.1) {
                        Text("Double-press speed")
                    } minimumValueLabel: {
                        Image(systemName: "hare.fill").font(.caption)
                    } maximumValueLabel: {
                        Image(systemName: "tortoise.fill").font(.caption)
                    }
                }
            } header: {
                Text("DiTAG button")
            } footer: {
                Text("With the camera open, every press takes a photo instead. Any press stops your iPhone ringing. A longer double-press time makes double presses easier but a single press waits longer.")
            }

            Section {
                Toggle("Save where it was left", isOn: Binding(
                    get: { settings.saveLocation },
                    set: { on in
                        manager.edit { $0.saveLocation = on }
                        if on && !model.location.isAuthorized { model.location.requestSharingAuthorization() }
                    }))
                Toggle("Offer Quiet mode at quiet hours", isOn: manager.binding(\.quietHoursPrompt))
                    .disabled(!model.settings.settings.quietHoursEnabled)
                if model.location.status != .authorizedAlways {
                    // Saving a spot or where a DiTAG was left happens in the background, which
                    // needs "Always".
                    Button {
                        // iOS asks to upgrade to Always once; after that only Settings can change it.
                        if model.location.isDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        } else {
                            model.location.requestSharingAuthorization()
                        }
                    } label: {
                        Label("Allow location: Always", systemImage: "location.fill")
                    }
                }
            } footer: {
                Text(model.settings.settings.quietHoursEnabled
                     ? "Quiet hours and safe places from Settings apply to every DiTAG. At the start of quiet hours, a notification offers to silence your DiTAGs until they end."
                     : "Turn on quiet hours in Settings to be offered Quiet mode when they start. Safe places also apply to every DiTAG.")
            }

            Section {
                NavigationLink {
                    PlacesView()
                } label: {
                    Label("Places", systemImage: "map")
                }
                NavigationLink {
                    ShortcutsHelpView()
                } label: {
                    Label("Shortcuts and Siri", systemImage: "square.2.layers.3d.fill")
                }
                NavigationLink {
                    DiTagActivityView()
                } label: {
                    Label("Activity", systemImage: "list.bullet.rectangle")
                }
                Button {
                    showGuide = true
                } label: {
                    Label("How to set up a DiTAG", systemImage: "questionmark.circle")
                }
            }
        }
        .navigationTitle("DiTAG options")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showGuide) {
            DiTagSetupGuide(startAtIntro: true)
                .environmentObject(model)
        }
    }
}

/// How to use DiTether from Shortcuts, Siri and the Action button.
struct ShortcutsHelpView: View {
    var body: some View {
        Form {
            Section {
                Text("DiTether's actions work in the Shortcuts app and with Siri, and most run without opening the app.")
                    .font(.subheadline)
                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            Section("Actions") {
                HelpRow(symbol: "camera.fill", color: .pink, title: "Open DiTAG Camera",
                        text: "Opens the camera ready for a DiTAG press.")
                HelpRow(symbol: "moon.zzz.fill", color: .indigo, title: "Start Quiet Mode / End Quiet Mode",
                        text: "For one DiTAG or all, for some minutes or until you end it.")
                HelpRow(symbol: "speaker.wave.3.fill", color: .blue, title: "Ring DiTAG",
                        text: "Beeps a DiTAG for 5 seconds.")
                HelpRow(symbol: "mappin.and.ellipse", color: .teal, title: "Save My Spot",
                        text: "Saves where you are on the Places map.")
            }

            Section {
                HelpRow(symbol: "button.horizontal.top.press.fill", color: .orange, title: "Action button",
                        text: "Settings → Action Button → Shortcut → DiTether → Open DiTAG Camera.")
                HelpRow(symbol: "building.2.fill", color: .gray, title: "Quiet at work",
                        text: "Shortcuts → Automation → New → Arrive → Work → Start Quiet Mode. Choose Run Immediately.")
                HelpRow(symbol: "clock.fill", color: .indigo, title: "Quiet every night",
                        text: "Shortcuts → Automation → New → Time of Day → 23:00 → Start Quiet Mode, 480 minutes. Choose Run Immediately.")
            } header: {
                Text("Ideas")
            } footer: {
                Text("Automations run even when DiTether is closed. Swiping DiTether away in the app switcher still pauses DiTAG alerts until you open it.")
            }
        }
        .navigationTitle("Shortcuts and Siri")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HelpRow: View {
    let symbol: String
    let color: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: symbol, color: color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// What the DiTAGs did, newest first: the quickest way to check a walk test.
struct DiTagActivityView: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        List {
            if model.diTag.activity.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Disconnects, alerts and why one stayed quiet show up here."))
            }
            ForEach(model.diTag.activity) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.text)
                    Text(line.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            if !model.diTag.activity.isEmpty {
                Button("Clear") { model.diTag.clearActivity() }
            }
        }
    }
}

/// Icons, colours and wording shared by every DiTAG view.
enum DiTagLook {
    static func icon(_ state: DiTagManager.TagState) -> String {
        switch state {
        case .connected: return "tag.fill"
        case .lost: return "exclamationmark.triangle.fill"
        case .off: return "tag.slash"
        case .connecting: return "tag"
        case .quiet: return "moon.zzz.fill"
        }
    }

    static func color(_ state: DiTagManager.TagState) -> Color {
        switch state {
        case .connected: return .green
        case .lost: return .orange
        case .quiet: return .indigo
        default: return .secondary
        }
    }

    static func shortText(_ state: DiTagManager.TagState) -> String {
        switch state {
        case .connected: return "With you"
        case .lost: return "Left behind"
        case .off: return "Off"
        case .connecting: return "Connecting…"
        case .quiet: return "Quiet mode"
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
        case .quiet:
            return Text("Quiet mode")
        }
    }
}
