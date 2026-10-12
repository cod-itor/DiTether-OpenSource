import SwiftUI

struct WatchSettingsView: View {
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        List {
            Section {
                Toggle("Protection", isOn: model.binding(\.protectionEnabled))
            } footer: {
                Text("Off saves battery. Your watch stops checking for your iPhone.")
            }

            Section {
                Picker("Detection", selection: model.binding(\.detectionMode)) {
                    ForEach(DetectionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } footer: {
                Text(model.settings.settings.detectionMode.summary)
            }

            Section {
                Picker("Vibration", selection: model.binding(\.alertStyle)) {
                    ForEach(AlertStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            } footer: {
                Text(model.settings.settings.alertStyle.summary)
            }

            Section {
                Toggle("First reminder", isOn: model.binding(\.softAlertEnabled))
                Toggle("Loud alert", isOn: model.binding(\.strongAlertEnabled))
                Toggle("Alert when I walk away", isOn: model.binding(\.distanceAlertEnabled))
                Toggle("Bluetooth range", isOn: model.binding(\.bluetoothRangeEnabled))
            } header: {
                Text("Alerts")
            } footer: {
                Text("Weak Bluetooth signal: first reminder. Signal gone: loud alert.")
            }

            Section {
                Toggle("Quiet at safe places", isOn: model.binding(\.muteInSafePlaces))
            } footer: {
                Text("Add safe places such as home in the DiTether app on your iPhone.")
            }

            Section("Silence alerts") {
                if model.settings.settings.isSnoozed() {
                    Button("Resume alerts") { model.resumeAlerts() }
                }
                Button("30 minutes") { model.snooze(minutes: 30) }
                Button("1 hour") { model.snooze(minutes: 60) }
                Button("3 hours") { model.snooze(minutes: 180) }
            }

            Section {
                Button("First reminder") { model.showTestAlert(.firstReminder) }
                Button("Loud alert") { model.showTestAlert(.loud) }
            } header: {
                Text("Preview alerts")
            } footer: {
                Text("Shows and plays a sample alert. Nothing is wrong when you do this.")
            }

            Section {
                NavigationLink("Connection log") {
                    ConnectionLogView(log: model.log)
                }
            } footer: {
                Text("What your watch noticed during a test, such as when it lost your iPhone and why.")
            }

            Section {
                Text("Timings, safe places and history are in the DiTether app on your iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}
