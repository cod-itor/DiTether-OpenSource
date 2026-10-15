import SwiftUI
import Combine
import CoreLocation
import UserNotifications

/// Owns every phone-side service. Created once, at launch (see AppDelegate).
@MainActor
final class PhoneModel: ObservableObject {
    let settings: SettingsStore
    let events: EventStore
    let connectivity: ConnectivityService
    let location: PhoneLocation
    let beacon = ProximityBeacon()
    let launcher = WatchLauncher()
    let ringer = PhoneRinger()
    /// The DiTAG key finder. iPhone only, with its own switch: never synced to the watch.
    let diTag: DiTagManager

    enum RingWatchState: Equatable {
        case idle
        case sending
        case ringing
        case failed
    }

    @Published private(set) var ringWatchState: RingWatchState = .idle
    private var ringWatchResetTask: Task<Void, Never>?

    /// The latest report from the watch. Kept on disk so the status screen is right straight after launch.
    @Published private(set) var watchStatus: WatchStatus?
    private let watchStatusFile = JSONFile<WatchStatus>(name: "watch-status.json")

    enum TestAlertState: Equatable {
        case idle
        case sending
        case sent
        case failed
    }

    @Published private(set) var testAlertState: TestAlertState = .idle
    private var testResetTask: Task<Void, Never>?

    private var cancellables = Set<AnyCancellable>()

