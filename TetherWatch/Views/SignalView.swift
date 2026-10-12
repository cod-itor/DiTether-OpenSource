import SwiftUI

/// Live strength of Tether's own Bluetooth link to the iPhone: the "range" at a glance.
struct SignalView: View {
    let signal: ProximitySignal
    let rssi: Int?
    /// Why there is no link yet, shown instead of a vague "Connecting".
    var problem: String? = nil

    /// 0 at the edge of range (about -95 dBm), 1 right next to the iPhone (about -45 dBm).
    private var level: Double {
        guard let rssi, signal != .lost else { return 0 }
        return min(max((Double(rssi) + 95) / 50, 0.05), 1)
    }

    private var text: String {
        switch signal {
        case .unknown: return problem ?? "Connecting…"
        case .strong: return "Strong signal"
        case .weak: return "Weak signal"
        case .lost: return "No signal"
        }
    }

    private var color: Color {
        switch signal {
        case .unknown: return .secondary
        case .strong: return .green
        case .weak: return .orange
        case .lost: return .red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cellularbars", variableValue: level)
                .foregroundStyle(color)
            Text(text)
                .foregroundStyle(signal == .unknown ? .secondary : .primary)
        }
        .font(.caption2)
        .accessibilityElement(children: .combine)
    }
}
