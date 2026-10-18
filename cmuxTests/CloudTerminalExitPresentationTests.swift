import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A failed agent run on a Cloud machine keeps a row that says how it ended
/// and offers the fix; `vm terminal read` on it answers with the final screen.
@MainActor
@Suite("Cloud terminal exit presentation")
struct CloudTerminalExitPresentationTests {
    private static let machine = SurfaceMachineID.cloud("vm-1")

    private static func failedTerminal(code: Int = 1, exitedAt: Date) -> SurfaceResource {
        var resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_1"),
            title: "claude",
            lifecycle: .exited,
            remoteViews: []
        )
        resource.exit = SurfaceTerminalExit(
            kind: .exit,
            code: code,
            exitedAtMilliseconds: Int64(exitedAt.timeIntervalSince1970 * 1000)
        )
        return resource
    }

    @Test("An invalid API key is recognized and offers Add API Key")
    func recognizesCredentialFailures() {
        let tail = """
        Welcome to Claude Code
        Invalid API key · Please run /login
        """
        #expect(CloudTerminalExitPresentation.diagnosis(lastLines: tail) == .missingAPIKey)
        #expect(CloudTerminalExitPresentation.diagnosis(lastLines: "Error: 401 Unauthorized") == .missingAPIKey)
        #expect(CloudTerminalExitPresentation.diagnosis(lastLines: "error: could not compile `app`") == nil)
    }

    @Test("Last lines drop surrounding blank rows and keep the tail")
    func lastLinesKeepsTheTail() {
        let screen = "\n\nline 1\nline 2   \nline 3\n\n\n"
        #expect(CloudTerminalExitPresentation.lastLines(of: screen, limit: 2) == "line 2\nline 3")
        #expect(CloudTerminalExitPresentation.lastLines(of: "\n \n") == "")
    }

    @Test("A failed tabless run is listed only within the retention window")
    func retentionAgesOutOldFailures() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let recent = Self.failedTerminal(exitedAt: now.addingTimeInterval(-60))
        let old = Self.failedTerminal(exitedAt: now.addingTimeInterval(-CloudTerminalExitPresentation.retention - 1))
        #expect(CloudTerminalExitPresentation.isListed(recent, now: now))
        #expect(!CloudTerminalExitPresentation.isListed(old, now: now))
        let live = SurfaceResource(
            id: SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "term_2"),
            title: "zsh",
            lifecycle: .running,
            remoteViews: []
        )
        #expect(CloudTerminalExitPresentation.isListed(live, now: now))
    }

    @Test("The row exposes the failure only for a tabless failed run")
    func rowExitFailure() {
        let row = CloudTreeTerminalRow(resource: Self.failedTerminal(exitedAt: .now), isOpen: false)
        #expect(row.exitFailure?.exit.code == 1)
        let clean = Self.failedTerminal(code: 0, exitedAt: .now)
        #expect(CloudTreeTerminalRow(resource: clean, isOpen: false).exitFailure == nil)
    }

    @Test("The terminals pool keeps a recent failed run and counts it")
    func terminalsPoolListsFailedRun() throws {
        let now = Date()
        let info = SurfaceMachineInfo(id: Self.machine, name: "vm-1", status: "running", hasDesktop: false, linkState: .connected)
        let snapshot = SurfaceCatalogSnapshot(
            machines: [info],
            resources: [Self.failedTerminal(exitedAt: now.addingTimeInterval(-30))],
            projections: []
        )
        let children = CloudTreeNodeBuilder.cloudChildren(
            machine: Self.machine,
            machineSnapshot: nil,
            info: info,
            snapshot: snapshot,
            projectionIndex: CloudTreeNodeBuilder.LocalProjectionIndex(snapshot: snapshot),
            resourceNodeBuilder: .init(),
            now: now
        )
        let pool = try #require(children.first { $0.structureTag == "terminalsPool" })
        guard case .terminalsPool(_, let count) = pool.kind else {
            Issue.record("expected the terminals pool")
            return
        }
        #expect(count == 1)
        guard case .terminal(let row) = pool.children.first?.kind else {
            Issue.record("expected the failed run's row")
            return
        }
        #expect(row.exitFailure != nil)
    }

    @Test("Empty categories offer their next step")
    func emptyPlaceholdersOfferActions() throws {
        let info = SurfaceMachineInfo(id: Self.machine, name: "vm-1", status: "running", hasDesktop: false, linkState: .connected)
        let snapshot = SurfaceCatalogSnapshot(machines: [info], resources: [], projections: [])
        let children = CloudTreeNodeBuilder.cloudChildren(
            machine: Self.machine,
            machineSnapshot: nil,
            info: info,
            snapshot: snapshot,
            projectionIndex: CloudTreeNodeBuilder.LocalProjectionIndex(snapshot: snapshot),
            resourceNodeBuilder: .init(),
            now: .now
        )
        let actions = CloudTreeNodeBuilder.flattened(children).compactMap { node -> CloudTreePlaceholder.Action? in
            guard case .placeholder(_, let placeholder) = node.kind else { return nil }
            return placeholder.action
        }
        #expect(actions.contains(.newTerminal))
        #expect(actions.contains(.newWorkspace))
    }

    @Test("vm terminal read on an exited terminal reports the final screen and code")
    func exitedReadResponse() throws {
        let receipt: [String: Any] = [
            "state": "exited",
            "terminal_id": "term_1",
            "outcome": ["kind": "exit", "code": 1],
            "exited_at": "1700000000000",
        ]
        let exit = try #require(CloudTerminalExitedScreenResponse.exitReceipt(receipt))
        let response = CloudTerminalExitedScreenResponse.response(
            exit: exit,
            output: ["text": "Invalid API key\n", "start_offset": 0, "next_offset": 42, "complete": true]
        )
        #expect(response["text"] as? String == "Invalid API key\n")
        #expect(response["exited"] as? Bool == true)
        #expect(response["exit_code"] as? Int == 1)
        #expect(response["message"] as? String == "process exited (code 1)")
        #expect(CloudTerminalExitedScreenResponse.exitReceipt(["state": "pending", "lifecycle": "running"]) == nil)
    }

    // MARK: Agent failure mark (one predicate for terminal, workspace and checklist)

    private static func notification(_ id: String, level: String, terminal: String = "term_ws_1", readBy: [String] = []) -> CloudVMNotificationRow {
        CloudVMNotificationRow(
            id: "notification_\(String(repeating: "0", count: max(0, 32 - id.count)))\(id)",
            title: "Claude reported an error",
            body: "",
            level: level,
            createdAtMs: 1,
            terminalID: terminal,
            readBy: readBy
        )
    }

    @Test("A failed exit, or an unread error report on a live terminal, is one failure predicate")
    func failurePredicate() {
        let now = Date()
        #expect(CloudTerminalExitPresentation.reportsFailure(Self.failedTerminal(exitedAt: now), hasUnreadFailureNotification: false))
        var clean = Self.failedTerminal(code: 0, exitedAt: now)
        clean.remoteViews = nil
        #expect(!CloudTerminalExitPresentation.reportsFailure(clean, hasUnreadFailureNotification: false))
        // The shell `vm clone` keeps after the agent: alive, exit unknown.
        let shell = SurfaceResource(
            id: SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "term_shell"),
            title: "bash",
            lifecycle: .running
        )
        #expect(!CloudTerminalExitPresentation.reportsFailure(shell, hasUnreadFailureNotification: false))
        #expect(CloudTerminalExitPresentation.reportsFailure(shell, hasUnreadFailureNotification: true))
    }

    @Test("Only unread error-level rows mark a terminal as failed")
    func unreadFailureRows() {
        #expect(Self.notification("a", level: "error").reportsFailure)
        #expect(Self.notification("a", level: " Error ").reportsFailure)
        #expect(!Self.notification("a", level: "warning").reportsFailure)
        let rows = [
            Self.notification("a", level: "error", terminal: "term_a"),
            Self.notification("b", level: "info", terminal: "term_b"),
            Self.notification("c", level: "error", terminal: "term_c", readBy: ["mac"]),
        ]
        let state = CloudNotificationSyncState()
        let failures = CloudNotificationSyncReducer.unreadFailureTerminalIDs(rows: rows, clientID: "mac", state: state)
        #expect(failures == ["term_a"])
        #expect(failures.isSubset(of: CloudNotificationSyncReducer.unreadTerminalIDs(rows: rows, clientID: "mac", state: state)))
    }

    @Test("The sync reports failure terminals before the unread set, and clears them on read")
    func syncPublishesFailures() {
        let defaults = UserDefaults(suiteName: "CloudTerminalExitPresentationTests.\(UUID().uuidString)")!
        var failures: Set<String> = []
        var unreadSeenWithFailures: [Set<String>] = []
        let sync = CloudNotificationSync(
            machineID: "vm-1",
            clientID: "mac",
            store: CloudNotificationSyncStore(defaults: defaults),
            resolveTarget: { _ in nil },
            deliver: { _, _ in .declined },
            send: { _ in },
            unreadChanged: { _ in unreadSeenWithFailures.append(failures) },
            failuresChanged: { failures = $0 }
        )
        let error = Self.notification("a", level: "error")
        sync.apply(rows: [error])
        #expect(sync.unreadFailureTerminalIDs == ["term_ws_1"])
        #expect(failures == ["term_ws_1"])
        #expect(unreadSeenWithFailures.last == ["term_ws_1"], "the unread change already sees the failure")
        sync.apply(rows: [Self.notification("a", level: "error", readBy: ["mac"])])
        #expect(sync.unreadFailureTerminalIDs.isEmpty)
        #expect(failures.isEmpty)
        sync.retire()
    }

    @Test("A workspace whose agent reported an error carries the amber mark, not only the blue dot")
    func workspaceCarriesFailureMark() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let snapshot = fixture.snapshot()
        let unread = [fixture.machine.rawValue: Set(["term_ws_1", "term_ws_2"])]
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: snapshot, localWorkspaces: [],
            unreadTerminalIDs: unread,
            unreadFailureTerminalIDs: [fixture.machine.rawValue: ["term_ws_1"]],
            includeLocalMachine: false
        )
        let flat = CloudTreeNodeBuilder.flattened(nodes)
        let failed = try #require(flat.first { $0.id == fixture.folderID("ws_1") })
        let unreadOnly = try #require(flat.first { $0.id == fixture.folderID("ws_2") })
        #expect(failed.hasFailureAttention)
        #expect(failed.hasUnreadAttention)
        #expect(!unreadOnly.hasFailureAttention, "an ordinary unread notification stays a blue dot")
        #expect(unreadOnly.hasUnreadAttention)
        #expect(failed.contentSnapshot != CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: snapshot, localWorkspaces: [],
            unreadTerminalIDs: unread, includeLocalMachine: false
        )).first { $0.id == failed.id }?.contentSnapshot, "the row reloads when its agent fails")
        let terminal = try #require(flat.first {
            if case .terminal(let row) = $0.kind { return row.resource.id.key == "term_ws_1" }
            return false
        })
        #expect(terminal.hasFailureAttention)
        guard case .terminal(let row) = terminal.kind else { return }
        #expect(row.reportsFailure)
        #expect(row.exitFailure == nil, "a live terminal still opens its pane instead of the exit popover")
    }
}
