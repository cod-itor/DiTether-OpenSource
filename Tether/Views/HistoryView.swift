import SwiftUI
import MapKit

struct HistoryView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var confirmClear = false

    private struct DayGroup: Identifiable {
        let day: Date
        let events: [LeftBehindEvent]
        var id: Date { day }
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: model.events.events) { calendar.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { DayGroup(day: $0, events: grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.events.events.isEmpty {
                    ContentUnavailableView("No alerts yet",
                                           systemImage: "checkmark.shield",
                                           description: Text("When your watch loses your iPhone, or your DiTAG is left behind, it shows up here with the spot where it happened."))
                } else {
                    List {
                        ForEach(groups) { group in
                            Section(group.day.formatted(date: .complete, time: .omitted)) {
                                ForEach(group.events) { event in
                                    NavigationLink {
                                        EventDetailView(event: event)
                                    } label: {
                                        EventRow(event: event)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !model.events.events.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            confirmClear = true
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) { model.clearHistory() }
            } message: {
                Text("This removes every saved alert and location from this iPhone.")
            }
        }
    }
}

struct EventRow: View {
    let event: LeftBehindEvent

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: icon, color: event.strongAlertAt != nil ? .red : .orange, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.headline)
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if event.fix != nil {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        if event.item != nil { return "tag.fill" }
        return event.strongAlertAt != nil ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    private var summary: String {
        let prefix = event.item.map { "\($0) left behind · " } ?? ""
        if let duration = event.duration {
            return prefix + "Apart \(Format.duration(duration)), then reconnected"
        }
        return prefix + "Still apart, or not reconnected yet"
    }
}

struct EventDetailView: View {
    let event: LeftBehindEvent

    var body: some View {
        List {
            if let fix = event.fix {
                let coordinate = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
                Section("Where your \(event.item ?? "iPhone") probably is") {
                    Map(initialPosition: .region(MKCoordinateRegion(center: coordinate,
                                                                    latitudinalMeters: 400,
                                                                    longitudinalMeters: 400))) {
                        Marker(event.item ?? "iPhone", systemImage: event.item == nil ? "iphone" : "tag.fill",
                               coordinate: coordinate)
                    }
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())

                    Link(destination: mapsURL(for: fix)) {
                        Label("Open in Maps", systemImage: "map")
                    }
                    Text(event.item == nil
                         ? "This is where your watch was when the link dropped, accurate to about \(Int(fix.accuracy)) m."
                         : "This is where your iPhone was when the DiTAG went out of range, accurate to about \(Int(fix.accuracy)) m.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text(event.item == nil
                         ? "No location was available when this happened, for example because location was off or the watch had no signal."
                         : "No location was saved, for example because location was off or Save location is switched off for the DiTAG.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if event.escalatedByDistance == true || event.maxDistance != nil {
                Section("Distance") {
                    if event.escalatedByDistance == true {
                        Label("Alerted because you walked away", systemImage: "figure.walk")
                    }
                    if let furthest = event.maxDistance {
                        LabeledContent("Furthest from the spot", value: "about \(Int(furthest.rounded())) m")
                    }
                }
            }

            Section("Timeline") {
                LabeledContent("Link dropped", value: event.startedAt.formatted(date: .omitted, time: .standard))
                if let soft = event.softAlertAt {
                    LabeledContent(event.item == nil ? "First reminder" : "Alert", value: soft.formatted(date: .omitted, time: .standard))
                }
                if let strong = event.strongAlertAt {
                    LabeledContent("Loud alert", value: strong.formatted(date: .omitted, time: .standard))
                }
                if let resolved = event.resolvedAt {
                    LabeledContent("Reconnected", value: resolved.formatted(date: .omitted, time: .standard))
                    if let duration = event.duration {
                        LabeledContent("Time apart", value: Format.duration(duration))
                    }
                } else {
                    LabeledContent("Reconnected", value: "Not yet")
                }
            }
        }
        .navigationTitle(event.startedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func mapsURL(for fix: GeoFix) -> URL {
        let label = event.item == nil ? "Last known iPhone spot" : "Where \(event.item ?? "it") was left"
        let query = label.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Last%20known%20spot"
        let text = "https://maps.apple.com/?ll=\(fix.latitude),\(fix.longitude)&q=\(query)"
        return URL(string: text) ?? URL(string: "https://maps.apple.com")!
    }
}

enum Format {
    static func duration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(interval, 1)) ?? "\(Int(interval)) s"
    }
}
