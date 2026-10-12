import SwiftUI

/// The fine-tuning most people never need, kept off the main Settings screen.
struct AlertTimingView: View {
    @EnvironmentObject private var model: PhoneModel

    private var settings: TetherSettings { model.settings.settings }

    var body: some View {
        Form {
            Section {
                Picker("Vibration", selection: model.binding(\.alertStyle)) {
                    ForEach(AlertStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Vibration")
            } footer: {
                Text(settings.alertStyle.summary)
            }

            Section {
                Toggle("First reminder", isOn: model.binding(\.softAlertEnabled))
                if settings.softAlertEnabled {
                    Stepper(value: model.binding(\.softDelaySeconds), in: 5...120, step: 5) {
                        LabeledContent("After", value: "\(settings.softDelaySeconds) seconds")
                    }
                }
            } header: {
                Text("First reminder")
            } footer: {
                Text("A single gentle tap. The short wait means a quick Bluetooth blip never bothers you.")
            }

            Section {
                Toggle("Loud alert", isOn: model.binding(\.strongAlertEnabled))
                if settings.strongAlertEnabled {
                    Stepper(value: model.binding(\.strongDelaySeconds), in: 20...600, step: 10) {
                        LabeledContent("After", value: "\(settings.strongDelaySeconds) seconds")
                    }
                    Stepper(value: model.binding(\.strongRepeatMinutes), in: 1...30) {
                        LabeledContent("Keep alerting for", value: "\(settings.strongRepeatMinutes) min")
                    }
                }
            } header: {
                Text("Loud alert")
            } footer: {
                Text("Strong taps plus a notification, repeating until your iPhone is back in range or you silence it.")
            }

            Section {
                Toggle("Bluetooth range", isOn: model.binding(\.bluetoothRangeEnabled))
            } header: {
                Text("Bluetooth range")
            } footer: {
                Text("Your watch keeps its own Bluetooth link to this iPhone. When the signal gets weak you get the first reminder; when it drops you get the loud alert. Wi-Fi can't fool it.")
            }

            Section {
                Toggle("Alert when I walk away", isOn: model.binding(\.distanceAlertEnabled))
                if settings.distanceAlertEnabled {
                    Stepper(value: model.binding(\.distanceAlertMeters), in: 30...500, step: 10) {
                        LabeledContent("Loud alert at", value: "\(settings.distanceAlertMeters) m")
                    }
                    LabeledContent("First reminder at", value: "\(settings.distanceAlertMeters / 2) m")
                }
            } header: {
                Text("Walking away")
            } footer: {
                Text("Your watch compares its position with your iPhone's and alerts you as soon as you walk this far away, even if they still look connected over Wi-Fi. Indoors, where GPS is weak, the timers above are used instead.")
            }

            Section {
                Button("Use recommended settings") {
                    model.edit { settings in
                        let defaults = TetherSettings()
                        settings.softAlertEnabled = defaults.softAlertEnabled
                        settings.softDelaySeconds = defaults.softDelaySeconds
                        settings.strongAlertEnabled = defaults.strongAlertEnabled
                        settings.strongDelaySeconds = defaults.strongDelaySeconds
                        settings.strongRepeatMinutes = defaults.strongRepeatMinutes
                        settings.distanceAlertEnabled = defaults.distanceAlertEnabled
                        settings.distanceAlertMeters = defaults.distanceAlertMeters
                        settings.bluetoothRangeEnabled = defaults.bluetoothRangeEnabled
                        settings.alertStyle = defaults.alertStyle
                    }
                }
            } footer: {
                Text("First reminder after 10 seconds or 30 m, loud alert after 60 seconds or 60 m.")
            }
        }
        .navigationTitle("Alert timing")
        .navigationBarTitleDisplayMode(.inline)
    }
}
