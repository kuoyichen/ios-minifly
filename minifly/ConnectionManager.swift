import Foundation
import Network
import NetworkExtension
import SystemConfiguration.CaptiveNetwork
import CoreLocation

/// Manages WiFi connection detection, UDP communication, and RSSI monitoring.
final class ConnectionManager: ObservableObject {
    // MARK: - Published state
    @Published var wifiName: String = "no connection"
    @Published var rssi: Int = 0
    @Published var scanStatus: String = ""
    @Published var showScanDialog: Bool = false
    @Published var isConnecting: Bool = false

    // MARK: - Control values (thread-safe via locks)
    private let lock = NSLock()
    private var _rudder: Int = 1500
    private var _throttle: Int = 1000
    private var _trim: Int = 5

    var rudder: Int {
        get { lock.lock(); defer { lock.unlock() }; return _rudder }
        set { lock.lock(); _rudder = newValue; lock.unlock() }
    }
    var throttle: Int {
        get { lock.lock(); defer { lock.unlock() }; return _throttle }
        set { lock.lock(); _throttle = newValue; lock.unlock() }
    }
    var trim: Int {
        get { lock.lock(); defer { lock.unlock() }; return _trim }
        set { lock.lock(); _trim = newValue; lock.unlock() }
    }

    // MARK: - UDP
    private var udpConnection: NWConnection?
    private var udpTimer: DispatchSourceTimer?
    private var udpRunning = false

    // MARK: - Network monitor
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let monitorQueue = DispatchQueue(label: "wifi.monitor")

    // MARK: - Location manager for RSSI (iOS requires location for WiFi info)
    private let locationManager = CLLocationManager()

    init() {
        startNetworkMonitor()
    }

    deinit {
        stopUdpSender()
        monitor.cancel()
    }

    // MARK: - Network monitoring

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                if path.status == .satisfied {
                    self?.updateWifiName()
                } else {
                    let wasConnected = self?.wifiName.hasPrefix("Minifly") ?? false
                    self?.wifiName = "no connection"
                    self?.rssi = 0
                    self?.stopUdpSender()
                    if wasConnected {
                        // Connection was lost – UI will detect via wasMiniflyConnected
                    }
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    func updateWifiName() {
        let name = currentSSID() ?? "no connection"
        DispatchQueue.main.async {
            let previousName = self.wifiName
            self.wifiName = name

            if name.hasPrefix("Minifly") {
                self.startUdpSender()
            } else if previousName.hasPrefix("Minifly") {
                self.stopUdpSender()
            }
        }
    }

    private func currentSSID() -> String? {
        // Use NEHotspotNetwork on iOS 14+
        if #available(iOS 14.0, *) {
            var ssid: String?
            let semaphore = DispatchSemaphore(value: 0)
            NEHotspotNetwork.fetchCurrent { network in
                ssid = network?.ssid
                semaphore.signal()
            }
            semaphore.wait()
            return ssid
        }
        // Fallback for older iOS
        if let interfaces = CNCopySupportedInterfaces() as? [String] {
            for iface in interfaces {
                if let info = CNCopyCurrentNetworkInfo(iface as CFString) as? [String: Any],
                   let ssid = info[kCNNetworkInfoKeySSID as String] as? String {
                    return ssid
                }
            }
        }
        return nil
    }

    /// Refresh RSSI value (called periodically)
    func refreshRSSI() {
        if #available(iOS 14.0, *) {
            NEHotspotNetwork.fetchCurrent { [weak self] network in
                DispatchQueue.main.async {
                    // NEHotspotNetwork provides signalStrength 0.0–1.0
                    if let strength = network?.signalStrength {
                        // Convert to approximate dBm: 0.0 = -100dBm, 1.0 = -30dBm
                        self?.rssi = Int(-100.0 + strength * 70.0)
                    }
                }
            }
        }
    }

    // MARK: - Quick Connect

    func startQuickConnect() {
        showScanDialog = true
        scanStatus = "Connecting to Minifly..."
        isConnecting = true

        // iOS doesn't allow WiFi scanning. Use NEHotspotConfigurationManager
        // to directly request connection to any "Minifly" prefixed network.
        let config = NEHotspotConfiguration(ssidPrefix: "Minifly")
        config.joinOnce = false

        NEHotspotConfigurationManager.shared.apply(config) { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    let nsError = error as NSError
                    if nsError.domain == NEHotspotConfigurationErrorDomain,
                       nsError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                        // Already connected
                        self?.scanStatus = "Already connected"
                        self?.updateWifiName()
                    } else {
                        self?.scanStatus = "Failed: \(error.localizedDescription)"
                    }
                } else {
                    self?.scanStatus = "Connected!"
                    self?.updateWifiName()
                }
                self?.isConnecting = false

                // Auto-close dialog after short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if self?.wifiName.hasPrefix("Minifly") == true {
                        self?.showScanDialog = false
                    }
                }
            }
        }
    }

    // MARK: - Reset

    func resetConnection() {
        stopUdpSender()
        rudder = 1500
        throttle = 1000
        trim = 5

        // Remove Minifly configuration to disconnect
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: wifiName)
        wifiName = "no connection"
        rssi = 0
    }

    // MARK: - UDP sender

    private func startUdpSender() {
        guard !udpRunning else { return }
        udpRunning = true

        let host = NWEndpoint.Host("10.10.10.1")
        let port = NWEndpoint.Port(integerLiteral: 6188)
        let connection = NWConnection(host: host, port: port, using: .udp)
        self.udpConnection = connection

        connection.start(queue: DispatchQueue(label: "udp.sender"))

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "udp.timer"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.udpRunning else { return }
            let r = self.rudder
            let t = self.throttle
            let tr = self.trim
            let msg = String(format: "SRV%04d%04d1%d001500#", r, t, tr)
            if let data = msg.data(using: .ascii) {
                connection.send(content: data, completion: .contentProcessed({ _ in }))
            }
        }
        timer.resume()
        self.udpTimer = timer
    }

    private func stopUdpSender() {
        udpRunning = false
        udpTimer?.cancel()
        udpTimer = nil
        udpConnection?.cancel()
        udpConnection = nil
    }
}
