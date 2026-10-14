import Foundation

/// Tiny JSON-file persistence. Lives in Application Support, never leaves the device,
/// and is excluded from iCloud/iTunes backups (location history stays private).
final class JSONFile<T: Codable> {
    private let url: URL

    init(name: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent(name)
    }

    func load() -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save(_ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The user's settings, persisted. Local edits stamp `updatedAt`; remote copies only win if newer.
@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: TetherSettings
    private let file = JSONFile<TetherSettings>(name: "settings.json")

    init() {
        settings = (file.load() ?? TetherSettings()).sanitized
    }

    /// Apply a local edit. Returns the stored result so the caller can sync it to the other device.
    @discardableResult
    func edit(_ change: (inout TetherSettings) -> Void) -> TetherSettings {
        var updated = settings
        change(&updated)
        updated = updated.sanitized
        let now = Date()
        updated.updatedAt = now
        if updated.snoozedUntil != settings.snoozedUntil {
            updated.snoozeUpdatedAt = now
        }
        settings = updated
        file.save(updated)
        return updated
    }

    /// Merge the other device's copy: the newer copy wins, except the snooze, which comes from
    /// whichever side changed it last. Both devices merge the same way, so they end up identical.
    /// Returns true if anything changed.
    @discardableResult
    func adopt(_ remote: TetherSettings) -> Bool {
        var merged = remote.updatedAt > settings.updatedAt ? remote.sanitized : settings
        let snoozeSource = remote.snoozeUpdatedAt > settings.snoozeUpdatedAt ? remote : settings
        merged.snoozedUntil = snoozeSource.snoozedUntil
        merged.snoozeUpdatedAt = snoozeSource.snoozeUpdatedAt
        guard merged != settings else { return false }
        settings = merged
        file.save(settings)
        return true
    }
}

/// The history of left-behind episodes, newest first.
@MainActor
final class EventStore: ObservableObject {
    @Published private(set) var events: [LeftBehindEvent] = []
    private let file: JSONFile<[LeftBehindEvent]>
    private let cap: Int

    init(fileName: String, cap: Int) {
        self.file = JSONFile<[LeftBehindEvent]>(name: fileName)
        self.cap = cap
        self.events = file.load() ?? []
        sortAndTrim()
    }

    /// Insert a new event or replace the one with the same id (events are updated when they resolve).
    func upsert(_ event: LeftBehindEvent) {
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index] = event
        } else {
            events.append(event)
        }
        sortAndTrim()
        file.save(events)
    }

    func remove(id: UUID) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events.remove(at: index)
        file.save(events)
    }

    func clear() {
        events = []
        file.delete()
    }

    private func sortAndTrim() {
        events.sort { $0.startedAt > $1.startedAt }
        if events.count > cap {
            events = Array(events.prefix(cap))
        }
    }
}
