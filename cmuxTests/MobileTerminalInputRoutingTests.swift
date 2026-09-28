@preconcurrency import XCTest
import CMUXMobileCore
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Phone input reaches exactly the terminal it names, at most once.
@MainActor
final class MobileTerminalInputRoutingTests: XCTestCase {
    private var trackedManagers: [TabManager] = []
    private var previousManager: TabManager?

    override func setUp() {
        super.setUp()
        previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
    }

    override func tearDown() {
        TerminalController.shared.setActiveTabManager(previousManager)
        for manager in trackedManagers.reversed() {
            manager.closeWorkspacesForTesting()
        }
        trackedManagers.removeAll()
        super.tearDown()
    }

    /// A workspace whose focused terminal queues input instead of writing it,
    /// so the test can count exactly what reached the terminal.
    private func makeQueueingTerminal() throws -> (Workspace, TerminalPanel) {
        let manager = TabManager()
        trackedManagers.append(manager)
        TerminalController.shared.setActiveTabManager(manager)
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panel = try XCTUnwrap(workspace.focusedTerminalPanel)
        panel.surface.releaseHostedSurfaceForTesting()
        return (workspace, panel)
    }

    private func queuedInputCount(_ panel: TerminalPanel) -> Int {
        TerminalMutationBus.shared.drainForTesting()
        return panel.surface.debugPendingSocketInputForTesting().inputTextItems
    }

    private func send(
        _ method: String,
        _ params: [String: Any]
    ) async -> MobileHostRPCResult {
        await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(id: UUID().uuidString, method: method, params: params, auth: nil)
        )
    }

    private func acknowledgement(_ result: MobileHostRPCResult) throws -> MobileTerminalInputAcknowledgement {
        guard case let .ok(payload) = result, let object = payload as? [String: Any] else {
            XCTFail("Expected an answered input unit, got \(result)")
            throw XCTSkip("no acknowledgement")
        }
        return try XCTUnwrap(MobileTerminalInputAcknowledgement.fromRPC(payload: object))
    }

    func testPhonePasteAndCloseThatNameNoTerminalAreRefused() async throws {
        let (workspace, panel) = try makeQueueingTerminal()

        for method in ["terminal.paste", "mobile.terminal.close"] {
            let result = await send(method, ["workspace_id": workspace.id.uuidString, "text": "x"])
            guard case let .failure(error) = result else {
                XCTFail("\(method) without a terminal id must be refused")
                continue
            }
            XCTAssertEqual(error.code, "terminal_id_required", method)
        }
        XCTAssertEqual(queuedInputCount(panel), 0)
        XCTAssertNotNil(workspace.focusedTerminalPanel)
    }

    func testIdentifiedInputResentAfterALostResponseIsWrittenOnce() async throws {
        let (workspace, panel) = try makeQueueingTerminal()
        let delivery = MobileTerminalInputDelivery(surfaceID: panel.id, streamID: UUID(), sequence: 1)
        var params: [String: Any] = [
            "workspace_id": workspace.id.uuidString,
            "surface_id": panel.id.uuidString,
            "text": "make deploy\r",
        ]
        params.merge(delivery.rpcParameters) { current, _ in current }

        let first = try acknowledgement(await send("terminal.input", params))
        // One write can queue several input items (text plus submit key), so
        // the invariant is that the resend adds none, whatever the count.
        let writtenOnce = queuedInputCount(panel)
        XCTAssertGreaterThan(writtenOnce, 0)
        let resent = try acknowledgement(await send("terminal.input", params))

        XCTAssertEqual(first.status, .applied)
        XCTAssertEqual(resent.status, .duplicate)
        XCTAssertEqual(resent.sequence, 1)
        XCTAssertEqual(queuedInputCount(panel), writtenOnce)
    }

    func testIdentifiedInputThatArrivesBeforeItsPredecessorIsNotWritten() async throws {
        let (workspace, panel) = try makeQueueingTerminal()
        let stream = UUID()
        func params(_ sequence: UInt64, _ text: String) -> [String: Any] {
            var params: [String: Any] = [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panel.id.uuidString,
                "text": text,
            ]
            params.merge(
                MobileTerminalInputDelivery(surfaceID: panel.id, streamID: stream, sequence: sequence).rpcParameters
            ) { current, _ in current }
            return params
        }

        let early = try acknowledgement(await send("terminal.input", params(2, "second")))
        XCTAssertEqual(early.status, .gap)
        XCTAssertEqual(early.expected, 1)
        XCTAssertEqual(queuedInputCount(panel), 0)

        let first = try acknowledgement(await send("terminal.input", params(1, "first")))
        let second = try acknowledgement(await send("terminal.input", params(2, "second")))
        XCTAssertEqual(first.status, .applied)
        XCTAssertEqual(second.status, .applied)
        XCTAssertEqual(queuedInputCount(panel), 2)
    }

    func testAStreamBoundToOneTerminalNeverWritesIntoAnother() async throws {
        let (workspace, panel) = try makeQueueingTerminal()
        let other = try XCTUnwrap(workspace.newTerminalSplit(from: panel.id, orientation: .horizontal))
        other.surface.releaseHostedSurfaceForTesting()
        let stream = UUID()
        var first: [String: Any] = [
            "workspace_id": workspace.id.uuidString,
            "surface_id": panel.id.uuidString,
            "text": "a",
        ]
        first.merge(MobileTerminalInputDelivery(surfaceID: panel.id, streamID: stream, sequence: 1).rpcParameters) { current, _ in current }
        var crossing: [String: Any] = [
            "workspace_id": workspace.id.uuidString,
            "surface_id": other.id.uuidString,
            "text": "b",
        ]
        crossing.merge(MobileTerminalInputDelivery(surfaceID: other.id, streamID: stream, sequence: 2).rpcParameters) { current, _ in current }

        let applied = try acknowledgement(await send("terminal.input", first))
        let refused = try acknowledgement(await send("terminal.input", crossing))
        XCTAssertEqual(applied.status, .applied)
        XCTAssertEqual(refused.status, .surfaceMismatch)
        XCTAssertEqual(queuedInputCount(other), 0)
    }

    func testIdentifiedInputForAClosedTerminalIsReportedUndeliverable() async throws {
        let (workspace, panel) = try makeQueueingTerminal()
        panel.surface.beginPortalCloseLifecycle(reason: "test.mobile.closed")
        var params: [String: Any] = [
            "workspace_id": workspace.id.uuidString,
            "surface_id": panel.id.uuidString,
            "text": "echo lost\r",
        ]
        params.merge(
            MobileTerminalInputDelivery(surfaceID: panel.id, streamID: UUID(), sequence: 1).rpcParameters
        ) { current, _ in current }

        let answer = try acknowledgement(await send("terminal.input", params))
        XCTAssertEqual(answer.status, .terminalUnavailable)
    }

    func testOrderedInputKeyIsTheSameForEverySpellingOfOneTerminal() {
        let id = UUID()
        func key(_ params: [String: Any]) -> String {
            MobileHostRPCRequest(id: "k", method: "terminal.input", params: params, auth: nil)
                .orderedInputSurfaceKey
        }
        XCTAssertEqual(key(["surface_id": id.uuidString]), key(["surface_id": id.uuidString.lowercased()]))
        XCTAssertEqual(key(["surface_id": id.uuidString]), key(["terminal_id": " \(id.uuidString) "]))
        XCTAssertEqual(key(["surface_id": id.uuidString]), key(["surface_id": "not-a-terminal", "tab_id": id.uuidString]))
    }
}
