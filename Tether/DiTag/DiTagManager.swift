import AudioToolbox
import CoreBluetooth
import SwiftUI
import UserNotifications

/// Everything the iPhone does with its DiTAGs (one or several): set up, stay connected, beep,
/// read the battery, ring the iPhone on a double press, and alert when one is left behind.
///
/// Left behind is decided by the Bluetooth link alone: a DiTAG disconnecting is the signal.
/// iOS keeps the connections and wakes DiTether for a disconnect or a button press, also while
/// the app is closed to the background (bluetooth-central mode and state restoration). One
/// Bluetooth manager serves every DiTAG, and it only exists while at least one DiTAG is switched on
/// or one is being set up: otherwise nothing runs.
///
/// Phone only: nothing about the DiTAGs is ever sent to the watch. A left-behind notification
/// reaches the watch the normal way, through iOS notification forwarding when the iPhone is locked.
@MainActor
final class DiTagManager: NSObject, ObservableObject {
    enum TagState: Equatable {
        /// This DiTAG's switch is off.
        case off
        case connecting
        case connected
        /// Out of range: iOS keeps trying and reconnects by itself when it is back.
        case lost
    }

    enum BluetoothStatus: Equatable {
        case ok
        case off
        case unauthorized
    }

    enum SetupPhase: Equatable {
        case scanning
        case connecting
        /// Connected to a new DiTAG, waiting for its button.
        case confirming
    }

    enum Proximity {
        case near, medium, far

        init(rssi: Int) {
            if rssi > -60 {
                self = .near
            } else if rssi >= -80 {
                self = .medium
            } else {
                self = .far
            }
        }

        var title: String {
            switch self {
            case .near: return "Near"
            case .medium: return "Medium"
            case .far: return "Far"
            }
        }
    }

    struct TagStatus: Equatable {
        var state: TagState = .connecting
        var battery: Int?
        var signal: Int?
        var isBeeping = false
        var lostAt: Date?

        var proximity: Proximity? { signal.map(Proximity.init(rssi:)) }
    }

    @Published private(set) var statuses: [UUID: TagStatus] = [:]
    @Published private(set) var bluetooth: BluetoothStatus = .ok
    @Published private(set) var setupPhase: SetupPhase?
    /// Why the last setup did not finish, shown under "Add DiTAG".
    @Published private(set) var setupMessage: String?
    /// The DiTAG added most recently, so the setup guide can move on to naming it.
    @Published private(set) var lastAddedID: UUID?

    /// What happened, newest first, so a walk test can be checked afterwards (Devices → Activity).
    struct ActivityLine: Codable, Identifiable, Equatable {
        var id = UUID()
        var date: Date
        var text: String
    }
    @Published private(set) var activity: [ActivityLine] = []
    private let activityFile = JSONFile<[ActivityLine]>(name: "ditag-activity.json")

    let store: DiTagSettingsStore
    var settings: DiTagSettings { store.settings }

    func status(_ id: UUID) -> TagStatus {
        if settings.tag(id)?.isEnabled == false { return TagStatus(state: .off) }
        return statuses[id] ?? TagStatus()
    }

    /// The DiTAGs whose left-behind alarm is going, for the in-app alert's title.
    var alarmTitle: String {
        let names = settings.tags.filter { alarming.contains($0.id) }.map(\.displayName)
        guard !names.isEmpty else { return "DiTAG left behind" }
        return ListFormatter.localizedString(byJoining: names) + " left behind"
    }

    private let tetherSettings: SettingsStore
    private let events: EventStore
    private let location: PhoneLocation
    private let ringer: PhoneRinger

    private var central: CBCentralManager?

    /// Per-DiTAG connection and timers.
    private final class Link {
        let id: UUID
        var peripheral: CBPeripheral?
        var alertCharacteristic: CBCharacteristic?
        var episode: LostEpisode?
        var pressCount = 0
        var pressTask: Task<Void, Never>?
        var beepResetTask: Task<Void, Never>?
        var launchChecked = false
        var launchCheckTask: Task<Void, Never>?
        /// Early warning: weak readings in a row, and whether this weak spell was already announced.
        var weakCount = 0
        var farWarned = false
        /// When the last real (alerted) episode ended, to calm a DiTAG flickering at the edge of range.
        var lastEndedAt: Date?

        init(id: UUID) { self.id = id }

        func cancelTasks() {
            pressTask?.cancel()
            beepResetTask?.cancel()
            launchCheckTask?.cancel()
        }
    }

    private struct LostEpisode {
        /// The History entry, recorded with the alert. nil = stayed quiet (snooze, quiet hours or a
        /// safe place), so nothing was recorded.
        var eventID: UUID?
        var startedAt: Date
        /// Back within this long = a blip: no trace in History.
        var blipWindow: TimeInterval = DiTagManager.blipWindow
    }

    /// Back within this long = a blip at the edge of range: the alert stops and leaves no History entry.
    nonisolated fileprivate static let blipWindow: TimeInterval = 5
    /// Out of range again this soon after the last alert: probably the edge of range, so the next
    /// alert waits a little (and the vibration loop is skipped) instead of going off at once.
    private static let flickerWindow: TimeInterval = 60
    private static let flickerDelay: TimeInterval = 10

