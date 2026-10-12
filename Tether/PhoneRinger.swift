import AVFoundation
import UserNotifications

/// Plays a loud, repeating beep so you can find the iPhone (asked for from the watch).
///
/// Uses the "playback" audio category, so it rings even with the silent switch on, mixed with any
/// other audio so iOS allows starting it while DiTether is in the background. A notification is
/// posted too, as a fallback. Stops by itself after 30 seconds, when DiTether is opened, or when the
/// watch says stop.
@MainActor
final class PhoneRinger: ObservableObject {
    @Published private(set) var isRinging = false

    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?
    private let notificationID = "ditether.ringPhone"
    private static let ringDuration: UInt64 = 30

    /// True if the sound started.
    @discardableResult
    func ring() -> Bool {
        stopTask?.cancel()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let newPlayer = try AVAudioPlayer(data: Self.tone)
            newPlayer.numberOfLoops = -1
            newPlayer.volume = 1
            newPlayer.play()
            player = newPlayer
        } catch {
            player = nil
        }
        postNotification()
        isRinging = true
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.ringDuration * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
        return player?.isPlaying == true
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        guard isRinging else { return }
        isRinging = false
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        center.removeDeliveredNotifications(withIdentifiers: [notificationID])
    }

    private func postNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Here's your iPhone"
        content.body = "Your watch is looking for it."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notificationID,
                                                                     content: content, trigger: nil))
    }

    // MARK: Tone

    /// A 1.2-second loop: two sharp high beeps, then a pause. Built in code as a 16-bit mono WAV.
    private static let tone: Data = {
        let rate = 44_100
        var samples: [Int16] = []
        func beep(_ frequency: Double, _ seconds: Double) {
            let count = Int(Double(rate) * seconds)
            for i in 0..<count {
                // Short fade in and out so the beep does not click.
                let edge = min(Double(i), Double(count - i)) / (Double(rate) * 0.005)
                let envelope = min(edge, 1)
                let value = sin(2 * .pi * frequency * Double(i) / Double(rate)) * envelope * 0.9
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        func silence(_ seconds: Double) {
            samples.append(contentsOf: repeatElement(0, count: Int(Double(rate) * seconds)))
        }
        beep(2_600, 0.18); silence(0.08); beep(3_100, 0.18); silence(0.76)

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        for sample in samples { append(sample) }
        return data
    }()
}
