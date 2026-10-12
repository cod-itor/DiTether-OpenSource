import WatchKit

/// Metal-detector taps: the closer you get to your iPhone, the faster the watch taps.
///
/// Runs only while something asks for guidance, and stops by itself the moment `nextInterval`
/// returns nil (found it, or guidance no longer wanted).
@MainActor
final class GuideHaptics {
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    /// Starts tapping if not already. `nextInterval` is asked before every tap.
    func start(nextInterval: @escaping @MainActor () -> TimeInterval?) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = nextInterval() else { break }
                WKInterfaceDevice.current().play(.click)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            self?.task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: Pace

    /// From GPS distance to the spot where you left the iPhone: one tap every 3 s at 200 m or more,
    /// down to about three a second within 10 m.
    static func interval(forMeters meters: Double) -> TimeInterval {
        let clamped = min(max(meters, 10), 200)
        return 0.35 + (clamped - 10) / 190 * 2.65
    }

    /// From Bluetooth signal strength (more precise up close): -95 dBm slow, -45 dBm fast.
    static func interval(forRSSI rssi: Int) -> TimeInterval {
        let level = min(max((Double(rssi) + 95) / 50, 0), 1)
        return 2.0 - level * 1.65
    }
}
