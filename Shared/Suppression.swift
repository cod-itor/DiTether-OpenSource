import Foundation

/// Pure decision logic: "should we stay quiet right now, and why?"
/// No UI, no hardware, so it is easy to reason about (and to unit test later).
enum Suppression {

    /// A reading less precise than this is never trusted to mute an alert.
    static let maxTrustedAccuracy: Double = 150
    /// A reading older than this is never trusted to mute an alert.
    static let maxFixAge: TimeInterval = 10 * 60

    /// The reason to stay quiet, or nil if alerts should go ahead.
    /// Order matters: snooze, then quiet hours, then safe places.
    static func reason(settings: TetherSettings,
                       now: Date = Date(),
                       fix: GeoFix?,
                       calendar: Calendar = .current) -> String? {
        if settings.isSnoozed(at: now) {
            return "Snoozed"
        }
        if settings.quietHoursEnabled,
           isQuiet(now: now,
                   startMinute: settings.quietStartMinute,
                   endMinute: settings.quietEndMinute,
                   calendar: calendar) {
            return "Quiet hours"
        }
        if settings.muteInSafePlaces, let place = safePlace(for: fix, in: settings.safePlaces, now: now) {
            return "At \(place.name)"
        }
        return nil
    }

    /// True if `now` falls inside the quiet window. Handles windows that cross midnight (22:00 to 07:00).
    static func isQuiet(now: Date, startMinute: Int, endMinute: Int, calendar: Calendar = .current) -> Bool {
        if startMinute == endMinute { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute < endMinute {
            return minute >= startMinute && minute < endMinute
        }
        return minute >= startMinute || minute < endMinute
    }

    /// The safe place the fix is inside, if the fix is fresh and precise enough to trust.
    static func safePlace(for fix: GeoFix?, in places: [SafePlace], now: Date = Date()) -> SafePlace? {
        guard let fix, !places.isEmpty else { return nil }
        guard fix.accuracy >= 0, fix.accuracy <= maxTrustedAccuracy else { return nil }
        guard now.timeIntervalSince(fix.timestamp) <= maxFixAge else { return nil }
        return places.first { place in
            Geo.distance(lat1: fix.latitude, lon1: fix.longitude,
                         lat2: place.latitude, lon2: place.longitude) <= place.radius
        }
    }
}

enum Geo {
    /// Great-circle distance in metres (haversine).
    static func distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
