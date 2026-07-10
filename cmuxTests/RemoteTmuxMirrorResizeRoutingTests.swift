import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension RemoteTmuxMirrorCLIObservabilityTests {
    /// Regression for #7831: projected mirror pane IDs stay actionable through
    /// the real coordinator while the adapter preserves point-based API units.
    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func paneResizeRoutesProjectedPaneAtBackingScale(_ scale: CGFloat) throws {
        let harness = try Harness(connectedTransport: true, geometryScale: scale)
        defer { harness.tearDown() }
        let tmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
        let paneID = try #require(harness.mirror.syntheticPaneID(forPane: tmuxPaneID)?.id)
        let amountPoints = 24

        let result = ControlCommandCoordinator(context: TerminalController.shared).handle(
            ControlRequest(
                id: .int(1),
                method: "pane.resize",
                params: [
                    "workspace_id": .string(harness.workspace.id.uuidString),
                    "pane_id": .string(paneID.uuidString),
                    "direction": .string("right"),
                    "amount": .int(Int64(amountPoints)),
                ]
            )
        )

        guard case .ok(let payload)? = result else {
            Issue.record("Projected mirror pane resize failed: \(String(describing: result))")
            return
        }
        let response = try #require(payload.foundationObject as? [String: Any])
        #expect(response["pane_id"] as? String == paneID.uuidString)
        #expect(response["direction"] as? String == "right")
        #expect(response["amount"] as? Int == amountPoints)
        let commands = try readControlCommands(harness)
        #expect(commands.contains("resize-pane -t @3.%\(tmuxPaneID) -R 3\n"))
    }

    @Test func absolutePaneResizeConvertsOuterPointsAndClampsSubcellGrid() throws {
        let layout = RemoteTmuxLayoutNode(
            width: 80, height: 24, x: 0, y: 0,
            content: .vertical([
                RemoteTmuxLayoutNode(width: 80, height: 11, x: 0, y: 0, content: .pane(11)),
                RemoteTmuxLayoutNode(width: 80, height: 12, x: 0, y: 12, content: .pane(22)),
            ])
        )
        let harness = try Harness(connectedTransport: true, mirrorLayout: layout)
        defer { harness.tearDown() }
        let tmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
        let paneID = try #require(harness.mirror.syntheticPaneID(forPane: tmuxPaneID)?.id)
        let tabBarHeight = harness.mirror.bonsplitController.configuration.appearance.tabBarHeight
        let paneChromePoints = tabBarHeight + 4
        let targetPoints = Double(paneChromePoints + 17 * 3.4)

        let convertedResult = ControlCommandCoordinator(context: TerminalController.shared).handle(
            ControlRequest(
                id: .int(1),
                method: "pane.resize",
                params: [
                    "workspace_id": .string(harness.workspace.id.uuidString),
                    "pane_id": .string(paneID.uuidString),
                    "absolute_axis": .string("vertical"),
                    "target_pixels": .double(targetPoints),
                ]
            )
        )
        guard case .ok(let payload)? = convertedResult else {
            Issue.record("Absolute mirror pane resize failed: \(String(describing: convertedResult))")
            return
        }
        let response = try #require(payload.foundationObject as? [String: Any])
        #expect(response["pane_id"] as? String == paneID.uuidString)
        #expect(response["absolute_axis"] as? String == "vertical")
        #expect(response["target_pixels"] as? Double == targetPoints)
        #expect(response["remote"] as? Bool == true)

        let subcellResult = ControlCommandCoordinator(context: TerminalController.shared).handle(
            ControlRequest(
                id: .int(2),
                method: "pane.resize",
                params: [
                    "workspace_id": .string(harness.workspace.id.uuidString),
                    "pane_id": .string(paneID.uuidString),
                    "absolute_axis": .string("vertical"),
                    "target_pixels": .double(Double(paneChromePoints + 0.1)),
                ]
            )
        )
        guard case .ok? = subcellResult else {
            Issue.record("Positive subcell mirror pane resize failed: \(String(describing: subcellResult))")
            return
        }
        let commands = try readControlCommands(harness)
        #expect(commands.contains("resize-pane -t @3.%\(tmuxPaneID) -y 3\n"))
        #expect(commands.contains("resize-pane -t @3.%\(tmuxPaneID) -y 1\n"))
    }

    @Test func paneResizeRejectsAbsentRemoteSplitBordersAndAxes() throws {
        let harness = try Harness(connectedTransport: true)
        defer { harness.tearDown() }
        let tmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
        let paneID = try #require(harness.mirror.syntheticPaneID(forPane: tmuxPaneID)?.id)
        let coordinator = ControlCommandCoordinator(context: TerminalController.shared)

        let outerEdge = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "pane.resize",
            params: [
                "workspace_id": .string(harness.workspace.id.uuidString),
                "pane_id": .string(paneID.uuidString),
                "direction": .string("left"),
                "amount": .int(8),
            ]
        ))
        guard case .err(let edgeCode, _, let edgeData)? = outerEdge else {
            Issue.record("Outer-edge resize unexpectedly succeeded: \(String(describing: outerEdge))")
            return
        }
        #expect(edgeCode == "invalid_state")
        #expect(edgeData == .object([
            "pane_id": .string(paneID.uuidString),
            "direction": .string("left"),
        ]))

        let absentAxis = coordinator.handle(ControlRequest(
            id: .int(2),
            method: "pane.resize",
            params: [
                "workspace_id": .string(harness.workspace.id.uuidString),
                "pane_id": .string(paneID.uuidString),
                "absolute_axis": .string("vertical"),
                "target_pixels": .double(100),
            ]
        ))
        guard case .err(let axisCode, _, let axisData)? = absentAxis else {
            Issue.record("Absent-axis resize unexpectedly succeeded: \(String(describing: absentAxis))")
            return
        }
        #expect(axisCode == "invalid_state")
        #expect(axisData == .object([
            "pane_id": .string(paneID.uuidString),
            "absolute_axis": .string("vertical"),
        ]))
        #expect(try readControlCommands(harness).isEmpty)
    }

    private func readControlCommands(_ harness: Harness) throws -> String {
        let writer = try #require(harness.controlWriter)
        let pipe = try #require(harness.controlPipe)
        writer.close()
        return try #require(String(
            bytes: try pipe.fileHandleForReading.readToEnd() ?? Data(),
            encoding: .utf8
        ))
    }
}
