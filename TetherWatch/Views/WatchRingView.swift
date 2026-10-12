import SwiftUI

/// Shown while the iPhone is ringing this watch (Find my watch).
struct WatchRingView: View {
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(.blue)
            Text("Here's your watch")
                .font(.headline)
            Spacer(minLength: 0)
            Button("Stop", action: onStop)
                .tint(.blue)
        }
        .padding(.horizontal, 4)
    }
}
