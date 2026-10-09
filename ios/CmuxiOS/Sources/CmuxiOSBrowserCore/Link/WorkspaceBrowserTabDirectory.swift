public import CmuxiOSFeatureKit

/// Browser tab records from the workspace mirror (C5): every `browser`
/// surface of a host's workspaces.
public struct WorkspaceBrowserTabDirectory: BrowserTabDirectory {
    public let source: any WorkspaceSource

    public init(source: any WorkspaceSource) {
        self.source = source
    }

    public func tabs(on hostID: HostID) async -> AsyncStream<SourceSnapshot<[BrowserTabInfo]>> {
        let source = source
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                for await snapshot in await source.updates() {
                    let workspaces = snapshot.value.first { $0.hostID == hostID }?.workspaces ?? []
                    let tabs = workspaces.flatMap { workspace in
                        workspace.panes.flatMap(\.surfaces).filter { $0.kind == .browser }.map {
                            BrowserTabInfo(id: $0.id, workspaceID: workspace.id, title: $0.title, url: $0.url)
                        }
                    }
                    continuation.yield(SourceSnapshot(revision: snapshot.revision, value: tabs, connection: snapshot.connection))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
