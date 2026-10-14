import Foundation

/// One DiTAG the user set up, for example on their keys.
struct DiTag: Codable, Equatable, Identifiable {
    /// The iOS Bluetooth identifier of this DiTAG (stable on this iPhone).
    var id: UUID
    /// Shown everywhere, for example "Keys left behind".
    var name: String
    /// This DiTAG's switch. Off = no Bluetooth connection and nothing running for it.
    var isEnabled = true
    /// No left-behind alerts until then.
    var snoozedUntil: Date?
    /// No left-behind alerts until it is back in range ("I'm leaving it here on purpose").
    var snoozedUntilBack = false

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    /// The name as shown, never empty.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "DiTAG" : trimmed
    }

    func isSnoozed(at date: Date = Date()) -> Bool {
        if snoozedUntilBack { return true }
        if let until = snoozedUntil { return until > date }
        return false
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "DiTAG"
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        snoozedUntil = try? c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        snoozedUntilBack = (try? c.decodeIfPresent(Bool.self, forKey: .snoozedUntilBack)) ?? false
    }
}

/// DiTAG settings. iPhone only: stored in their own file and never sent to the watch.
struct DiTagSettings: Codable, Equatable {
    var tags: [DiTag] = []
    // Shared by every DiTAG:
    var ringOnDoublePress = true
    /// Remember where the iPhone was when a DiTAG went out of range.
    var saveLocation = true
    /// How long a DiTAG may be out of range before the alert, so a blip at the edge of range stays
    /// quiet. Kept short enough to fit the background time iOS gives after a disconnect.
    var graceSeconds = 5

    static let graceRange = 0...30
    /// iOS keeps only a handful of Bluetooth connections at once (the watch uses one as well).
    static let maxTags = 8

    var hasTags: Bool { !tags.isEmpty }

    func tag(_ id: UUID) -> DiTag? {
        tags.first { $0.id == id }
    }

    /// A name that is not taken yet: Keys, Bag, Wallet, then DiTAG 4, 5…
    var suggestedName: String {
        let taken = Set(tags.map { $0.displayName.lowercased() })
        for name in ["Keys", "Bag", "Wallet"] where !taken.contains(name.lowercased()) {
            return name
        }
        var number = tags.count + 1
        while taken.contains("ditag \(number)") { number += 1 }
        return "DiTAG \(number)"
    }

    var sanitized: DiTagSettings {
        var copy = self
        copy.graceSeconds = min(max(graceSeconds, Self.graceRange.lowerBound), Self.graceRange.upperBound)
        for index in copy.tags.indices {
            copy.tags[index].name = String(copy.tags[index].name.prefix(30))
        }
        return copy
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case tags, ringOnDoublePress, saveLocation, graceSeconds
        // From the first, single-DiTAG version; read once and moved into `tags`.
        case savedPeripheralID, name, isEnabled, snoozedUntil, snoozedUntilBack
    }

    /// Missing fields fall back to their defaults, and a file from the single-DiTAG version becomes
    /// a list with that one DiTAG, so nothing set up before is lost.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ target: inout T) {
            if let value = try? c.decodeIfPresent(T.self, forKey: key) { target = value }
        }
        read(.tags, &tags)
        read(.ringOnDoublePress, &ringOnDoublePress)
        read(.saveLocation, &saveLocation)
        read(.graceSeconds, &graceSeconds)
        if tags.isEmpty, let legacyID = try? c.decodeIfPresent(UUID.self, forKey: .savedPeripheralID) {
            var tag = DiTag(id: legacyID, name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Keys")
            read(.isEnabled, &tag.isEnabled)
            tag.snoozedUntil = try? c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
            read(.snoozedUntilBack, &tag.snoozedUntilBack)
            tags = [tag]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tags, forKey: .tags)
        try c.encode(ringOnDoublePress, forKey: .ringOnDoublePress)
        try c.encode(saveLocation, forKey: .saveLocation)
        try c.encode(graceSeconds, forKey: .graceSeconds)
    }
}

@MainActor
final class DiTagSettingsStore: ObservableObject {
    @Published private(set) var settings: DiTagSettings
    private let file = JSONFile<DiTagSettings>(name: "ditag-settings.json")

    init() {
        settings = (file.load() ?? DiTagSettings()).sanitized
    }

    @discardableResult
    func edit(_ change: (inout DiTagSettings) -> Void) -> DiTagSettings {
        var updated = settings
        change(&updated)
        updated = updated.sanitized
        guard updated != settings else { return settings }
        settings = updated
        file.save(updated)
        return updated
    }

    func editTag(_ id: UUID, _ change: (inout DiTag) -> Void) {
        edit { settings in
            if let index = settings.tags.firstIndex(where: { $0.id == id }) {
                change(&settings.tags[index])
            }
        }
    }
}
