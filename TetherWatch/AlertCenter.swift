import Foundation
import UserNotifications
import WatchKit

/// Everything that buzzes or posts a notification.
///
/// Two layers on purpose:
///  1. Live haptics, played by the running app (immediate, strongest feel).
///  2. Local notifications scheduled in advance. The system delivers these by itself, so they still
///     fire if watchOS suspends the app at the worst moment. That includes the "watchdog".
@MainActor
final class AlertCenter: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let watchdogID = "tether.watchdog"
    private let softID = "tether.soft"
    private let strongPrefix = "tether.strong."
    private var strongIDs: [String] = []
    private var pulseTask: Task<Void, Never>?
    private let testID = "tether.test"
    private var testTask: Task<Void, Never>?
    private let ringID = "ditether.ringWatch"
    private var ringTask: Task<Void, Never>?

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Clears anything left over from a previous run so stale alarms can never fire.
    func resetPending() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        strongIDs = []
    }

    // MARK: Tier 1

    func soft(style: AlertStyle) {
        switch style {
        case .light: WKInterfaceDevice.current().play(.click)
        case .standard: WKInterfaceDevice.current().play(.notification)
        case .persistent: pulse(style: .persistent)
        }
        post(id: softID, title: "iPhone out of range", body: "Check you have it.")
    }

    // MARK: Tier 2

    func strong(repeatMinutes: Int, style: AlertStyle) {
        pulse(style: style)
        let firstID = strongPrefix + "0"
        post(id: firstID, title: "iPhone left behind?", body: "Go back for it.")
        strongIDs = [firstID]

        // Safety net: these fire by themselves every few seconds, even if the app is asleep by then.
        // (iOS keeps at most 64 pending notifications, so the count is capped.)
        let interval = style.repeatNotificationInterval
        let count = min(max(Int(Double(max(repeatMinutes, 1) * 60) / interval), 1), 40)
        for index in 1...count {
            let id = strongPrefix + String(index)
            post(id: id, title: "iPhone left behind?", body: "Still out of range.", after: Double(index) * interval)
            strongIDs.append(id)
        }
    }

    /// One buzz (Light) or a short burst of three different taps. Repeated while the loud alert is on.
    func pulse(style: AlertStyle) {
        pulseTask?.cancel()
        if style == .light {
            WKInterfaceDevice.current().play(.notification)
            return
        }
        pulseTask = Task { await Self.burst() }
    }

    private static func burst() async {
        let device = WKInterfaceDevice.current()
        device.play(.notification)
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        device.play(.retry)
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        device.play(.failure)
    }

    // MARK: Test

    /// Plays a sample of a real alert: the same haptics and a notification, clearly marked as a test.
    /// Uses its own notification id, so it can never cancel or be mistaken for a real alert.
    func test(_ level: TestAlertLevel, style: AlertStyle) {
        stopTest()
        switch level {
        case .firstReminder:
            switch style {
            case .light: WKInterfaceDevice.current().play(.click)
            case .standard: WKInterfaceDevice.current().play(.notification)
            case .persistent: testTask = Task { await Self.burst() }
            }
            post(id: testID, title: "iPhone out of range", body: "Test")
        case .loud:
            post(id: testID, title: "iPhone left behind?", body: "Test")
            // A real loud alert repeats every few seconds; three bursts give the feel of it.
            testTask = Task {
                for round in 0..<3 {
                    if round > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(style.pulseInterval / 2 * 1_000_000_000))
                    }
                    if Task.isCancelled { return }
                    if style == .light {
                        WKInterfaceDevice.current().play(.notification)
                    } else {
                        await Self.burst()
                    }
                }
            }
        }
    }

    func stopTest() {
        testTask?.cancel()
        testTask = nil
        center.removeDeliveredNotifications(withIdentifiers: [testID])
    }

    // MARK: Stopping

    func stopAll() {
        pulseTask?.cancel()
        let ids = strongIDs + [softID]
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        strongIDs = []
    }

    func reconnected(wasAlerting: Bool) {
        stopAll()
        if wasAlerting {
            WKInterfaceDevice.current().play(.success)
        }
    }

    // MARK: Find my watch

    /// Buzzes and beeps for 20 seconds (asked for from the iPhone), so the watch can be found.
    func ringWatch() {
        stopRingingWatch()
        post(id: ringID, title: "Here's your watch", body: "Your iPhone is looking for it.")
        ringTask = Task {
            for _ in 0..<10 {
                if Task.isCancelled { return }
                await Self.burst()
                try? await Task.sleep(nanoseconds: 1_300_000_000)
            }
        }
    }

    func stopRingingWatch() {
        ringTask?.cancel()
        ringTask = nil
        center.removeDeliveredNotifications(withIdentifiers: [ringID])
    }

    // MARK: Protection interrupted

    /// The background session ended on its own, so Tether can no longer watch with the wrist down.
    func protectionInterrupted() {
        cancelWatchdog()   // it would only add a confusing second message
        post(id: "tether.interrupted",
             title: "DiTether stopped watching",
             body: "Open DiTether to turn it back on.")
    }

    // MARK: Watchdog (dead-man's switch)

    /// Promises the system a notification that only a healthy, running Tether keeps pushing back.
    /// If the app is ever suspended or killed, nobody cancels it and it fires on its own.
    func armWatchdog(after seconds: TimeInterval) {
        center.removePendingNotificationRequests(withIdentifiers: [watchdogID])
        post(id: watchdogID,
             title: "Is your iPhone with you?",
             body: "DiTether lost contact.",
             after: max(seconds, 5))
    }

    func cancelWatchdog() {
        center.removePendingNotificationRequests(withIdentifiers: [watchdogID])
        center.removeDeliveredNotifications(withIdentifiers: [watchdogID])
    }

    // MARK: Helpers

    private func post(id: String, title: String, body: String, after delay: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "tether"
        var trigger: UNNotificationTrigger?
        if let delay {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(delay, 1), repeats: false)
        }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    // Show banners and play sounds even while Tether is the frontmost app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
