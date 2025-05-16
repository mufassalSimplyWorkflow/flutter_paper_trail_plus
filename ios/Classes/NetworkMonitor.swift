import Network

public class NetworkMonitor {
    private var monitor: NWPathMonitor?
    private var queue: DispatchQueue?

    public static let shared = NetworkMonitor()

    private init() {}

    public func startMonitoring() {
        monitor = NWPathMonitor()
        queue = DispatchQueue(label: "NetworkMonitorQueue")

        monitor?.pathUpdateHandler = { path in
            if path.status == .satisfied {
                print("Network is available")
            } else {
                print("Network is unavailable")
            }
        }

        monitor?.start(queue: queue!)
    }

    public func stopMonitoring() {
        monitor?.cancel()
    }
}
