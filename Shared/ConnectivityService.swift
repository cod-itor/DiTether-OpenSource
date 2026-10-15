import Foundation
import WatchConnectivity

/// How data is packed for WatchConnectivity: one `Data` blob per message, so nothing
/// non-Sendable ever has to cross threads.
enum Wire {
    static let key = "p"

    enum Kind: String, Codable {
        case settings
        case event
        case status
        case testAlert
        case command
        case tagRequest
    }

    struct Envelope: Codable {
        var kind: Kind
        var body: Data
    }

    static let pingData = Data("ping".utf8)
    static let pongData = Data("pong".utf8)

    static func pack<T: Encodable>(_ kind: Kind, _ value: T) -> [String: Any]? {
        guard let body = try? JSONEncoder().encode(value),
              let data = try? JSONEncoder().encode(Envelope(kind: kind, body: body)) else { return nil }
        return [key: data]
    }

    static func unpack<T: Decodable>(_ type: T.Type, kind: Kind, from dictionary: [String: Any]) -> T? {
        guard let data = dictionary[key] as? Data,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.kind == kind else { return nil }
        return try? JSONDecoder().decode(T.self, from: envelope.body)
    }

    static func kind(of dictionary: [String: Any]) -> Kind? {
        guard let data = dictionary[key] as? Data else { return nil }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.kind
    }
}

/// Makes sure a continuation is resumed exactly once, whichever callback gets there first.
private final class OneShot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// The iPhone's latest location, handed to the watch in every ping reply so the watch can measure
/// how far apart the two really are. Written on the main actor, read on WatchConnectivity's queue.
final class SharedPhoneFix: @unchecked Sendable {
    static let shared = SharedPhoneFix()
    private let lock = NSLock()
    private var fix: GeoFix?

    var value: GeoFix? {
        get { lock.lock(); defer { lock.unlock() }; return fix }
        set { lock.lock(); fix = newValue; lock.unlock() }
    }
}

/// The one place that talks to WatchConnectivity, on both the watch and the phone.
///
/// - Settings travel as the *application context* (latest value wins, delivered when possible).
/// - Events travel as *user info* (queued, guaranteed, delivered in order once the devices meet again).
/// - Nothing needs the internet: it all goes over the Bluetooth link between the two devices.
@MainActor
final class ConnectivityService: NSObject, ObservableObject {
    static let shared = ConnectivityService()

    @Published private(set) var isReachable = false
    @Published private(set) var isActivated = false
    /// True once activation has finished, whether it worked or not, so the UI can stop saying "connecting".
    @Published private(set) var hasFinishedActivating = false
    @Published private(set) var lastHeardFromPeer: Date?
    #if os(iOS)
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    #endif

    var onSettings: ((TetherSettings) -> Void)?
    var onEvent: ((LeftBehindEvent) -> Void)?
    var onStatus: ((WatchStatus) -> Void)?
    var onReachability: ((Bool) -> Void)?
    var onActivated: (() -> Void)?
    var onTestAlert: ((TestAlertLevel) -> Void)?
    var onCommand: ((RemoteCommand) -> Void)?
    /// iPhone side: answers the watch's DiTAG screen with the current list.
    var onTagRequest: ((TagRequest) -> [WatchTagInfo])?
    /// How long the latest answered ping took. Bluetooth and local Wi-Fi answer in well under a
    /// second; a relay through iCloud is usually much slower.
    private(set) var lastProbeRoundTrip: TimeInterval?

    /// The iPhone's location from the latest ping reply, and when it arrived (watch side).
    private(set) var lastPhoneFix: GeoFix?
    private(set) var lastPhoneFixAt: Date?

    private var started = false
    /// Settings that still have to be handed to WatchConnectivity. Kept until that succeeds, because
    /// it fails while the other app is not installed yet (typical during first setup).
    private var pendingSettings: TetherSettings?

    override init() {
        super.init()
    }

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    func start() {
        guard !started else { return }
        guard let session else {
            hasFinishedActivating = true
            return
        }
        started = true
        session.delegate = self
        session.activate()
    }

