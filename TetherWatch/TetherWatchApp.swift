import HealthKit
import SwiftUI
import WatchKit

/// Owning the model here (instead of in a view) means protection starts even when watchOS launches
/// the app in the background, before any screen exists.
@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    let model = WatchModel()

    func applicationDidBecomeActive() {
        model.appBecameActive()
    }

    /// The iPhone opened DiTether (a setup step or "Open on watch"). Being brought to the front is
    /// the moment a background session may start, so restart protection if it had stopped.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        model.appBecameActive()
    }

    /// watchOS relaunched Tether after it quit or crashed while its workout session was active.
    func handleActiveWorkoutRecovery() {
        model.recoverActiveSession()
    }
}

@main
struct TetherWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(delegate.model)
        }
    }
}
