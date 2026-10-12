import SwiftUI

struct SafePlacesView: View {
    @EnvironmentObject private var model: PhoneModel

    @State private var isLocating = false
    @State private var isNaming = false
    @State private var newName = ""
    @State private var pendingFix: GeoFix?
    @State private var notice: String?

    private var places: [SafePlace] { model.settings.settings.safePlaces }

    var body: some View {
        List {
            Section {
                Button {
                    addCurrentLocation()
                } label: {
                    HStack {
                        Label("Add current location", systemImage: "location.fill")
                        if isLocating {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isLocating)

                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Stand where you want DiTether to stay quiet, such as home or your desk, then tap the button. Your watch uses these to know when being apart from your iPhone is normal.")
            }

            Section {
                if places.isEmpty {
                    Text("No safe places yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(places) { place in
                    SafePlaceRow(place: place) { model.update($0) }
                }
                .onDelete { offsets in
                    model.removeSafePlaces(at: offsets)
                }
            } header: {
                Text("Your safe places")
            } footer: {
                Text("Indoors, GPS can be off by 50 to 100 metres, so a radius of 100 m or more works best.")
            }
        }
        .navigationTitle("Safe places")
        .alert("Name this place", isPresented: $isNaming) {
            TextField("Home", text: $newName)
            Button("Save") { savePending() }
            Button("Cancel", role: .cancel) { pendingFix = nil }
        } message: {
            Text("DiTether stays quiet whenever your watch is inside this area.")
        }
    }

    private func addCurrentLocation() {
        notice = nil
        let location = model.location
        if location.isDenied {
            notice = "Location is off for DiTether. Turn it on in the iPhone's Settings app under Privacy & Security, then Location Services."
            return
        }
        if !location.isAuthorized {
            location.requestAuthorization()
            notice = "Allow location access, then tap the button again."
            return
        }
        isLocating = true
        Task {
            let fix = await location.current()
            isLocating = false
            if let fix {
                pendingFix = fix
                newName = ""
                isNaming = true
            } else {
                notice = "Could not get your location. Try again near a window or outside."
            }
        }
    }

    private func savePending() {
        guard let fix = pendingFix else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        model.addSafePlace(name: trimmed.isEmpty ? "Safe place" : trimmed, fix: fix)
        pendingFix = nil
    }
}

private struct SafePlaceRow: View {
    let place: SafePlace
    let onChange: (SafePlace) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(place.name)
                .font(.headline)
            Stepper(value: radiusBinding, in: 50...1000, step: 25) {
                Text("Radius \(Int(place.radius)) m")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var radiusBinding: Binding<Double> {
        Binding(
            get: { place.radius },
            set: { newValue in
                var updated = place
                updated.radius = newValue
                onChange(updated)
            }
        )
    }
}
