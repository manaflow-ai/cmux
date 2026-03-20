import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - TmuxKeyEncoder Tests

final class TmuxKeyEncoderTests: XCTestCase {

    func testEmptyDataProducesNoCommands() {
        let commands = TmuxKeyEncoder.encode(Data(), forPane: 0)
        XCTAssertTrue(commands.isEmpty)
    }

    func testPureLiteralCharacters() {
        let data = Data("hello".utf8)
        let commands = TmuxKeyEncoder.encode(data, forPane: 5)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0], "send-keys -lt %5 hello\n")
    }

    func testSpaceIsLiteral() {
        let data = Data("a b".utf8)
        let commands = TmuxKeyEncoder.encode(data, forPane: 1)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0], "send-keys -lt %1 a b\n")
    }

    func testSpecialLiteralCharacters() {
        // +/):,_ are all literal per spec SS8
        let data = Data("+/):,_".utf8)
        let commands = TmuxKeyEncoder.encode(data, forPane: 2)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0], "send-keys -lt %2 +/):,_\n")
    }

    func testDigitsAreLiteral() {
        let data = Data("0123456789".utf8)
        let commands = TmuxKeyEncoder.encode(data, forPane: 3)

        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].hasPrefix("send-keys -lt %3"))
    }

    func testEscapeIsHexEncoded() {
        let data = Data([0x1B])
        let commands = TmuxKeyEncoder.encode(data, forPane: 10)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0], "send-keys -t %10 0x1B\n")
    }

    func testReturnIsHexEncoded() {
        let data = Data([0x0D])
        let commands = TmuxKeyEncoder.encode(data, forPane: 7)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0], "send-keys -t %7 0x0D\n")
    }

    func testTabIsHexEncoded() {
        let data = Data([0x09])
        let commands = TmuxKeyEncoder.encode(data, forPane: 8)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0], "send-keys -t %8 0x09\n")
    }

    func testMixedLiteralAndHexProducesMultipleCommands() {
        // "hello" (literal) + ESC (hex) + "world" (literal)
        var data = Data("hello".utf8)
        data.append(0x1B)
        data.append(contentsOf: "world".utf8)
        let commands = TmuxKeyEncoder.encode(data, forPane: 99)

        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(commands[0], "send-keys -lt %99 hello\n")
        XCTAssertEqual(commands[1], "send-keys -t %99 0x1B\n")
        XCTAssertEqual(commands[2], "send-keys -lt %99 world\n")
    }

    func testConsecutiveHexBytesAreBatched() {
        let data = Data([0x1B, 0x5B, 0x41])  // ESC [ A (arrow up)
        let commands = TmuxKeyEncoder.encode(data, forPane: 4)

        // ESC and [ are hex, A is literal → 2 commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0], "send-keys -t %4 0x1B 0x5B\n")
        XCTAssertEqual(commands[1], "send-keys -lt %4 A\n")
    }

    func testLiteralBatchLimit() {
        let longString = String(repeating: "a", count: TmuxKeyEncoder.maxLiteralBatch + 50)
        let data = Data(longString.utf8)
        let commands = TmuxKeyEncoder.encode(data, forPane: 6)

        XCTAssertEqual(commands.count, 2)
        // First batch should be exactly maxLiteralBatch characters
        let expectedFirst = "send-keys -lt %6 " + String(repeating: "a", count: TmuxKeyEncoder.maxLiteralBatch) + "\n"
        XCTAssertEqual(commands[0], expectedFirst)
        // Second batch should have the remainder
        let expectedSecond = "send-keys -lt %6 " + String(repeating: "a", count: 50) + "\n"
        XCTAssertEqual(commands[1], expectedSecond)
    }

    func testHexBatchLimit() {
        // Create more than maxHexBatch non-literal bytes
        let count = TmuxKeyEncoder.maxHexBatch + 10
        let data = Data(repeating: 0x01, count: count)
        let commands = TmuxKeyEncoder.encode(data, forPane: 11)

        XCTAssertEqual(commands.count, 2)
        // First command should have maxHexBatch hex values
        let firstHexCount = commands[0].components(separatedBy: "0x").count - 1
        XCTAssertEqual(firstHexCount, TmuxKeyEncoder.maxHexBatch)
        // Second command should have the remainder
        let secondHexCount = commands[1].components(separatedBy: "0x").count - 1
        XCTAssertEqual(secondHexCount, 10)
    }

    func testAllCommandsEndWithNewline() {
        var data = Data("test".utf8)
        data.append(0x1B)
        data.append(contentsOf: "more".utf8)
        let commands = TmuxKeyEncoder.encode(data, forPane: 0)

        for command in commands {
            XCTAssertTrue(command.hasSuffix("\n"), "Command missing newline: \(command)")
        }
    }
}