    /// Reads the flag straight from the system rather than the cached @Published copy.
    var liveReachable: Bool {
        session?.isReachable ?? false
    }

    func push(_ settings: TetherSettings) {
        pendingSettings = settings
        flushSettings()
    }

    /// Retried whenever delivery might have become possible: activation, the watch app getting
    /// installed, or the other side becoming reachable.
    private func flushSettings() {
        guard let settings = pendingSettings,
              let session, session.activationState == .activated,
              let payload = Wire.pack(.settings, settings) else { return }
        #if os(iOS)
        guard session.isPaired, session.isWatchAppInstalled else { return }
        #endif
        do {
            try session.updateApplicationContext(payload)
            pendingSettings = nil
        } catch {
            // Keep it pending; the next trigger tries again.
        }
    }

    func send(_ event: LeftBehindEvent) {
        guard let session, session.activationState == .activated,
              let payload = Wire.pack(.event, event) else { return }
        session.transferUserInfo(payload)
    }

    /// Queued like events, so it arrives even if the iPhone app is not running right now.
    /// Older status reports still waiting in the queue are dropped, only the newest matters.
    func send(_ status: WatchStatus) {
        guard let session, session.activationState == .activated,
              let payload = Wire.pack(.status, status) else { return }
        for transfer in session.outstandingUserInfoTransfers where Wire.kind(of: transfer.userInfo) == .status {
            transfer.cancel()
        }
        session.transferUserInfo(payload)
    }

    #if os(iOS)
    /// Asks the watch to play a sample alert. True if the watch confirmed it.
    /// Live only: a test alert that arrives hours later would be confusing, so nothing is queued.
    func sendTestAlert(_ level: TestAlertLevel, timeout: TimeInterval = 6) async -> Bool {
        await sendLive(.testAlert, level, timeout: timeout)
    }
    #endif

    /// Sends a live command to the other device. True if it confirmed receiving it.
    func send(_ command: RemoteCommand, timeout: TimeInterval = 6) async -> Bool {
        await sendLive(.command, command, timeout: timeout)
    }

    #if os(watchOS)
    /// Asks the iPhone for its DiTAGs (and to beep one). nil if the iPhone did not answer.
    func request(_ tagRequest: TagRequest, timeout: TimeInterval = 5) async -> [WatchTagInfo]? {
        guard let session, session.activationState == .activated, session.isReachable,
              let payload = Wire.pack(.tagRequest, tagRequest),
              let data = payload[Wire.key] as? Data else { return nil }
        let reply = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            Self.sendQuery(data, on: session, timeout: timeout, gate: OneShot(continuation))
        }
        guard let reply else { return nil }
        lastHeardFromPeer = Date()
        return try? JSONDecoder().decode([WatchTagInfo].self, from: reply)
    }

    private nonisolated static func sendQuery(_ data: Data, on session: WCSession, timeout: TimeInterval,
                                              gate: OneShot<Data?>) {
        session.sendMessage([Wire.key: data],
                            replyHandler: { reply in gate.finish(reply[Wire.key] as? Data) },
                            errorHandler: { _ in gate.finish(nil) })
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.finish(nil) }
    }
    #endif

    private func sendLive<T: Encodable>(_ kind: Wire.Kind, _ value: T, timeout: TimeInterval) async -> Bool {
        guard let session, session.activationState == .activated, session.isReachable,
              let payload = Wire.pack(kind, value),
              let data = payload[Wire.key] as? Data else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Self.sendCommand(data, on: session, timeout: timeout, gate: OneShot(continuation))
        }
    }

    private nonisolated static func sendCommand(_ data: Data, on session: WCSession, timeout: TimeInterval, gate: OneShot<Bool>) {
        session.sendMessage([Wire.key: data],
                            replyHandler: { _ in gate.finish(true) },
                            errorHandler: { _ in gate.finish(false) })
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.finish(false) }
    }

    /// True if the other device answers a live ping right now.
    /// Cheap insurance against a stale reachability flag, used just before waking the user.
    /// The iPhone's reply carries its location when it has one, saved in `lastPhoneFix`.
    func probe(timeout: TimeInterval = 4) async -> Bool {
        guard let session, session.activationState == .activated, session.isReachable else { return false }
        let sentAt = Date()
        let reply = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            Self.sendPing(on: session, timeout: timeout, gate: OneShot(continuation))
        }
        guard let reply else { return false }
        lastProbeRoundTrip = Date().timeIntervalSince(sentAt)
        if reply != Wire.pongData, let fix = try? JSONDecoder().decode(GeoFix.self, from: reply) {
            lastPhoneFix = fix
            lastPhoneFixAt = Date()
        }
        return true
    }

    // Built in a nonisolated context on purpose: WatchConnectivity calls these closures on its own queue.
    private nonisolated static func sendPing(on session: WCSession, timeout: TimeInterval, gate: OneShot<Data?>) {
        session.sendMessageData(Wire.pingData,
                                replyHandler: { data in gate.finish(data) },
                                errorHandler: { _ in gate.finish(nil) })
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.finish(nil) }
    }

    private func setReachable(_ reachable: Bool) {
        let changed = reachable != isReachable
        isReachable = reachable
        if changed { onReachability?(reachable) }
        if reachable { flushSettings() }
    }
}

