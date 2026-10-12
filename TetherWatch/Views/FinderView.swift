import SwiftUI

/// Hot/cold finder: the live Bluetooth signal as a big gauge, which way it is changing, and a
/// button that makes the iPhone ring.
struct FinderView: View {
    @EnvironmentObject private var model: WatchModel

    private var proximity: ProximityMonitor { model.proximity }

    /// 0 at the edge of range, 1 right next to the iPhone.
    private var level: Double {
        guard let rssi = proximity.rssi, proximity.signal != .lost else { return 0 }
        return min(max((Double(rssi) + 95) / 50, 0.03), 1)
    }

    private var color: Color {
        switch proximity.signal {
        case .strong: return .green
        case .weak: return .orange
        case .lost: return .red
        case .unknown: return .gray
        }
    }

    private var hint: String {
        switch proximity.signal {
        case .lost: return "No signal"
        case .unknown: return proximity.problem ?? "Connecting…"
        case .strong, .weak:
            switch proximity.trend {
            case 1: return "Getting closer"
            case -1: return "Getting farther"
            default: return level > 0.8 ? "Very close" : "Keep moving"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(color.opacity(0.2), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: level)
                        .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.4), value: level)
                    Image(systemName: proximity.trend == -1 ? "arrow.down" : (proximity.trend == 1 ? "arrow.up" : "iphone"))
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(color)
                }
                .frame(width: 96, height: 96)

                Text(hint)
                    .font(.headline)

                if proximity.signal == .lost, let meters = model.engine.distanceFromSpot {
                    Text("\(Int(meters.rounded())) m from where you left it")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                ringButton
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Find iPhone")
        .onAppear { model.setFinderOpen(true) }
        .onDisappear { model.setFinderOpen(false) }
    }

    @ViewBuilder
    private var ringButton: some View {
        switch model.ringPhoneState {
        case .ringing:
            Button("Stop ringing") { model.stopRingingPhone() }
                .tint(.red)
        case .sending:
            ProgressView()
        case .idle, .failed:
            Button {
                model.ringPhone()
            } label: {
                Label("Ring iPhone", systemImage: "speaker.wave.3.fill")
            }
            .tint(.blue)
            if model.ringPhoneState == .failed {
                Text("Can't reach it")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}
