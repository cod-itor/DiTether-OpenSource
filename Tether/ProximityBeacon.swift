import CoreBluetooth
import Foundation

/// Makes this iPhone visible to Tether on the watch over Bluetooth, so the watch can read the
/// signal strength (a weak signal means you are walking away) and notice the link dropping.
@MainActor
final class ProximityBeacon: NSObject, ObservableObject {
    @Published private(set) var authorization: CBManagerAuthorization = CBManager.authorization

    private var manager: CBPeripheralManager?
    private var wantsAdvertising = false
    private var serviceAdded = false

    var isAllowed: Bool { authorization == .allowedAlways }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    /// Picks up a permission changed in the Settings app while Tether was in the background.
    func refreshAuthorization() {
        let current = CBManager.authorization
        if current != authorization { authorization = current }
    }

    /// Creating the manager shows the Bluetooth permission prompt the first time.
    func start() {
        wantsAdvertising = true
        if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: nil,
                                          options: [CBPeripheralManagerOptionRestoreIdentifierKey: "tether.beacon"])
        }
        advertiseIfReady()
    }

    func stop() {
        wantsAdvertising = false
        guard let manager else { return }
        manager.stopAdvertising()
        manager.removeAllServices()
        serviceAdded = false
    }

    private func advertiseIfReady() {
        guard wantsAdvertising, let manager, manager.state == .poweredOn else { return }
        if !serviceAdded {
            serviceAdded = true
            manager.add(CBMutableService(type: ProximityService.uuid, primary: true))
        }
        if !manager.isAdvertising {
            manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [ProximityService.uuid],
                                      CBAdvertisementDataLocalNameKey: "DiTether"])
        }
    }

    fileprivate func stateChanged() {
        authorization = CBManager.authorization
        if manager?.state != .poweredOn {
            serviceAdded = false   // services are cleared when Bluetooth turns off
        }
        advertiseIfReady()
    }

    fileprivate func restored(serviceUUIDs: [CBUUID]) {
        serviceAdded = serviceUUIDs.contains(ProximityService.uuid)
    }
}

extension ProximityBeacon: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in self.stateChanged() }
    }

    /// iOS relaunched Tether in the background to keep the beacon going.
    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        let services = (dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService]) ?? []
        let uuids = services.map(\.uuid)
        Task { @MainActor in self.restored(serviceUUIDs: uuids) }
    }
}
