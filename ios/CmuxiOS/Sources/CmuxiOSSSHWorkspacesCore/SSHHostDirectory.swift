public import CmuxiOSFeatureKit
public import CmuxiOSWorkspacesCore
import Foundation

/// The SSH records of the hosts store as `.ssh` workspace hosts, in the
/// store's order (lane C9's records; paired Macs and direct hosts stay out).
public struct SSHHostDirectory: WorkspaceHostDirectory {
    public let store: any HostsStore

    public init(store: any HostsStore) { self.store = store }

    public func hosts() async -> AsyncStream<[WorkspaceHostDescriptor]> {
        let updates = await store.updates()
        let (stream, continuation) = AsyncStream.makeStream(of: [WorkspaceHostDescriptor].self, bufferingPolicy: .bufferingNewest(1))
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

    public static func hosts(in records: [HostRecord]) -> [WorkspaceHostDescriptor] {
        records.compactMap { record in
            guard case .ssh = record.kind else { return nil }
            return WorkspaceHostDescriptor(id: record.id, name: record.name, kind: .ssh)
        }
    }
}
