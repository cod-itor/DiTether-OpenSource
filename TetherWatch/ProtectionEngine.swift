import Foundation

/// The brain of Tether. It lives on the watch and needs no internet and no iPhone to make decisions.
///
/// One loop ticks every 2 seconds and does everything, so the logic reads top to bottom:
///   * phone reachable      -> "watching": refresh the dead-man's-switch notification, keep a fresh location handy
///   * phone not reachable  -> "separated": anchor to where the watch was (the iPhone is probably
///        there), then escalate on whichever comes first, distance or time:
///        half the alert distance, or soft delay   -> gentle tap             (tier 1)
///        the full alert distance, or strong delay -> strong repeating alert (tier 2)
///        Every alert is confirmed with a live ping first, so a stale "unreachable" flag never buzzes you.
///        snooze / quiet hours / safe place -> "muted": no alerts, but we keep watching, and the
///        moment the reason goes away (you leave home, snooze ends) the right alert fires.
///   * phone reachable again -> resolve the event, stop everything, one soft "success" tap.
///
/// WatchConnectivity callbacks make it react instantly; the 2-second poll is the self-healing backup
/// in case a callback was missed while the app was suspended.
@MainActor
final class ProtectionEngine: ObservableObject {

    enum Phase: Equatable {
        case off
        case starting
        case watching
        case separated(since: Date)
        case softAlerted(since: Date)
        case strongAlerted(since: Date)
        case muted(since: Date, reason: String)
    }

    @Published private(set) var phase: Phase = .off
    /// Roughly how far the watch is from where the link dropped. nil while together or without a good reading.
    @Published private(set) var distanceFromSpot: Double?
    /// You walked away and are now walking back toward where you left the iPhone.
    @Published private(set) var isHeadingBack = false

    /// Heading back: you got at least this far from the spot…
    static let headingBackMinimumAway: Double = 30
    /// …and then came at least this much closer again (larger than typical GPS wobble).
    static let headingBackMargin: Double = 20
    /// Back to "walking away" once within this of the furthest point again.
    static let walkingAwayAgainMargin: Double = 8

    /// Readings worse than this are never used to measure distance (watch GPS outdoors is usually 5 to 20 m).
    static let maxDistanceAccuracy: Double = 65
    /// Readings older than this are never used to measure distance.
    static let maxDistanceFixAge: TimeInterval = 30
    /// The pre-drop reading is used as the anchor only if it is at least this recent.
    static let maxAnchorAge: TimeInterval = 120
    /// The iPhone's shared position is trusted for this long after it arrived in a ping reply.
    static let maxPhoneFixAge: TimeInterval = 60
    /// Shared iPhone positions less precise than this are ignored.
    static let maxPhoneFixAccuracy: Double = 100
    /// A ping answered faster than this most likely went over Bluetooth or local Wi-Fi, not iCloud.
    static let quickAnswer: TimeInterval = 0.8
    /// How long the loud alert waits for Bluetooth to return after such a quick answer.
    static let bluetoothRecoveryGrace: TimeInterval = 15

    /// While apart, a reading older than this makes the watch ask for a fresh one.
    static let staleTrackingAge: TimeInterval = 20

    // Bluetooth-first power saving: while the direct Bluetooth link is healthy, it alone answers
    // "is the iPhone close?", so the other signals slow right down. They return to full speed the
    // moment Bluetooth is not connected or you are apart.
    /// Main loop interval while together over a healthy Bluetooth link (Bluetooth changes still act instantly).
    static let bluetoothTickInterval: TimeInterval = 10
    /// Normal main loop interval.
    static let tickInterval: TimeInterval = 2
    /// Ping health check while together over a healthy Bluetooth link.
    static let bluetoothPingInterval: TimeInterval = 120
    /// The backup "Is your iPhone with you?" notification, while resting on a healthy Bluetooth link:
    /// pushed back every 2 minutes and due 5 minutes out (instead of every 15 s), since an
    /// unexpected end of the background session is already announced right away.
    static let bluetoothWatchdogRearm: TimeInterval = 120
    static let bluetoothWatchdogDelay: TimeInterval = 300

    // Calm while apart: once the alert has done its job (alerts finished, no turning back) or while
    // quiet at a safe place, continuous GPS and a 2-second loop are wasted battery.
    /// A separation becomes "calm" after this long, once the loud alert's repeat time is over.
    static let calmAfter: TimeInterval = 10 * 60
    /// One GPS reading this often while calm (enough to notice turning back or leaving).
    static let calmFixInterval: TimeInterval = 120
    /// One GPS reading this often while quiet at a safe place (enough to notice walking out of it).
    static let safePlaceFixInterval: TimeInterval = 60
    /// Without Bluetooth, the iPhone is asked "are you back?" at most this often while apart.
    static let apartProbeInterval: TimeInterval = 10

