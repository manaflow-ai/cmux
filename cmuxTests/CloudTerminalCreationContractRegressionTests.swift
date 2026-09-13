import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Red regression coverage for the client side of Cloud terminal creation.
///
/// The daemon's creation contract is durable: a workspace run and a later
/// `session.creation.resolve` return the same CreatedPath when the original
/// reply was lost. These tests intentionally exercise the executable JSON
/// seam rather than source text. The wrapped-result case fails on the baseline
/// client because it only decodes the flat workspace.run envelope.
@Suite("Cloud terminal creation contract")
struct CloudTerminalCreationContractRegressionTests {
    @Test("wrapped create result preserves the exact terminal and placement")
    func creationResolutionPreservesCreatedPath() throws {
        let wrapped: [String: Any] = [
            "result": [
                "value": [
                    "kind": "terminal",
                    "workspace_id": "ws_main",
                    "screen_id": "screen_main",
                    "pane_id": "pane_main",
                    "tab_id": "tab_new",
                    "terminal_id": "term_99fc27476ab25b4631d4da1a0c9146b5",
                ],
                "generation": "daemon-generation",
                "revision": "259",
            ],
        ]

        // `session.creation.resolve` and `workspace.run` return the same
        // CreatedPath contract. A lost run reply must therefore feed the same
        // identity path into materialization, rather than becoming “not created”.
        let created = CmuxTuiSnapshotParser.createdTerminal(fromRunResult: wrapped)
        #expect(created?.terminalID == "term_99fc27476ab25b4631d4da1a0c9146b5")
        #expect(created?.workspaceID == "ws_main")
        #expect(created?.tabID == "tab_new")
        #expect(created?.cursor == CloudVMCursor(generation: "daemon-generation", revision: 259))
    }

    @Test("malformed closed creation path does not fabricate a terminal")
    func malformedClosedCreationPathFailsClosed() throws {
        let malformed: [String: Any] = [
            "result": [
                "value": [
                    "kind": "terminal",
                    "workspace_id": "ws_main",
                    "lifecycle": "exited",
                ],
                "generation": "daemon-generation",
                "revision": "259",
            ],
        ]
        #expect(CmuxTuiSnapshotParser.createdTerminal(fromRunResult: malformed) == nil)
    }
}
