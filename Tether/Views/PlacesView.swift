import MapKit
import SwiftUI

/// Places: where DiTAGs were left (orange) and spots saved with a press (blue), on a map and in a
/// list, newest first. Tap a row to centre it, swipe to delete, or get directions.
struct PlacesView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var position: MapCameraPosition = .automatic
    @State private var selection: UUID?
    @State private var confirmClear = false

    private var places: [SavedPlace] { model.places.places }

    var body: some View {
        Group {
            if places.isEmpty {
                ContentUnavailableView {
                    Label("No places yet", systemImage: "map")
                } description: {
                    Text("Press a DiTAG once to save where you are, like where you parked. Where a DiTAG gets left behind shows up here too.")
                } actions: {
                    Button("Save this spot") { model.diTag.saveSpot() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.brand)
                }
            } else {
                List {
                    Section {
                        map
                            .frame(height: 280)
                            .listRowInsets(EdgeInsets())
                    }
                    Section {
                        ForEach(places) { place in
                            Button {
                                focus(place)
                            } label: {
                                PlaceRow(place: place, isSelected: selection == place.id)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .leading) {
                                Button {
                                    directions(to: place)
                                } label: {
                                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                                }
                                .tint(.blue)
                            }
                        }
                        .onDelete { model.places.remove(atOffsets: $0) }
                    } footer: {
                        Text("Swipe right for directions, left to delete. Places stay on this iPhone.")
                    }
                }
            }
        }
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        model.diTag.saveSpot()
                    } label: {
                        Label("Save this spot", systemImage: "mappin.and.ellipse")
                    }
                    if !places.isEmpty {
                        Button(role: .destructive) {
                            confirmClear = true
                        } label: {
                            Label("Clear all places", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .confirmationDialog("Clear all places?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear places", role: .destructive) { model.places.clear() }
        }
        .onAppear { model.places.resolveAddresses() }
    }

    private var map: some View {
        Map(position: $position, selection: $selection) {
            ForEach(places.prefix(50)) { place in
                Marker(place.kind == .lost ? (place.tagName ?? "DiTAG") : "Spot",
                       systemImage: place.kind == .lost ? "tag.fill" : "mappin",
                       coordinate: place.coordinate)
                    .tint(place.kind == .lost ? Color.orange : Color.blue)
                    .tag(place.id)
            }
            UserAnnotation()
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
    }

    private func focus(_ place: SavedPlace) {
        selection = place.id
        withAnimation {
            position = .region(MKCoordinateRegion(center: place.coordinate,
                                                  latitudinalMeters: 300, longitudinalMeters: 300))
        }
    }

    private func directions(to place: SavedPlace) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
        item.name = place.title
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}

private struct PlaceRow: View {
    let place: SavedPlace
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: place.kind == .lost ? "tag.fill" : "mappin.and.ellipse",
                      color: place.kind == .lost ? .orange : .blue, size: 40, filled: isSelected)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.title)
                    .font(.subheadline.weight(.semibold))
                Text(place.address ?? "Finding the street…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(place.date, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