    /// Own readings while together when the mode does not compare positions: just often enough
    /// that a recent one is ready to anchor the drop point (see maxAnchorAge).
    static let saverFixInterval: TimeInterval = 110

    /// Right after protection starts, the reachability flag can take a few seconds to settle.
    /// Not seeing the iPhone during this window is not treated as being apart.
    static let connectGrace: TimeInterval = 8

    private let settingsStore: SettingsStore
    private let events: EventStore
    private let connectivity: ConnectivityService
    private let location: WatchLocation
    private let alerts: AlertCenter
    private let keepAlive: KeepAliveSession
    private let log: ConnectionLog
    private let proximity: ProximityMonitor

    private var loopTask: Task<Void, Never>?
    private var armed = false
    private var armedAt = Date.distantPast

    // State of the current separation. All reset while the iPhone is with us.
    private var separationStart: Date?
    /// True when this separation was started by measuring distance while the link still looked up.
    /// Such a separation only ends on proof the iPhone is close again, never on a missing reading.
    private var separatedByDistance = false
    /// The user opened DiTether while the alert was going: stop buzzing for this episode.
    private var acknowledged = false
    /// Furthest raw distance from the spot in this episode (for heading-back detection).
    private var furthestFromSpot: Double = 0
    /// Something wants precise GPS right now (the hot/cold guide).
    private var guidanceWanted = false
    /// The separation is calm (see calmAfter): light GPS, slow loop.
    private var calmApart = false
    private var headingBackSince: Date?
    private var lastApartProbeAt = Date.distantPast
    /// After an iPhone restart its Bluetooth beacon is gone until DiTether relaunches (the watch's
    /// own ping relaunches it). A quick answer to a ping when Bluetooth drops means the iPhone is
    /// probably right here, so the loud alert waits briefly for Bluetooth to come back.
    private var bluetoothHoldChecked = false
    private var bluetoothHoldUntil: Date?
    private var lastTrackingRefreshAt = Date.distantPast
    private var generation = 0
    private var openEvent: LeftBehindEvent?
    private var softFired = false
    private var strongFired = false
    private var strongFiredAt: Date?
    private var lastPulseAt: Date?
    private var mutedReason: String?
    private var anchor: GeoFix?
    private var maxMoved: Double = 0
    private var escalatedByDistance = false

    // Helpers
    private var latestFix: GeoFix?
    private var fixInFlight = false
    private var lastFixRequestAt = Date.distantPast
    private var watchdogArmed = false
    private var lastWatchdogArmAt = Date.distantPast
    private var lastKeepAliveRetryAt = Date.distantPast
    private var lastPingAt = Date.distantPast
    private var pingFailures = 0

    init(settings: SettingsStore,
         events: EventStore,
         connectivity: ConnectivityService,
         location: WatchLocation,
         alerts: AlertCenter,
         keepAlive: KeepAliveSession,
         log: ConnectionLog,
         proximity: ProximityMonitor) {
        self.settingsStore = settings
        self.events = events
        self.connectivity = connectivity
        self.location = location
        self.alerts = alerts
        self.keepAlive = keepAlive
        self.log = log
        self.proximity = proximity
        proximity.onChange = { [weak self] signal in
            self?.proximityChanged(signal)
        }
        location.onUpdate = { [weak self] fix in
            self?.handleFix(fix)
        }
    }

    // MARK: - Entry points

    /// Call at launch and after every settings change (local or synced from the phone).
    func settingsChanged() {
        let settings = settingsStore.settings
        guard settings.protectionEnabled else {
            disarm()
            return
        }
        arm()
        proximity.readInterval = settings.detectionMode.bluetoothReadInterval
        if settings.bluetoothRangeEnabled {
            proximity.start()
        } else {
            proximity.stop()
        }
        // "Silence" should feel instant, so apply it now instead of waiting for the next tick.
        if separationStart != nil,
           let reason = Suppression.reason(settings: settings, now: Date(), fix: latestFix) {
            enterMute(reason)
        }
        publishPhase()
    }

    /// Tether's own Bluetooth link changed: fading = first reminder, dropped = loud alert.
    /// Acted on right away instead of waiting for the next tick.
    private func proximityChanged(_ signal: ProximitySignal) {
        guard armed, usesBluetooth else { return }
        switch signal {
        case .weak:
            beginSeparation(because: "Bluetooth signal weak")
        case .lost:
            beginSeparation(because: "Bluetooth link lost")
        case .strong:
            Task { await confirmReconnected() }
        case .unknown:
            return
        }
        guard separationStart != nil else { return }
        Task { [weak self] in
            guard let self, self.armed else { return }
            await self.tickSeparated(self.settingsStore.settings)
            self.publishPhase()
        }
    }

