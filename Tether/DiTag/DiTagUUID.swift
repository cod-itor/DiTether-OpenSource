import CoreBluetooth

/// The DiTAG's Bluetooth layout (the hardware advertises the name "iTAG"). Tested by hand in nRF
/// Connect on 14 Oct 2026. No pairing or handshake is needed.
///
/// FFE2 to FFE7 also exist, but their meaning is unknown: never write to them.
enum DiTagUUID {
    /// Write 0x01 to beep, 0x00 to stop (0x02 does nothing on this firmware).
    static let immediateAlertService = CBUUID(string: "1802")
    static let alertLevel = CBUUID(string: "2A06")
    /// One byte, 0 to 100 %.
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")
    /// Also advertised, so it is what we scan for. FFE1 sends one notification per button press.
    static let buttonService = CBUUID(string: "FFE0")
    static let buttonPress = CBUUID(string: "FFE1")

    static let services = [immediateAlertService, batteryService, buttonService]
}
