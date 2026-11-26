import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct CloudMachineWorkspaceResolutionTests {
    @Test("A failed first open retries its binding even when a later workspace has focus")
    func retryUsesBoundWorkspace() {
        let catalog: [String: Any] = [
            "machines": [["id": "machine", "link_state": "connected", "remote_workspaces": [
                ["id": "ws-first", "name": "workspace-1", "focused": false],
                ["id": "ws-later", "name": "workspace-2", "focused": true]
            ]]],
            "resources": ["first", "later"].map { id -> [String: Any] in
                ["id": "machine/terminal/term-" + id, "kind": "terminal", "lifecycle": "running",
                 "remote_views": [["tab_id": "tab-" + id, "workspace": ["id": "ws-" + id]]]]
            }
        ]
        let resolver = VMRemoteWorkspaceResolver()
        #expect(resolver.remoteWorkspaceName("ws-first", machine: "machine", in: catalog) == "workspace-1")
        #expect(resolver.resolveVMMachineTerminal(machine: "machine", catalog: catalog)
            == .resolved(workspaceID: "ws-later", terminalID: "term-later", tabID: "tab-later"))
        #expect(resolver.resolveVMRemoteTerminalPlacement("term-first", machine: "machine", workspaceID: "ws-first", in: catalog)
            == .resolved(terminalID: "term-first", tabID: "tab-first"))
        #expect(resolver.resolveVMRemoteTerminalPlacement("term-first", machine: "machine", workspaceID: "deleted", in: catalog) == .notFound)
    }
}
