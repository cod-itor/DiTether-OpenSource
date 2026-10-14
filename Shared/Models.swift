import Foundation

// MARK: - Location

/// A place where being apart from your iPhone is normal (home, office).
struct SafePlace: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    /// Radius in metres.
    var radius: Double = 100
}

/// One location reading, kept small and Codable so it can travel between watch and phone.
struct GeoFix: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    /// Horizontal accuracy in metres (smaller is better).
    var accuracy: Double
    var timestamp: Date
}

// MARK: - Detection mode

/// How hard the devices work to notice the iPhone is gone: faster detection costs more battery.
/// The watch's background session runs in every mode; without it nothing can be noticed at all.
enum DetectionMode: String, Codable, CaseIterable, Identifiable {
    case fast
    case balanced
    case saver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .saver: return "Battery Saver"
        }
    }

    var summary: String {
        switch self {
        case .fast:
            return "Notices within about 5 to 15 seconds, even over Wi-Fi. Uses the most battery on both devices."
        case .balanced:
            return "Notices within about 15 to 30 seconds, even over Wi-Fi. Moderate battery use."
        case .saver:
            return "Notices within about 30 to 60 seconds once the connection drops. May miss it while both devices share Wi-Fi. Lightest on battery."
        }
    }

    var symbol: String {
        switch self {
        case .fast: return "hare.fill"
        case .balanced: return "gauge.with.dots.needle.50percent"
        case .saver: return "leaf.fill"
        }
    }

    /// How often the watch pings the iPhone while together (signal 2). Two misses in a row mean apart.
    var pingInterval: TimeInterval {
        switch self {
        case .fast: return 5
        case .balanced: return 10
        case .saver: return 30
        }
    }

    /// How often the watch reads its own position while together, to compare with the iPhone's (signal 5).
    /// nil = not compared while together.
    var togetherFixInterval: TimeInterval? {
        switch self {
        case .fast: return 10
        case .balanced: return 30
        case .saver: return nil
        }
    }

    /// Seconds between Bluetooth signal-strength readings.
    /// A dropped link is an instant event in every mode; this only sets how soon a fading signal is noticed.
    var bluetoothReadInterval: TimeInterval {
        switch self {
        case .fast: return 3
        case .balanced: return 5
        case .saver: return 10
        }
    }

    /// Whether the iPhone shares its position with the watch (signal 5).
    var sharesPhoneLocation: Bool { self != .saver }

    /// The iPhone sends a new position after moving this far.
    var phoneDistanceFilter: Double {
        self == .fast ? 5 : 20
    }

    /// GPS precision while apart (signal 3). Battery Saver accepts coarser readings.
    var preciseTracking: Bool { self != .saver }
}

// MARK: - Settings

/// Everything the user can tune. The iPhone is the comfortable editor, the watch enforces it.
/// Both sides keep a copy; the copy with the newest `updatedAt` wins.
struct TetherSettings: Codable, Equatable {
    /// Master switch. Off = no background session, no alerts, no battery use.
    var protectionEnabled = true

    /// Speed versus battery for noticing that the iPhone is gone.
    var detectionMode: DetectionMode = .balanced

    /// Tier 1: a gentle tap shortly after the link drops.
    var softAlertEnabled = true
    var softDelaySeconds = 10

    /// Tier 2: strong, repeating alert if the link stays gone.
    var strongAlertEnabled = true
    var strongDelaySeconds = 60
    var strongRepeatMinutes = 5

    /// Distance escalation. When the link drops, the watch remembers where it was (that is where the
    /// iPhone probably is). Walking half this distance away gives the gentle tap, the full distance
    /// gives the strong alert right away, without waiting for the timers above. The timers stay as
    /// the fallback when no good location reading is available.
    var distanceAlertEnabled = true
    /// Use Tether's own direct Bluetooth link: a fading signal gives the first reminder, a dropped
    /// link the loud alert. Cannot be fooled by Wi-Fi or iCloud keeping the devices "connected".
    var bluetoothRangeEnabled = true
    /// How strongly the watch vibrates.
    var alertStyle: AlertStyle = .standard
    var distanceAlertMeters = 60

    /// Where and when to stay quiet.
    var muteInSafePlaces = true
    var safePlaces: [SafePlace] = []
    var quietHoursEnabled = false
    var quietStartMinute = 22 * 60   // minutes after midnight
    var quietEndMinute = 7 * 60

    /// "I left it on purpose." Alerts resume when this passes.
    var snoozedUntil: Date?
    /// When the snooze was last set or cleared. Synced separately from `updatedAt`, so silencing on
    /// the watch is not lost if the iPhone edits something else before the two devices meet.
    var snoozeUpdatedAt: Date = .distantPast

    /// Conflict resolution between the phone and watch copies (last writer wins).
    var updatedAt: Date = .distantPast

    func isSnoozed(at date: Date = Date()) -> Bool {
        guard let until = snoozedUntil else { return false }
        return until > date
    }

    /// Clamps values into sane ranges so a bad edit can never produce nonsense timings.
    var sanitized: TetherSettings {
        var s = self
        s.softDelaySeconds = min(max(s.softDelaySeconds, 5), 120)
        s.strongDelaySeconds = min(max(s.strongDelaySeconds, s.softDelaySeconds + 10), 600)
        s.strongRepeatMinutes = min(max(s.strongRepeatMinutes, 1), 30)
        s.distanceAlertMeters = min(max(s.distanceAlertMeters, 30), 500)
        s.quietStartMinute = min(max(s.quietStartMinute, 0), 1439)
        s.quietEndMinute = min(max(s.quietEndMinute, 0), 1439)
        s.safePlaces = s.safePlaces.map { place in
            var p = place
            p.radius = min(max(p.radius, 50), 1000)
            return p
        }
        return s
    }
}

