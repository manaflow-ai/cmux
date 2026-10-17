import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Issue #21227: the click that brings cmux forward is counted by the window
/// server as click 1 of a double-click, so the next click on a sidebar row
/// started an inline rename instead of just focusing the workspace.
@Suite("Sidebar row rename click gate")
struct SidebarRowRenameClickGateTests {
    @Test func deliberateDoubleClickInKeyWindowRenames() {
        var gate = SidebarRowRenameClickGate()
        gate.notePress(row: 2, clickCount: 1, timestamp: 10, windowIsKey: true)
        let renamed = gate.notePress(row: 2, clickCount: 2, timestamp: 10.2, windowIsKey: true)
        #expect(renamed)
    }

    @Test func activationClickFollowedBySecondClickDoesNotRename() {
        var gate = SidebarRowRenameClickGate()
        // Window was inactive when the first press arrived.
        gate.notePress(row: 0, clickCount: 1, timestamp: 10, windowIsKey: false)
        gate.noteActivation(at: 10.01)
        let renamed = gate.notePress(row: 0, clickCount: 2, timestamp: 10.3, windowIsKey: true)
        #expect(!renamed)
    }

    @Test func pressThatActivatedTheWindowDoesNotArmRename() {
        var gate = SidebarRowRenameClickGate()
        // AppKit can make the window key before dispatching the first mouse.
        gate.noteActivation(at: 10)
        gate.notePress(row: 0, clickCount: 1, timestamp: 10.02, windowIsKey: true)
        let renamed = gate.notePress(row: 0, clickCount: 2, timestamp: 10.3, windowIsKey: true)
        #expect(!renamed)
    }

    @Test func secondClickWithoutAnObservedFirstPressDoesNotRename() {
        var gate = SidebarRowRenameClickGate()
        let renamed = gate.notePress(row: 1, clickCount: 2, timestamp: 5, windowIsKey: true)
        #expect(!renamed)
    }

    @Test func doubleClickAcrossDifferentRowsDoesNotRename() {
        var gate = SidebarRowRenameClickGate()
        gate.notePress(row: 1, clickCount: 1, timestamp: 10, windowIsKey: true)
        let renamed = gate.notePress(row: 2, clickCount: 2, timestamp: 10.2, windowIsKey: true)
        #expect(!renamed)
    }

    @Test func doubleClickWellAfterActivationRenames() {
        var gate = SidebarRowRenameClickGate()
        gate.noteActivation(at: 10)
        gate.notePress(row: 3, clickCount: 1, timestamp: 12, windowIsKey: true)
        let renamed = gate.notePress(row: 3, clickCount: 2, timestamp: 12.2, windowIsKey: true)
        #expect(renamed)
    }

    @Test func tripleClickDoesNotRenameAgain() {
        var gate = SidebarRowRenameClickGate()
        gate.notePress(row: 0, clickCount: 1, timestamp: 10, windowIsKey: true)
        let renamed = gate.notePress(row: 0, clickCount: 2, timestamp: 10.1, windowIsKey: true)
        #expect(renamed)
        let renamedAgain = gate.notePress(row: 0, clickCount: 3, timestamp: 10.2, windowIsKey: true)
        #expect(!renamedAgain)
    }
}
