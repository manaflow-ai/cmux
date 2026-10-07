public import CmuxTerminalRenderCore

/// Makes the byte source behind a terminal surface. Lane C1 provides the
/// real one (`.host` authority over `CmuxLink`, channel kind `terminal`);
/// the default is the mock session host. The terminal screen owns the
/// source and closes it when it leaves.
@MainActor
public protocol WorkspaceTerminalSourceFactory: AnyObject {
    func makeSource(for target: WorkspaceTerminalTarget) -> any TerminalByteSource
}
