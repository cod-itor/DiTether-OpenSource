import SwiftUI
import Combine
import WidgetKit

/// Owns every watch-side service and wires them together. Created once, at launch.
@MainActor
final class WatchModel: ObservableObject {
    let settings: SettingsStore
    let events: EventStore
    let connectivity: ConnectivityService
    let location: WatchLocation
    let alerts: AlertCenter
    let keepAlive: KeepAliveSession
    let engine: ProtectionEngine
    let log: ConnectionLog
    let proximity: ProximityMonitor

    /// False until the user taps through the intro. Until then nothing asks for permissions or starts
    /// the background session, so the system prompts never appear without an explanation first.
    @Published private(set) var isSetUp = UserDefaults.standard.bool(forKey: WatchModel.setupKey)

    /// A sample alert currently shown on screen (sent from the iPhone or started from watch settings).
    @Published var testAlert: TestAlertLevel?
    /// The iPhone asked this watch to ring (Find my watch); shows a screen with Stop.
    @Published var isRingingWatch = false

    enum RingPhoneState: Equatable {
        case idle
        case sending
        case ringing
        case failed
    }

    /// Progress of "Ring iPhone", shown on the finder screen.
    @Published private(set) var ringPhoneState: RingPhoneState = .idle
    private var ringPhoneResetTask: Task<Void, Never>?
    private var ringWatchStopTask: Task<Void, Never>?

    /// The Find iPhone screen is open, so the hot/cold taps should run.
    @Published private(set) var isFinderOpen = false
    private let guide = GuideHaptics()
    private var guideStartedAt: Date?
    /// Automatic hot/cold taps stop after this long (the Find iPhone screen keeps them going).
    private static let guideTimeLimit: TimeInterval = 10 * 60

    private static let setupKey = "tether.watchSetupDone"
    private var cancellables = Set<AnyCancellable>()
    private var reportedStatus: WatchStatus?

    init() {
        let settings = SettingsStore()
        let events = EventStore(fileName: "watch-events.json", cap: 50)
        let connectivity = ConnectivityService.shared
        let location = WatchLocation()
        let alerts = AlertCenter()
        let keepAlive = KeepAliveSession()
        let log = ConnectionLog()
        let proximity = ProximityMonitor()
        let engine = ProtectionEngine(settings: settings,
                                      events: events,
                                      connectivity: connectivity,
                                      location: location,
                                      alerts: alerts,
                                      keepAlive: keepAlive,
                                      log: log,
                                      proximity: proximity)
        self.settings = settings
        self.events = events
        self.connectivity = connectivity
        self.location = location
        self.alerts = alerts
        self.keepAlive = keepAlive
        self.engine = engine
        self.log = log
        self.proximity = proximity
        proximity.onLog = { [weak log] text in log?.add(text) }

        connectivity.onSettings = { [weak self] remote in
            guard let self else { return }
            if self.settings.adopt(remote), self.isSetUp {
                self.engine.settingsChanged()
            }
        }
        connectivity.onReachability = { [weak self] reachable in
            self?.engine.reachabilityChanged(reachable)
        }
        connectivity.onTestAlert = { [weak self] level in
            self?.showTestAlert(level)
        }
        connectivity.onCommand = { [weak self] command in
            self?.handle(command)
        }
        connectivity.onActivated = { [weak self] in
            guard let self else { return }
            self.resendRecentEvents()
            if let status = self.reportedStatus {
                self.connectivity.send(status)
            }
        }
        connectivity.start()

        // Let SwiftUI redraw when any nested object changes.
        let publishers: [ObservableObjectPublisher] = [
            settings.objectWillChange,
            engine.objectWillChange,
            keepAlive.objectWillChange,
            proximity.objectWillChange,
            connectivity.objectWillChange
        ]
        for publisher in publishers {
            publisher
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        // Tell the iPhone what the watch is really doing, so its status screen can be honest.
        // Debounced so a burst of changes (session starting, settings syncing) becomes one message.
        let bluetoothLinked = settings.$settings.map(\.bluetoothRangeEnabled)
            .combineLatest(proximity.$hasConnected)
            .map { enabled, connected in enabled && connected }
        Publishers.CombineLatest4($isSetUp,
                                  settings.$settings.map(\.protectionEnabled),
                                  keepAlive.$isRunning,
                                  keepAlive.$lastError)
            .combineLatest(bluetoothLinked)
            .map { values, linked in
                let (setUp, enabled, running, problem) = values
                return WatchStatus(isSetUp: setUp,
                                   isProtecting: enabled && running,
                                   problem: enabled && !running ? problem : nil,
                                   bluetoothLinked: linked)
            }
            .removeDuplicates()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] status in self?.report(status) }
            .store(in: &cancellables)

