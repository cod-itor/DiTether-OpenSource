import Foundation
import CoreLocation

/// Two jobs:
///  * one-shot readings for "Add current location as a safe place";
///  * while protection is on, sharing the iPhone's position with the watch (in every ping reply), so the
///    watch can measure how far apart the two are even when the link to the iPhone still looks connected.
@MainActor
final class PhoneLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined
    private(set) var isSharing = false
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<GeoFix?, Never>?
    private var backgroundActivity: CLBackgroundActivitySession?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        status = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    var isDenied: Bool {
        status == .denied || status == .restricted
    }

    /// The last reading iOS already has, without asking for a new one (free: no GPS, no indicator).
    var lastKnown: GeoFix? {
        guard isAuthorized, let location = manager.location, location.horizontalAccuracy >= 0 else { return nil }
        return GeoFix(latitude: location.coordinate.latitude,
                      longitude: location.coordinate.longitude,
                      accuracy: location.horizontalAccuracy,
                      timestamp: location.timestamp)
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// "Always" lets the iPhone keep sharing its position after it is locked or relaunched in the
    /// background. "While using" also works, but iOS shows a location indicator while sharing.
    func requestSharingAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    /// Continuous, battery-friendly updates: only a new reading after moving a few metres, and none while the
    /// iPhone lies still (which is exactly when it has been left behind).
    func startSharing(distanceFilter: Double) {
        guard isAuthorized else { return }
        if isSharing {
            manager.distanceFilter = distanceFilter   // mode changed while sharing
            return
        }
        isSharing = true
        // Only "While using" needs a background session, and that session always shows the location
        // indicator in the Dynamic Island. With "Always" no session (and no indicator) is needed.
        if status == .authorizedWhenInUse {
            backgroundActivity = CLBackgroundActivitySession()
        }
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = distanceFilter
        manager.pausesLocationUpdatesAutomatically = false
        if Self.hasLocationBackgroundMode {
            manager.allowsBackgroundLocationUpdates = true
        }
        manager.showsBackgroundLocationIndicator = false
        manager.startUpdatingLocation()
    }

    /// Setting `allowsBackgroundLocationUpdates` without this mode is a hard crash, so check first.
    private static let hasLocationBackgroundMode: Bool = {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return modes.contains("location")
    }()

    func stopSharing() {
        guard isSharing else { return }
        isSharing = false
        manager.stopUpdatingLocation()
        if Self.hasLocationBackgroundMode {
            manager.allowsBackgroundLocationUpdates = false
        }
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        backgroundActivity?.invalidate()
        backgroundActivity = nil
        SharedPhoneFix.shared.value = nil
    }

    /// One fresh reading, or after `timeout` the latest shared one (or nil), so callers never hang.
    /// While sharing, continuous updates are already running and may stay silent while the iPhone
    /// lies still, which is why the timeout matters.
    func current(timeout: TimeInterval = 15) async -> GeoFix? {
        guard isAuthorized else { return nil }
        finish(nil)   // never leave an earlier request hanging
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(SharedPhoneFix.shared.value)
        }
        defer { timeoutTask.cancel() }
        return await withCheckedContinuation { (pending: CheckedContinuation<GeoFix?, Never>) in
            continuation = pending
            manager.requestLocation()
        }
    }

    private func finish(_ fix: GeoFix?) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: fix)
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let newStatus = manager.authorizationStatus
        Task { @MainActor in
            self.status = newStatus
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        let fix = GeoFix(latitude: location.coordinate.latitude,
                         longitude: location.coordinate.longitude,
                         accuracy: location.horizontalAccuracy,
                         timestamp: location.timestamp)
        Task { @MainActor in
            if self.isSharing {
                SharedPhoneFix.shared.value = fix
            }
            self.finish(fix)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(nil)
        }
    }
}
