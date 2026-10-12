import SwiftUI

/// "See what an alert looks like": plays a sample alert on the watch, with clear feedback here.
struct TestAlertSection: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        Section {
            Menu {
                Button {
                    model.sendTestAlert(.firstReminder)
                } label: {
                    Label("First reminder", systemImage: "hand.tap.fill")
                }
                Button {
                    model.sendTestAlert(.loud)
                } label: {
                    Label("Loud alert", systemImage: "bell.and.waves.left.and.right.fill")
                }
            } label: {
                HStack {
                    Label("Send a test alert to your watch", systemImage: "applewatch.radiowaves.left.and.right")
                    if model.testAlertState == .sending {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(model.testAlertState == .sending)
        } footer: {
            footer
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch model.testAlertState {
        case .idle, .sending:
            Text("Your watch shows and plays a sample alert, so you know what to expect. Nothing is recorded in History.")
        case .sent:
            Label("Sent. Check your watch.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Label("Couldn't reach your watch. Make sure it's nearby and unlocked, open DiTether on it, then try again.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