// MARK: - WCSessionDelegate

extension ConnectivityService: WCSessionDelegate {

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let activated = activationState == .activated
        let reachable = session.isReachable
        let latest = Wire.unpack(TetherSettings.self, kind: .settings, from: session.receivedApplicationContext)
        #if os(iOS)
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        #endif
        Task { @MainActor in
            self.isActivated = activated
            self.hasFinishedActivating = true
            #if os(iOS)
            self.isPaired = paired
            self.isWatchAppInstalled = installed
            #endif
            self.flushSettings()
            self.setReachable(reachable)
            if let latest {
                self.lastHeardFromPeer = Date()
                self.onSettings?(latest)
            }
            if activated { self.onActivated?() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.setReachable(reachable)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let settings = Wire.unpack(TetherSettings.self, kind: .settings, from: applicationContext) else { return }
        Task { @MainActor in
            self.lastHeardFromPeer = Date()
            self.onSettings?(settings)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let event = Wire.unpack(LeftBehindEvent.self, kind: .event, from: userInfo) {
            Task { @MainActor in
                self.lastHeardFromPeer = Date()
                self.onEvent?(event)
            }
        } else if let status = Wire.unpack(WatchStatus.self, kind: .status, from: userInfo) {
            Task { @MainActor in
                self.lastHeardFromPeer = Date()
                self.onStatus?(status)
            }
        }
    }

    /// Live requests: the test alert and the ring / stop commands.
    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        // The watch's DiTAG screen: answered with the list, after doing what it asked.
        if let tagRequest = Wire.unpack(TagRequest.self, kind: .tagRequest, from: message) {
            Task { @MainActor in
                self.lastHeardFromPeer = Date()
                let tags = self.onTagRequest?(tagRequest) ?? []
                replyHandler([Wire.key: (try? JSONEncoder().encode(tags)) ?? Data()])
            }
            return
        }
        let level = Wire.unpack(TestAlertLevel.self, kind: .testAlert, from: message)
        let command = Wire.unpack(RemoteCommand.self, kind: .command, from: message)
        replyHandler([:])
        guard level != nil || command != nil else { return }
        Task { @MainActor in
            self.lastHeardFromPeer = Date()
            if let level { self.onTestAlert?(level) }
            if let command { self.onCommand?(command) }
        }
    }

    /// Answers the watch's live ping, with the iPhone's location when it is sharing one.
    nonisolated func session(_ session: WCSession,
                             didReceiveMessageData messageData: Data,
                             replyHandler: @escaping (Data) -> Void) {
        if let fix = SharedPhoneFix.shared.value, let data = try? JSONEncoder().encode(fix) {
            replyHandler(data)
        } else {
            replyHandler(Wire.pongData)
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Switching to a different paired watch: re-activate so the new one can connect.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        Task { @MainActor in
            self.isPaired = paired
            self.isWatchAppInstalled = installed
            // The watch app may have just been installed: settings that failed earlier can go now.
            self.flushSettings()
        }
    }
    #endif
}
