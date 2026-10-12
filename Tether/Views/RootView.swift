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
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .fullScreenCover(isPresented: Binding(get: { !hasOnboarded }, set: { hasOnboarded = !$0 })) {
            OnboardingView {
                hasOnboarded = true
                model.requestNotificationPermission()
            }
                .environmentObject(model)
        }
    }
}