// MARK: - TmuxLayoutEngine Tests

final class TmuxLayoutEngineTests: XCTestCase {

    // MARK: - toBinary

    func testSinglePaneConvertsToLeaf() {
        let node = TmuxLayoutNode.pane(TmuxLayoutLeaf(
            paneId: 0, width: 80, height: 24, x: 0, y: 0
        ))
        let binary = TmuxLayoutEngine.toBinary(node)

        switch binary {
        case .leaf(let paneId, _, _, _, _):
            XCTAssertEqual(paneId, 0)
        case .split:
            XCTFail("Single pane should be a leaf, not a split")
        }
    }

    func testTwoPaneHorizontalSplit() {
        let left = TmuxLayoutNode.pane(TmuxLayoutLeaf(
            paneId: 0, width: 39, height: 24, x: 0, y: 0
        ))
        let right = TmuxLayoutNode.pane(TmuxLayoutLeaf(
            paneId: 1, width: 40, height: 24, x: 40, y: 0
        ))
        let node = TmuxLayoutNode.horizontal(TmuxLayoutSplit(
            width: 80, height: 24, x: 0, y: 0, children: [left, right]
        ))
        let binary = TmuxLayoutEngine.toBinary(node)

        switch binary {
        case .split(let orientation, let first, let second, let fraction):
            XCTAssertEqual(orientation, .horizontal)
            // fraction = 39 / (39 + 1 + 40) = 39/80 ≈ 0.4875
            XCTAssertEqual(fraction, CGFloat(39) / CGFloat(80), accuracy: 0.001)
            XCTAssertEqual(first.allPaneIds, [0])
            XCTAssertEqual(second.allPaneIds, [1])
        case .leaf:
            XCTFail("Two-pane layout should be a split")
        }
    }

    func testTwoPaneVerticalSplit() {
        let top = TmuxLayoutNode.pane(TmuxLayoutLeaf(
            paneId: 0, width: 80, height: 11, x: 0, y: 0
        ))
        let bottom = TmuxLayoutNode.pane(TmuxLayoutLeaf(
            paneId: 1, width: 80, height: 12, x: 0, y: 12
        ))
        let node = TmuxLayoutNode.vertical(TmuxLayoutSplit(
            width: 80, height: 24, x: 0, y: 0, children: [top, bottom]
        ))
        let binary = TmuxLayoutEngine.toBinary(node)

        switch binary {
        case .split(let orientation, _, _, let fraction):
            XCTAssertEqual(orientation, .vertical)
            // fraction = 11 / (11 + 1 + 12) = 11/24 ≈ 0.458
            XCTAssertEqual(fraction, CGFloat(11) / CGFloat(24), accuracy: 0.001)
        case .leaf:
            XCTFail("Two-pane layout should be a split")
        }
    }

    func testThreePaneRightFolds() {
        // Three horizontal panes: A(26) | B(26) | C(26) with dividers
        let a = TmuxLayoutNode.pane(TmuxLayoutLeaf(paneId: 0, width: 26, height: 24, x: 0, y: 0))
        let b = TmuxLayoutNode.pane(TmuxLayoutLeaf(paneId: 1, width: 26, height: 24, x: 27, y: 0))
        let c = TmuxLayoutNode.pane(TmuxLayoutLeaf(paneId: 2, width: 26, height: 24, x: 54, y: 0))
        let node = TmuxLayoutNode.horizontal(TmuxLayoutSplit(
            width: 80, height: 24, x: 0, y: 0, children: [a, b, c]
        ))
        let binary = TmuxLayoutEngine.toBinary(node)

        // Should be: split(A, split(B, C))
        switch binary {
        case .split(_, let first, let second, _):
            XCTAssertEqual(first.allPaneIds, [0])
            switch second {
            case .split(_, let innerFirst, let innerSecond, _):
                XCTAssertEqual(innerFirst.allPaneIds, [1])
                XCTAssertEqual(innerSecond.allPaneIds, [2])
            case .leaf:
                XCTFail("Inner node should be a split")
            }
        case .leaf:
            XCTFail("Three-pane layout should be a split")
        }
    }

