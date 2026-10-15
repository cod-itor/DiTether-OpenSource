import SwiftUI

/// Step-by-step DiTAG setup: what it does, turning it on, freeing it from other apps, bringing it
/// close, connecting it live, and naming it. The connect step runs the real setup, so finishing the
/// tutorial means the DiTAG is ready.
struct DiTagSetupGuide: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case intro, powerOn, freeUp, bringClose, connect, done
    }

    @State private var step: Step
    @State private var goingForward = true
    @State private var addedID: UUID?
    @State private var name = ""

    private let startedAtIntro: Bool

    private var manager: DiTagManager { model.diTag }

    /// `startAtIntro` false skips the "what is a DiTAG" page for people adding another one.
    init(startAtIntro: Bool) {
        _step = State(initialValue: startAtIntro ? .intro : .powerOn)
        startedAtIntro = startAtIntro
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if step != .done {
                    ProgressDots(current: step.rawValue, count: Step.connect.rawValue + 1)
                        .padding(.top, 4)
                }
                ScrollView {
                    page
                        .id(step)
                        .transition(.asymmetric(
                            insertion: .move(edge: goingForward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: goingForward ? .leading : .trailing).combined(with: .opacity)))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                }
                .scrollBounceBehavior(.basedOnSize)
                bottomBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .padding(.top, 8)
            }
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if step != .done {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Close")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(manager.setupPhase != nil)
        .onChange(of: manager.lastAddedID) { _, id in
            guard let id, step == .connect else { return }
            addedID = id
            name = manager.settings.tag(id)?.displayName ?? "Keys"
            go(to: .done)
        }
        .onDisappear {
            if manager.setupPhase != nil { manager.cancelSetup() }
        }
    }

    // MARK: Pages

    @ViewBuilder
    private var page: some View {
        switch step {
        case .intro:
            GuidePage(title: "Never leave your keys behind",
                      text: "Attach a DiTAG to your keys, bag or wallet. Your iPhone keeps an eye on it over Bluetooth.") {
                IntroArt()
            } content: {
                VStack(alignment: .leading, spacing: 16) {
                    GuidePoint(symbol: "bell.badge.fill", color: .orange,
                               title: "Alerts the moment it's left",
                               text: "Your iPhone vibrates, and your watch too when the iPhone is locked.")
                    GuidePoint(symbol: "speaker.wave.3.fill", color: .blue,
                               title: "Play a sound to find it",
                               text: "Make the DiTAG beep from your iPhone or your watch.")
                    GuidePoint(symbol: "iphone.radiowaves.left.and.right", color: Theme.brand,
                               title: "Double-press to find your iPhone",
                               text: "Your iPhone rings at full volume, even on silent.")
                }
            }

        case .powerOn:
            GuidePage(title: "Turn it on",
                      text: "Hold the button on the DiTAG for 3 to 5 seconds, until you hear two beeps.") {
                PowerOnArt()
            } content: {
                VStack(alignment: .leading, spacing: 16) {
                    GuidePoint(symbol: "2.circle.fill", color: .green,
                               title: "Two beeps: it's on",
                               text: "Let go as soon as you hear them.")
                    GuidePoint(symbol: "1.circle.fill", color: .orange,
                               title: "One long beep: it switched off",
                               text: "It was already on. Hold the button again to turn it back on.")
                    GuidePoint(symbol: "battery.25", color: .gray,
                               title: "No beep at all?",
                               text: "Check the CR2032 coin battery under the cover.")
                }
            }

        case .freeUp:
            GuidePage(title: "Free it from other apps",
                      text: "A DiTAG talks to one app at a time. If another app is connected to it, DiTether can't find it.") {
                FreeUpArt()
            } content: {
                VStack(alignment: .leading, spacing: 16) {
                    GuidePoint(symbol: "xmark.app.fill", color: .red,
                               title: "Close iSearching",
                               text: "Swipe it away in the app switcher, or remove the tag in it.")
                    GuidePoint(symbol: "antenna.radiowaves.left.and.right.slash", color: .orange,
                               title: "Disconnect in nRF Connect",
                               text: "If you used it for testing, tap Disconnect.")
                }
            }

        case .bringClose:
            GuidePage(title: "Bring it close",
                      text: "Hold the DiTAG right next to your iPhone. DiTether picks the closest one it finds.") {
                CloseArt()
            } content: {
                VStack(alignment: .leading, spacing: 16) {
                    GuidePoint(symbol: "hand.raised.fill", color: Theme.brand,
                               title: "One at a time",
                               text: "Keep other new DiTAGs away or switched off while adding this one.")
                    GuidePoint(symbol: "checkmark.circle.fill", color: .green,
                               title: "Already added ones are fine",
                               text: "DiTAGs you set up before are skipped.")
                }
            }

        case .connect:
            connectPage

        case .done:
            donePage
        }
    }

    @ViewBuilder
    private var connectPage: some View {
        let phase = manager.setupPhase
        VStack(spacing: 24) {
            ZStack {
                if phase == .confirming {
                    PulsingShield(symbol: "hand.tap.fill", color: Theme.brand, isLive: true)
                        .scaleEffect(1.3)
                } else {
                    RadarArt(isScanning: phase != nil)
                }
            }
            .frame(height: 200)

            VStack(spacing: 8) {
                Text(connectTitle(phase))
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(connectText(phase))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if phase == nil, let message = manager.setupMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if manager.bluetooth == .unauthorized {
                VStack(spacing: 10) {
                    Label("Bluetooth is not allowed for DiTether.", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            } else if manager.bluetooth == .off {
                Label("Turn on Bluetooth in Control Center first.", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func connectTitle(_ phase: DiTagManager.SetupPhase?) -> String {
        switch phase {
        case .scanning: return "Looking for your DiTAG…"
        case .connecting: return "Connecting…"
        case .confirming: return "Press the DiTAG button once"
        case nil: return manager.setupMessage == nil ? "Ready to connect" : "Let's try again"
        }
    }

    private func connectText(_ phase: DiTagManager.SetupPhase?) -> String {
        switch phase {
        case .scanning: return "Keep it close to your iPhone. This takes a few seconds."
        case .connecting: return "Almost there."
        case .confirming: return "It just beeped, so you know which one. A quick press confirms it's yours."
        case nil: return "Make sure it's on and next to your iPhone, then tap Find my DiTAG."
        }
    }

    private var donePage: some View {
        VStack(spacing: 24) {
            PulsingShield(symbol: "checkmark", color: .green, isLive: true)
                .scaleEffect(1.2)
                .padding(.top, 20)
                .padding(.bottom, 8)
            VStack(spacing: 8) {
                Text("Connected!")
                    .font(.largeTitle.bold())
                Text("What is it attached to?")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                TextField("Name", text: $name)
                    .font(.title3.weight(.semibold))
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .submitLabel(.done)
                NameSuggestions(selection: name) { name = $0 }
            }
            VStack(alignment: .leading, spacing: 16) {
                GuidePoint(symbol: "hand.tap.fill", color: Theme.brand,
                           title: "Double-press to find your iPhone",
                           text: "Press the DiTAG button twice quickly.")
                GuidePoint(symbol: "moon.zzz.fill", color: .indigo,
                           title: "Leaving it on purpose?",
                           text: "Snooze it on its screen, or tap Left it on purpose on the alert.")
                GuidePoint(symbol: "rectangle.stack.fill", color: .orange,
                           title: "Keep DiTether in the background",
                           text: "Don't swipe it away, or the DiTAG alerts pause.")
            }
            .card()
        }
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        switch step {
        case .connect:
            VStack(spacing: 10) {
                if manager.setupPhase == nil {
                    Button {
                        model.requestNotificationPermission()
                        manager.startSetup()
                    } label: {
                        Label(manager.setupMessage == nil ? "Find my DiTAG" : "Try again",
                              systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(manager.bluetooth == .unauthorized || !manager.canAddMore)
                    backButton
                } else {
                    Button("Cancel") { manager.cancelSetup() }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
        case .done:
            Button("Done") {
                if let addedID { manager.rename(addedID, to: name) }
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle(color: .green))
        default:
            VStack(spacing: 10) {
                Button("Continue") {
                    if let next = Step(rawValue: step.rawValue + 1) { go(to: next) }
                }
                .buttonStyle(PrimaryButtonStyle())
                if step != .intro && !(step == .powerOn && !startedAtIntro) {
                    backButton
                }
            }
        }
    }

    private var backButton: some View {
        Button("Back") {
            if let previous = Step(rawValue: step.rawValue - 1) { go(to: previous, forward: false) }
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func go(to next: Step, forward: Bool = true) {
        goingForward = forward
        withAnimation(.snappy) { step = next }
    }
}

// MARK: - Building blocks

private struct GuidePage<Art: View, Content: View>: View {
    let title: String
    let text: String
    @ViewBuilder let art: Art
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 24) {
            art
                .frame(height: 200)
            VStack(spacing: 8) {
                Text(title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
                .card()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct GuidePoint: View {
    let symbol: String
    let color: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconBadge(symbol: symbol, color: color, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ProgressDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.secondary.opacity(0.2)))
                    .frame(width: index == current ? 28 : 8, height: 8)
            }
        }
        .animation(.snappy, value: current)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

// MARK: - Illustrations (SF Symbols, animated)

private struct IntroArt: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.brand.opacity(0.12))
                .frame(width: 190, height: 190)
            Image(systemName: "key.fill")
                .font(.system(size: 78, weight: .semibold))
                .foregroundStyle(Theme.brandGradient)
                .rotationEffect(.degrees(-35))
                .offset(x: -14, y: 8)
            IconBadge(symbol: "tag.fill", color: Theme.brand, size: 64, filled: true)
                .offset(x: 52, y: -46)
                .shadow(color: Theme.brand.opacity(0.4), radius: 10, y: 4)
            Image(systemName: "wave.3.right")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .symbolEffect(.variableColor.iterative.reversing)
                .offset(x: 98, y: -46)
        }
    }
}

private struct PowerOnArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(0.12))
                .frame(width: 190, height: 190)
            IconBadge(symbol: "tag.fill", color: Theme.brand, size: 96, filled: true)
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 50))
                .foregroundStyle(.primary.opacity(0.85))
                .offset(x: 38, y: pressed ? 44 : 60)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.green)
                .symbolEffect(.variableColor.iterative, isActive: pressed)
                .offset(x: -74, y: -54)
        }
        .onAppear {
            guard !reduceMotion else { pressed = true; return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pressed = true }
        }
    }
}

private struct FreeUpArt: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.orange.opacity(0.12))
                .frame(width: 190, height: 190)
            IconBadge(symbol: "tag.fill", color: Theme.brand, size: 80, filled: true)
            IconBadge(symbol: "app.connected.to.app.below.fill", color: .gray, size: 52, filled: true)
                .offset(x: -66, y: -54)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, .red)
                        .offset(x: -50, y: -66)
                }
            IconBadge(symbol: "iphone", color: Theme.brandDeep, size: 52, filled: true)
                .offset(x: 66, y: 54)
        }
    }
}

