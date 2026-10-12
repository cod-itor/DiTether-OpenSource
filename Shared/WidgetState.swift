import Foundation

/// What the watch face complication shows. The watch app writes it to the shared App Group; the
/// widget extension reads it. Kept tiny so writing it on every state change is cheap.
struct WidgetState: Codable, Equatable {
    enum Status: String, Codable {
        case protected
        case apart
        case alerting
        case quiet
        case off
    }

    var status: Status
    var updatedAt: Date

    static let key = "ditether.widgetState"

    /// The App Group shared by the watch app and its widget, read from Info.plist so it follows
    /// the bundle prefix in Config/Local.xcconfig.
    static var defaults: UserDefaults? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "DiTetherAppGroup") as? String else { return nil }
        return UserDefaults(suiteName: group)
    }

    static func load() -> WidgetState {
        guard let data = defaults?.data(forKey: key),
              let state = try? JSONDecoder().decode(WidgetState.self, from: data) else {
            return WidgetState(status: .off, updatedAt: .distantPast)
        }
        return state
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.defaults?.set(data, forKey: Self.key)
    }
}
