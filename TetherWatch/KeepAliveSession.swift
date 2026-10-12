import Foundation
import HealthKit

/// Keeps the watch app running in the background so it can notice the link dropping.
///
/// watchOS normally suspends apps within seconds of the wrist going down. A workout session is the
/// one sanctioned way to stay alive for hours. Tether runs it the way Apple documents it, a session
/// plus its live workout builder, but gives the builder no data source (nothing is measured) and
/// discards the workout when it ends, so nothing is ever saved to Health.
@MainActor
final class KeepAliveSession: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    /// Every state change and failure, for the connection log.
    var onLog: ((String) -> Void)?
    /// The session ended without Tether asking for it (the app cannot restart it from the background).
    var onUnexpectedEnd: (() -> Void)?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var isStarting = false

    func start() async {
        guard session == nil, !isStarting else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            lastError = "Health is not available on this watch."
            return
        }
        isStarting = true
        defer { isStarting = false }

        do {
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
        } catch {
            fail("Allow Workout access so DiTether can keep running.")
            return
        }

        // If watchOS kept an earlier session alive (for example after a crash or relaunch),
        // take it over instead of starting a second one. Apple's forums report that a duplicate
        // session can break WatchConnectivity reachability.
        if await recover() { return }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown

        do {
            let newSession = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let newBuilder = newSession.associatedWorkoutBuilder()
            newSession.delegate = self
            session = newSession
            builder = newBuilder
            let start = Date()
            newSession.startActivity(with: start)
            try await newBuilder.beginCollection(at: start)
            isRunning = true
            lastError = nil
            onLog?("Background session started")
        } catch {
            // Starting is only allowed while Tether is on screen; from the background this fails.
            tearDown()
            fail("Could not start the background session. Open DiTether on your watch. (\(error.localizedDescription))")
        }
    }

    /// Adopts a session watchOS kept running for us. Called at start, and by the app delegate when
    /// watchOS relaunches Tether to recover an active workout.
    @discardableResult
    func recover() async -> Bool {
        guard session == nil,
              let existing = try? await store.recoverActiveWorkoutSession() else { return false }
        existing.delegate = self
        session = existing
        builder = existing.associatedWorkoutBuilder()
        if existing.state == .paused {
            existing.resume()
        }
        isRunning = true
        lastError = nil
        onLog?("Background session recovered")
        return true
    }

    /// Ends the session on purpose. The session is forgotten first, so its "ended" callback is
    /// ignored by `stateChanged` and never reported as a problem.
    func stop() {
        guard let current = session else { return }
        let currentBuilder = builder
        tearDown()
        current.end()
        // Nothing is ever saved to Health: close the builder and throw the workout away.
        Task {
            try? await currentBuilder?.endCollection(at: Date())
            currentBuilder?.discardWorkout()
        }
        onLog?("Background session stopped (protection off)")
    }

    private func tearDown() {
        session = nil
        builder = nil
        isRunning = false
    }

    private func fail(_ message: String) {
        lastError = message
        onLog?("Problem: \(message)")
    }

    // MARK: Delegate events (hopped to the main actor)

    fileprivate func stateChanged(_ id: ObjectIdentifier, to state: HKWorkoutSessionState) {
        guard let current = session, ObjectIdentifier(current) == id else { return }
        switch state {
        case .paused:
            // Something paused the session (for example a system gesture). A paused session still
            // counts as a workout, but resume right away so Tether is clearly running.
            onLog?("Background session paused, resuming")
            current.resume()
        case .stopped:
            // A stopped session must be ended to release it; Tether did not ask for this.
            onLog?("Background session was stopped by the system")
            current.end()
        case .ended:
            let currentBuilder = builder
            tearDown()
            Task { currentBuilder?.discardWorkout() }
            fail("The background session ended. Open DiTether on your watch to turn protection back on.")
            onUnexpectedEnd?()
        case .running:
            isRunning = true
        default:
            break
        }
    }

    fileprivate func failed(_ id: ObjectIdentifier, error: Error) {
        guard let current = session, ObjectIdentifier(current) == id else { return }
        fail("Background session failed: \(error.localizedDescription)")
    }
}

// MARK: - HKWorkoutSessionDelegate

extension KeepAliveSession: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        let id = ObjectIdentifier(workoutSession)
        Task { @MainActor in
            self.stateChanged(id, to: toState)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let id = ObjectIdentifier(workoutSession)
        Task { @MainActor in
            self.failed(id, error: error)
        }
    }
}
