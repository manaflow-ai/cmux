public import CmuxiOSWorkspacesCore
public import CmuxTerminalRenderCore
import CmuxiOSTerminal

/// The default terminal source until lane C1 registers the real one: A2's
/// mock session host, titled after the surface the user opened.
@MainActor
public final class MockWorkspaceTerminalSourceFactory: WorkspaceTerminalSourceFactory {
    public init() {}

    public func makeSource(for target: WorkspaceTerminalTarget) -> any TerminalByteSource {
        let ref = TerminalRef(host: target.hostID.rawValue, terminal: MockTerminalSessionSource.demo.terminal,
                              title: target.title, hostName: target.hostName)
        return SessionTerminalByteSource(source: MockTerminalSessionSource(), terminal: ref)
    }
}
