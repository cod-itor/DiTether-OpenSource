import HealthKit
import UIKit

/// Opens the right place for a setup step: DiTether on the watch, or the iPhone's Watch app.
@MainActor
final class WatchLauncher: ObservableObject {
    /// A short note shown when opening did not work, so the user knows what to do by hand.
    @Published private(set) var message: String?

    private let store = HKHealthStore()

    /// Launches DiTether on the watch. This is Apple's one official way for an iPhone app to open its
    /// watch app; the watch app also restarts its background session when opened like this.
    func openOnWatch() {
        message = nil
        guard HKHealthStore.isHealthDataAvailable() else {
            message = "Open DiTether from the app list on your watch."
            return
        }
        Task {
            // Launching needs Workout access on the iPhone too (nothing is read or saved).
            _ = try? await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .other
            configuration.locationType = .unknown
            let opened = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                store.startWatchApp(with: configuration) { success, _ in
                    continuation.resume(returning: success)
                }
            }
            message = opened ? nil : "Couldn't open it. Wake your watch and open DiTether from its app list."
        }
    }

    /// Opens the iPhone's Watch app, where watches are paired and watch apps installed.
    func openWatchAppOnPhone() {
        message = nil
        let candidates = ["itms-watchs://", "itms-watch://"].compactMap(URL.init(string:))
        open(candidates)
    }

    private func open(_ urls: [URL]) {
        guard let url = urls.first else {
            message = "Open the Watch app on this iPhone."
            return
        }
        UIApplication.shared.open(url) { [weak self] success in
            guard !success else { return }
            Task { @MainActor in self?.open(Array(urls.dropFirst())) }
        }
    }
}
