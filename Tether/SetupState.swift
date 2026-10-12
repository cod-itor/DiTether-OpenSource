import Foundation

/// The one answer to "am I protected right now?", built from everything the iPhone knows.
/// Checked in order: the first thing that is wrong is the thing the user needs to fix.
enum ProtectionStatus: Equatable {
    case connecting
    case noWatch
    case watchAppMissing
    case off
    case watchNotSetUp
    case watchProblem(String)
    case waitingForWatch
    case silenced(until: Date)
    case protected
}

/// One item on the first-run checklist.
struct SetupStep: Identifiable {
    enum ID {
        case paired
        case installed
        case watchSetUp
        case phoneLocation
        case bluetooth
        case safePlace
    }

    let id: ID
    let title: String
    let detail: String
    let isDone: Bool
    let isOptional: Bool
}

extension PhoneModel {

    var protectionStatus: ProtectionStatus {
        let settings = settings.settings
        guard connectivity.hasFinishedActivating else { return .connecting }
        guard connectivity.isActivated, connectivity.isPaired else { return .noWatch }
        guard connectivity.isWatchAppInstalled else { return .watchAppMissing }
        guard settings.protectionEnabled else { return .off }
        guard let status = watchStatus, status.isSetUp else { return .watchNotSetUp }
        if !status.isProtecting {
            if let problem = status.problem { return .watchProblem(problem) }
            return .waitingForWatch
        }
        if settings.isSnoozed(), let until = settings.snoozedUntil { return .silenced(until: until) }
        return .protected
    }

    var setupSteps: [SetupStep] {
        let needsPhoneLocation = settings.settings.detectionMode.sharesPhoneLocation
        let needsBluetooth = settings.settings.bluetoothRangeEnabled
        return [
            SetupStep(id: .paired,
                      title: "Pair an Apple Watch",
                      detail: "DiTether needs an Apple Watch paired with this iPhone.",
                      isDone: connectivity.isPaired,
                      isOptional: false),
            SetupStep(id: .installed,
                      title: "Install DiTether on your watch",
                      detail: "Open the Watch app on this iPhone, scroll to Available Apps and tap Install next to DiTether.",
                      isDone: connectivity.isWatchAppInstalled,
                      isOptional: false),
            SetupStep(id: .watchSetUp,
                      title: "Open DiTether on your watch",
                      detail: "Tap Get started and allow Notifications, Location and Workout.",
                      isDone: watchStatus?.isSetUp == true,
                      isOptional: false),
            SetupStep(id: .phoneLocation,
                      title: "Allow location on this iPhone",
                      detail: location.isDenied
                        ? "Location is off for DiTether. Turn it on in Settings > Privacy & Security > Location Services > DiTether, and choose Always."
                        : "Lets your watch measure how far you are from your iPhone, so it alerts within about 30 m. Tap, then choose Allow, and Always if asked.",
                      isDone: location.isAuthorized,
                      isOptional: false),
            SetupStep(id: .bluetooth,
                      title: "Allow Bluetooth on this iPhone",
                      detail: beacon.isDenied
                        ? "Bluetooth is off for DiTether. Turn it on in Settings > Privacy & Security > Bluetooth > DiTether."
                        : "Lets your watch feel how close your iPhone is, even when Wi-Fi keeps them connected. Tap, then choose Allow.",
                      isDone: beacon.isAllowed,
                      isOptional: false),
        ].filter { ($0.id != .phoneLocation || needsPhoneLocation) && ($0.id != .bluetooth || needsBluetooth) } + [
            SetupStep(id: .safePlace,
                      title: "Add your home",
                      detail: "DiTether stays quiet at safe places, so leaving your iPhone in another room at home never buzzes you.",
                      isDone: !settings.settings.safePlaces.isEmpty,
                      isOptional: true)
        ]
    }

    /// True once every required step is done (the safe place is a suggestion, not a requirement).
    var isSetupComplete: Bool {
        setupSteps.allSatisfy { $0.isDone || $0.isOptional }
    }

    /// Most recent sign of life from the watch, from this session or saved from an earlier one.
    var lastWatchContact: Date? {
        [connectivity.lastHeardFromPeer, watchStatus?.sentAt].compactMap { $0 }.max()
    }
}