    private var links: [UUID: Link] = [:]
    /// DiTAGs whose left-behind vibration is going.
    private var alarming: Set<UUID> = []
    /// Background time held while the spot where a DiTAG was left is being measured.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // Setup of a new DiTAG
    private var candidates: [UUID: (peripheral: CBPeripheral, rssi: Int)] = [:]
    private var setupPeripheral: CBPeripheral?
    private var setupAlertCharacteristic: CBCharacteristic?
    private var setupTask: Task<Void, Never>?

    // Button: one FFE1 notification per press, about 225 ms apart in a double press.
    private static let doublePressWindow: UInt64 = 500_000_000

    private var signalWanted: Set<UUID> = []
    private var signalTask: Task<Void, Never>?
    /// One position request shared by every DiTAG lost at the same moment (a bag with two tags).
    private var freshFixTask: Task<GeoFix?, Never>?

    /// Early warning: this many readings in a row below `weakRSSI` (about 6 s) taps once; it is
    /// announced again only after the signal recovered above `recoveredRSSI`.
    private static let weakRSSI = -86
    private static let recoveredRSSI = -78
    private static let weakReadingsNeeded = 3
    /// Low battery: warned at or below this, and armed again when a fresh battery reads high.
    private static let lowBattery = 15
    private static let freshBattery = 50
    /// After the alert, iOS delivers this many follow-up notifications, this far apart. Each one
    /// vibrates the iPhone (and the watch), even when DiTether itself is suspended.
    private static let followUps = 6
    private static let followUpSpacing: TimeInterval = 5

    nonisolated static let alertNotificationPrefix = "ditag.leftBehind."
    nonisolated static let alertCategory = "ditag.leftBehind"
    nonisolated static let leaveItAction = "ditag.leaveIt"
    nonisolated static let tagIDKey = "tagID"
    private static let restoreID = "ditether.ditag"
    /// The DiTAGs that were connected when DiTether last ran. If a fresh launch cannot reach one,
    /// it was left behind while DiTether was not running.
    private static let withMeKey = "ditag.withMe"

