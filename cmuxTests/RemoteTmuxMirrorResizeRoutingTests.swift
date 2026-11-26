import CmuxRemoteSession
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
        let cellHintResult = ControlCommandCoordinator(context: TerminalController.shared).handle(
            ControlRequest(
                id: .int(3),
                method: "pane.resize",
                params: [
                    "workspace_id": .string(harness.workspace.id.uuidString),
                    "pane_id": .string(paneID.uuidString),
                    "absolute_axis": .string("vertical"),
                    "target_pixels": .double(targetPoints),
                    "target_cells": .int(7),
                    "tmux_compat": .bool(true),
                ]
            )
        )
        guard case .ok? = cellHintResult else {
            Issue.record("Exact-cell mirror pane resize failed: \(String(describing: cellHintResult))")
            return
        }
        let percentageResult = ControlCommandCoordinator(context: TerminalController.shared).handle(
            ControlRequest(
                id: .int(4),
                method: "pane.resize",
                params: [
                    "workspace_id": .string(harness.workspace.id.uuidString),
                    "pane_id": .string(paneID.uuidString),
                    "absolute_axis": .string("vertical"),
                    "target_pixels": .double(targetPoints),
                    "target_percentage": .int(50),
                    "tmux_compat": .bool(true),
                ]
            )
        )
        guard case .ok? = percentageResult else {
            Issue.record("Percentage mirror pane resize failed: \(String(describing: percentageResult))")
            return
        }
        let commands = try readControlCommands(harness)
        #expect(commands.contains("resize-pane -t @3.%\(tmuxPaneID) -y 3\n"))
        #expect(commands.contains("resize-pane -t @3.%\(tmuxPaneID) -y 1\n"))
        #expect(commands.contains("resize-pane -t @3.%\(tmuxPaneID) -y 7\n"))
        #expect(commands.contains("resize-pane -t @3.%\(tmuxPaneID) -y 50%\n"))
    }

    @Test func paneResizeTargetsTheSelectedLeadingBorderInNaryLayout() throws {
        let layout = RemoteTmuxLayoutNode(
            width: 160, height: 24, x: 0, y: 0,
            content: .horizontal([
                RemoteTmuxLayoutNode(width: 39, height: 24, x: 0, y: 0, content: .pane(11)),
                RemoteTmuxLayoutNode(width: 39, height: 24, x: 40, y: 0, content: .pane(22)),
                RemoteTmuxLayoutNode(width: 39, height: 24, x: 80, y: 0, content: .pane(33)),
                RemoteTmuxLayoutNode(width: 40, height: 24, x: 120, y: 0, content: .pane(44)),
            ])
        )
        let harness = try Harness(connectedTransport: true, mirrorLayout: layout)
        defer { harness.tearDown() }
        let paneID = try #require(harness.mirror.syntheticPaneID(forPane: 22)?.id)

        let result = ControlCommandCoordinator(context: TerminalController.shared).handle(
            ControlRequest(
                id: .int(1),
                method: "pane.resize",
                params: [
                    "workspace_id": .string(harness.workspace.id.uuidString),
                    "pane_id": .string(paneID.uuidString),
                    "direction": .string("left"),
                    "amount": .int(8),
                ]
            )
        )
        guard case .ok? = result else {
            Issue.record("Middle-pane leading resize failed: \(String(describing: result))")
            return
        }
        let trailingResult = ControlCommandCoordinator(context: TerminalController.shared).handle(
            ControlRequest(
                id: .int(2),
                method: "pane.resize",
                params: [
                    "workspace_id": .string(harness.workspace.id.uuidString),
                    "pane_id": .string(paneID.uuidString),
                    "direction": .string("right"),
                    "amount": .int(8),
                ]
            )
        )
        guard case .ok? = trailingResult else {
            Issue.record("Middle-pane trailing resize failed: \(String(describing: trailingResult))")
            return
        }
        let firstPaneID = try #require(harness.mirror.syntheticPaneID(forPane: 11)?.id)
        let hintedResult = ControlCommandCoordinator(context: TerminalController.shared).handle(
            ControlRequest(
                id: .int(3),
                method: "pane.resize",
                params: [
                    "workspace_id": .string(harness.workspace.id.uuidString),
                    "pane_id": .string(firstPaneID.uuidString),
                    "direction": .string("left"),
                    "amount": .int(160),
                    "amount_cells": .int(2),
                    "tmux_compat": .bool(true),
                ]
            )
        )
        guard case .ok? = hintedResult else {
            Issue.record("Exact-cell relative resize failed: \(String(describing: hintedResult))")
            return
        }
        let commands = try readControlCommands(harness)
        #expect(commands.contains("resize-pane -t @3.%11 -L 1\n"))
        #expect(!commands.contains("resize-pane -t @3.%22 -L"))
        #expect(commands.contains("resize-pane -t @3.%22 -R 1\n"))
        #expect(!commands.contains("resize-pane -t @3.%33 -R"))
        #expect(commands.contains("resize-pane -t @3.%11 -L 2\n"))
    }

    @Test func paneResizeTargetsTheAncestorThatOwnsANestedTrailingBorder() throws {
        let layout = RemoteTmuxLayoutNode(
            width: 120, height: 48, x: 0, y: 0,
            content: .horizontal([
                RemoteTmuxLayoutNode(
                    width: 80, height: 48, x: 0, y: 0,
                    content: .vertical([
                        RemoteTmuxLayoutNode(
                            width: 80, height: 23, x: 0, y: 0,
                            content: .horizontal([
                                RemoteTmuxLayoutNode(width: 39, height: 23, x: 0, y: 0, content: .pane(11)),
                                RemoteTmuxLayoutNode(width: 40, height: 23, x: 40, y: 0, content: .pane(22)),
                            ])
                        ),
                        RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 24, content: .pane(33)),
                    ])
                ),
                RemoteTmuxLayoutNode(width: 39, height: 48, x: 81, y: 0, content: .pane(44)),
            ])
        )
        let harness = try Harness(connectedTransport: true, mirrorLayout: layout)
        defer { harness.tearDown() }
        let paneID = try #require(harness.mirror.syntheticPaneID(forPane: 22)?.id)

        let result = ControlCommandCoordinator(context: TerminalController.shared).handle(
            ControlRequest(
                id: .int(1),
                method: "pane.resize",
                params: [
                    "workspace_id": .string(harness.workspace.id.uuidString),
                    "pane_id": .string(paneID.uuidString),
                    "direction": .string("right"),
                    "amount": .int(8),
                ]
            )
        )
        guard case .ok? = result else {
            Issue.record("Nested trailing-border resize failed: \(String(describing: result))")
            return
        }
        // The control stream legitimately carries the attach-time
        // `list-windows` topology fetch (sent when the first command result
        // drains the attach block), so judge only the resize sends: exactly
        // one, and it must target the ancestor (%33) that owns the nested
        // trailing border rather than the requested inner pane.
        let resizeCommands = try readControlCommands(harness)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("resize-pane") }
        #expect(resizeCommands == ["resize-pane -t @3.%33 -R 1"])
    }

    @Test func paneResizeRejectsMalformedExplicitUnitValues() throws {
        let harness = try Harness(connectedTransport: true)
        defer { harness.tearDown() }
        let tmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
        let paneID = try #require(harness.mirror.syntheticPaneID(forPane: tmuxPaneID)?.id)
        let coordinator = ControlCommandCoordinator(context: TerminalController.shared)
        let requests: [[String: JSONValue]] = [
            [
                "workspace_id": .string(harness.workspace.id.uuidString),
                "pane_id": .string(paneID.uuidString),
                "direction": .string("right"),
                "amount": .string("bad"),
            ],
            [
                "workspace_id": .string(harness.workspace.id.uuidString),
                "pane_id": .string(paneID.uuidString),
                "absolute_axis": .string("horizontal"),
                "target_pixels": .double(40),
                "target_cells": .int(0),
                "tmux_compat": .bool(true),
            ],
            [
                "workspace_id": .string(harness.workspace.id.uuidString),
                "pane_id": .string(paneID.uuidString),
                "direction": .string("right"),
                "amount": .int(8),
                "amount_cells": .int(0),
                "tmux_compat": .bool(true),
            ],
        ]

        for (index, params) in requests.enumerated() {
            let result = coordinator.handle(ControlRequest(
                id: .int(Int64(index + 1)),
                method: "pane.resize",
                params: params
            ))
            guard case .err(let code, _, _)? = result else {
                Issue.record("Malformed resize unexpectedly succeeded: \(String(describing: result))")
                continue
            }
            #expect(code == "invalid_params")
        }
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
        let tmuxCompatibleAxis = coordinator.handle(ControlRequest(
            id: .int(3),
            method: "pane.resize",
            params: [
                "workspace_id": .string(harness.workspace.id.uuidString),
                "pane_id": .string(paneID.uuidString),
                "absolute_axis": .string("vertical"),
                "target_pixels": .double(68),
                "target_cells": .int(4),
                "tmux_compat": .bool(true),
            ]
        ))
        guard case .ok? = tmuxCompatibleAxis else {
            Issue.record("Native tmux absolute resize failed: \(String(describing: tmuxCompatibleAxis))")
            return
        }
        // Same filtering rationale as
        // paneResizeTargetsTheAncestorThatOwnsANestedTrailingBorder: ignore the
        // attach-time `list-windows` topology fetch and require that the two
        // rejected requests sent nothing while the tmux-compat request sent
        // exactly one absolute resize.
        let resizeCommands = try readControlCommands(harness)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("resize-pane") }
        #expect(resizeCommands == ["resize-pane -t @3.%\(tmuxPaneID) -y 4"])
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
