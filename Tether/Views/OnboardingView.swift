import SwiftUI

/// First-run intro: what Tether does, how it alerts, the one rule, then a live setup checklist.
struct OnboardingView: View {
    @EnvironmentObject private var model: PhoneModel
    let onFinish: () -> Void

    @State private var page = 0
    private let lastPage = 4

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    WelcomePage().tag(0)
                    HowItWorksPage().tag(1)
                    KeepOpenPage().tag(2)
                    SpeedPage().tag(3)
                    SetupPage().tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button {
                    if page < lastPage {
                        withAnimation { page += 1 }
                    } else {
                        onFinish()
                    }
                } label: {
                    Text(buttonTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .toolbar {
                if page < lastPage {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Skip") { withAnimation { page = lastPage } }
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var buttonTitle: String {
        guard page == lastPage else { return "Continue" }
        return model.isSetupComplete ? "Done" : "Finish later"
    }
}

// MARK: - Pages

private struct PageLayout<Content: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: symbol)
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 112, height: 112)
                    .background(color.opacity(0.15), in: Circle())
                    .padding(.top, 32)
                VStack(spacing: 8) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                content
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 56)   // room for the page dots
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct WelcomePage: View {
    var body: some View {
        PageLayout(symbol: "iphone.radiowaves.left.and.right",
                   color: .green,
                   title: "Never leave your iPhone behind",
                   subtitle: "Your Apple Watch taps you the moment your iPhone gets left behind.") {
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(symbol: "wifi.slash", color: .blue,
                           title: "Works without internet",
                           detail: "Your watch and iPhone talk to each other directly.")
                FeatureRow(symbol: "lock.fill", color: .gray,
                           title: "Private",
                           detail: "No account and no server. Everything stays on your devices.")
            }
            .padding(.top, 8)
        }
    }
}

private struct HowItWorksPage: View {
    var body: some View {
        PageLayout(symbol: "applewatch.radiowaves.left.and.right",
                   color: .blue,
                   title: "How it works",
                   subtitle: "Your watch does all the checking. This app is just for settings and history.") {
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(symbol: "hand.tap.fill", color: .orange,
                           title: "First, a gentle tap",
                           detail: "A few seconds after your iPhone drops out of range.")
                FeatureRow(symbol: "bell.and.waves.left.and.right.fill", color: .red,
                           title: "Then a loud alert",
                           detail: "If it stays out of range, or sooner if you walk away from where you left it.")
                FeatureRow(symbol: "house.fill", color: .green,
                           title: "Quiet where it's safe",
                           detail: "At home, at work, or during quiet hours you choose.")
            }
            .padding(.top, 8)
        }
    }
}

private struct KeepOpenPage: View {
    var body: some View {
        PageLayout(symbol: "hand.raised.fill",
                   color: .orange,
                   title: "One important rule",
                   subtitle: "Keep DiTether open in the background.") {
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(symbol: "rectangle.stack.fill", color: .orange,
                           title: "Don't swipe it away",
                           detail: "If you close DiTether in the app switcher, your watch can't reach it and thinks your iPhone was left behind.")
                FeatureRow(symbol: "arrow.clockwise", color: .blue,
                           title: "After a restart, open it once",
                           detail: "When your iPhone restarts, open DiTether once so your watch can find it again.")
                FeatureRow(symbol: "moon.fill", color: .indigo,
                           title: "Allow it in Focus",
                           detail: "Add DiTether to the allowed apps in your Focus modes, or alerts will be silenced.")
            }
            .padding(.top, 8)
        }
    }
}

private struct SpeedPage: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        PageLayout(symbol: "speedometer",
                   color: .blue,
                   title: "Speed or battery?",
                   subtitle: "Choose how quickly DiTether notices your iPhone is gone. You can change this any time in Settings.") {
            VStack(spacing: 14) {
                ForEach(DetectionMode.allCases) { mode in
                    DetectionModeRow(mode: mode, isSelected: model.settings.settings.detectionMode == mode) {
                        model.edit { $0.detectionMode = mode }
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.top, 8)
        }
    }
}

private struct SetupPage: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        PageLayout(symbol: "checklist",
                   color: .green,
                   title: "Let's set up",
                   subtitle: "These tick themselves off as you go.") {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(model.setupSteps) { step in
                    HStack {
                        SetupStepLink(step: step)
                            .buttonStyle(.plain)
                        if !step.isDone {
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                if let message = model.launcher.message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Text("Anything left shows on the Status screen until it's done.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .padding(.top, 8)
        }
    }
}
