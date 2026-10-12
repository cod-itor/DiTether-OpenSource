import CoreBluetooth
import Foundation

/// How close the iPhone is, judged from Tether's own direct Bluetooth link to it.
enum ProximitySignal: Equatable {
    /// Never connected yet in this run (permission missing, iPhone app not running, Bluetooth off).
    case unknown
    case strong
    /// The signal is fading or readings are failing: you are walking away ("stutter").
    case weak
    /// The link dropped completely.
    case lost
}

/// Connects to the iPhone's Tether beacon and reads its signal strength every few seconds.
///
/// Unlike the WatchConnectivity link, this connection is plain Bluetooth: it cannot be carried over
/// Wi-Fi or iCloud, so it really drops when the devices are apart. After a drop the connect request
/// simply stays pending, and Core Bluetooth reconnects by itself when the iPhone is back in range.
@MainActor
final class ProximityMonitor: NSObject, ObservableObject {
    @Published private(set) var signal: ProximitySignal = .unknown
    /// Smoothed signal strength in dBm (roughly -40 right next to it, -90 at the edge of range).
    @Published private(set) var rssi: Int?
    /// Hot/cold: +1 getting closer, -1 getting farther, 0 steady (compares recent readings).
    @Published private(set) var trend = 0
    private var recent: [Double] = []
    /// Why there is no link yet, in a few words, for the watch screen. nil while connected.
    @Published private(set) var problem: String?
    /// True once the link has worked at least once since protection started. Until then the other
    /// signals decide, so a missing permission or an old iPhone build never causes false alarms.
    @Published private(set) var hasConnected = false

    var onChange: ((ProximitySignal) -> Void)?
    var onLog: ((String) -> Void)?
    /// Seconds between signal readings, set from the detection mode.
    var readInterval: TimeInterval = 3

    /// Below this (smoothed) the signal counts as weak; it must recover above `strongAbove` to count
    /// as strong again, so a value hovering at the edge does not flip back and forth.
    static let weakBelow: Double = -84
    static let strongAbove: Double = -78
    /// Readings in a row with no answer that count as a stutter.
    static let missedReadsForWeak = 2