    func testFourPaneFoldsCorrectly() {
        let panes = (0..<4).map { i in
            TmuxLayoutNode.pane(TmuxLayoutLeaf(
                paneId: i, width: 19, height: 24, x: i * 20, y: 0
            ))
        }
        let node = TmuxLayoutNode.horizontal(TmuxLayoutSplit(
            width: 80, height: 24, x: 0, y: 0, children: panes
        ))
        let binary = TmuxLayoutEngine.toBinary(node)

        // Should produce: split(0, split(1, split(2, 3)))
        let allIds = binary.allPaneIds
        XCTAssertEqual(allIds, [0, 1, 2, 3])
    }

    func testAllPaneIdsCollectsAllLeaves() {
        let leaf = TmuxLayoutEngine.BinaryNode.leaf(paneId: 42, width: 80, height: 24, x: 0, y: 0)
        XCTAssertEqual(leaf.allPaneIds, [42])

        let split = TmuxLayoutEngine.BinaryNode.split(
            orientation: .horizontal,
            first: .leaf(paneId: 1, width: 40, height: 24, x: 0, y: 0),
            second: .leaf(paneId: 2, width: 40, height: 24, x: 41, y: 0),
            dividerFraction: 0.5
        )
        XCTAssertEqual(split.allPaneIds, [1, 2])
    }

    // MARK: - Diffing

    func testDiffIdenticalLayoutsProducesNoOps() {
        let layout = TmuxLayoutNode.pane(TmuxLayoutLeaf(
            paneId: 0, width: 80, height: 24, x: 0, y: 0
        ))
        let ops = TmuxLayoutEngine.diff(old: layout, new: layout)

        XCTAssertTrue(ops.isEmpty)
    }

    func testDiffSamePaneDifferentSizeProducesResize() {
        let old = TmuxLayoutNode.pane(TmuxLayoutLeaf(
            paneId: 0, width: 80, height: 24, x: 0, y: 0
        ))
        let new = TmuxLayoutNode.pane(TmuxLayoutLeaf(
            paneId: 0, width: 100, height: 30, x: 0, y: 0
        ))
        let ops = TmuxLayoutEngine.diff(old: old, new: new)

        XCTAssertEqual(ops.count, 1)
        switch ops[0] {
        case .resize(let paneId, let width, let height):
            XCTAssertEqual(paneId, 0)
            XCTAssertEqual(width, 100)
            XCTAssertEqual(height, 30)
        case .rebuild:
            XCTFail("Same topology with size change should produce resize, not rebuild")
        }
    }

    func testDiffDifferentPaneSetProducesRebuild() {
        let old = TmuxLayoutNode.pane(TmuxLayoutLeaf(
            paneId: 0, width: 80, height: 24, x: 0, y: 0
        ))
        let new = TmuxLayoutNode.pane(TmuxLayoutLeaf(
            paneId: 1, width: 80, height: 24, x: 0, y: 0
        ))
        let ops = TmuxLayoutEngine.diff(old: old, new: new)

        XCTAssertEqual(ops.count, 1)
        switch ops[0] {
        case .rebuild:
            break  // Expected
        case .resize:
            XCTFail("Different pane set should produce rebuild")
        }
    }

    func testDiffTopologyChangeProducesRebuild() {
        let oldLeft = TmuxLayoutNode.pane(TmuxLayoutLeaf(paneId: 0, width: 40, height: 24, x: 0, y: 0))
        let oldRight = TmuxLayoutNode.pane(TmuxLayoutLeaf(paneId: 1, width: 40, height: 24, x: 41, y: 0))
        let old = TmuxLayoutNode.horizontal(TmuxLayoutSplit(
            width: 80, height: 24, x: 0, y: 0, children: [oldLeft, oldRight]
        ))

        // Same panes but vertical instead of horizontal
        let newTop = TmuxLayoutNode.pane(TmuxLayoutLeaf(paneId: 0, width: 80, height: 11, x: 0, y: 0))
        let newBottom = TmuxLayoutNode.pane(TmuxLayoutLeaf(paneId: 1, width: 80, height: 12, x: 0, y: 12))
        let new = TmuxLayoutNode.vertical(TmuxLayoutSplit(
            width: 80, height: 24, x: 0, y: 0, children: [newTop, newBottom]
        ))

        let ops = TmuxLayoutEngine.diff(old: old, new: new)
        XCTAssertEqual(ops.count, 1)
        switch ops[0] {
        case .rebuild:
            break  // Expected
        case .resize:
            XCTFail("Topology change should produce rebuild")
        }
    }

