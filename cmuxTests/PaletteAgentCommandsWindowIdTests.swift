import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// How `palette.agentCommands.list` reads its `window_id`.
///
/// Every other window-scoped v2 method resolves `window_id` through `v2UUID`,
/// which accepts a handle ref from `window.list` as well as a UUID. This method
/// parsed the value itself, so a ref was refused as malformed before any window
/// was asked, and a `window_id` that was not a string at all fell through to
/// "No cmux window is open." while the caller had in fact named a target.
@MainActor
struct PaletteAgentCommandsWindowIdTests {
    /// A ref resolves to the window id it was minted for, so the answer has to
    /// come from looking that window up, not from parsing the ref.
    @Test func aHandleRefWindowIdReachesTheWindowLookup() {
        let controller = TerminalController.shared
        // A ref for a window id nothing owns: it resolves back to this UUID, and
        // no window has it, which is the answer the caller should be given.
        let absentWindowId = UUID()
        let ref = controller.v2EnsureHandleRef(kind: .window, uuid: absentWindowId)

        let result = controller.v2PaletteAgentCommandsList(params: ["window_id": ref])

        guard case let .err(code, _, data) = result else {
            Issue.record("Expected an error for a window id nothing owns, got \(result)")
            return
        }
        #expect(code == "not_found")
        #expect(data?["window_id"] as? String == absentWindowId.uuidString)
    }

    /// A `window_id` of the wrong JSON type is a malformed request, not an
    /// absent one: reporting "no cmux window is open" sends an agent looking
    /// for a window rather than at the value it sent.
    @Test func aWindowIdThatIsNotAStringIsReportedAsMalformed() {
        let result = TerminalController.shared.v2PaletteAgentCommandsList(
            params: ["window_id": 7]
        )

        guard case let .err(code, _, _) = result else {
            Issue.record("Expected an error for a non-string window_id, got \(result)")
            return
        }
        #expect(code == "invalid_params")
    }
}
