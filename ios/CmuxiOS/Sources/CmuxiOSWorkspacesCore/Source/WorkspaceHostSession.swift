import CmuxiOSFeatureKit
import Foundation

/// One host inside `ControlPlaneWorkspaceSource`: its channel, confirmed
/// mirror and intent log.
struct WorkspaceHostSession {
    var descriptor: WorkspaceHostDescriptor
    var channel: (any WorkspaceControlChannel)?
    var state: WorkspaceChannelState = .connecting
    var mirror = HostWorkspaceMirror()
    var log = WorkspaceIntentLog()
    /// A snapshot was requested after a gap and has not arrived yet.
    var resyncRequested = false
    var tasks: [Task<Void, Never>] = []
    /// Bumped on every open; frames and states from an older channel's
    /// tasks (already past their cancellation check) are dropped.
    var generation = 0

    init(descriptor: WorkspaceHostDescriptor) {
        self.descriptor = descriptor
    }

    var isLive: Bool {
        if case .live = state { return true }
        return false
    }

    /// The host as the seam publishes it: mirror plus pending intents.
    var value: HostWorkspaces {
        let reachable: Bool
        let capabilities: WorkspaceCapabilities
        let reason: String?
        switch state {
        case .live(_, let caps):
            reachable = true
            capabilities = WorkspaceCapabilities(negotiated: caps)
            reason = nil
        case .connecting:
            reachable = false
            capabilities = []
            reason = nil
        case .offline(let why):
            reachable = false
            capabilities = []
            reason = why
        }
        return HostWorkspaces(
            hostID: descriptor.id, hostName: descriptor.name, isReachable: reachable,
            workspaces: log.overlay(mirror.summaries(hostID: descriptor.id)), kind: descriptor.kind,
            capabilities: capabilities, offlineReason: reason,
            isResyncing: mirror.hasSnapshot && mirror.needsSnapshot)
    }
}