    /// Bluetooth decides once it has worked at least once since protection started.
    private var usesBluetooth: Bool {
        settingsStore.settings.bluetoothRangeEnabled && proximity.hasConnected
    }

    /// The direct Bluetooth link says the iPhone is close, whatever Wi-Fi or pings say.
    private var bluetoothSaysNear: Bool {
        usesBluetooth && proximity.signal == .strong
    }

    /// Called the moment WatchConnectivity reports a reachability change.
    func reachabilityChanged(_ reachable: Bool) {
        guard armed else { return }
        if isSettling(reachable: reachable, now: Date()) { return }
        if reachable {
            // Flags can be stale, so only believe "back" once the iPhone answers a live ping.
            Task { await confirmReconnected() }
        } else {
            beginSeparation(because: "Link to iPhone dropped")
        }
    }

    /// Still inside the start-up window and the iPhone has not shown up yet.
    private func isSettling(reachable: Bool, now: Date) -> Bool {
        separationStart == nil && !reachable && now.timeIntervalSince(armedAt) < Self.connectGrace
    }

    private func confirmReconnected() async {
        guard separationStart != nil else { return }
        let expected = generation
        if await phoneIsWithUs(), armed, expected == generation {
            endSeparation()
            publishPhase()
        }
    }

    /// True if the iPhone answers a live ping and is not measurably far away.
    /// Over shared Wi-Fi or iCloud the iPhone can answer from far away, so the answer alone is not enough.
    private func phoneIsWithUs() async -> Bool {
        // A direct Bluetooth link cannot be relayed over Wi-Fi or iCloud, so when it is working
        // it is the answer: near only while its signal is strong.
        if usesBluetooth {
            return proximity.signal == .strong
        }
        guard await connectivity.probe() else { return false }
        if let meters = distanceToPhone(now: Date()) {
            return meters < farThreshold
        }
        // No usable positions. If distance is what said "apart", a missing reading is not proof of
        // being back; otherwise the answered ping is the best evidence there is.
        return !(separationStart != nil && separatedByDistance)
    }

    /// How far the watch certainly is from the iPhone, in metres: the distance between the two
    /// positions minus their combined error margin. nil without fresh, precise positions from both.
    private func distanceToPhone(now: Date) -> Double? {
        guard let phone = connectivity.lastPhoneFix, let receivedAt = connectivity.lastPhoneFixAt,
              now.timeIntervalSince(receivedAt) <= Self.maxPhoneFixAge,
              phone.accuracy >= 0, phone.accuracy <= Self.maxPhoneFixAccuracy,
              let own = latestFix,
              now.timeIntervalSince(own.timestamp) <= Self.maxDistanceFixAge,
              own.accuracy >= 0, own.accuracy <= Self.maxDistanceAccuracy else { return nil }
        let raw = Geo.distance(lat1: own.latitude, lon1: own.longitude,
                               lat2: phone.latitude, lon2: phone.longitude)
        let margin = (own.accuracy * own.accuracy + phone.accuracy * phone.accuracy).squareRoot()
        return max(raw - margin, 0)
    }

    /// Being this far from the iPhone counts as apart, even if the link still looks connected.
    private var farThreshold: Double {
        max(Double(settingsStore.settings.distanceAlertMeters) / 2, 25)
    }

    /// The reachability flag can go stale, so every few seconds the watch asks the iPhone directly.
    /// Two misses in a row count as "apart" even if the flag still says reachable. The reply carries
    /// the iPhone's position, so walking away is caught even while the link stays up over Wi-Fi or iCloud.
    private func pingIfDue(_ now: Date) async {
        let interval = restingOnBluetooth ? Self.bluetoothPingInterval : settingsStore.settings.detectionMode.pingInterval
        guard now.timeIntervalSince(lastPingAt) >= interval else { return }
        lastPingAt = now
        let answered = await connectivity.probe()
        guard armed, !Task.isCancelled else { return }
        if answered {
            if pingFailures > 0 {
                log.add("iPhone answered again")
            }
            pingFailures = 0
            if settingsStore.settings.distanceAlertEnabled, let meters = distanceToPhone(now: Date()), meters >= farThreshold {
                beginSeparation(because: "About \(Int(meters)) m from iPhone, link still up")
                separatedByDistance = true
            }
        } else {
            pingFailures += 1
            log.add("iPhone did not answer a ping (\(pingFailures) in a row)")
            if pingFailures >= 2 {
                beginSeparation(because: "iPhone stopped answering")
            }
        }
    }

    // MARK: - Arming

    private func arm() {
        guard !armed else { return }
        armed = true
        armedAt = Date()
        log.add("Protection on")
        alerts.resetPending()
        let session = keepAlive
        Task {
            await session.start()
        }
        startLoop()
        publishPhase()
    }