    private static let savedIDKey = "tether.beaconPeripheralID"

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var readTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    /// Scan bursts in a row that found nothing; the pause between bursts grows with it.
    private var emptyScans = 0
    private var smoothed: Double?
    private var awaitingRead = false
    private var missedReads = 0

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        scanTask?.cancel()
        scanTask = nil
        if let central {
            central.stopScan()
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
        }
        central = nil
        peripheral = nil
        hasConnected = false
        smoothed = nil
        rssi = nil
        problem = nil
        set(.unknown)
    }

    // MARK: Connecting

    private func connectOrScan() {
        guard let central, central.state == .poweredOn else { return }
        if peripheral == nil {
            if let connected = central.retrieveConnectedPeripherals(withServices: [ProximityService.uuid]).first {
                adopt(connected)
            } else if let text = UserDefaults.standard.string(forKey: Self.savedIDKey),
                      let id = UUID(uuidString: text),
                      let known = central.retrievePeripherals(withIdentifiers: [id]).first {
                adopt(known)
            }
        }
        if let peripheral, peripheral.state != .connected {
            // A pending connect never times out: it completes whenever the iPhone comes into range.
            central.connect(peripheral)
        }
        // Scan too, in case the iPhone's Bluetooth identity changed since last time.
        if peripheral?.state != .connected {
            startScanBursts()
        }
    }

    /// Short scans with pauses instead of scanning non-stop, which would keep the radio busy for
    /// as long as you are apart. A known iPhone reconnects through its pending connect anyway, so
    /// scans are only a backup then; with no iPhone found yet, pauses grow from 20 s to 5 minutes.
    private func startScanBursts() {
        guard scanTask == nil else { return }
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let central = self.central, central.state == .poweredOn,
                      self.peripheral?.state != .connected else { break }
                central.scanForPeripherals(withServices: [ProximityService.uuid])
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self.central?.stopScan()
                if Task.isCancelled { break }
                self.emptyScans += 1
                let pause: UInt64
                if self.peripheral != nil {
                    pause = 110
                } else {
                    pause = self.emptyScans < 6 ? 20 : (self.emptyScans < 20 ? 60 : 300)
                }
                try? await Task.sleep(nanoseconds: pause * 1_000_000_000)
            }
            self?.scanTask = nil
        }
    }

    private func adopt(_ found: CBPeripheral) {
        peripheral = found
        found.delegate = self
        UserDefaults.standard.set(found.identifier.uuidString, forKey: Self.savedIDKey)
    }

    // MARK: Reading the signal

    private func startReading() {
        readTask?.cancel()
        awaitingRead = false
        missedReads = 0
        readTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.readOnce()
                try? await Task.sleep(nanoseconds: UInt64(max(self.readInterval, 1) * 1_000_000_000))
            }
        }
    }

    private func readOnce() {
        guard let peripheral, peripheral.state == .connected else { return }
        if awaitingRead {
            // The previous reading never came back: the link is stuttering.
            missedReads += 1
            if missedReads >= Self.missedReadsForWeak, signal == .strong {
                onLog?("Bluetooth stuttering (\(missedReads) readings missed)")
                set(.weak)
            }
        }
        awaitingRead = true
        peripheral.readRSSI()
    }

    private func handleReading(_ value: Double) {
        awaitingRead = false
        missedReads = 0
        let next = smoothed.map { $0 * 0.6 + value * 0.4 } ?? value
        smoothed = next
        // Publish only real changes: every publish redraws the watch screen.
        let rounded = Int(next.rounded())
        if rounded != rssi { rssi = rounded }
        recent.append(next)
        if recent.count > 4 { recent.removeFirst(recent.count - 4) }
        if let first = recent.first, recent.count >= 3 {
            let change = next - first
            let newTrend = change > 3 ? 1 : (change < -3 ? -1 : 0)
            if newTrend != trend { trend = newTrend }
        }
        switch signal {
        case .strong where next < Self.weakBelow:
            onLog?("Bluetooth signal weak (\(Int(next)) dBm)")
            set(.weak)
        case .weak where next > Self.strongAbove,
             .unknown, .lost:
            if signal != .strong {
                onLog?("Bluetooth signal strong (\(Int(next)) dBm)")
            }
            set(next < Self.weakBelow ? .weak : .strong)
        default:
            break
        }
    }

    private func set(_ next: ProximitySignal) {
        guard next != signal else { return }
        signal = next
        onChange?(next)
    }

    // MARK: Delegate events (hopped to the main actor)

    fileprivate func stateChanged(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            problem = hasConnected ? nil : "Looking for iPhone…"
            connectOrScan()
        case .unauthorized:
            problem = "Allow Bluetooth for DiTether"
            onLog?("Bluetooth not allowed for DiTether on the watch")
        case .poweredOff:
            problem = "Bluetooth is off"
            onLog?("Bluetooth is off on the watch")
            if hasConnected { set(.lost) }
        default:
            break
        }
    }

    fileprivate func discovered(_ found: CBPeripheral) {
        guard let central else { return }
        if peripheral?.identifier != found.identifier {
            adopt(found)
        }
        central.connect(found)
    }

    fileprivate func connected(_ id: UUID) {
        guard let central, let peripheral, peripheral.identifier == id else { return }
        scanTask?.cancel()
        scanTask = nil
        emptyScans = 0
        central.stopScan()
        if !hasConnected { onLog?("Bluetooth link to iPhone connected") }
        hasConnected = true
        problem = nil
        smoothed = nil
        startReading()
    }

    fileprivate func disconnected(_ id: UUID) {
        guard let peripheral, peripheral.identifier == id else { return }
        readTask?.cancel()
        readTask = nil
        smoothed = nil
        rssi = nil
        recent = []
        trend = 0
        if hasConnected, signal != .lost {
            onLog?("Bluetooth link to iPhone lost")
            set(.lost)
        }
        connectOrScan()
    }

    fileprivate func readRSSI(_ value: Int?) {
        // 127 means "not available".
        guard let value, value != 127, value < 0 else {
            awaitingRead = false
            missedReads += 1
            if missedReads >= Self.missedReadsForWeak, signal == .strong {
                onLog?("Bluetooth stuttering (readings failing)")
                set(.weak)
            }
            return
        }
        handleReading(Double(value))
    }
}

// MARK: - Core Bluetooth delegates

extension ProximityMonitor: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in self.stateChanged(state) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in self.discovered(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        Task { @MainActor in self.connected(id) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        Task { @MainActor in self.disconnected(id) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        Task { @MainActor in self.disconnected(id) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let value = error == nil ? RSSI.intValue : nil
        Task { @MainActor in self.readRSSI(value) }
    }
}
