import Foundation

/// A fixed host list (previews and tests); `update` replaces it live.
public actor StaticHostDirectory: WorkspaceHostDirectory {
    private var current: [WorkspaceHostDescriptor]
    private var subscribers: [UUID: AsyncStream<[WorkspaceHostDescriptor]>.Continuation] = [:]

    public init(_ hosts: [WorkspaceHostDescriptor]) { current = hosts }

    public func hosts() -> AsyncStream<[WorkspaceHostDescriptor]> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [WorkspaceHostDescriptor].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
        continuation.yield(current)
        return stream
    }

    public func update(_ hosts: [WorkspaceHostDescriptor]) {
        current = hosts
        for continuation in subscribers.values { continuation.yield(hosts) }
    }

    private func drop(_ id: UUID) { subscribers[id] = nil }
}
