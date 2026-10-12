import SwiftUI

/// A sample alert: the same icon and words a real alert shows, a small "Test" label, and Done.
struct TestAlertView: View {
    let level: TestAlertLevel
    let onDone: () -> Void

    private var symbol: String {
        level == .loud ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    private var color: Color {
        level == .loud ? .red : .orange
    }

    private var title: String {
        level == .loud ? "iPhone left behind?" : "iPhone out of range"
    }

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(color)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Test")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Done", action: onDone)
                .tint(color)
        }
        .padding(.horizontal, 4)
    }
}
