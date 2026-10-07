public import CmuxiOSWorkspacesCore
public import CmuxTerminalLink
public import CmuxTerminalRenderCore
import CmuxiOSTerminal

/// Lane C1's `WorkspaceTerminalSourceFactory` (c1-terminal-rpc.md): a
/// workspace terminal opens as a `LinkTerminalByteSource` on that Mac's
/// `cmux.mobile/1` session, restoring the GHOSTSNP version this build's
/// Ghostty surface reads. The terminal screen owns and closes the source.
@MainActor
public final class LinkWorkspaceTerminalSourceFactory: WorkspaceTerminalSourceFactory {
    private let directory: any MobileLinkDirectory
    private let options: TerminalLinkOptions

    public init(directory: any MobileLinkDirectory, options: TerminalLinkOptions? = nil) {
        self.directory = directory
        self.options = options
            ?? TerminalLinkOptions(snapshotVersions: [Int(GhosttyTerminalView.supportedSnapshotVersion)])
    }

    public func makeSource(for target: WorkspaceTerminalTarget) -> any TerminalByteSource {
        guard let client = directory.client(for: target.hostID) else {
            return UnreachableTerminalByteSource(terminalID: target.terminalID,
                                                 reason: TerminalLinkFailure.unreachable.localizedText)
        }
        return LinkTerminalByteSource(terminal: target.terminalID, client: client, options: options,
                                      describe: { $0.localizedText })
    }
}
