public import CmuxiOSFeatureKit
import Foundation

/// The team's bound Cloud machines as workspace hosts (lane C12). A machine
/// joins once `CloudDO` recorded its overlay host id; classic machines (no
/// cmux-next daemon), failed and deleting ones stay out. A paused machine
/// stays listed: its host shows offline through `HostDO` presence.
public struct CloudMachineHostDirectory: WorkspaceHostDirectory {
    public let source: any CloudMachineSource

    public init(source: any CloudMachineSource) { self.source = source }

    public func hosts() async -> AsyncStream<[WorkspaceHostDescriptor]> {
        let updates = await source.updates()
        let (stream, continuation) = AsyncStream.makeStream(
            of: [WorkspaceHostDescriptor].self, bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            var last: [WorkspaceHostDescriptor]?
            for await snapshot in updates {
                let hosts = Self.hosts(in: snapshot.value.machines)
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

    public static func hosts(in machines: [CloudMachine]) -> [WorkspaceHostDescriptor] {
        machines.compactMap { machine in
            guard let host = machine.host, !machine.isClassic, machine.status != .deleting, machine.status != .failed else {
                return nil
            }
            return WorkspaceHostDescriptor(id: host, name: machine.displayName, kind: .cloud)
        }
    }
}
