public import Foundation
import Network

/// Whether the device has a usable network path. Sign-in uses it to fail fast offline.
public protocol NetworkReachability: Sendable {
    var isOnline: Bool { get async }
}

/// `NWPathMonitor` behind an actor. The monitor delivers path updates on its
/// own queue; nothing polls.
public actor PathReachability: NetworkReachability {
    private let monitor = NWPathMonitor()
    private var satisfied = true

    public init() {
        let monitor = self.monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { await self?.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "cmux.ios.reachability"))
    }

    deinit { monitor.cancel() }

    public var isOnline: Bool { satisfied }

    private func update(_ online: Bool) { satisfied = online }
}
