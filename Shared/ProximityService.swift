import CoreBluetooth

/// The private Bluetooth service the iPhone app advertises and the watch connects to.
/// A direct Bluetooth link cannot be relayed over Wi-Fi or iCloud, so its signal strength is a true
/// measure of how close the two devices are.
enum ProximityService {
    static let uuid = CBUUID(string: "6B1A7F3E-2C4D-4E8A-9B5F-1D3C7A9E2B40")
}