    private func disarm() {
        guard armed else {
            phase = .off
            return
        }
        armed = false
        log.add("Protection off")
        loopTask?.cancel()
        loopTask = nil
        finishOpenEvent(reconnected: false)
        resetSeparationState()
        alerts.stopAll()
        cancelWatchdogIfNeeded()
        keepAlive.stop()
        proximity.stop()
        phase = .off
    }

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.currentTickInterval ?? Self.tickInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.step()
            }
        }
    }

    // MARK: - The loop

    /// Together over a healthy Bluetooth link: nothing else needs checking often.
    private var restingOnBluetooth: Bool {
        separationStart == nil && bluetoothSaysNear
    }

    private var currentTickInterval: TimeInterval {
        restingOnBluetooth || calmApart ? Self.bluetoothTickInterval : Self.tickInterval
    }

    private func step() async {
        let settings = settingsStore.settings
        guard settings.protectionEnabled else {
            disarm()
            return
        }
        guard connectivity.isActivated else {
            publishPhase()
            return
        }
        let now = Date()
        ensureKeepAlive(now)

        let reachable = connectivity.liveReachable
        if isSettling(reachable: reachable, now: now) {
            publishPhase()
            return
        }
        if separationStart == nil, usesBluetooth, proximity.signal == .weak || proximity.signal == .lost {
            // Self-healing backup in case a Bluetooth change was missed while suspended.
            beginSeparation(because: proximity.signal == .lost ? "Bluetooth link lost" : "Bluetooth signal weak")
        }
        if separationStart == nil {
            if reachable {
                await pingIfDue(now)
                guard armed, !Task.isCancelled else { return }
                if separationStart == nil {
                    heartbeat(settings, now: now)
                }
            } else {
                beginSeparation(because: "Link to iPhone dropped")
            }
        } else {
            let expected = generation
            // Bluetooth answers instantly; a ping costs a message both ways, so it is rationed.
            let mayAsk = usesBluetooth || (reachable && now.timeIntervalSince(lastApartProbeAt) >= Self.apartProbeInterval)
            if mayAsk, !usesBluetooth { lastApartProbeAt = now }
            if mayAsk, await phoneIsWithUs() {
                guard armed, !Task.isCancelled else { return }
                if expected == generation { endSeparation() }
            } else {
                guard armed, !Task.isCancelled else { return }
                await tickSeparated(settings)
            }
        }
        guard armed else { return }
        publishPhase()
    }

    /// While the phone is with us: keep the dead-man's switch pushed back and a recent location handy.
    private func heartbeat(_ settings: TetherSettings, now: Date) {
        // Snoozed or quiet hours: no alert is wanted, so the backup notification must not fire either.
        if Suppression.reason(settings: settings, now: now, fix: nil) != nil {
            cancelWatchdogIfNeeded()
        } else if restingOnBluetooth {
            if now.timeIntervalSince(lastWatchdogArmAt) >= Self.bluetoothWatchdogRearm {
                armWatchdog(after: Self.bluetoothWatchdogDelay, now: now)
            }
        } else if now.timeIntervalSince(lastWatchdogArmAt) >= 15 {
            let target = settings.strongAlertEnabled ? settings.strongDelaySeconds : settings.softDelaySeconds
            armWatchdog(after: Double(target) + 30, now: now)
        }
        // While together the watch borrows the iPhone's location, so a reading every minute is cheap.
        // It means that when the link drops, we already know where the iPhone is.
        // Cheap while the iPhone is close (the watch borrows its location then), and needed to notice
        // walking away while the link still looks connected.
        // With a healthy Bluetooth link, comparing positions adds nothing: one reading every couple
        // of minutes is enough to know where the iPhone is when you separate.
        let interval: TimeInterval
        if !settings.distanceAlertEnabled {
            interval = 300
        } else if restingOnBluetooth {
            interval = Self.saverFixInterval
        } else {
            interval = settings.detectionMode.togetherFixInterval ?? Self.saverFixInterval
        }
        if wantsLocation(settings), now.timeIntervalSince(lastFixRequestAt) >= interval {
            requestFix()
        }
    }

    private func tickSeparated(_ settings: TetherSettings) async {
        guard let start = separationStart else { return }
        let generationAtStart = generation
        let now = Date()
        let elapsed = now.timeIntervalSince(start)

        // Snooze and quiet hours do not depend on where you are, so no GPS is needed while they last.
        if let reason = Suppression.reason(settings: settings, now: now, fix: nil) {
            location.stopTracking()
            enterMute(reason)
            keepWatchdogRolling(settings, elapsed: elapsed)
            return
        }

        calmApart = isCalm(settings, now: now, elapsed: elapsed)
        if wantsLocation(settings), calmApart {
            // Calm: an occasional single reading instead of continuous GPS.
            if location.isTracking {
                location.stopTracking()
                log.add(mutedReason != nil ? "Quiet at a safe place: GPS checks once a minute" : "Long separation: GPS checks every 2 minutes")
            }
            let interval = mutedReason != nil ? Self.safePlaceFixInterval : Self.calmFixInterval
            if now.timeIntervalSince(lastFixRequestAt) >= interval {
                requestFix()
            }
        } else {
            // Distance and safe-place checks need fresh locations while we are apart. Continuous
            // tracking normally provides them; one-shot requests are the backup.
            if wantsLocation(settings), !location.isTracking {
                location.startTracking(precise: wantsPreciseTracking(settings))
            }
            // Tracking only reports after moving a few metres, so standing still produces no new
            // readings and the last one grows stale. Restarting tracking forces a fresh reading.
            if location.isTracking, let fix = latestFix,
               now.timeIntervalSince(fix.timestamp) > Self.staleTrackingAge,
               now.timeIntervalSince(lastTrackingRefreshAt) > Self.staleTrackingAge {
                lastTrackingRefreshAt = now
                location.refreshTracking()
            }
            if wantsLocation(settings), !location.isTracking, now.timeIntervalSince(lastFixRequestAt) >= 30 {
                requestFix()
            }
        }
        // Give the very first reading a few seconds to arrive before deciding anything.
        // (Only matters for safe places: it avoids buzzing you at home before the watch knows it is home.)
        if usesSafePlaces(settings), fixInFlight || location.isTracking, !hasUsableFix(now: now),
           elapsed < Double(settings.softDelaySeconds) + 12 {
            return
        }

        if let reason = Suppression.reason(settings: settings, now: now, fix: latestFix) {
            enterMute(reason)
            return
        }
        mutedReason = nil

        // Distance first: walking away is the clearest sign the iPhone was left behind,
        // so it escalates right away instead of waiting for the timers.
        var handled = false
        if usesBluetooth {
            switch proximity.signal {
            case .lost:
                if !strongFired, await holdForBluetoothRecovery(now: now) {
                    handled = true
                } else if settings.strongAlertEnabled, !strongFired {
                    await fireStrong(generation: generationAtStart, settings: settings)
                } else if settings.softAlertEnabled, !softFired, !strongFired {
                    await fireSoft(generation: generationAtStart)
                }
                handled = true
            case .weak:
                if settings.softAlertEnabled, !softFired, !strongFired {
                    await fireSoft(generation: generationAtStart)
                }
                handled = true
            case .strong, .unknown:
                break
            }
        }
        if !handled, settings.distanceAlertEnabled, let moved = movedMeters(now: now) {
            let limit = Double(settings.distanceAlertMeters)
            if settings.strongAlertEnabled, !strongFired, moved >= limit {
                if !softFired { escalatedByDistance = true }
                await fireStrong(generation: generationAtStart, settings: settings)
                handled = true
            } else if settings.softAlertEnabled, !softFired, !strongFired, moved >= limit / 2 {
                escalatedByDistance = true
                await fireSoft(generation: generationAtStart)
                handled = true
            }
        }

        // Timers are the fallback, for when there is no good location reading (indoors, location off).
        if !handled, separationStart != nil {
            if settings.strongAlertEnabled, !strongFired, elapsed >= Double(settings.strongDelaySeconds) {
                await fireStrong(generation: generationAtStart, settings: settings)
            } else if settings.softAlertEnabled, !softFired, !strongFired, elapsed >= Double(settings.softDelaySeconds) {
                await fireSoft(generation: generationAtStart)
            }
        }

        // An alert attempt may have discovered the iPhone is back and ended the separation.
        guard separationStart != nil else { return }
        if strongFired {
            pulseIfDue(settings)
        }
        keepWatchdogRolling(settings, elapsed: Date().timeIntervalSince(start))
    }

    /// Nothing urgent is going on while apart: quiet at a safe place, or the alerts have finished
    /// long ago. Turning back or the hot/cold guide always count as urgent.
    private func isCalm(_ settings: TetherSettings, now: Date, elapsed: TimeInterval) -> Bool {
        let recentlyTurnedBack = headingBackSince.map { now.timeIntervalSince($0) < Self.calmAfter } ?? false
        if recentlyTurnedBack || guidanceWanted { return false }
        if mutedReason != nil { return true }   // time-based quiet returns earlier; this is a safe place
        guard elapsed >= Self.calmAfter else { return false }
        if let fired = strongFiredAt, !acknowledged,
           now.timeIntervalSince(fired) < Double(settings.strongRepeatMinutes * 60) {
            return false
        }
        return true
    }

    /// True while waiting for Bluetooth to come back after the iPhone answered a ping quickly.
    private func holdForBluetoothRecovery(now: Date) async -> Bool {
        if let until = bluetoothHoldUntil {
            return now < until
        }
        guard !bluetoothHoldChecked else { return false }
        bluetoothHoldChecked = true
        guard await connectivity.probe(timeout: 2),
              let roundTrip = connectivity.lastProbeRoundTrip, roundTrip < Self.quickAnswer else { return false }
        bluetoothHoldUntil = now.addingTimeInterval(Self.bluetoothRecoveryGrace)
        log.add("iPhone answered in \(Int(roundTrip * 1000)) ms: waiting \(Int(Self.bluetoothRecoveryGrace)) s for Bluetooth (iPhone app may have restarted)")
        return true
    }

    // MARK: - Separation lifecycle

    private func beginSeparation(because reason: String) {
        guard armed, separationStart == nil else { return }
        // The direct Bluetooth link says the iPhone is right here (for example the iPhone app is
        // not running, or a ping got lost): no alert.
        guard !bluetoothSaysNear else { return }
        log.add("Apart: \(reason)")
        generation += 1
        let now = Date()
        separationStart = now
        openEvent = LeftBehindEvent(startedAt: now)
        softFired = false
        strongFired = false
        strongFiredAt = nil
        lastPulseAt = nil
        mutedReason = nil
        anchor = nil
        maxMoved = 0
        escalatedByDistance = false
        distanceFromSpot = nil

        // The anchor is where the iPhone probably is. Best: the position the iPhone itself shared in a
        // recent ping reply. Next best: the last reading taken while still connected (the watch borrows
        // the iPhone's own location then). Otherwise the first good reading after the drop, in handleFix.
        if let phone = connectivity.lastPhoneFix, let receivedAt = connectivity.lastPhoneFixAt,
           now.timeIntervalSince(receivedAt) <= Self.maxAnchorAge,
           phone.accuracy >= 0, phone.accuracy <= Self.maxPhoneFixAccuracy {
            setAnchor(phone)
        } else if let fix = latestFix,
           now.timeIntervalSince(fix.timestamp) <= Self.maxAnchorAge,
           fix.accuracy >= 0, fix.accuracy <= 100 {
            setAnchor(fix)
        }
        let settings = settingsStore.settings
        if wantsLocation(settings) {
            location.startTracking(precise: wantsPreciseTracking(settings))
        }
        if !location.isTracking {
            requestFix()
        }
        publishPhase()
    }

    private func endSeparation() {
        guard separationStart != nil else { return }
        generation += 1
        let wasAlerting = softFired || strongFired
        log.add("Together again")
        finishOpenEvent(reconnected: true)
        resetSeparationState()
        alerts.reconnected(wasAlerting: wasAlerting)
        lastWatchdogArmAt = .distantPast      // re-arm the dead-man's switch on the next tick
        publishPhase()
    }

    /// Closes the episode in history (only episodes that actually alerted are kept).
    /// Turning protection off mid-episode keeps it unresolved: nothing actually reconnected.
    private func finishOpenEvent(reconnected: Bool) {
        guard var event = openEvent, event.wasAlerted else { return }
        if reconnected {
            event.resolvedAt = Date()
        }
        event.fix = event.fix ?? anchor
        event.escalatedByDistance = escalatedByDistance
        if maxMoved > 0 { event.maxDistance = maxMoved }
        events.upsert(event)
        connectivity.send(event)
    }

    private func resetSeparationState() {
        location.stopTracking()
        separatedByDistance = false
        acknowledged = false
        furthestFromSpot = 0
        isHeadingBack = false
        calmApart = false
        headingBackSince = nil
        lastApartProbeAt = .distantPast
        bluetoothHoldChecked = false
        bluetoothHoldUntil = nil
        anchor = nil
        maxMoved = 0
        escalatedByDistance = false
        distanceFromSpot = nil
        pingFailures = 0
        separationStart = nil
        openEvent = nil
        softFired = false
        strongFired = false
        strongFiredAt = nil
        lastPulseAt = nil
        mutedReason = nil
    }

    // MARK: - Alerts

    private func fireSoft(generation expected: Int) async {
        if await phoneIsWithUs() {
            if armed, expected == generation { endSeparation() }
            return
        }
        guard armed, expected == generation, separationStart != nil, mutedReason == nil, !softFired, !strongFired else { return }
        let now = Date()
        softFired = true
        log.add("First reminder sent")
        alerts.soft(style: settingsStore.settings.alertStyle)
        record { $0.softAlertAt = $0.softAlertAt ?? now }
    }

    private func fireStrong(generation expected: Int, settings: TetherSettings) async {
        if await phoneIsWithUs() {
            if armed, expected == generation { endSeparation() }
            return
        }
        guard armed, expected == generation, separationStart != nil, mutedReason == nil, !strongFired else { return }
        let now = Date()
        softFired = true
        strongFired = true
        strongFiredAt = now
        lastPulseAt = now
        cancelWatchdogIfNeeded()      // the app is clearly alive, the safety net would only duplicate this
        log.add("Loud alert sent")
        alerts.strong(repeatMinutes: settings.strongRepeatMinutes, style: settings.alertStyle)
        record { $0.strongAlertAt = $0.strongAlertAt ?? now }
    }

    private func pulseIfDue(_ settings: TetherSettings) {
        guard let firedAt = strongFiredAt, !acknowledged, !isHeadingBack else { return }
        let now = Date()
        guard now.timeIntervalSince(firedAt) < Double(settings.strongRepeatMinutes * 60) else { return }
        if let last = lastPulseAt, now.timeIntervalSince(last) < settings.alertStyle.pulseInterval { return }
        lastPulseAt = now
        alerts.pulse(style: settings.alertStyle)
    }

    private func enterMute(_ reason: String) {
        if mutedReason != reason {
            log.add("Staying quiet: \(reason)")
        }
        if mutedReason == nil {
            // Going quiet: stop any live alarm. Alerts start over if the reason later disappears.
            alerts.stopAll()
            softFired = false
            strongFired = false
            strongFiredAt = nil
            lastPulseAt = nil
            cancelWatchdogIfNeeded()
        }
        mutedReason = reason
    }

    /// Saves the open event (first time an alert fires) and syncs it to the phone's history.
    private func record(_ change: (inout LeftBehindEvent) -> Void) {
        guard var event = openEvent else { return }
        change(&event)
        openEvent = event
        events.upsert(event)
        connectivity.send(event)
    }

    // MARK: - Dead-man's switch

    private func armWatchdog(after seconds: TimeInterval, now: Date) {
        alerts.armWatchdog(after: seconds)
        watchdogArmed = true
        lastWatchdogArmAt = now
    }

    private func cancelWatchdogIfNeeded() {
        guard watchdogArmed else { return }
        alerts.cancelWatchdog()
        watchdogArmed = false
    }

    /// While apart and still expecting to alert, keep promising a notification a little after the
    /// alert is due. If this app stops running, that notification still arrives.
    private func keepWatchdogRolling(_ settings: TetherSettings, elapsed: TimeInterval) {
        var target: Double?
        if mutedReason != nil || strongFired {
            target = nil
        } else if settings.strongAlertEnabled {
            target = Double(settings.strongDelaySeconds)
        } else if settings.softAlertEnabled, !softFired {
            target = Double(settings.softDelaySeconds)
        }
        guard let target else {
            cancelWatchdogIfNeeded()
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastWatchdogArmAt) >= 15 else { return }
        armWatchdog(after: max(target - elapsed, 0) + 25, now: now)
    }

    // MARK: - Location

    /// When Bluetooth raises the alerts, GPS only serves safe places and the History map, for which
    /// moderate accuracy is plenty.
    private func wantsPreciseTracking(_ settings: TetherSettings) -> Bool {
        guidanceWanted || isHeadingBack || (settings.detectionMode.preciseTracking && !usesBluetooth)
    }

    private func wantsLocation(_ settings: TetherSettings) -> Bool {
        settings.distanceAlertEnabled || usesSafePlaces(settings)
    }

    private func usesSafePlaces(_ settings: TetherSettings) -> Bool {
        settings.muteInSafePlaces && !settings.safePlaces.isEmpty
    }

    /// Every location reading, from one-shot requests or continuous tracking, lands here.
    private func handleFix(_ fix: GeoFix) {
        latestFix = fix
        guard let start = separationStart else { return }

        if anchor == nil {
            // First good reading after the drop (taken no earlier than shortly before it).
            guard fix.accuracy >= 0, fix.accuracy <= 100,
                  fix.timestamp >= start.addingTimeInterval(-Self.maxAnchorAge) else { return }
            setAnchor(fix)
            return
        }
        if let moved = movedMeters(now: Date()) {
            maxMoved = max(maxMoved, moved)
        }
        if let anchor, fix.accuracy >= 0, fix.accuracy <= Self.maxDistanceAccuracy {
            let distance = Geo.distance(lat1: anchor.latitude, lon1: anchor.longitude,
                                        lat2: fix.latitude, lon2: fix.longitude)
            distanceFromSpot = distance
            furthestFromSpot = max(furthestFromSpot, distance)
            updateHeadingBack(distance)
        }
    }

    /// Turning back means the alert did its job: pause the loud buzzing so the hot/cold guide taps
    /// can lead the way. Walking away again brings the loud alert back.
    private func updateHeadingBack(_ distance: Double) {
        let headingBack: Bool
        if isHeadingBack {
            headingBack = distance < furthestFromSpot - Self.walkingAwayAgainMargin
        } else {
            headingBack = furthestFromSpot >= Self.headingBackMinimumAway
                && distance <= furthestFromSpot - Self.headingBackMargin
        }
        guard headingBack != isHeadingBack else { return }
        isHeadingBack = headingBack
        headingBackSince = headingBack ? Date() : nil
        let settings = settingsStore.settings
        if headingBack {
            log.add("Heading back to your iPhone (\(Int(distance)) m from the spot)")
            if strongFired, !acknowledged {
                alerts.stopAll()
            }
        } else {
            log.add("Walking away again (\(Int(distance)) m from the spot)")
            // Re-arm the furthest point so a later turn-around is measured from here.
            furthestFromSpot = distance
            if strongFired, !acknowledged, mutedReason == nil {
                alerts.strong(repeatMinutes: settings.strongRepeatMinutes, style: settings.alertStyle)
                lastPulseAt = Date()
            }
        }
        applyTrackingPrecision()
    }

    /// The hot/cold guide is active (Find iPhone screen open, or heading back): use precise GPS.
    func setGuidance(_ wanted: Bool) {
        guard wanted != guidanceWanted else { return }
        guidanceWanted = wanted
        applyTrackingPrecision()
    }

    private func applyTrackingPrecision() {
        guard location.isTracking else { return }
        location.setPrecise(wantsPreciseTracking(settingsStore.settings))
    }

    private func setAnchor(_ fix: GeoFix) {
        anchor = fix
        distanceFromSpot = 0
        guard var event = openEvent else { return }
        event.fix = fix
        openEvent = event
        if event.wasAlerted {
            events.upsert(event)
            connectivity.send(event)
        }
    }

    /// How far you have certainly walked from the spot, in metres: the measured distance minus the
    /// reading's own error margin, so a jumpy GPS reading cannot fake a walk-away.
    /// nil if there is no anchor or no fresh, precise reading.
    private func movedMeters(now: Date) -> Double? {
        guard let anchor, let fix = latestFix,
              fix.timestamp > anchor.timestamp,
              now.timeIntervalSince(fix.timestamp) <= Self.maxDistanceFixAge,
              fix.accuracy >= 0, fix.accuracy <= Self.maxDistanceAccuracy else { return nil }
        let raw = Geo.distance(lat1: anchor.latitude, lon1: anchor.longitude,
                               lat2: fix.latitude, lon2: fix.longitude)
        return max(raw - fix.accuracy, 0)
    }

    private func hasUsableFix(now: Date) -> Bool {
        guard let fix = latestFix else { return false }
        return now.timeIntervalSince(fix.timestamp) <= Suppression.maxFixAge
    }

    private func requestFix() {
        guard !fixInFlight else { return }
        fixInFlight = true
        lastFixRequestAt = Date()
        Task { [weak self] in
            guard let self else { return }
            // New readings arrive through location.onUpdate -> handleFix; this only tracks the request.
            _ = await self.location.fix()
            self.fixInFlight = false
        }
    }

    // MARK: - Misc

    /// The user opened DiTether during an alert: they have noticed, so stop the buzzing and the
    /// queued notifications. Watching continues, and a new reason (the link dropping after only a
    /// weak signal) can still raise the loud alert.
    func acknowledgeAlerts() {
        guard separationStart != nil, softFired || strongFired, !acknowledged else { return }
        acknowledged = true
        alerts.stopAll()
        cancelWatchdogIfNeeded()
        log.add("Alert seen on the watch, buzzing stopped")
    }

    /// Called when the app comes to the front, where starting a session is allowed.
    func restartKeepAliveIfNeeded() {
        guard armed, !keepAlive.isRunning else { return }
        lastKeepAliveRetryAt = .distantPast
        ensureKeepAlive(Date())
    }

    private func ensureKeepAlive(_ now: Date) {
        guard !keepAlive.isRunning, now.timeIntervalSince(lastKeepAliveRetryAt) >= 30 else { return }
        lastKeepAliveRetryAt = now
        let session = keepAlive
        Task {
            await session.start()
        }
    }

    private func publishPhase() {
        let next: Phase
        if !armed {
            next = .off
        } else if !connectivity.isActivated || isSettling(reachable: connectivity.liveReachable, now: Date()) {
            next = .starting
        } else if let start = separationStart {
            if let reason = mutedReason {
                next = .muted(since: start, reason: reason)
            } else if strongFired {
                next = .strongAlerted(since: strongFiredAt ?? start)
            } else if softFired {
                next = .softAlerted(since: start)
            } else {
                next = .separated(since: start)
            }
        } else {
            next = .watching
        }
        if next != phase {
            phase = next
        }
    }
}
