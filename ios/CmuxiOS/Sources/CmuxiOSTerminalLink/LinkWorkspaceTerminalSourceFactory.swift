public import CmuxiOSWorkspacesCore
public import CmuxTerminalLink
public import CmuxTerminalRenderCore
import CmuxiOSTerminal

/// Lane C1's `WorkspaceTerminalSourceFactory` (c1-terminal-rpc.md): a
/// workspace terminal opens on that Mac's `cmux.mobile/1` session from the
/// link directory, restoring the GHOSTSNP version this build's Ghostty
/// surface reads. The terminal screen owns and closes the source.
@MainActor
public final class LinkWorkspaceTerminalSourceFactory: WorkspaceTerminalSourceFactory {
    private let directory: any MobileLinkDirectory
    private let options: TerminalLinkOptions
    public let openTerminals: OpenLinkTerminals

    public init(directory: any MobileLinkDirectory, options: TerminalLinkOptions? = nil,
                openTerminals: OpenLinkTerminals = OpenLinkTerminals()) {
        self.directory = directory
        self.options = options ?? Self.defaultOptions()
        self.openTerminals = openTerminals
    }

    /// The options for this build's surface; `prediction` is the DEV switch.
    public static func defaultOptions(prediction: Bool = false) -> TerminalLinkOptions {
        var options = TerminalLinkOptions(snapshotVersions: [Int(GhosttyTerminalView.supportedSnapshotVersion)])
        options.prediction.enabled = prediction
        return options
    }

    public func makeSource(for target: WorkspaceTerminalTarget) -> any TerminalByteSource {
        let source = DirectoryTerminalByteSource(
            host: target.hostID, terminal: target.terminalID, directory: directory, options: options,
            unreachable: TerminalLinkFailure.unreachable.localizedText, describe: { $0.localizedText })
        openTerminals.register(source)
        return source
    }
}
