import SwiftUI

/// Plain-language background for anyone curious, moved off the Status screen to keep it short.
struct HowTetherWorksView: View {
    var body: some View {
        List {
            Section {
                Label("Your watch checks the direct link to your iPhone every couple of seconds. Apple decides whether that link is Bluetooth or shared Wi-Fi, so no internet is needed.", systemImage: "antenna.radiowaves.left.and.right")
                Label("When the link drops, your watch remembers where it was. That is where your iPhone probably is, and History shows it on a map.", systemImage: "mappin.and.ellipse")
                Label("Before any alert, your watch pings your iPhone once more, so a brief glitch never buzzes you.", systemImage: "checkmark.seal")
            } header: {
                Text("Watching")
            }

            Section {
                Label("Detection mode sets how often your watch checks: Fast pings your iPhone every 5 seconds and compares both positions; Battery Saver pings every 30 seconds and only uses GPS once you are apart.", systemImage: "gauge.with.dots.needle.50percent")
                Label("To keep checking with your wrist down, DiTether runs a background workout session. Nothing is saved to Health, but it does use some battery.", systemImage: "battery.50percent")
                Label("If your watch ever stops DiTether, a backup notification asks \u{201C}Is your iPhone with you?\u{201D} That can occasionally be a false alarm.", systemImage: "bell.badge")
            } header: {
                Text("Battery and background")
            }

            Section {
                Label("Don't swipe DiTether away in the app switcher, and open it once after restarting your iPhone.", systemImage: "hand.raised.fill")
                Label("Add DiTether to the allowed apps in your Focus modes so alerts get through.", systemImage: "moon.fill")
                Label("Your iPhone and watch on the same Wi-Fi can stay connected across a building, so alerts may come later there.", systemImage: "wifi")
            } header: {
                Text("Good to know")
            }
        }
        .navigationTitle("How DiTether works")
        .navigationBarTitleDisplayMode(.inline)
    }
}