private struct CloseArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var near = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.brand.opacity(0.12))
                .frame(width: 190, height: 190)
            Image(systemName: "iphone")
                .font(.system(size: 96, weight: .light))
                .foregroundStyle(Theme.brandDeep)
                .offset(x: -26)
            IconBadge(symbol: "tag.fill", color: Theme.brand, size: 56, filled: true)
                .offset(x: near ? 30 : 74, y: 26)
                .shadow(color: Theme.brand.opacity(0.4), radius: 8, y: 3)
        }
        .onAppear {
            guard !reduceMotion else { near = true; return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { near = true }
        }
    }
}

/// Rings sweeping outwards from the iPhone while it scans.
private struct RadarArt: View {
    let isScanning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .stroke(Theme.brand.opacity(isScanning ? 0.5 : 0.15), lineWidth: 2)
                    .scaleEffect(isScanning && !reduceMotion ? (sweep ? 1.0 : 0.3) : 0.45 + Double(ring) * 0.25)
                    .opacity(isScanning && !reduceMotion ? (sweep ? 0 : 1) : 1)
                    .animation(isScanning && !reduceMotion
                               ? .easeOut(duration: 2.1).repeatForever(autoreverses: false).delay(Double(ring) * 0.7)
                               : .default,
                               value: sweep)
            }
            .frame(width: 200, height: 200)
            IconBadge(symbol: "iphone.radiowaves.left.and.right", color: Theme.brand, size: 76, filled: true)
                .shadow(color: Theme.brand.opacity(0.4), radius: 10, y: 4)
        }
        .onAppear { sweep = true }
    }
}