extension TetherSettings {
    enum CodingKeys: String, CodingKey {
        case protectionEnabled, detectionMode
        case softAlertEnabled, softDelaySeconds
        case strongAlertEnabled, strongDelaySeconds, strongRepeatMinutes
        case distanceAlertEnabled, distanceAlertMeters, bluetoothRangeEnabled, alertStyle
        case muteInSafePlaces, safePlaces, quietHoursEnabled, quietStartMinute, quietEndMinute
        case snoozedUntil, snoozeUpdatedAt, updatedAt
    }

    /// Every field falls back to its default when missing, so adding a setting in a later version
    /// never throws away the saved file (safe places included), and the watch and iPhone can sync
    /// even if one of them runs an older build.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let decoded = try? c.decodeIfPresent(T.self, forKey: key) { value = decoded }
        }
        read(.protectionEnabled, &protectionEnabled)
        read(.detectionMode, &detectionMode)
        read(.softAlertEnabled, &softAlertEnabled)
        read(.softDelaySeconds, &softDelaySeconds)
        read(.strongAlertEnabled, &strongAlertEnabled)
        read(.strongDelaySeconds, &strongDelaySeconds)
        read(.strongRepeatMinutes, &strongRepeatMinutes)
        read(.distanceAlertEnabled, &distanceAlertEnabled)
        read(.bluetoothRangeEnabled, &bluetoothRangeEnabled)
        read(.alertStyle, &alertStyle)
        read(.distanceAlertMeters, &distanceAlertMeters)
        read(.muteInSafePlaces, &muteInSafePlaces)
        read(.safePlaces, &safePlaces)
        read(.quietHoursEnabled, &quietHoursEnabled)
        read(.quietStartMinute, &quietStartMinute)
        read(.quietEndMinute, &quietEndMinute)
        snoozedUntil = try? c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        read(.snoozeUpdatedAt, &snoozeUpdatedAt)
        read(.updatedAt, &updatedAt)
    }
}

// MARK: - Events

/// One "my phone dropped off" episode. Created on the watch, synced to the phone's history.
/// It is only recorded once an alert actually fired, so short Bluetooth blips never show up.
struct LeftBehindEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    /// When the link dropped.
    var startedAt: Date
    var softAlertAt: Date?
    var strongAlertAt: Date?
    /// When the link came back. nil = still apart.
    var resolvedAt: Date?
    /// Where the watch was when the link dropped, which is where the iPhone probably is.
    var fix: GeoFix?
    /// True if walking away (not a timer) triggered the first alert.
    var escalatedByDistance: Bool?
    /// Furthest you got from the spot during this episode, in metres.
    var maxDistance: Double?
    /// What was left behind: nil = the iPhone (created by the watch). Otherwise the DiTAG's name,
    /// for example "Keys". Only the iPhone sets it; older files and watch events decode it as nil.
    var item: String?

    var wasAlerted: Bool { softAlertAt != nil || strongAlertAt != nil }
    var isOpen: Bool { resolvedAt == nil }
    var duration: TimeInterval? { resolvedAt.map { $0.timeIntervalSince(startedAt) } }
}

// MARK: - Watch status

/// What the watch reports about itself, so the iPhone can show an honest status instead of guessing.
/// Sent from the watch whenever it changes; the newest `sentAt` wins.
struct WatchStatus: Codable, Equatable {
    /// The user went through the intro on the watch and permissions were requested.
    var isSetUp: Bool
    /// The background session is running, so the watch is actually checking the link.
    var isProtecting: Bool
    /// Why protection could not start (for example Workout access was denied), if it is on but not running.
    var problem: String?
    /// The watch's own Bluetooth link to the iPhone works, so the iPhone does not need to share its
    /// location (saves iPhone battery). nil from older builds = unknown, keep sharing.
    var bluetoothLinked: Bool?
    var sentAt: Date = .distantPast
}

// MARK: - Remote commands

/// Live requests between the devices, answered right away or not at all (never queued).
enum RemoteCommand: String, Codable {
    /// Watch -> iPhone: play a sound so you can find the iPhone.
    case ringPhone
    case stopRingingPhone
    /// iPhone -> watch: buzz and beep so you can find the watch.
    case ringWatch
    case stopRingingWatch
}

// MARK: - Alert style

/// How strongly the watch vibrates for alerts.
enum AlertStyle: String, Codable, CaseIterable, Identifiable {
    case light
    case standard
    case persistent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .standard: return "Standard"
        case .persistent: return "Persistent"
        }
    }

    var summary: String {
        switch self {
        case .light: return "Single taps. Easy to miss when busy."
        case .standard: return "A tap, then strong repeating buzzes."
        case .persistent: return "Strong buzzes twice as often, for longer."
        }
    }

    /// Seconds between buzz bursts while the loud alert is on.
    var pulseInterval: TimeInterval {
        self == .persistent ? 4 : 8
    }

    /// Seconds between the backup notifications that keep the loud alert going if the app sleeps.
    var repeatNotificationInterval: TimeInterval {
        self == .persistent ? 8 : 12
    }
}

// MARK: - Test alert

/// Which alert the "send a test alert" button plays on the watch.
enum TestAlertLevel: String, Codable, Identifiable {
    case firstReminder
    case loud

    var id: String { rawValue }
}
