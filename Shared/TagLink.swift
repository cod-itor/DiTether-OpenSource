import Foundation

/// One of the iPhone's DiTAGs as the watch shows it. Sent live in reply to a `TagRequest` and never
/// stored on the watch: the iPhone stays the only owner of DiTAG data.
struct WatchTagInfo: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        case withYou
        case leftBehind
        case connecting
        case off
        /// Quiet mode: disconnected on purpose for a while.
        case quiet
    }

    var id: UUID
    var name: String
    var state: State
    var battery: Int?
    var isBeeping: Bool
    /// When it was left behind.
    var since: Date?
}

/// Watch -> iPhone, live only. The iPhone answers every request with the current list of DiTAGs.
enum TagRequest: Codable, Equatable {
    case list
    case beep(UUID)
    case stopBeep(UUID)
}
