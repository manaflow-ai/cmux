public import CmuxiOSFeatureKit
import Foundation

/// The trusted Macs of the account's device registry (lane B6), by host id:
/// the real registry's record ids name installs (`install:…`), so a Mac's
/// `hostID` wins; mock records use the host id as their id.
public struct DeviceRegistryHostDirectory: WorkspaceHostDirectory {
    public let registry: any DeviceRegistry

    public init(registry: any DeviceRegistry) { self.registry = registry }

    public func hosts() async -> AsyncStream<[WorkspaceHostDescriptor]> {
        let updates = await registry.updates()
        let (stream, continuation) = AsyncStream.makeStream(
            of: [WorkspaceHostDescriptor].self, bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            var last: [WorkspaceHostDescriptor]?
            for await snapshot in updates {
                let hosts = Self.hosts(in: snapshot.value)
                if hosts != last {
                    last = hosts
                    continuation.yield(hosts)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public static func hosts(in devices: [DeviceRecord]) -> [WorkspaceHostDescriptor] {
        devices
            .filter { $0.platform == .mac && $0.trust == .trusted && !$0.isThisDevice }
            .map { WorkspaceHostDescriptor(id: HostID($0.hostID ?? $0.id), name: $0.name, kind: .mac) }
    }
}
