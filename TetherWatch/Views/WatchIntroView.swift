import SwiftUI

/// First launch on the watch. Explains the three permission prompts before they appear,
/// because a Health request from an app about phones looks odd without a reason.
struct WatchIntroView: View {
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 6) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 34))
                        .foregroundStyle(.green)
                    Text("DiTether")
                        .font(.headline)
                    Text("Your watch taps you if you walk away from your iPhone.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                Text("Next, please allow:")
                    .font(.footnote.weight(.semibold))

                PermissionRow(symbol: "bell.badge.fill", color: .red,
                              title: "Notifications", detail: "So DiTether can alert you.")
                PermissionRow(symbol: "dot.radiowaves.left.and.right", color: .blue,
                              title: "Bluetooth", detail: "To feel how close your iPhone is.")
                PermissionRow(symbol: "location.fill", color: .blue,
                              title: "Location", detail: "To notice when you walk away. It never leaves your devices.")
                PermissionRow(symbol: "figure.walk", color: .green,
                              title: "Workout", detail: "Keeps DiTether running in the background. Nothing is saved to Health.")

                Button {
                    model.completeSetup()
                } label: {
                    Text("Get started")
                        .frame(maxWidth: .infinity)
                }
                .tint(.green)
                .padding(.top, 4)
            }
            .padding(.horizontal, 4)
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
