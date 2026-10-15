import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: PhoneModel
    @AppStorage(RootView.onboardedKey) private var hasOnboarded = false
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @State private var tab = Tab.home

    static let onboardedKey = "tether.onboarded"

    enum Tab: Hashable {
        case home, devices, camera, history, settings
    }

    var body: some View {
        TabView(selection: $tab) {
            HomeView { tab = .devices }
                .tabItem { Label("Home", systemImage: "shield.lefthalf.filled") }
                .tag(Tab.home)
            DevicesView()
                .tabItem { Label("Devices", systemImage: "dot.radiowaves.left.and.right") }
                .tag(Tab.devices)
                .badge(model.diTag.statuses.values.filter { $0.state == .lost }.count)
            // Its own tab: the camera only runs while this tab is showing.
            CameraView()
                .tabItem { Label("Camera", systemImage: "camera.fill") }
                .tag(Tab.camera)
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Theme.brand)
        // "Open camera" from Home, Devices, Settings or the "Open DiTAG Camera" shortcut.
        .onChange(of: model.showCamera) { _, show in
            guard show else { return }
            tab = .camera
            model.showCamera = false
        }
        .onAppear {
            if model.showCamera {
                tab = .camera
                model.showCamera = false
            }
        }
        .onAppear { AppAppearance.apply(appearance) }
        .onChange(of: appearance) { _, newValue in AppAppearance.apply(newValue) }
        // Ringing (or the left-behind vibration) while DiTether is open: one tap stops it.
        .alert(ringTitle, isPresented: Binding(get: { model.ringer.isRinging },
                                               set: { if !$0 { foundIt() } })) {
            Button("Found it") { foundIt() }
        }
        .fullScreenCover(isPresented: Binding(get: { !hasOnboarded }, set: { hasOnboarded = !$0 })) {
            OnboardingView {
                hasOnboarded = true
                model.requestNotificationPermission()
            }
                .environmentObject(model)
        }
    }

    private func foundIt() {
        model.ringer.stop()
        model.diTag.stopFollowUps()
    }

    private var ringTitle: String {
        switch model.ringer.reason {
        case .leftBehind: return model.diTag.alarmTitle
        case .tag: return "Your DiTAG is calling"
        default: return "Here's your iPhone"
        }
    }
}