    init(store: DiTagSettingsStore, tetherSettings: SettingsStore, events: EventStore,
         location: PhoneLocation, ringer: PhoneRinger) {
        self.store = store
        self.tetherSettings = tetherSettings
        self.events = events
        self.location = location
        self.ringer = ringer
        super.init()
        activity = activityFile.load() ?? []
        registerNotificationActions()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["ditag.paused"])
        // DiTAG episodes that were still open when DiTether last stopped can't be followed any more.
        for var event in events.events where event.item != nil && event.resolvedAt == nil {
            event.resolvedAt = Date()
            events.upsert(event)
        }
        // Created right away when a DiTAG is in use, because iOS expects the restored manager to be
        // recreated during launch when it relaunches DiTether for a Bluetooth event.
        reconcile()
    }

    // MARK: - Settings

    func edit(_ change: (inout DiTagSettings) -> Void) {
        store.edit(change)
    }

    func binding<T>(_ keyPath: WritableKeyPath<DiTagSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] },
                set: { value in self.edit { $0[keyPath: keyPath] = value } })
    }

    func rename(_ id: UUID, to name: String) {
        store.editTag(id) { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        store.editTag(id) { $0.isEnabled = enabled }
        reconcile()
    }

    func setEarlyWarning(_ on: Bool) {
        edit { $0.earlyWarning = on }
        if !on {
            for link in links.values { clearFarWarning(link) }
        }
        updateSignalReading()
    }

    // MARK: - Watch

    /// The watch's DiTAG screen: does what it asked, then answers with every DiTAG's state.
    func handleWatchRequest(_ request: TagRequest) -> [WatchTagInfo] {
        switch request {
        case .list: break
        case .beep(let id): beep(id)
        case .stopBeep(let id): stopBeep(id)
        }
        return settings.tags.map { tag in
            let current = status(tag.id)
            let state: WatchTagInfo.State
            switch current.state {
            case .connected: state = .withYou
            case .lost: state = .leftBehind
            case .connecting: state = .connecting
            case .off: state = .off
            }
            return WatchTagInfo(id: tag.id, name: tag.displayName, state: state, battery: current.battery,
                                isBeeping: current.isBeeping, since: current.lostAt)
        }
    }

    // MARK: - Snooze

    func snooze(_ id: UUID, minutes: Int) {
        store.editTag(id) {
            $0.snoozedUntil = Date().addingTimeInterval(Double(minutes) * 60)
            $0.snoozedUntilBack = false
        }
        silencePendingAlert(id)
    }

    /// "I'm leaving it here on purpose": quiet until this DiTAG is back in range, then on again.
    func snoozeUntilBack(_ id: UUID) {
        store.editTag(id) {
            $0.snoozedUntilBack = true
            $0.snoozedUntil = nil
        }
        silencePendingAlert(id)
    }

    func resumeAlerts(_ id: UUID) {
        store.editTag(id) {
            $0.snoozedUntil = nil
            $0.snoozedUntilBack = false
        }
    }

    // MARK: - Adding and removing

    var canAddMore: Bool { settings.tags.count < DiTagSettings.maxTags }

    /// Scans for 4 s, connects to the strongest DiTAG that is not set up yet, beeps it, and waits
    /// for its button.
    func startSetup() {
        guard canAddMore else { return }
        cancelSetupWork()
        setupMessage = nil
        lastAddedID = nil   // so adding the same DiTAG again still counts as a change
        candidates = [:]
        setupPhase = .scanning
        let manager = ensureCentral()
        if manager.state == .poweredOn {
            beginSetupScan()
        }
        // Otherwise centralManagerDidUpdateState starts the scan, or reports why it cannot.
    }

    func cancelSetup() {
        failSetup(message: nil)
    }

    func forget(_ id: UUID) {
        if let link = links[id] {
            tearDown(link)
            links[id] = nil
        }
        statuses[id] = nil
        signalWanted.remove(id)
        setWithMe(id, false)
        edit { $0.tags.removeAll { $0.id == id } }
        reconcile()
    }

    // MARK: - Beep

    func beep(_ id: UUID) {
        guard let link = links[id], write(0x01, to: link) else { return }
        update(id) { $0.isBeeping = true }
        link.beepResetTask?.cancel()
        link.beepResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stopBeep(id)
        }
    }

    func stopBeep(_ id: UUID) {
        guard let link = links[id] else { return }
        write(0x00, to: link)
        stopBeepState(link)
    }

    /// Read the signal every 2 s while a DiTAG's screen is open, for Near / Medium / Far.
    func setSignalWanted(_ id: UUID, _ wanted: Bool) {
        if wanted { signalWanted.insert(id) } else { signalWanted.remove(id) }
        updateSignalReading()
    }

    /// Bluetooth permission may have been granted in the Settings app while DiTether was away.
    func refreshAuthorization() {
        guard bluetooth == .unauthorized, CBManager.authorization == .allowedAlways else { return }
        bluetooth = .ok
        reconcile()
    }

    /// Swiped away: iOS ends the connections and will not relaunch DiTether for the DiTAGs.
    func appWillTerminate() {
        let watched = settings.tags.filter(\.isEnabled)
        guard !watched.isEmpty else { return }
        log(nil, "DiTether was closed: DiTAG alerts paused")
        let names = ListFormatter.localizedString(byJoining: watched.map(\.displayName))
        let content = UNMutableNotificationContent()
        content.title = "DiTAG paused"
        content.body = "Open DiTether to keep watching your \(names)."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ditag.paused",
                                                                     content: content, trigger: nil))
    }

    // MARK: - Central manager

    @discardableResult
    private func ensureCentral() -> CBCentralManager {
        if let central { return central }
        // Main queue, so the delegate methods below can step straight onto the main actor.
        let manager = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID,
                                                 CBCentralManagerOptionShowPowerAlertKey: false])
        central = manager
        return manager
    }

    /// Matches the connections to the switches: connects every DiTAG that is on, drops the others,
    /// and releases Bluetooth completely when none is on (so iOS has nothing to wake DiTether for).
    private func reconcile() {
        let wanted = Set(settings.tags.filter(\.isEnabled).map(\.id))
        for (id, link) in links where !wanted.contains(id) {
            tearDown(link)
            links[id] = nil
            statuses[id] = nil
            setWithMe(id, false)
        }
        if wanted.isEmpty && setupPhase == nil {
            releaseCentral()
            return
        }
        let manager = ensureCentral()
        for id in wanted where links[id] == nil {
            links[id] = Link(id: id)
        }
        if manager.state == .poweredOn {
            for link in links.values { connect(link) }
        }
    }

    private func releaseCentral() {
        stopSignalReading()
        // Unknown without a manager; it is checked again when one is created.
        if bluetooth == .off { bluetooth = .ok }
        if let central {
            central.stopScan()
            central.delegate = nil
        }
        central = nil
    }

    /// Ends one DiTAG's connection and everything running for it.
    private func tearDown(_ link: Link) {
        endEpisode(link, cancelled: true)
        clearFarWarning(link)
        link.cancelTasks()
        if let peripheral = link.peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
        link.peripheral = nil
        link.alertCharacteristic = nil
    }

    /// Reconnects to a remembered DiTAG without scanning. iOS never times out a connect request,
    /// so this also covers coming back into range later.
    private func connect(_ link: Link) {
        guard let central, central.state == .poweredOn else { return }
        if link.peripheral == nil {
            link.peripheral = central.retrievePeripherals(withIdentifiers: [link.id]).first
        }
        guard let peripheral = link.peripheral else {
            // iOS forgot it (rare, for example after a reset): find it again by scanning.
            if setupPhase != .scanning {
                central.scanForPeripherals(withServices: [DiTagUUID.buttonService])
            }
            startLaunchCheck(link)
            return
        }
        peripheral.delegate = self
        switch peripheral.state {
        case .connected:
            didBecomeConnected(link)
        case .connecting:
            startLaunchCheck(link)
        default:
            central.connect(peripheral)
            startLaunchCheck(link)
        }
    }

    /// After a fresh launch: if this DiTAG was with you last time but cannot be reached now, it was
    /// left behind while DiTether was not running (for example after the watch relaunched it).
    private func startLaunchCheck(_ link: Link) {
        guard !link.launchChecked else { return }
        link.launchChecked = true
        guard withMe.contains(link.id) else { return }
        link.launchCheckTask = Task { [weak self, weak link] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, let link, self.links[link.id] === link else { return }
            if self.status(link.id).state != .connected && link.episode == nil {
                self.log(link.id, "Not found after DiTether started")
                self.beginEpisode(link, lostAt: Date())
            }
        }
    }

    // MARK: - Connected

    private func didBecomeConnected(_ link: Link) {
        guard let peripheral = link.peripheral else { return }
        link.launchChecked = true
        link.launchCheckTask?.cancel()
        log(link.id, link.episode != nil ? "Back in range" : "Connected")
        update(link.id) { $0.state = .connected }
        // Always rediscover, also for a connection iOS restored: otherwise Beep would have no
        // characteristic to write to after a background relaunch.
        peripheral.discoverServices(DiTagUUID.services)
        setWithMe(link.id, true)
        endEpisode(link, cancelled: false)
        if settings.tag(link.id)?.snoozedUntilBack == true {
            store.editTag(link.id) { $0.snoozedUntilBack = false }
        }
        updateSignalReading()
    }

    @discardableResult
    private func write(_ value: UInt8, to link: Link) -> Bool {
        guard let peripheral = link.peripheral, peripheral.state == .connected,
              let characteristic = link.alertCharacteristic else { return false }
        peripheral.writeValue(Data([value]), for: characteristic, type: .withoutResponse)
        return true
    }

    private func stopBeepState(_ link: Link) {
        link.beepResetTask?.cancel()
        link.beepResetTask = nil
        update(link.id) { $0.isBeeping = false }
    }

    private func log(_ id: UUID?, _ text: String) {
        let name = id.flatMap { settings.tag($0)?.displayName }
        activity.insert(ActivityLine(date: Date(), text: name.map { "\($0): \(text)" } ?? text), at: 0)
        if activity.count > 80 { activity.removeLast(activity.count - 80) }
        activityFile.save(activity)
    }

    func clearActivity() {
        activity = []
        activityFile.delete()
    }

    private func update(_ id: UUID, _ change: (inout TagStatus) -> Void) {
        var status = statuses[id] ?? TagStatus()
        change(&status)
        if statuses[id] != status { statuses[id] = status }
    }

    /// Reads the signal every 2 s while a DiTAG screen is open, or for the early warning. Only while
    /// DiTether is running: iOS pauses this loop when it suspends the app, so it costs nothing then.
    private func updateSignalReading() {
        let screenOpen = signalWanted.contains { status($0).state == .connected }
        let warning = settings.earlyWarning && links.values.contains { status($0.id).state == .connected }
        guard screenOpen || warning else {
            stopSignalReading()
            return
        }
        guard signalTask == nil else { return }
        signalTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ids = self.settings.earlyWarning ? Set(self.links.keys) : self.signalWanted
                for id in ids {
                    if let peripheral = self.links[id]?.peripheral, peripheral.state == .connected {
                        peripheral.readRSSI()
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopSignalReading() {
        signalTask?.cancel()
        signalTask = nil
    }

    // MARK: - Left behind

    private func beginEpisode(_ link: Link, lostAt: Date) {
        guard link.episode == nil, let tag = settings.tag(link.id) else { return }
        update(link.id) {
            $0.state = .lost
            $0.lostAt = lostAt
            $0.signal = nil
        }
        stopBeepState(link)
        // Alerted (or deliberately quiet) once: a relaunch must not alert again.
        setWithMe(link.id, false)

        clearFarWarning(link)

        // Remember roughly where it was left, also when the alert stays quiet. iOS's last reading
        // is only used if it is recent; a fresh one replaces it a moment later.
        var fix: GeoFix?
        if settings.saveLocation, let known = location.lastKnown,
           lostAt.timeIntervalSince(known.timestamp) < 5 * 60 {
            fix = known
        }
        if settings.saveLocation {
            store.editTag(link.id) {
                $0.lastLeftAt = lostAt
                $0.lastLeftFix = fix
            }
        }
        if settings.saveLocation && location.isAuthorized {
            requestFreshFix(for: link)
        }

        if let reason = quietReason(for: tag, fix: fix) {
            log(link.id, "No alert: \(reason)")
            link.episode = LostEpisode(eventID: nil, startedAt: lostAt)
            return
        }

        let flickering = link.lastEndedAt.map { lostAt.timeIntervalSince($0) < Self.flickerWindow } ?? false
        var episode = LostEpisode(eventID: nil, startedAt: lostAt)
        if flickering {
            // Just came back and dropped again: alert in 10 s unless it is back by then. Scheduled
            // notifications still fire if iOS suspends DiTether, and each one buzzes.
            scheduleAlert(for: tag, after: Self.flickerDelay)
            episode.blipWindow = Self.flickerDelay + 1
            log(link.id, "Out of range again: alert in \(Int(Self.flickerDelay)) s unless it's back")
        } else {
            // Alert right now, while iOS has DiTether awake for the disconnect: vibrate in a loop
            // (the silent audio keeps DiTether running), plus notifications iOS repeats by itself.
            let alreadyRinging = ringer.isRinging && ringer.reason != .leftBehind
            alarming.insert(link.id)
            let loud = settings.alarmSound
            let started = ringer.ring(.leftBehind, sound: loud)
            scheduleAlert(for: tag)
            if alreadyRinging {
                log(link.id, "Alert: iPhone was already ringing")
            } else {
                log(link.id, started ? (loud ? "Alert: sound + vibrating" : "Alert: vibrating")
                                     : "Alert: notifications only (iOS blocked the alarm loop)")
            }
        }

        var event = LeftBehindEvent(startedAt: lostAt, softAlertAt: lostAt.addingTimeInterval(flickering ? Self.flickerDelay : 0), fix: fix)
        event.item = tag.displayName
        events.upsert(event)
        episode.eventID = event.id
        link.episode = episode
    }

    private func requestFreshFix(for link: Link) {
        let pending: Task<GeoFix?, Never>
        if let freshFixTask {
            pending = freshFixTask
        } else {
            pending = Task { [location] in await location.current(timeout: 10) }
            freshFixTask = pending
        }
        beginBackgroundTime()
        Task { [weak self, weak link] in
            let fix = await pending.value
            guard let self else { return }
            self.freshFixTask = nil
            if let link { self.adoptFreshFix(fix, link: link) }
            self.endBackgroundTime()
        }
    }

    /// A fresh position: remember it as where the DiTAG was left, store it with the event, and stop
    /// the alert after all if it turns out to be in a safe place (left at home is fine).
    private func adoptFreshFix(_ fix: GeoFix?, link: Link) {
        guard let fix, let episode = link.episode, settings.tag(link.id) != nil else { return }
        store.editTag(link.id) { $0.lastLeftFix = fix }
        guard let eventID = episode.eventID,
              var event = events.events.first(where: { $0.id == eventID }) else { return }
        // Only a safe place can stop it now; a snooze tapped meanwhile keeps the History entry.
        let shared = tetherSettings.settings
        if shared.muteInSafePlaces, let place = Suppression.safePlace(for: fix, in: shared.safePlaces) {
            log(link.id, "Alert stopped: at \(place.name)")
            silencePendingAlert(link.id)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: Self.alertIDs(link.id))
            events.remove(id: eventID)
            link.episode?.eventID = nil
            return
        }
        event.fix = fix
        events.upsert(event)
    }

    // MARK: - Early warning

    private static func farNotificationID(_ id: UUID) -> String {
        "ditag.far." + id.uuidString
    }

    private func checkEarlyWarning(_ link: Link, rssi: Int) {
        guard settings.earlyWarning, let tag = settings.tag(link.id) else { return }
        if rssi < Self.weakRSSI {
            link.weakCount += 1
        } else {
            link.weakCount = 0   // weak readings must come in a row
            if rssi > Self.recoveredRSSI { clearFarWarning(link) }
        }
        guard link.weakCount >= Self.weakReadingsNeeded, !link.farWarned else { return }
        link.farWarned = true
        guard quietReason(for: tag, fix: location.lastKnown) == nil else { return }
        // One tap, the first reminder; the disconnect brings the strong alert.
        log(link.id, "Signal weak (\(rssi) dBm): early warning")
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        let content = UNMutableNotificationContent()
        content.title = "\(tag.displayName) getting far"
        content.body = "Its signal is weak. Did you forget it?"
        content.sound = .default
        content.threadIdentifier = "ditag"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.farNotificationID(tag.id),
                                                                     content: content, trigger: nil))
    }

    /// Back in good range (or gone completely): the "getting far" reminder no longer applies.
    private func clearFarWarning(_ link: Link) {
        link.weakCount = 0
        guard link.farWarned else { return }
        link.farWarned = false
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.farNotificationID(link.id)])
    }

    // MARK: - Battery

    private func batteryRead(_ level: Int, for id: UUID) {
        update(id) { $0.battery = level }
        guard let tag = settings.tag(id) else { return }
        if level >= Self.freshBattery, tag.lowBatteryWarned {
            store.editTag(id) { $0.lowBatteryWarned = false }
        } else if level > 0, level <= Self.lowBattery, !tag.lowBatteryWarned {
            // Once per battery: a dead DiTAG looks exactly like a lost one.
            store.editTag(id) { $0.lowBatteryWarned = true }
            log(id, "Battery low (\(level)%)")
            let content = UNMutableNotificationContent()
            content.title = "\(tag.displayName): battery low"
            content.body = "\(level)% left. It takes a CR2032 coin cell."
            content.sound = .default
            content.threadIdentifier = "ditag"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ditag.battery." + id.uuidString,
                                                                         content: content, trigger: nil))
        }
    }

    /// The DiTAG's own snooze, plus the quiet hours and safe places shared with the watch alerts.
    /// The watch snooze is not used: silencing the watch should not silence your keys.
    private func quietReason(for tag: DiTag, fix: GeoFix?) -> String? {
        if tag.isSnoozed() { return "Snoozed" }
        var shared = tetherSettings.settings
        shared.snoozedUntil = nil
        return Suppression.reason(settings: shared, fix: fix)
    }

    private static func notificationID(_ id: UUID) -> String {
        alertNotificationPrefix + id.uuidString
    }

    private func scheduleAlert(for tag: DiTag, after start: TimeInterval = 0) {
        let content = UNMutableNotificationContent()
        content.title = "\(tag.displayName) left behind"
        content.body = "Your DiTAG is out of range."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = Self.alertCategory
        content.threadIdentifier = "ditag"
        content.userInfo = [Self.tagIDKey: tag.id.uuidString]
        // Scheduled notifications fire even if iOS suspends DiTether, and each one vibrates.
        let center = UNUserNotificationCenter.current()
        for (index, identifier) in Self.alertIDs(tag.id).enumerated() {
            let delay = start + Double(index) * Self.followUpSpacing
            let trigger = delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false) : nil
            let item = (content.mutableCopy() as? UNMutableNotificationContent) ?? content
            if index > 0 {
                item.body = "Still out of range."
            }
            center.add(UNNotificationRequest(identifier: identifier, content: item, trigger: trigger))
        }
    }

    /// The alert and its follow-ups.
    private static func alertIDs(_ id: UUID) -> [String] {
        [notificationID(id)] + followUpIDs(id)
    }

    private static func followUpIDs(_ id: UUID) -> [String] {
        (1...followUps).map { notificationID(id) + ".\($0)" }
    }

    /// You've seen it (opened DiTether or tapped Found it): no more follow-up buzzes.
    func stopFollowUps() {
        alarming.removeAll()
        let ids = links.values.filter { $0.episode != nil }.flatMap { Self.followUpIDs($0.id) }
        guard !ids.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// Snoozed (or found to be in a safe place) while out of range: stop buzzing.
    private func silencePendingAlert(_ id: UUID) {
        guard let link = links[id], link.episode != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: Self.alertIDs(id))
        center.removeDeliveredNotifications(withIdentifiers: Self.followUpIDs(id))
        stopAlarm(id)
    }

    /// Back in range (or the episode was cancelled): a blip of a few seconds leaves no trace, a real
    /// one gets its reconnect time.
    private func endEpisode(_ link: Link, cancelled: Bool) {
        update(link.id) { $0.lostAt = nil }
        guard let current = link.episode else { return }
        link.episode = nil
        let ids = Self.alertIDs(link.id)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: Self.followUpIDs(link.id))
        stopAlarm(link.id)
        guard let eventID = current.eventID,
              var event = events.events.first(where: { $0.id == eventID }) else { return }
        if Date().timeIntervalSince(current.startedAt) < current.blipWindow {
            events.remove(id: eventID)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        } else {
            // Back in range, or no longer watched (switched off, forgotten, Bluetooth off): either
            // way the episode is over, so History never shows it as open forever.
            event.resolvedAt = Date()
            events.upsert(event)
            link.lastEndedAt = Date()
            if !cancelled {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    /// Stops the vibration once no DiTAG needs it any more.
    private func stopAlarm(_ id: UUID) {
        alarming.remove(id)
        if alarming.isEmpty && ringer.reason == .leftBehind {
            ringer.stop()
        }
    }

    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DiTAG location") { [weak self] in
            Task { @MainActor in self?.endBackgroundTime() }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private var withMe: Set<UUID> {
        let strings = UserDefaults.standard.stringArray(forKey: Self.withMeKey) ?? []
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }

    private func setWithMe(_ id: UUID, _ isWithMe: Bool) {
        var ids = withMe
        if isWithMe { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: Self.withMeKey)
    }

    private func registerNotificationActions() {
        let leaveIt = UNNotificationAction(identifier: Self.leaveItAction, title: "Left it on purpose", options: [])
        let category = UNNotificationCategory(identifier: Self.alertCategory, actions: [leaveIt],
                                              intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - Button

    private func buttonPressed(_ link: Link) {
        // Any press answers: stops the iPhone ringing (whatever started it), or this DiTAG's beep.
        if ringer.isRinging {
            ringer.stop()
            stopFollowUps()
            link.pressCount = 0
            link.pressTask?.cancel()
            return
        }
        if status(link.id).isBeeping {
            stopBeep(link.id)
            return
        }
        link.pressCount += 1
        link.pressTask?.cancel()
        link.pressTask = Task { [weak self, weak link] in
            try? await Task.sleep(nanoseconds: Self.doublePressWindow)
            guard !Task.isCancelled, let self, let link else { return }
            let presses = link.pressCount
            link.pressCount = 0
            if presses >= 2 && self.settings.ringOnDoublePress {
                self.ringer.ring(.tag)
            }
        }
    }

    // MARK: - Setup steps

    private func beginSetupScan() {
        guard setupPhase == .scanning, let central else { return }
        setupTask?.cancel()
        central.scanForPeripherals(withServices: [DiTagUUID.buttonService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        setupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.pickCandidate()
        }
    }

    private func pickCandidate() {
        guard setupPhase == .scanning else { return }
        central?.stopScan()
        guard let best = candidates.values.max(by: { $0.rssi < $1.rssi })?.peripheral, let central else {
            failSetup(message: "No new DiTAG found. Turn it on (hold its button until it beeps twice) and close other finder apps.")
            return
        }
        candidates = [:]
        setupPhase = .connecting
        setupPeripheral = best
        best.delegate = self
        central.connect(best)
        setupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self?.failSetup(message: "Couldn't connect. Close iSearching or nRF Connect and try again.")
        }
        // A remembered DiTAG that iOS had forgotten is looked for again by scanning.
        for link in links.values where link.peripheral == nil { connect(link) }
    }

    private func setupConnected(_ peripheral: CBPeripheral) {
        setupTask?.cancel()
        setupPhase = .confirming
        peripheral.discoverServices(DiTagUUID.services)
        setupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            self?.failSetup(message: "Press the DiTAG button to confirm it's yours.")
        }
    }

    /// A short beep so you can tell which DiTAG is being set up.
    private func identifyBeep() {
        guard let peripheral = setupPeripheral, let characteristic = setupAlertCharacteristic else { return }
        peripheral.writeValue(Data([0x01]), for: characteristic, type: .withoutResponse)
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard peripheral.state == .connected else { return }
            peripheral.writeValue(Data([0x00]), for: characteristic, type: .withoutResponse)
        }
    }

    /// The button was pressed: the new DiTAG joins the list, keeping its connection.
    private func completeSetup() {
        guard let peripheral = setupPeripheral else { return }
        cancelSetupWork()
        setupPhase = nil
        setupMessage = nil
        let link = Link(id: peripheral.identifier)
        link.peripheral = peripheral
        link.alertCharacteristic = setupAlertCharacteristic
        link.launchChecked = true
        links[link.id] = link
        setupPeripheral = nil
        setupAlertCharacteristic = nil
        edit { settings in
            settings.tags.append(DiTag(id: peripheral.identifier, name: settings.suggestedName))
        }
        update(link.id) { $0.state = .connected }
        setWithMe(link.id, true)
        lastAddedID = link.id
        log(link.id, "Added")
        updateSignalReading()
    }

    private func failSetup(message: String?) {
        cancelSetupWork()
        guard setupPhase != nil else { return }
        setupPhase = nil
        candidates = [:]
        setupMessage = message
        if let peripheral = setupPeripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        setupPeripheral = nil
        setupAlertCharacteristic = nil
        central?.stopScan()
        reconcile()
    }

    private func cancelSetupWork() {
        setupTask?.cancel()
        setupTask = nil
    }

    // MARK: - Delegate handlers (main actor)

    private func isSetupPeripheral(_ peripheral: CBPeripheral) -> Bool {
        setupPhase != nil && peripheral.identifier == setupPeripheral?.identifier
    }

    fileprivate func handleStateChange(_ managerState: CBManagerState) {
        switch managerState {
        case .poweredOn:
            bluetooth = .ok
            if setupPhase == .scanning { beginSetupScan() }
            for link in links.values { connect(link) }
        case .unknown:
            break
        case .resetting:
            // The Bluetooth system restarts: every peripheral object is stale now.
            resetLinks()
        default:
            if setupPhase != nil {
                failSetup(message: managerState == .unauthorized ? nil : "Turn on Bluetooth to add a DiTAG.")
            }
            bluetooth = managerState == .unauthorized ? .unauthorized : .off
            // Bluetooth turned off: you did that, so nothing is "left behind".
            if !links.isEmpty {
                log(nil, managerState == .unauthorized ? "Bluetooth not allowed" : "Bluetooth turned off: no alerts")
            }
            resetLinks()
        }
    }

    /// Forgets every live connection detail; they are fetched again once Bluetooth is on.
    private func resetLinks() {
        for link in links.values {
            silencePendingAlert(link.id)
            endEpisode(link, cancelled: true)
            stopBeepState(link)
            clearFarWarning(link)
            link.launchCheckTask?.cancel()
            // Check again once Bluetooth is back: a DiTAG left behind meanwhile sends no
            // disconnect, so this is the only way to notice it.
            link.launchChecked = false
            link.peripheral = nil
            link.alertCharacteristic = nil
            update(link.id) {
                $0.state = .connecting
                $0.signal = nil
            }
        }
        stopSignalReading()
    }

    fileprivate func handleRestore(_ restored: [CBPeripheral]) {
        for peripheral in restored {
            guard settings.tag(peripheral.identifier)?.isEnabled == true else { continue }
            let link = links[peripheral.identifier] ?? Link(id: peripheral.identifier)
            link.peripheral = peripheral
            peripheral.delegate = self
            links[link.id] = link
        }
    }

    fileprivate func handleDiscover(_ found: CBPeripheral, rssi: Int) {
        if let link = links[found.identifier] {
            // A remembered DiTAG, found again by scanning.
            guard link.peripheral == nil else { return }
            link.peripheral = found
            found.delegate = self
            central?.connect(found)
            if setupPhase != .scanning && !links.values.contains(where: { $0.peripheral == nil }) {
                central?.stopScan()
            }
        } else if setupPhase == .scanning, settings.tag(found.identifier) == nil {
            guard rssi < 0 else { return }   // 127 = no reading
            let best = max(rssi, candidates[found.identifier]?.rssi ?? Int.min)
            candidates[found.identifier] = (found, best)
        }
    }

    fileprivate func handleConnect(_ connected: CBPeripheral) {
        if isSetupPeripheral(connected) {
            if setupPhase == .connecting { setupConnected(connected) }
        } else if let link = links[connected.identifier] {
            link.peripheral = connected
            didBecomeConnected(link)
        }
    }

    fileprivate func handleFailToConnect(_ failed: CBPeripheral) {
        if isSetupPeripheral(failed) {
            failSetup(message: "Couldn't connect. Close iSearching or nRF Connect and try again.")
        } else if links[failed.identifier] != nil {
            central?.connect(failed)
        }
    }

    fileprivate func handleDisconnect(_ lost: CBPeripheral) {
        if isSetupPeripheral(lost) {
            failSetup(message: "The DiTAG disconnected. Keep it close and try again.")
            return
        }
        guard let link = links[lost.identifier], let central else { return }
        link.alertCharacteristic = nil
        log(link.id, "Out of range")
        // Ask again right away: iOS completes it whenever the DiTAG is back in range.
        central.connect(lost)
        beginEpisode(link, lostAt: Date())
        updateSignalReading()
    }

    fileprivate func handleServices(_ owner: CBPeripheral) {
        for service in owner.services ?? [] {
            switch service.uuid {
            case DiTagUUID.immediateAlertService:
                owner.discoverCharacteristics([DiTagUUID.alertLevel], for: service)
            case DiTagUUID.batteryService:
                owner.discoverCharacteristics([DiTagUUID.batteryLevel], for: service)
            case DiTagUUID.buttonService:
                owner.discoverCharacteristics([DiTagUUID.buttonPress], for: service)
            default:
                break
            }
        }
    }

    fileprivate func handleCharacteristics(_ owner: CBPeripheral, service: CBService) {
        let setup = isSetupPeripheral(owner)
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case DiTagUUID.alertLevel:
                if setup {
                    setupAlertCharacteristic = characteristic
                    if setupPhase == .confirming { identifyBeep() }
                } else {
                    links[owner.identifier]?.alertCharacteristic = characteristic
                }
            case DiTagUUID.batteryLevel:
                owner.readValue(for: characteristic)
                owner.setNotifyValue(true, for: characteristic)
            case DiTagUUID.buttonPress:
                owner.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
    }

    fileprivate func handleValue(_ owner: CBPeripheral, _ characteristic: CBCharacteristic) {
        let id = owner.identifier
        switch characteristic.uuid {
        case DiTagUUID.batteryLevel:
            if let level = characteristic.value?.first {
                batteryRead(min(Int(level), 100), for: id)
            }
        case DiTagUUID.buttonPress:
            if isSetupPeripheral(owner) {
                if setupPhase == .confirming {
                    completeSetup()
                }
            } else if let link = links[id] {
                buttonPressed(link)
            }
        default:
            break
        }
    }

    fileprivate func handleRSSI(_ owner: CBPeripheral, _ rssi: Int) {
        guard rssi < 0, status(owner.identifier).state == .connected else { return }
        update(owner.identifier) { $0.signal = rssi }
        if let link = links[owner.identifier] { checkEarlyWarning(link, rssi: rssi) }
    }
}

// MARK: - CBCentralManagerDelegate

// The manager runs on the main queue, so each callback steps straight onto the main actor.
extension DiTagManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let managerState = central.state
        MainActor.assumeIsolated { self.handleStateChange(managerState) }
    }

    /// iOS relaunched DiTether in the background for a DiTAG event.
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        MainActor.assumeIsolated { self.handleRestore(restored) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        MainActor.assumeIsolated { self.handleDiscover(peripheral, rssi: rssi) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { self.handleConnect(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { self.handleFailToConnect(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { self.handleDisconnect(peripheral) }
    }
}

// MARK: - CBPeripheralDelegate

extension DiTagManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { self.handleServices(peripheral) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated { self.handleCharacteristics(peripheral, service: service) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard error == nil else { return }
        MainActor.assumeIsolated { self.handleValue(peripheral, characteristic) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        let rssi = RSSI.intValue
        MainActor.assumeIsolated { self.handleRSSI(peripheral, rssi) }
    }
}
