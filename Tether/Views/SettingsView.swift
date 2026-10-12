import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var confirmClear = false
    @AppStorage(RootView.onboardedKey) private var hasOnboarded = false

    private var settings: TetherSettings { model.settings.settings }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Protection", isOn: model.binding(\.protectionEnabled))
                } footer: {
                    Text("Your watch keeps checking in the background while this is on. Switch off to save battery.")
                }

                Section {
                    NavigationLink {
                        AlertTimingView()
                    } label: {
                        LabeledContent("Alert timing", value: timingSummary)
                    }
                } header: {
                    Text("Alerts")
                } footer: {
                    Text("The defaults work well for most people.")
                }

                Section {
                    DetectionModePicker()
                } header: {
                    Text("Detection")
                } footer: {
                    Text("Faster detection checks more often and uses location on both devices. Your watch's background session runs in every mode.")
                }

                if model.connectivity.isWatchAppInstalled {
                    TestAlertSection()
                }

                Section {
                    NavigationLink {
                        SafePlacesView()
                    } label: {
                        LabeledContent("Safe places", value: "\(settings.safePlaces.count)")
                    }
                    Toggle("Quiet at safe places", isOn: model.binding(\.muteInSafePlaces))
                    Toggle("Quiet hours", isOn: model.binding(\.quietHoursEnabled))
                    if settings.quietHoursEnabled {
                        DatePicker("From", selection: timeBinding(\.quietStartMinute), displayedComponents: .hourAndMinute)
                        DatePicker("Until", selection: timeBinding(\.quietEndMinute), displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("Stay quiet")
                } footer: {
                    Text("Quiet is not the same as off: if you walk out of a safe place without your iPhone, the alert fires right away.")
                }

                Section("Silence") {
                    if settings.isSnoozed(), let until = settings.snoozedUntil {
                        LabeledContent("Silenced until", value: until.formatted(date: .omitted, time: .shortened))
                        Button("Resume alerts") { model.resumeAlerts() }
                    } else {
                        Menu("Silence alerts for...") {
                            Button("30 minutes") { model.snooze(minutes: 30) }
                            Button("1 hour") { model.snooze(minutes: 60) }
                            Button("3 hours") { model.snooze(minutes: 180) }
                            Button("8 hours") { model.snooze(minutes: 480) }
                        }
                    }
                }

                Section("Help") {
                    NavigationLink("How DiTether works") {
                        HowTetherWorksView()
                    }
                    Button("Show the intro again") {
                        hasOnboarded = false
                    }
                }

                Section {
                    Button("Clear history", role: .destructive) {
                        confirmClear = true
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("History and locations stay on your iPhone and Apple Watch. There is no account and no server, and the files are left out of backups.")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) { model.clearHistory() }
            }
        }
    }

    private var timingSummary: String {
        var parts: [String] = []
        if settings.softAlertEnabled { parts.append("\(settings.softDelaySeconds) s") }
        if settings.strongAlertEnabled { parts.append("\(settings.strongDelaySeconds) s") }
        return parts.isEmpty ? "Off" : parts.joined(separator: " · ")
    }

    /// Settings store "minutes after midnight"; the picker wants a Date.
    private func timeBinding(_ keyPath: WritableKeyPath<TetherSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = model.settings.settings[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                model.edit { $0[keyPath: keyPath] = minutes }
            }
        )
    }
}
