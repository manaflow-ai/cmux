import CMUXMobileCore
import CmuxMobileShell
import CmuxV3Transport
import Foundation

/// Projects the authenticated v3 control directory into the shell's existing
/// discovery seam. The route payload is v3-only; the legacy protocol name is
/// retained here until the shell's discovery protocol is renamed.
@MainActor
public final class MobileV3DiscoveryProvider: MobileIrohMacDiscovering {
    private let runtime: MobileV3RuntimeComposition
    private let preferredTag: String
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(runtime: MobileV3RuntimeComposition, preferredTag: String = "default") {
        self.runtime = runtime
        self.preferredTag = preferredTag
    }

    public func directoryUpdates() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(())
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers[id] = nil }
        }
        return stream
    }

    public func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] {
        guard let directory = try? await runtime.directory() else { return [] }
        let candidates = Self.candidates(from: directory, preferredTag: preferredTag)
        for observer in observers.values { observer.yield(()) }
        return candidates
    }

    static func candidates(from directory: CmxV3Directory, preferredTag: String, now: Date = Date()) -> [MobileDiscoveredIrohMac] {
        directory.devices.compactMap { device -> MobileDiscoveredIrohMac? in
            guard device.active, !device.addresses.isEmpty,
                  let identity = try? CmxV3PeerIdentity(peerID: device.peerID, addresses: device.addresses),
                  let route = try? CmxAttachRoute(
                    id: "v3-\(device.deviceID)",
                    kind: .v3,
                    endpoint: .v3Peer(identity),
                    priority: -10_000
                  ) else { return nil }
            return MobileDiscoveredIrohMac(
                deviceID: device.deviceID,
                displayName: nil,
                instanceTag: preferredTag,
                routes: [route],
                lastSeenAt: now,
                capabilities: ["transport-v3"],
                clientNamespace: "mac:v3"
            )
        }
    }

    public func invalidateDiscovery(forMacDeviceID deviceID: String) async {
        _ = deviceID
        for observer in observers.values { observer.yield(()) }
    }
}
