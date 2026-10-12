import SwiftUI

struct StatusView: View {
    @EnvironmentObject private var model: PhoneModel

    private var settings: TetherSettings { model.settings.settings }

    var body: some View {
        let status = model.protectionStatus
        let openSteps = model.setupSteps.filter { !$0.isDone }

        NavigationStack {
            List {
                Section {
                    StatusHero(status: status)
                }

                Section {
                    KeepOpenCard()
                }
                .listRowBackground(Color.orange.opacity(0.12))

                if status == .protected {
                    TestAlertSection()
                }

                if !openSteps.isEmpty {
                    Section {
                        ForEach(openSteps) { step in
                            SetupStepLink(step: step)
                        }
                    } header: {
                        Text("Finish setting up")
                    } footer: {
                        if let message = model.launcher.message {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Toggle(isOn: model.binding(\.protectionEnabled)) {
                        Label("Protection", systemImage: settings.protectionEnabled ? "checkmark.shield.fill" : "moon.zzz.fill")
                    }
                } footer: {
                    Text("Turns checking on or off on both devices. Switch off to save watch battery when you don't need it.")
                }

                if let latest = model.events.events.first {
                    Section("Most recent alert") {
                        NavigationLink {
                            EventDetailView(event: latest)
                        } label: {
                            EventRow(event: latest)
                        }
                    }
                }

                if model.connectivity.isPaired {
                    Section("Your Apple Watch") {
                        LabeledContent("DiTether on watch", value: model.connectivity.isWatchAppInstalled ? "Installed" : "Not installed")
                        LabeledContent("Last contact", value: lastContactText)
                        Button {
                            model.ringWatch()
                        } label: {
                            HStack {
                                Label("Ring my watch", systemImage: "applewatch.radiowaves.left.and.right")
                                Spacer()
                                switch model.ringWatchState {
                                case .sending: ProgressView()
                                case .ringing: Text("Ringing").foregroundStyle(.green)
                                case .failed: Text("Can't reach it").foregroundStyle(.orange)
                                case .idle: EmptyView()
                                }
                            }
                        }
                        .disabled(model.ringWatchState == .sending)
                    }
                }
            }
            .navigationTitle("DiTether")
        }
    }

    private var lastContactText: String {
        if model.connectivity.isReachable { return "Now" }
        guard let date = model.lastWatchContact else { return "Not yet" }
        return date.formatted(.relative(presentation: .named))
    }
}