    init() {
        let settings = SettingsStore()
        let events = EventStore(fileName: "events.json", cap: 300)
        let connectivity = ConnectivityService.shared
        let location = PhoneLocation()
        self.settings = settings
        self.events = events
        self.connectivity = connectivity
        self.location = location
        self.watchStatus = watchStatusFile.load()
        self.diTag = DiTagManager(store: DiTagSettingsStore(), tetherSettings: settings, events: events,
                                  location: location, ringer: ringer)

        connectivity.onSettings = { [weak self] remote in
            _ = self?.settings.adopt(remote)
        }
        connectivity.onEvent = { [weak self] event in
            self?.events.upsert(event)
        }
        connectivity.onCommand = { [weak self] command in
            self?.handle(command)
        }
        connectivity.onTagRequest = { [weak self] request in
            self?.diTag.handleWatchRequest(request) ?? []
        }
        connectivity.onStatus = { [weak self] status in
            self?.adopt(status)
        }
        connectivity.onActivated = { [weak self] in
            // Make sure the watch has our latest copy. It ignores it if its own is newer.
            guard let self else { return }
            self.connectivity.push(self.settings.settings)
        }
        connectivity.start()

        // Keep the Bluetooth beacon on only while protection and Bluetooth range are on. It is only
        // created once permission was given (from the setup checklist), so no prompt appears
        // unannounced. With protection off it is released completely, so iOS has no reason to wake
        // DiTether in the background.
        settings.$settings.map { $0.protectionEnabled && $0.bluetoothRangeEnabled }
            .removeDuplicates()
            .combineLatest(beacon.$authorization)
            .sink { [weak self] wanted, authorization in
                guard let self else { return }
                if wanted && authorization == .allowedAlways {
                    self.beacon.start()
                } else {
                    self.beacon.shutDown()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.beacon.refreshAuthorization()
                self?.diTag.refreshAuthorization()
                // Found it: opening DiTether stops the ringing and the DiTAG follow-up buzzes.
                self?.ringer.stop()
                self?.diTag.stopFollowUps()
            }
            .store(in: &cancellables)

        // Share the iPhone's position with the watch only as a fallback: protection on, and the watch
        // has said its own Bluetooth link is NOT working (or Bluetooth range is turned off). Never just
        // because the watch has not reported yet, so launching DiTether does not start location.
        settings.$settings.map { ($0.protectionEnabled, $0.detectionMode, $0.bluetoothRangeEnabled) }
            .combineLatest(location.$status, $watchStatus.map { $0?.bluetoothLinked })
            .sink { [weak self] values, status, bluetoothLinked in
                let (protecting, mode, bluetoothRange) = values
                let needsFallback = !bluetoothRange || bluetoothLinked == false
                self?.updateLocationSharing(enabled: protecting && needsFallback, mode: mode, status: status)
            }
            .store(in: &cancellables)

        let publishers: [ObservableObjectPublisher] = [
            settings.objectWillChange,
            events.objectWillChange,
            connectivity.objectWillChange,
            location.objectWillChange,
            beacon.objectWillChange,
            launcher.objectWillChange,
            ringer.objectWillChange,
            diTag.objectWillChange,
            diTag.store.objectWillChange
        ]
        for publisher in publishers {
            publisher
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    // MARK: - Editing settings (saved here and pushed to the watch)

    func edit(_ change: (inout TetherSettings) -> Void) {
        let updated = settings.edit(change)
        connectivity.push(updated)
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

    // MARK: - Safe places

    func addSafePlace(name: String, fix: GeoFix, radius: Double = 150) {
        edit { $0.safePlaces.append(SafePlace(name: name, latitude: fix.latitude, longitude: fix.longitude, radius: radius)) }
    }

    func update(_ place: SafePlace) {
        edit { settings in
            if let index = settings.safePlaces.firstIndex(where: { $0.id == place.id }) {
                settings.safePlaces[index] = place
            }
        }
    }

    func removeSafePlaces(at offsets: IndexSet) {
        edit { $0.safePlaces.remove(atOffsets: offsets) }
    }

    // MARK: - Background work

    /// Everything that can run in the background, stopped at once. Used when DiTether is being
    /// terminated; turning protection off stops the same things through the settings sinks above.
    /// The DiTAG has its own switch; iOS ends its connection anyway, so it only says it paused.
    func stopBackgroundWork() {
        location.stopSharing()
        beacon.shutDown()
        ringer.stop()
        diTag.appWillTerminate()
    }

    // MARK: - Location sharing

    private func updateLocationSharing(enabled: Bool, mode: DetectionMode, status: CLAuthorizationStatus) {
        let allowed = status == .authorizedAlways || status == .authorizedWhenInUse
        if enabled && allowed && mode.sharesPhoneLocation {
            location.startSharing(distanceFilter: mode.phoneDistanceFilter)
        } else {
            location.stopSharing()
        }
    }

    // MARK: - Watch status

    private func adopt(_ status: WatchStatus) {
        if let current = watchStatus, current.sentAt >= status.sentAt { return }
        watchStatus = status
        watchStatusFile.save(status)
    }

    // MARK: - Finding each other

    private func handle(_ command: RemoteCommand) {
        switch command {
        case .ringPhone:
            ringer.ring()
        case .stopRingingPhone:
            ringer.stop()
        case .ringWatch, .stopRingingWatch:
            break   // meant for the watch
        }
    }

    /// Makes the watch buzz and beep for a while, so you can find it.
    func ringWatch() {
        guard ringWatchState != .sending else { return }
        ringWatchResetTask?.cancel()
        ringWatchState = .sending
        Task {
            let delivered = await connectivity.send(.ringWatch)
            ringWatchState = delivered ? .ringing : .failed
            ringWatchResetTask = Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if !Task.isCancelled { ringWatchState = .idle }
            }
        }
    }

    /// Asks for permission to show the "Here's your iPhone" notification while ringing.
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Test alert

    func sendTestAlert(_ level: TestAlertLevel) {
        guard testAlertState != .sending else { return }
        testResetTask?.cancel()
        testAlertState = .sending
        Task {
            let delivered = await connectivity.sendTestAlert(level)
            testAlertState = delivered ? .sent : .failed
            // Let the result message fade back to the normal hint after a while.
            testResetTask = Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if !Task.isCancelled { testAlertState = .idle }
            }
        }
    }

    // MARK: - History

    func clearHistory() {
        events.clear()
    }
}