    func testDiffSameTopologyDifferentSizesProducesResizes() {
        let oldLeft = TmuxLayoutNode.pane(TmuxLayoutLeaf(paneId: 0, width: 40, height: 24, x: 0, y: 0))
        let oldRight = TmuxLayoutNode.pane(TmuxLayoutLeaf(paneId: 1, width: 40, height: 24, x: 41, y: 0))
        let old = TmuxLayoutNode.horizontal(TmuxLayoutSplit(
            width: 80, height: 24, x: 0, y: 0, children: [oldLeft, oldRight]
        ))

        let newLeft = TmuxLayoutNode.pane(TmuxLayoutLeaf(paneId: 0, width: 50, height: 24, x: 0, y: 0))
        let newRight = TmuxLayoutNode.pane(TmuxLayoutLeaf(paneId: 1, width: 30, height: 24, x: 51, y: 0))
        let new = TmuxLayoutNode.horizontal(TmuxLayoutSplit(
            width: 80, height: 24, x: 0, y: 0, children: [newLeft, newRight]
        ))

        let ops = TmuxLayoutEngine.diff(old: old, new: new)
        XCTAssertEqual(ops.count, 2)
        for op in ops {
            switch op {
            case .resize:
                break  // Expected
            case .rebuild:
                XCTFail("Same topology with size changes should produce resizes, not rebuild")
            }
        }
    }
}

// MARK: - TmuxTypes Codable Tests

final class TmuxTypesTests: XCTestCase {

