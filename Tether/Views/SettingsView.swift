import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var confirmClear = false
    @AppStorage(RootView.onboardedKey) private var hasOnboarded = false
    @State private var showTagGuide = false

    private var settings: TetherSettings { model.settings.settings }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AppearancePicker()
                        .listRowInsets(EdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12))
                } header: {
                    Text("Appearance")
                }

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
                        Menu("Silence alerts for…") {
                            Button("30 minutes") { model.snooze(minutes: 30) }
                            Button("1 hour") { model.snooze(minutes: 60) }
                            Button("3 hours") { model.snooze(minutes: 180) }
                            Button("8 hours") { model.snooze(minutes: 480) }
                        }
                    }
                }

                Section("DiTAG") {
                    NavigationLink {
                        DiTagOptionsView()
                    } label: {
                        LabeledContent("DiTAG options",
                                       value: model.diTag.settings.alarmSound ? "Sound + vibrate" : "Vibrate")
                    }
                    NavigationLink("Activity") { DiTagActivityView() }
                }

                Section("Help") {
                    NavigationLink("How DiTether works") {
                        HowTetherWorksView()
                    }
                    Button("How to set up a DiTAG") { showTagGuide = true }
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
            .sheet(isPresented: $showTagGuide) {
                DiTagSetupGuide(startAtIntro: true)
                    .environmentObject(model)
            }
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

/// Three small previews (System, Light, Dark); tap one to switch the whole app.
struct AppearancePicker: View {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AppAppearance.allCases) { option in
                let isSelected = appearance == option.rawValue
                Button {
                    withAnimation(.snappy) { appearance = option.rawValue }
                } label: {
                    VStack(spacing: 8) {
                        AppearancePreview(option: option)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(isSelected ? Theme.brand : Color.secondary.opacity(0.25),
                                                  lineWidth: isSelected ? 2.5 : 1)
                            }
                        Label(option.title, systemImage: option.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? Theme.brand : .secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// A tiny drawing of the Home screen in light or dark.
private struct AppearancePreview: View {
    let option: AppAppearance

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                switch option {
                case .light:
                    screen(dark: false)
                case .dark:
                    screen(dark: true)
                case .system:
                    screen(dark: false)
                        .frame(width: geometry.size.width / 2, alignment: .leading)
                        .clipped()
                    screen(dark: true)
                        .frame(width: geometry.size.width / 2, alignment: .trailing)
                        .clipped()
                }
            }
        }
        .frame(height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func screen(dark: Bool) -> some View {
        let background = dark ? Color(white: 0.0) : Color(white: 0.95)
        let card = dark ? Color(white: 0.15) : .white
        return VStack(spacing: 5) {
            Circle()
                .fill(Color.green.gradient)
                .frame(width: 20, height: 20)
                .padding(.top, 10)
            RoundedRectangle(cornerRadius: 3).fill(card).frame(height: 12)
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(card)
                RoundedRectangle(cornerRadius: 3).fill(card)
            }
            .frame(height: 18)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
    }
}
