import SwiftUI
import MapKit

/// One DiTAG: a live header, find it, see where it was left, snooze, rename, switch off or forget.
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
                NameSuggestions(selection: tag.displayName) { name in
                    nameDraft = name
                    saveName()
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
                        .background(isSelected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.brand.opacity(0.12)),
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
                Toggle("Ring iPhone on double-press", isOn: manager.binding(\.ringOnDoublePress))
                Toggle("Save where it was left", isOn: Binding(
                    get: { settings.saveLocation },
                    set: { on in
                        manager.edit { $0.saveLocation = on }
                        if on && !model.location.isAuthorized { model.location.requestSharingAuthorization() }
                    }))
            } footer: {
                Text("Quiet hours and safe places from Settings apply to every DiTAG.")
            }

            Section {
                NavigationLink("Activity") { DiTagActivityView() }
                Button("How to set up a DiTAG") { showGuide = true }
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
        }
    }

    static func color(_ state: DiTagManager.TagState) -> Color {
        switch state {
        case .connected: return .green
        case .lost: return .orange
        default: return .secondary
        }
    }

    static func shortText(_ state: DiTagManager.TagState) -> String {
        switch state {
        case .connected: return "With you"
        case .lost: return "Left behind"
        case .off: return "Off"
        case .connecting: return "Connecting…"
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
}
