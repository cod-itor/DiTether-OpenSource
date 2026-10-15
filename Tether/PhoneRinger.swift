import AVFoundation
import AudioToolbox
import MediaPlayer
import UIKit
import UserNotifications

/// Plays a loud, repeating beep so you can find the iPhone (asked for from the watch or the DiTAG),
/// or, for a DiTAG left behind, vibrates hard and repeatedly without sound.
///
/// Uses the "playback" audio category, so it rings even with the silent switch on, mixed with any
/// other audio so iOS allows starting it while DiTether is in the background. While ringing it turns
/// the volume all the way up (and puts it back afterwards) and vibrates with every beep, so a
/// phone in a bag or face down on a table rattles too. A notification is posted as a fallback.
/// Stops by itself after 30 seconds, when DiTether is opened, or when the watch says stop.
///
/// The left-behind alarm plays a silent loop instead of the beep: that keeps DiTether running in the
/// background (audio background mode) so the vibration can repeat, without touching the volume.
///
/// iOS has no official way to play at full volume regardless of the volume setting (Critical
/// Alerts need Apple's approval), so the volume is raised through the system volume slider, the
/// same way other find-my-phone apps do it.
@MainActor
final class PhoneRinger: ObservableObject {
    enum Reason: Equatable {
        /// The watch asked: find the iPhone.
        case watch
        /// The DiTAG button was double-pressed: find the iPhone.
        case tag
        /// A DiTAG was left behind: vibrate, with the alarm sound only if asked for.
        case leftBehind
    }

    @Published private(set) var isRinging = false
    @Published private(set) var reason: Reason?

    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?
    private var vibrateTask: Task<Void, Never>?
    /// The volume before ringing, restored afterwards.
    private var savedVolume: Float?
    /// Hidden system volume control used to raise the volume. Kept off screen.
    private lazy var volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
    private let notificationID = "ditether.ringPhone"
    private static let ringDuration: UInt64 = 30

    /// True if the sound started.
    @discardableResult
    func ring(_ reason: Reason = .watch, sound: Bool = true) -> Bool {
        // Finding the iPhone wins over the silent left-behind alarm.
        if isRinging, self.reason != .leftBehind, reason == .leftBehind { return true }
        stopTask?.cancel()
        let audible = reason != .leftBehind || sound
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            player?.stop()
            let newPlayer = try AVAudioPlayer(data: audible ? Self.tone : Self.silence)
            newPlayer.numberOfLoops = -1
            newPlayer.volume = audible ? 1 : 0
            newPlayer.play()
            player = newPlayer
            if audible {
                raiseVolume(current: session.outputVolume)
            }
        } catch {
            player = nil
        }
        startVibrating()
        if reason != .leftBehind {
            postNotification(body: reason == .tag ? "Your DiTAG is looking for it." : "Your watch is looking for it.")
        }
        isRinging = true
        self.reason = reason
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
        reason = nil
        player?.stop()
        player = nil
        vibrateTask?.cancel()
        vibrateTask = nil
        restoreVolume()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        center.removeDeliveredNotifications(withIdentifiers: [notificationID])
    }

    // MARK: Volume and vibration

    private func raiseVolume(current: Float) {
        if savedVolume == nil { savedVolume = current }
        setSystemVolume(1)
    }

    private func restoreVolume() {
        guard let saved = savedVolume else { return }
        savedVolume = nil
        setSystemVolume(saved)
    }

    private func setSystemVolume(_ value: Float) {
        // The slider only takes effect while the volume view is part of a window.
        if volumeView.superview == nil {
            let window = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.windows.first }
                .first
            window?.addSubview(volumeView)
        }
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        // The slider needs a moment after being created before it accepts a value.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            slider.value = value
        }
    }

    /// One vibration per beep, so the phone rattles against whatever it lies on.
    private func startVibrating() {
        vibrateTask?.cancel()
        vibrateTask = Task {
            while !Task.isCancelled {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }

    private func postNotification(body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Here's your iPhone"
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notificationID,
                                                                     content: content, trigger: nil))
    }

    // MARK: Tone

    /// A 1.2-second loop: two harsh high beeps, then a pause. Built in code as a 16-bit mono WAV.
    /// The wave is driven into soft clipping, close to a square wave: at the same volume that sounds
    /// much louder and cuts through noise better than a pure tone, at the frequencies (2.5 to 3.5 kHz)
    /// where both the iPhone speaker and human hearing are most sensitive.
    private static let tone: Data = {
        let rate = 44_100
        var samples: [Int16] = []
        func beep(_ frequency: Double, _ seconds: Double) {
            let count = Int(Double(rate) * seconds)
            for i in 0..<count {
                // Short fade in and out so the beep does not click.
                let edge = min(Double(i), Double(count - i)) / (Double(rate) * 0.005)
                let envelope = min(edge, 1)
                let wave = sin(2 * .pi * frequency * Double(i) / Double(rate))
                let value = tanh(wave * 4) / tanh(4) * envelope * 0.98
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        func silence(_ seconds: Double) {
            samples.append(contentsOf: repeatElement(0, count: Int(Double(rate) * seconds)))
        }
        beep(2_900, 0.22); silence(0.06); beep(3_400, 0.22); silence(0.70)
        return wav(samples, rate: rate)
    }()

    /// One second of silence, looped to keep DiTether running while the left-behind alarm vibrates.
    private static let silence: Data = wav([Int16](repeating: 0, count: 44_100), rate: 44_100)

    private static func wav(_ samples: [Int16], rate: Int) -> Data {
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
    }
}
