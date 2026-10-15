import SwiftUI

/// The iPhone's DiTAGs, live: which are with you, battery, and a button to make one beep.
/// Asks the iPhone every few seconds, only while this screen is open; nothing is stored on the
/// watch and nothing runs once you leave it.
struct WatchTagsView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tags: [WatchTagInfo]?
    @State private var unreachable = false
    /// Bumped by every request, so an older list reply can't overwrite a newer beep reply.
    @State private var requestNumber = 0

    var body: some View {
        List {
            if let tags {
                if tags.isEmpty {
                    Text("No DiTAGs yet. Add one in DiTether on your iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(tags) { tag in
                    Button {
                        Task { await send(tag.isBeeping ? .stopBeep(tag.id) : .beep(tag.id)) }
                    } label: {
                        TagRow(tag: tag)
                    }
                    .disabled(unreachable || (tag.state != .withYou && !tag.isBeeping))
                }
            } else if !unreachable {
                ProgressView()
            }
            if unreachable {
                Label("Can't reach your iPhone", systemImage: "iphone.slash")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("DiTAGs")
        // Only while the screen is really in front of you: with the wrist down the view stays on
        // screen (the background session keeps DiTether alive), but the polling stops.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await send(.list)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    private func send(_ request: TagRequest) async {
        requestNumber += 1
        let number = requestNumber
        let reply = await model.connectivity.request(request)
        guard number == requestNumber else { return }   // a newer request already answered
        if let reply {
            tags = reply
            unreachable = false
        } else {
            unreachable = true
        }
    }
}

private struct TagRow: View {
    let tag: WatchTagInfo

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(tag.name)
                    .font(.headline)
                    .lineLimit(1)
                Group {
                    if tag.isBeeping {
                        Text("Tap to stop sound")
                    } else if tag.state == .leftBehind, let since = tag.since {
                        Text("Left \(since, style: .relative) ago")
                    } else {
                        Text(subtitle)
                    }
                }
                .font(.caption2)
                .foregroundStyle(tag.isBeeping ? Color.accentColor : color)
            }
            Spacer(minLength: 0)
            if let battery = tag.battery, tag.state == .withYou {
                Text("\(battery)%")
                    .font(.caption2)
                    .foregroundStyle(battery <= 15 ? Color.red : Color.secondary)
            }
        }
    }

    private var icon: String {
        if tag.isBeeping { return "speaker.wave.3.fill" }
        switch tag.state {
        case .withYou: return "tag.fill"
        case .leftBehind: return "exclamationmark.triangle.fill"
        case .connecting: return "tag"
        case .off: return "tag.slash"
        case .quiet: return "moon.zzz.fill"
        }
    }

    private var color: Color {
        switch tag.state {
        case .withYou: return .green
        case .leftBehind: return .orange
        case .quiet: return .indigo
        case .connecting, .off: return .secondary
        }
    }

    private var subtitle: String {
        switch tag.state {
        case .withYou: return "Tap to play sound"
        case .leftBehind: return "Left behind"
        case .connecting: return "Connecting…"
        case .off: return "Off"
        case .quiet: return "Quiet mode"
        }
    }
}
