import CmuxiOSBrowserCore
import CmuxiOSFeatureKit
import os

/// The browser seam's tab records come from whichever workspace source the
/// signed-in seams resolved (C5); the browser factory is built before them.
final class CurrentWorkspaceTabs: BrowserTabDirectory {
    // carve-out: set on the main actor when seams resolve, read by the stream factory.
    private let source = OSAllocatedUnfairLock<(any WorkspaceSource)?>(initialState: nil)

    func set(_ workspaces: (any WorkspaceSource)?) {
        source.withLock { $0 = workspaces }
    }

    func tabs(on hostID: HostID) async -> AsyncStream<SourceSnapshot<[BrowserTabInfo]>> {
        guard let workspaces = source.withLock({ $0 }) else { return AsyncStream { $0.finish() } }
        return await WorkspaceBrowserTabDirectory(source: workspaces).tabs(on: hostID)
    }
}