    func testTmuxSessionInfoRoundtrips() throws {
        let info = TmuxSessionInfo(
            sessionName: "main",
            connectionCommand: "tmux -CC attach -t main"
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(TmuxSessionInfo.self, from: data)

        XCTAssertEqual(decoded.sessionName, "main")
        XCTAssertEqual(decoded.connectionCommand, "tmux -CC attach -t main")
    }

    func testTmuxWindowsPayloadDecodes() throws {
        let json = """
        {
            "session_id": 0,
            "tmux_version": "3.5a",
            "windows": [
                {
                    "id": 0,
                    "width": 80,
                    "height": 24,
                    "layout": {"width": 80, "height": 24, "x": 0, "y": 0, "pane": 0}
                }
            ]
        }
        """
        let data = Data(json.utf8)
        let payload = try JSONDecoder().decode(TmuxWindowsPayload.self, from: data)

        XCTAssertEqual(payload.sessionId, 0)
        XCTAssertEqual(payload.tmuxVersion, "3.5a")
        XCTAssertEqual(payload.windows.count, 1)
        XCTAssertEqual(payload.windows[0].id, 0)
        XCTAssertEqual(payload.windows[0].width, 80)
        XCTAssertEqual(payload.windows[0].height, 24)
    }

    func testLayoutNodePaneDecodes() throws {
        let json = """
        {"width": 80, "height": 24, "x": 0, "y": 0, "pane": 5}
        """
        let node = try JSONDecoder().decode(TmuxLayoutNode.self, from: Data(json.utf8))

        switch node {
        case .pane(let leaf):
            XCTAssertEqual(leaf.paneId, 5)
            XCTAssertEqual(leaf.width, 80)
            XCTAssertEqual(leaf.height, 24)
            XCTAssertEqual(leaf.x, 0)
            XCTAssertEqual(leaf.y, 0)
        default:
            XCTFail("Expected pane node")
        }
    }

    func testLayoutNodeHorizontalSplitDecodes() throws {
        let json = """
        {
            "width": 80, "height": 24, "x": 0, "y": 0,
            "horizontal": [
                {"width": 39, "height": 24, "x": 0, "y": 0, "pane": 0},
                {"width": 40, "height": 24, "x": 40, "y": 0, "pane": 1}
            ]
        }
        """
        let node = try JSONDecoder().decode(TmuxLayoutNode.self, from: Data(json.utf8))

        switch node {
        case .horizontal(let split):
            XCTAssertEqual(split.children.count, 2)
            XCTAssertEqual(node.allPaneIds, [0, 1])
        default:
            XCTFail("Expected horizontal split")
        }
    }

    func testLayoutNodeVerticalSplitDecodes() throws {
        let json = """
        {
            "width": 80, "height": 24, "x": 0, "y": 0,
            "vertical": [
                {"width": 80, "height": 11, "x": 0, "y": 0, "pane": 0},
                {"width": 80, "height": 12, "x": 0, "y": 12, "pane": 1}
            ]
        }
        """
        let node = try JSONDecoder().decode(TmuxLayoutNode.self, from: Data(json.utf8))

        switch node {
        case .vertical(let split):
            XCTAssertEqual(split.children.count, 2)
            XCTAssertEqual(node.allPaneIds, [0, 1])
        default:
            XCTFail("Expected vertical split")
        }
    }

    func testLayoutNodeNestedDecodes() throws {
        let json = """
        {
            "width": 80, "height": 24, "x": 0, "y": 0,
            "horizontal": [
                {
                    "width": 39, "height": 24, "x": 0, "y": 0,
                    "vertical": [
                        {"width": 39, "height": 11, "x": 0, "y": 0, "pane": 0},
                        {"width": 39, "height": 12, "x": 0, "y": 12, "pane": 1}
                    ]
                },
                {"width": 40, "height": 24, "x": 40, "y": 0, "pane": 2}
            ]
        }
        """
        let node = try JSONDecoder().decode(TmuxLayoutNode.self, from: Data(json.utf8))

        XCTAssertEqual(node.allPaneIds.sorted(), [0, 1, 2])
        XCTAssertEqual(node.width, 80)
        XCTAssertEqual(node.height, 24)
    }

    func testLayoutNodeRoundtrips() throws {
        let leaf = TmuxLayoutNode.pane(TmuxLayoutLeaf(
            paneId: 3, width: 80, height: 24, x: 5, y: 10
        ))
        let data = try JSONEncoder().encode(leaf)
        let decoded = try JSONDecoder().decode(TmuxLayoutNode.self, from: data)

        switch decoded {
        case .pane(let decodedLeaf):
            XCTAssertEqual(decodedLeaf.paneId, 3)
            XCTAssertEqual(decodedLeaf.width, 80)
            XCTAssertEqual(decodedLeaf.x, 5)
            XCTAssertEqual(decodedLeaf.y, 10)
        default:
            XCTFail("Expected pane node after roundtrip")
        }
    }

    func testLayoutNodeInvalidJsonThrows() {
        let json = """
        {"width": 80, "height": 24, "x": 0, "y": 0}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(TmuxLayoutNode.self, from: Data(json.utf8))
        )
    }

    func testLayoutNodeWidthAndHeightAccessors() {
        let pane = TmuxLayoutNode.pane(TmuxLayoutLeaf(paneId: 0, width: 100, height: 50, x: 0, y: 0))
        XCTAssertEqual(pane.width, 100)
        XCTAssertEqual(pane.height, 50)

        let split = TmuxLayoutNode.horizontal(TmuxLayoutSplit(
            width: 200, height: 100, x: 0, y: 0,
            children: [pane]
        ))
        XCTAssertEqual(split.width, 200)
        XCTAssertEqual(split.height, 100)
    }
}

// MARK: - TmuxCapabilities Tests

final class TmuxCapabilitiesTests: XCTestCase {

    func testVersion35aSupportsAllFeatures() {
        let caps = TmuxCapabilities(versionCheck: { minimum in
            // Simulate tmux 3.5a
            versionCompare("3.5", atLeast: minimum)
        })

        XCTAssertTrue(caps.supportsPauseMode)
        XCTAssertTrue(caps.supportsVariableWindowSize)
        XCTAssertTrue(caps.supportsPerWindowRefreshClient)
        XCTAssertTrue(caps.supportsSubscriptions)
    }

    func testVersion31SupportsPauseModeButNotPerWindowRefresh() {
        let caps = TmuxCapabilities(versionCheck: { minimum in
            versionCompare("3.1", atLeast: minimum)
        })

        // 3.1 < 3.2 → no pause mode
        XCTAssertFalse(caps.supportsPauseMode)
        XCTAssertTrue(caps.supportsVariableWindowSize)
        XCTAssertFalse(caps.supportsPerWindowRefreshClient)
        XCTAssertFalse(caps.supportsSubscriptions)
    }

    func testVersion28DoesNotSupportVariableWindowSize() {
        let caps = TmuxCapabilities(versionCheck: { minimum in
            versionCompare("2.8", atLeast: minimum)
        })

        XCTAssertFalse(caps.supportsPauseMode)
        XCTAssertFalse(caps.supportsVariableWindowSize)
        XCTAssertFalse(caps.supportsPerWindowRefreshClient)
        XCTAssertFalse(caps.supportsSubscriptions)
    }

    func testVersion32SupportsPauseModeAndSubscriptions() {
        let caps = TmuxCapabilities(versionCheck: { minimum in
            versionCompare("3.2", atLeast: minimum)
        })

        XCTAssertTrue(caps.supportsPauseMode)
        XCTAssertTrue(caps.supportsVariableWindowSize)
        XCTAssertFalse(caps.supportsPerWindowRefreshClient)
        XCTAssertTrue(caps.supportsSubscriptions)
    }

    func testVersion34SupportsPerWindowRefreshClient() {
        let caps = TmuxCapabilities(versionCheck: { minimum in
            versionCompare("3.4", atLeast: minimum)
        })

        XCTAssertTrue(caps.supportsPerWindowRefreshClient)
    }
}

// MARK: - TmuxConnectionState Tests

final class TmuxConnectionStateTests: XCTestCase {

    func testAllStatesHaveRawValues() {
        let states: [TmuxConnectionState] = [
            .connecting, .negotiating, .synchronizing,
            .connected, .disconnecting, .disconnected
        ]
        for state in states {
            XCTAssertFalse(state.rawValue.isEmpty, "State \(state) should have a non-empty raw value")
        }
    }
}

// MARK: - SessionWorkspaceSnapshot tmuxSession Tests

final class SessionWorkspaceSnapshotTmuxTests: XCTestCase {

    func testSnapshotWithoutTmuxSessionDecodesCleanly() throws {
        let json = """
        {
            "processTitle": "Terminal 1",
            "isPinned": false,
            "currentDirectory": "/Users/test",
            "layout": {"type": "pane", "pane": {"panelIds": [], "selectedPanelId": null}},
            "panels": [],
            "statusEntries": [],
            "logEntries": []
        }
        """
        let snapshot = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: Data(json.utf8))

        XCTAssertNil(snapshot.tmuxSession)
        XCTAssertEqual(snapshot.processTitle, "Terminal 1")
    }

    func testSnapshotWithTmuxSessionRoundtrips() throws {
        let json = """
        {
            "processTitle": "tmux:main",
            "isPinned": false,
            "currentDirectory": "/Users/test",
            "layout": {"type": "pane", "pane": {"panelIds": [], "selectedPanelId": null}},
            "panels": [],
            "statusEntries": [],
            "logEntries": [],
            "tmuxSession": {
                "sessionName": "main",
                "connectionCommand": "tmux -CC attach -t main"
            }
        }
        """
        let snapshot = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: Data(json.utf8))

        let tmux = try XCTUnwrap(snapshot.tmuxSession)
        XCTAssertEqual(tmux.sessionName, "main")
        XCTAssertEqual(tmux.connectionCommand, "tmux -CC attach -t main")

        // Roundtrip
        let reencoded = try JSONEncoder().encode(snapshot)
        let redecoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: reencoded)
        let reTmux = try XCTUnwrap(redecoded.tmuxSession)
        XCTAssertEqual(reTmux.sessionName, "main")
    }
}

// MARK: - Helpers

/// Simple version comparison for test fixtures.
private func versionCompare(_ current: String, atLeast minimum: String) -> Bool {
    let currentParts = current.components(separatedBy: ".").compactMap { Int($0) }
    let minimumParts = minimum.components(separatedBy: ".").compactMap { Int($0) }

    for i in 0..<max(currentParts.count, minimumParts.count) {
        let c = i < currentParts.count ? currentParts[i] : 0
        let m = i < minimumParts.count ? minimumParts[i] : 0
        if c > m { return true }
        if c < m { return false }
    }
    return true
}
