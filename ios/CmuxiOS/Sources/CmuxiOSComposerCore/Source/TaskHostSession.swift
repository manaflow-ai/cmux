import CmuxiOSFeatureKit
import CmuxiOSWorkspacesCore
import Foundation

/// One Mac's task channel and mirror inside `ControlPlaneTaskComposerSink`.
struct TaskHostSession {
    let channel: any WorkspaceControlChannel
    var mirror: TaskStreamMirror
    var state: WorkspaceChannelState = .connecting
    var pumps: [Task<Void, Never>] = []

    init(hostID: HostID, channel: any WorkspaceControlChannel) {
        self.channel = channel
        mirror = TaskStreamMirror(hostID: hostID)
    }

    var acceptsDispatch: Bool {
        if case .live(_, let caps) = state { return caps.contains(ControlPlaneTaskComposerSink.dispatchCap) }
        return false
    }

    var connection: SourceConnection {
        switch state {
        case .connecting: .connecting
        case .live(let path, _): .live(path: path)
        case .offline(let reason): .offline(reason: reason)
        }
    }
}
