import Foundation

/// A short, on-device record of what the watch decided and why, readable in watch Settings.
/// Only state changes are written (never every successful ping), so it stays small and cheap.
@MainActor
final class ConnectionLog: ObservableObject {
    struct Entry: Codable, Identifiable {
        var id = UUID()
        var date: Date
        var text: String
    }

    @Published private(set) var entries: [Entry] = []
    private let file = JSONFile<[Entry]>(name: "connection-log.json")
    private let cap = 150

    init() {
        entries = file.load() ?? []
    }

    func add(_ text: String) {
        entries.insert(Entry(date: Date(), text: text), at: 0)
        if entries.count > cap {
            entries.removeLast(entries.count - cap)
        }
        file.save(entries)
    }

    func clear() {
        entries = []
        file.delete()
    }
}
