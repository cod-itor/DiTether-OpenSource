import CoreLocation
import Foundation

/// A spot on the Places map: where a DiTAG went out of range, or a spot saved with a single
/// press ("I parked here").
struct SavedPlace: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case lost
        case marked
    }

    var id = UUID()
    var kind: Kind
    var date: Date
    var latitude: Double
    var longitude: Double
    var accuracy: Double
    /// The DiTAG involved, for example "Keys".
    var tagName: String?
    /// A short street address, looked up once and kept.
    var address: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var title: String {
        switch kind {
        case .lost: return "\(tagName ?? "DiTAG") left here"
        case .marked: return "Saved spot"
        }
    }
}

/// The last 100 places, newest first, kept on this iPhone only.
@MainActor
final class PlacesStore: ObservableObject {
    @Published private(set) var places: [SavedPlace]
    private let file = JSONFile<[SavedPlace]>(name: "places.json")
    private let geocoder = CLGeocoder()
    private var isLookingUp = false
    private static let cap = 100

    init() {
        places = file.load() ?? []
    }

    /// Adds a place and returns its id.
    @discardableResult
    func add(_ kind: SavedPlace.Kind, fix: GeoFix, tagName: String?) -> UUID {
        let place = SavedPlace(kind: kind, date: Date(), latitude: fix.latitude, longitude: fix.longitude,
                               accuracy: fix.accuracy, tagName: tagName)
        places.insert(place, at: 0)
        if places.count > Self.cap { places.removeLast(places.count - Self.cap) }
        save()
        resolveAddresses()
        return place.id
    }

    /// A better reading for a place saved a moment ago.
    func update(_ id: UUID, fix: GeoFix) {
        guard let index = places.firstIndex(where: { $0.id == id }) else { return }
        places[index].latitude = fix.latitude
        places[index].longitude = fix.longitude
        places[index].accuracy = fix.accuracy
        places[index].address = nil
        save()
        resolveAddresses()
    }

    func remove(_ id: UUID) {
        places.removeAll { $0.id == id }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        places.remove(atOffsets: offsets)
        save()
    }

    func clear() {
        places = []
        file.delete()
    }

    /// The most recent place for a DiTAG.
    func latest(_ kind: SavedPlace.Kind, tagName: String? = nil) -> SavedPlace? {
        places.first { $0.kind == kind && (tagName == nil || $0.tagName == tagName) }
    }

    /// Looks up street names one at a time (Apple limits how often), newest first.
    func resolveAddresses() {
        guard !isLookingUp, let next = places.first(where: { $0.address == nil }) else { return }
        isLookingUp = true
        let location = CLLocation(latitude: next.latitude, longitude: next.longitude)
        Task {
            let placemark = try? await geocoder.reverseGeocodeLocation(location).first
            isLookingUp = false
            guard let index = places.firstIndex(where: { $0.id == next.id }) else { return }
            places[index].address = placemark.map(Self.shortAddress) ?? "Unknown street"
            save()
            // Only keep going while there are recent ones left; old ones resolve when viewed.
            if places.prefix(20).contains(where: { $0.address == nil }) {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                resolveAddresses()
            }
        }
    }

    private static func shortAddress(_ placemark: CLPlacemark) -> String {
        let street = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let first = street.isEmpty ? (placemark.name ?? "") : street
        return [first, placemark.locality].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func save() {
        file.save(places)
    }
}
