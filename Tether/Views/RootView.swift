import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: PhoneModel
    @AppStorage(RootView.onboardedKey) private var hasOnboarded = false

    static let onboardedKey = "tether.onboarded"

    var body: some View {
        TabView {
            StatusView()
                .tabItem { Label("Status", systemImage: "applewatch") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            DiTagView()
                .tabItem { Label("DiTAG", systemImage: "tag") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        // Ringing (or the left-behind vibration) while DiTether is open: one tap stops it.
        .alert(ringTitle, isPresented: Binding(get: { model.ringer.isRinging },
                                               set: { if !$0 { model.ringer.stop() } })) {
            Button("Found it") { model.ringer.stop() }
        }
        .fullScreenCover(isPresented: Binding(get: { !hasOnboarded }, set: { hasOnboarded = !$0 })) {
            OnboardingView {
                hasOnboarded = true
                model.requestNotificationPermission()
            }
                .environmentObject(model)
        }
    }

    private var ringTitle: String {
        switch model.ringer.reason {
        case .leftBehind: return model.diTag.alarmTitle
        case .tag: return "Your DiTAG is calling"
        default: return "Here's your iPhone"
        }
    }
}
