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
}