        // Record when the background session starts, stops or fails: without it the watch sleeps
        // with the wrist down and cannot notice anything.
        keepAlive.onLog = { [weak log] text in log?.add(text) }
        // watchOS does not let Tether restart the session from the background, so say so loudly
        // instead of silently not protecting.
        keepAlive.onUnexpectedEnd = { [weak self] in
            guard let self, self.settings.settings.protectionEnabled else { return }
            self.alerts.protectionInterrupted()
        }

        // Hot/cold taps start on their own when you turn back toward your iPhone.
        engine.$isHeadingBack
            .removeDuplicates()
            .sink { [weak self] headingBack in
                if headingBack { self?.updateGuide() }
            }
            .store(in: &cancellables)

        // Keep the watch face complication in step. Only real status changes reload it, so it
        // costs nothing while nothing happens.
        engine.$phase
            .map(Self.widgetStatus)
            .removeDuplicates()
            .sink { status in
                WidgetState(status: status, updatedAt: Date()).save()
                WidgetCenter.shared.reloadAllTimelines()
            }
            .store(in: &cancellables)

        if isSetUp {
            startProtection()
        }
    }

    private static func widgetStatus(_ phase: ProtectionEngine.Phase) -> WidgetState.Status {
        switch phase {
        case .off: return .off
        case .starting, .watching: return .protected
        case .separated, .softAlerted: return .apart
        case .strongAlerted: return .alerting
        case .muted: return .quiet
        }
    }

    // MARK: - App lifecycle

    /// Opening Tether is the one moment watchOS allows starting a workout session, so restart a
    /// session that ended while the app was in the background.
    func appBecameActive() {
        guard isSetUp else { return }
        engine.restartKeepAliveIfNeeded()
        // Opening DiTether means the alert was noticed: stop the buzzing (Phone Buddy's top complaint
        // was an alarm that kept going).
        engine.acknowledgeAlerts()
    }

    // MARK: - Hot/cold guide

    func setFinderOpen(_ open: Bool) {
        isFinderOpen = open
        updateGuide()
    }

    private func updateGuide() {
        let wanted = guideWanted
        engine.setGuidance(wanted)
        if wanted {
            if !guide.isRunning { guideStartedAt = Date() }
            guide.start { [weak self] in self?.guideInterval() }
        } else {
            guide.stop()
            guideStartedAt = nil
        }
    }

    /// Guidance is for finding a phone that is not with you: the Find iPhone screen while apart
    /// or on a weak signal, or automatically while heading back.
    private var guideWanted: Bool {
        let apart: Bool
        switch engine.phase {
        case .separated, .softAlerted, .strongAlerted, .muted: apart = true
        case .off, .starting, .watching: apart = false
        }
        let searching = apart || proximity.signal == .weak
        return searching && (isFinderOpen || engine.isHeadingBack)
    }

    /// Seconds until the next tap, or nil to stop (found it, or guidance no longer wanted).
    private func guideInterval() -> TimeInterval? {
        let timedOut = !isFinderOpen && guideStartedAt.map { Date().timeIntervalSince($0) > Self.guideTimeLimit } == true
        guard guideWanted, !timedOut else {
            engine.setGuidance(false)
            guideStartedAt = nil
            return nil
        }
        // Bluetooth is more precise up close; GPS distance covers the rest. When both have a
        // reading, the faster pace wins, so the taps never suddenly slow down as Bluetooth
        // reconnects at the edge of its range.
        var candidates: [TimeInterval] = []
        if proximity.signal == .weak || proximity.signal == .strong, let rssi = proximity.rssi {
            candidates.append(GuideHaptics.interval(forRSSI: rssi))
        }
        if let meters = engine.distanceFromSpot {
            candidates.append(GuideHaptics.interval(forMeters: meters))
        }
        return candidates.min() ?? 3   // no reading yet: slow ticks so you know it is searching
    }

    // MARK: - Finding each other

    private func handle(_ command: RemoteCommand) {
        switch command {
        case .ringWatch:
            isRingingWatch = true
            alerts.ringWatch()
            ringWatchStopTask?.cancel()
            ringWatchStopTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if !Task.isCancelled { self?.stopRingingWatch() }
            }
        case .stopRingingWatch:
            stopRingingWatch()
        case .ringPhone, .stopRingingPhone:
            break   // meant for the iPhone
        }
    }

    func stopRingingWatch() {
        ringWatchStopTask?.cancel()
        isRingingWatch = false
        alerts.stopRingingWatch()
    }

    /// Makes the iPhone play a loud sound for 30 seconds. Works whenever the two can talk,
    /// including over Wi-Fi, so it helps both while the signal is weak and when you turn back.
    func ringPhone() {
        guard ringPhoneState != .sending else { return }
        ringPhoneResetTask?.cancel()
        ringPhoneState = .sending
        Task {
            let delivered = await connectivity.send(.ringPhone)
            ringPhoneState = delivered ? .ringing : .failed
            log.add(delivered ? "Asked iPhone to ring" : "Could not reach iPhone to ring it")
            ringPhoneResetTask = Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if !Task.isCancelled { ringPhoneState = .idle }
            }
        }
    }

    func stopRingingPhone() {
        ringPhoneResetTask?.cancel()
        ringPhoneState = .idle
        Task { _ = await connectivity.send(.stopRingingPhone) }
    }

    /// watchOS relaunched Tether after it quit during an active session: take that session back.
    func recoverActiveSession() {
        Task { [weak self] in
            guard let self else { return }
            await self.keepAlive.recover()
            if self.isSetUp {
                self.engine.settingsChanged()
            }
        }
    }

    // MARK: - First run

    /// Called from the intro screen. Asks for permissions with the explanation still on screen.
    func completeSetup() {
        guard !isSetUp else { return }
        isSetUp = true
        UserDefaults.standard.set(true, forKey: Self.setupKey)
        startProtection()
    }

    /// Ask for permissions one after another, then start protecting.
    private func startProtection() {
        Task { [weak self] in
            await self?.alerts.requestAuthorization()
            self?.location.requestAuthorizationIfNeeded()
            self?.engine.settingsChanged()
        }
    }

    private func report(_ status: WatchStatus) {
        var stamped = status
        stamped.sentAt = Date()
        reportedStatus = stamped
        connectivity.send(stamped)
    }

    // MARK: - Editing settings

    func edit(_ change: (inout TetherSettings) -> Void) {
        let updated = settings.edit(change)
        connectivity.push(updated)
        if isSetUp {
            engine.settingsChanged()
        }
    }

    func binding<T>(_ keyPath: WritableKeyPath<TetherSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings.settings[keyPath: keyPath] },
            set: { newValue in self.edit { $0[keyPath: keyPath] = newValue } }
        )
    }

    func snooze(minutes: Int) {
        edit { $0.snoozedUntil = Date().addingTimeInterval(Double(minutes) * 60) }
    }

    func resumeAlerts() {
        edit { $0.snoozedUntil = nil }
    }

    // MARK: - Test alert

    func showTestAlert(_ level: TestAlertLevel) {
        // Never cover up a real alert with a sample one.
        switch engine.phase {
        case .separated, .softAlerted, .strongAlerted:
            return
        default:
            break
        }
        testAlert = level
        alerts.test(level, style: settings.settings.alertStyle)
    }

    func dismissTestAlert() {
        testAlert = nil
        alerts.stopTest()
    }

    // MARK: - Syncing

    /// Events travel by a guaranteed queue; re-sending recent ones at launch is harmless
    /// because the phone replaces events by id.
    private func resendRecentEvents() {
        for event in events.events.prefix(5) where event.wasAlerted {
            connectivity.send(event)
        }
    }
}
