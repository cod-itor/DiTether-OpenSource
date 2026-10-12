import SwiftUI

/// What the watch noticed and decided, newest first. Useful after a walk-away test.
struct ConnectionLogView: View {
    @EnvironmentObject private var model: WatchModel
    @ObservedObject var log: ConnectionLog

    var body: some View {
        List {
            if log.entries.isEmpty {
                Text("Nothing yet. Turn on protection and walk away from your iPhone to test.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(log.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.date.formatted(date: .omitted, time: .standard))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(entry.text)
                        .font(.footnote)
                }
            }
            if !log.entries.isEmpty {
                Button("Clear log", role: .destructive) { log.clear() }
            }
        }
        .navigationTitle("Log")
    }
}
