import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class TmuxControlParserTests: XCTestCase {

    // MARK: - %layout-change (TmuxControlEvent)

    func testLayoutChange_singlePane() {
        let event = TmuxControlParser.parseLine("%layout-change @1 bb62,220x50,0,0,1")
        guard case .layoutChange(let layout) = event else {
            return XCTFail("Expected .layoutChange, got \(String(describing: event))")
        }
        XCTAssertEqual(layout.windowId, "@1")
        XCTAssertEqual(layout.allPaneIds, ["%1"])
        XCTAssertFalse(layout.isZoomed)
    }

    func testLayoutChange_horizontalSplit() {
        let line = "%layout-change @2 ab12,220x50,0,0{110x50,0,0,3,110x50,111,0,4}"
        let event = TmuxControlParser.parseLine(line)
        guard case .layoutChange(let layout) = event else {
            return XCTFail("Expected .layoutChange")
        }
        XCTAssertEqual(layout.windowId, "@2")
        XCTAssertEqual(layout.allPaneIds, ["%3", "%4"])
    }

    func testLayoutChange_verticalSplit() {
        let line = "%layout-change @3 cd34,220x50,0,0[220x24,0,0,5,220x25,0,25,6]"
        let event = TmuxControlParser.parseLine(line)
        guard case .layoutChange(let layout) = event else {
            return XCTFail("Expected .layoutChange")
        }
        XCTAssertEqual(layout.windowId, "@3")
        XCTAssertEqual(layout.allPaneIds, ["%5", "%6"])
    }

    func testLayoutChange_paneIdsSortedNumerically() {
        // allPaneIds returns traversal order; extractPaneIds returns sorted.
        let line = "%layout-change @4 ef56,220x50,0,0{110x50,0,0,10,110x50,111,0,2}"
        let event = TmuxControlParser.parseLine(line)
        guard case .layoutChange(let layout) = event else {
            return XCTFail("Expected .layoutChange")
        }
        // Tree traversal order is left-to-right: %10, %2
        XCTAssertEqual(layout.allPaneIds, ["%10", "%2"])
        // extractPaneIds is the numerically-sorted convenience wrapper
        XCTAssertEqual(TmuxControlParser.extractPaneIds(from: "ef56,220x50,0,0{110x50,0,0,10,110x50,111,0,2}"), ["%2", "%10"])
    }

    func testLayoutChange_zoomFlag() {
        let line = "%layout-change @5 aa00,220x50,0,0,7 aa00,220x50,0,0,7 Z"
        let event = TmuxControlParser.parseLine(line)
        guard case .layoutChange(let layout) = event else {
            return XCTFail("Expected .layoutChange")
        }
        XCTAssertTrue(layout.isZoomed)
    }

    func testLayoutChange_noZoomFlag() {
        let line = "%layout-change @5 aa00,220x50,0,0,7 aa00,220x50,0,0,7"
        let event = TmuxControlParser.parseLine(line)
        guard case .layoutChange(let layout) = event else {
            return XCTFail("Expected .layoutChange")
        }
        XCTAssertFalse(layout.isZoomed)
    }

    func testLayoutChange_missingLayoutTokenReturnsNil() {
        XCTAssertNil(TmuxControlParser.parseLine("%layout-change @1"))
    }

    // MARK: - %window-add / %window-close

    func testWindowAdd() {
        let event = TmuxControlParser.parseLine("%window-add @7")
        guard case .windowAdd(let window) = event else {
            return XCTFail("Expected .windowAdd")
        }
        XCTAssertEqual(window, "@7")
    }

    func testWindowClose() {
        let event = TmuxControlParser.parseLine("%window-close @8")
        guard case .windowClose(let window) = event else {
            return XCTFail("Expected .windowClose")
        }
        XCTAssertEqual(window, "@8")
    }

    // MARK: - Session events

    func testSessionRenamed() {
        // Real tmux format: %session-renamed $<id> <newName>
        let event = TmuxControlParser.parseLine("%session-renamed $1 my-new-name")
        guard case .sessionRenamed(let id, let name) = event else {
            return XCTFail("Expected .sessionRenamed")
        }
        XCTAssertEqual(id, "$1")
        XCTAssertEqual(name, "my-new-name")
    }

    func testSessionsChanged() {
        let event = TmuxControlParser.parseLine("%sessions-changed")
        guard case .sessionsChanged = event else {
            return XCTFail("Expected .sessionsChanged")
        }
    }

    func testWindowRenamed() {
        let event = TmuxControlParser.parseLine("%window-renamed @3 bash")
        guard case .windowRenamed(let window, let name) = event else {
            return XCTFail("Expected .windowRenamed")
        }
        XCTAssertEqual(window, "@3")
        XCTAssertEqual(name, "bash")
    }

    func testSessionWindowChanged() {
        let event = TmuxControlParser.parseLine("%session-window-changed $2 @5")
        guard case .sessionWindowChanged(let sid, let win) = event else {
            return XCTFail("Expected .sessionWindowChanged")
        }
        XCTAssertEqual(sid, "$2")
        XCTAssertEqual(win, "@5")
    }

    func testWindowPaneChanged() {
        let event = TmuxControlParser.parseLine("%window-pane-changed @4 %9")
        guard case .windowPaneChanged(let window, let pane) = event else {
            return XCTFail("Expected .windowPaneChanged")
        }
        XCTAssertEqual(window, "@4")
        XCTAssertEqual(pane, "%9")
    }

    // MARK: - New stub events (tmux ≥2.5 / ≥3.6)

    func testPaneModeChanged() {
        let event = TmuxControlParser.parseLine("%pane-mode-changed %3 copy")
        guard case .paneModeChanged(let paneId, let mode) = event else {
            return XCTFail("Expected .paneModeChanged")
        }
        XCTAssertEqual(paneId, "%3")
        XCTAssertEqual(mode, "copy")
    }

    func testPaneModeChanged_noMode() {
        let event = TmuxControlParser.parseLine("%pane-mode-changed %5")
        guard case .paneModeChanged(let paneId, let mode) = event else {
            return XCTFail("Expected .paneModeChanged")
        }
        XCTAssertEqual(paneId, "%5")
        XCTAssertEqual(mode, "")
    }

    func testPasteBufferChanged() {
        let event = TmuxControlParser.parseLine("%paste-buffer-changed")
        guard case .pasteBufferChanged = event else {
            return XCTFail("Expected .pasteBufferChanged")
        }
    }

    func testClientSessionChanged() {
        let event = TmuxControlParser.parseLine("%client-session-changed")
        guard case .clientSessionChanged = event else {
            return XCTFail("Expected .clientSessionChanged")
        }
    }

    // MARK: - %exit

    func testExit() {
        let event = TmuxControlParser.parseLine("%exit")
        guard case .exit = event else {
            return XCTFail("Expected .exit")
        }
    }

    // MARK: - Unknown / non-events return nil

    func testBeginReturnsNil() {
        XCTAssertNil(TmuxControlParser.parseLine("%begin 1234567890 123 0"))
    }

    func testEndReturnsNil() {
        XCTAssertNil(TmuxControlParser.parseLine("%end 1234567890 123 0"))
    }

    func testErrorReturnsNil() {
        XCTAssertNil(TmuxControlParser.parseLine("%error 1234567890 123 0"))
    }

    func testNonPercentLineReturnsNil() {
        XCTAssertNil(TmuxControlParser.parseLine("some random output"))
    }

    func testEmptyLineReturnsNil() {
        XCTAssertNil(TmuxControlParser.parseLine(""))
    }

    func testCarriageReturnStripped() {
        let event = TmuxControlParser.parseLine("%window-close @1\r\n")
        guard case .windowClose = event else {
            return XCTFail("Expected .windowClose after CR/LF stripping")
        }
    }

    // MARK: - Layout checksum skipping

    func testChecksumPrefixSkipped() {
        let event = TmuxControlParser.parseLine("%layout-change @1 bb62,100x30,0,0,42")
        guard case .layoutChange(let layout) = event else {
            return XCTFail("Expected .layoutChange")
        }
        XCTAssertEqual(layout.allPaneIds, ["%42"])
    }

    func testNestedLayout_threeWaySplit() {
        let layoutStr = "aa00,220x50,0,0{110x50,0,0,1,110x50,111,0[110x24,111,0,2,110x25,111,25,3]}"
        let event = TmuxControlParser.parseLine("%layout-change @1 \(layoutStr)")
        guard case .layoutChange(let layout) = event else {
            return XCTFail("Expected .layoutChange")
        }
        XCTAssertEqual(Set(layout.allPaneIds), Set(["%1", "%2", "%3"]))
        XCTAssertEqual(layout.allPaneIds.count, 3)
    }

    // MARK: - extractPaneIds standalone

    func testExtractPaneIds_singleLeaf() {
        XCTAssertEqual(TmuxControlParser.extractPaneIds(from: "220x50,0,0,5"), ["%5"])
    }

    func testExtractPaneIds_withChecksum() {
        XCTAssertEqual(TmuxControlParser.extractPaneIds(from: "bb62,220x50,0,0,5"), ["%5"])
    }

    func testExtractPaneIds_emptyString() {
        XCTAssertEqual(TmuxControlParser.extractPaneIds(from: ""), [])
    }

    // MARK: - Layout tree (TmuxLayoutNode / TmuxLayout)

    func testParseLayoutTree_singlePane_geometry() {
        let layout = TmuxControlParser.parseLayoutTree(windowId: "@1", flags: "", layoutString: "bb62,220x50,0,0,3")
        XCTAssertNotNil(layout)
        guard case .pane(let geom) = layout?.root else {
            return XCTFail("Expected .pane root")
        }
        XCTAssertEqual(geom.paneId, "%3")
        XCTAssertEqual(geom.width, 220)
        XCTAssertEqual(geom.height, 50)
        XCTAssertEqual(geom.x, 0)
        XCTAssertEqual(geom.y, 0)
    }

    func testParseLayoutTree_horizontalSplit_structure() {
        // Two panes side by side
        let str = "abcd,220x50,0,0{110x50,0,0,1,110x50,111,0,2}"
        let layout = TmuxControlParser.parseLayoutTree(windowId: "@2", flags: "", layoutString: str)
        XCTAssertNotNil(layout)
        guard case .horizontal(let children, let w, _, _, _) = layout?.root else {
            return XCTFail("Expected .horizontal root")
        }
        XCTAssertEqual(w, 220)
        XCTAssertEqual(children.count, 2)
        guard case .pane(let left) = children[0], case .pane(let right) = children[1] else {
            return XCTFail("Expected two pane children")
        }
        XCTAssertEqual(left.paneId, "%1")
        XCTAssertEqual(right.paneId, "%2")
    }

    func testParseLayoutTree_verticalSplit_structure() {
        // Two panes stacked
        let str = "abcd,220x50,0,0[220x25,0,0,1,220x24,0,26,2]"
        let layout = TmuxControlParser.parseLayoutTree(windowId: "@3", flags: "", layoutString: str)
        XCTAssertNotNil(layout)
        guard case .vertical(let children, _, _, _, _) = layout?.root else {
            return XCTFail("Expected .vertical root")
        }
        XCTAssertEqual(children.count, 2)
    }

    func testParseLayoutTree_nestedSplit_threePane() {
        // Left pane | right side [top/bottom]
        let str = "aa00,220x50,0,0{110x50,0,0,1,110x50,111,0[110x24,111,0,2,110x25,111,25,3]}"
        let layout = TmuxControlParser.parseLayoutTree(windowId: "@4", flags: "", layoutString: str)
        XCTAssertNotNil(layout)
        guard case .horizontal(let children, _, _, _, _) = layout?.root else {
            return XCTFail("Expected .horizontal root")
        }
        XCTAssertEqual(children.count, 2)
        guard case .pane(let left) = children[0] else {
            return XCTFail("Expected left child to be pane")
        }
        XCTAssertEqual(left.paneId, "%1")
        guard case .vertical(let rightChildren, _, _, _, _) = children[1] else {
            return XCTFail("Expected right child to be vertical split")
        }
        XCTAssertEqual(rightChildren.count, 2)
        XCTAssertEqual(layout?.allPaneIds, ["%1", "%2", "%3"])
    }

    func testParseLayoutTree_zoomFlag() {
        let layout = TmuxControlParser.parseLayoutTree(windowId: "@5", flags: "*Z",
                                                        layoutString: "aa00,220x50,0,0,7")
        XCTAssertEqual(layout?.isZoomed, true)
        XCTAssertEqual(layout?.windowFlags, "*Z")
    }

    func testParseLayoutTree_noZoomFlag() {
        let layout = TmuxControlParser.parseLayoutTree(windowId: "@5", flags: "",
                                                        layoutString: "aa00,220x50,0,0,7")
        XCTAssertEqual(layout?.isZoomed, false)
    }

    func testParseLayoutTree_emptyStringReturnsNil() {
        XCTAssertNil(TmuxControlParser.parseLayoutTree(windowId: "@1", flags: "", layoutString: ""))
    }
}
