import SwiftUI
import WidgetKit

struct StatusEntry: TimelineEntry {
    let date: Date
    let state: WidgetState
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), state: WidgetState(status: .protected, updatedAt: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: Date(), state: WidgetState.load()))
    }

    /// One entry; the watch app asks WidgetKit to reload whenever the status changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        completion(Timeline(entries: [StatusEntry(date: Date(), state: WidgetState.load())], policy: .never))
    }
}

private extension WidgetState.Status {
    var symbol: String {
        switch self {
        case .protected: return "checkmark.shield.fill"
        case .apart: return "iphone.slash"
        case .alerting: return "exclamationmark.octagon.fill"
        case .quiet: return "bell.slash.fill"
        case .off: return "shield.slash"
        }
    }

    var color: Color {
        switch self {
        case .protected: return .green
        case .apart: return .orange
        case .alerting: return .red
        case .quiet: return .blue
        case .off: return .gray
        }
    }

    var label: String {
        switch self {
        case .protected: return "iPhone nearby"
        case .apart: return "iPhone out of range"
        case .alerting: return "iPhone left behind?"
        case .quiet: return "Quiet"
        case .off: return "Protection off"
        }
    }

    var shortLabel: String {
        switch self {
        case .protected: return "Nearby"
        case .apart: return "Apart"
        case .alerting: return "Left?"
        case .quiet: return "Quiet"
        case .off: return "Off"
        }
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    private var status: WidgetState.Status { entry.state.status }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: status.symbol)
                    .font(.title3)
                    .foregroundStyle(status.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text("DiTether")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(status.label)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Label(status.shortLabel, systemImage: status.symbol)
        case .accessoryCorner:
            Image(systemName: status.symbol)
                .font(.title2)
                .foregroundStyle(status.color)
                .widgetLabel(status.shortLabel)
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: status.symbol)
                    .font(.title2)
                    .foregroundStyle(status.color)
            }
        }
    }
}

@main
struct DiTetherWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DiTetherStatus", provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("DiTether")
        .description("Whether your iPhone is with you.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}
