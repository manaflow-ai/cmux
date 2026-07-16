import Foundation

/// Actor-owned lifecycle and sizing state for one visible pane attachment.
struct CmuxPaneAttachment {
    let pane: UInt64
    let surface: UInt64
    let generation: UInt64
    let client: CmuxProtocolClient
    var eventTask: Task<Void, Never>?
    var resizeTask: Task<Void, Never>?
    var pendingResizeSize: CmuxSurfaceSize?
    var localSize: CmuxSurfaceSize?
    var lastSentSize: CmuxSurfaceSize?
}
