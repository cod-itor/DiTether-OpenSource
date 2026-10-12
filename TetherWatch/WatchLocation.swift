import Foundation
import CoreLocation

/// Location on the watch. GPS works without internet.
///
/// Two modes:
///  * One-shot readings (`fix()`), used while the iPhone is nearby. The watch borrows the iPhone's
///    location then, so this is cheap, and it means we already know where the phone is when the link drops.
///  * Continuous tracking (`startTracking()`), used only while apart, to measure how far you walk away.
@MainActor
final class WatchLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var lastFix: GeoFix?
    private(set) var isTracking = false
    private var waiters: [UUID: CheckedContinuation<GeoFix?, Never>] = [:]

    /// Called for every new reading, from either mode.
    var onUpdate: ((GeoFix) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
    }

    func requestAuthorizationIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Asks for a fresh reading. Gives up after `timeout` and returns the newest reading we already had (or nil).
    func fix(timeout: TimeInterval = 15) async -> GeoFix? {
        guard isAuthorized else { return lastFix }
        let token = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<GeoFix?, Never>) in
            waiters[token] = continuation
            if !isTracking {
                manager.requestLocation()
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.expire(token)
            }
        }
    }

    /// Precise, continuous updates. Only while apart, because GPS costs battery.
    /// Needs the "location" background mode (declared in project.yml) to keep running with the wrist down.
    func startTracking(precise: Bool) {
        guard isAuthorized, !isTracking else { return }
        isTracking = true
        manager.desiredAccuracy = precise ? kCLLocationAccuracyBest : kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = precise ? 5 : 15
        // Setting this without the "location" background mode is a hard crash, so check first.
        if Self.hasLocationBackgroundMode {
            manager.allowsBackgroundLocationUpdates = true
        }
        manager.startUpdatingLocation()
    }

    /// Switches precision while tracking, for example when the hot/cold guide starts.
    func setPrecise(_ precise: Bool) {
        guard isTracking else { return }
        manager.desiredAccuracy = precise ? kCLLocationAccuracyBest : kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = precise ? 5 : 15
    }

    /// Stopping and starting again makes Core Location deliver a fresh reading right away,
    /// even when the distance filter would otherwise stay silent because you are standing still.
    func refreshTracking() {
        guard isTracking else { return }
        manager.stopUpdatingLocation()
        manager.startUpdatingLocation()
    }

    private static let hasLocationBackgroundMode: Bool = {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return modes.contains("location")
    }()

    func stopTracking() {
        guard isTracking else { return }
        isTracking = false
        manager.stopUpdatingLocation()
        if Self.hasLocationBackgroundMode {
            manager.allowsBackgroundLocationUpdates = false
        }
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = kCLDistanceFilterNone
    }

    private func expire(_ token: UUID) {
        waiters.removeValue(forKey: token)?.resume(returning: lastFix)
    }

    private func deliver(_ fix: GeoFix?) {
        if let fix {
            lastFix = fix
            onUpdate?(fix)
        }
        let pending = waiters
        waiters = [:]
        for (_, continuation) in pending {
            continuation.resume(returning: fix ?? lastFix)
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        let fix = GeoFix(latitude: location.coordinate.latitude,
                         longitude: location.coordinate.longitude,
                         accuracy: location.horizontalAccuracy,
                         timestamp: location.timestamp)
        Task { @MainActor in
            self.deliver(fix)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.deliver(nil)
        }
    }
}
