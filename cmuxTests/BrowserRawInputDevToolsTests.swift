import CmuxBrowser
import CoreGraphics
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Raw input steps on a Chromium page become trusted DevTools input events.
struct BrowserRawInputDevToolsTests {
    @Test func clickStepsBecomeMousePressAndReleaseAtThePoint() {
        var pointer = CGPoint.zero
        let point = CGPoint(x: 120, y: 48)
        let press = TerminalController.v2DevToolsInputCommand(
            for: .mousePressed(.point(point), button: .left, clickCount: 1, modifiers: []),
            pointer: &pointer
        )
        let release = TerminalController.v2DevToolsInputCommand(
            for: .mouseReleased(.pointer, button: .left, clickCount: 1, modifiers: [.shift]),
            pointer: &pointer
        )

        #expect(press.method == "Input.dispatchMouseEvent")
        #expect(press.params["type"] as? String == "mousePressed")
        #expect(press.params["x"] as? CGFloat == 120)
        #expect(press.params["y"] as? CGFloat == 48)
        #expect(press.params["button"] as? String == "left")
        #expect(press.params["clickCount"] as? Int == 1)
        // A step at the pointer acts where the last step left it.
        #expect(release.params["type"] as? String == "mouseReleased")
        #expect(release.params["x"] as? CGFloat == 120)
        #expect(release.params["modifiers"] as? Int == 8)
        #expect(pointer == point)
    }

    @Test func wheelCarriesItsDeltas() {
        var pointer = CGPoint(x: 5, y: 6)
        let wheel = TerminalController.v2DevToolsInputCommand(
            for: .mouseWheel(.pointer, deltaX: 0, deltaY: 120, modifiers: []),
            pointer: &pointer
        )
        #expect(wheel.params["type"] as? String == "mouseWheel")
        #expect(wheel.params["deltaY"] as? Double == 120)
        #expect(wheel.params["button"] as? String == "none")
    }

    @Test func keysTypeTextOnlyWhenTheyInsertIt() {
        var pointer = CGPoint.zero
        let a = TerminalController.v2DevToolsInputCommand(for: .keyDown("a", modifiers: []), pointer: &pointer)
        let shortcut = TerminalController.v2DevToolsInputCommand(for: .keyDown("a", modifiers: [.meta]), pointer: &pointer)
        let arrow = TerminalController.v2DevToolsInputCommand(for: .keyDown("ArrowDown", modifiers: []), pointer: &pointer)
        let up = TerminalController.v2DevToolsInputCommand(for: .keyUp("a", modifiers: []), pointer: &pointer)
        let text = TerminalController.v2DevToolsInputCommand(for: .insertText("é"), pointer: &pointer)

        #expect(a.params["type"] as? String == "keyDown")
        #expect(a.params["text"] as? String == "a")
        #expect(shortcut.params["type"] as? String == "rawKeyDown")
        #expect(shortcut.params["text"] == nil)
        #expect(arrow.params["type"] as? String == "rawKeyDown")
        #expect(arrow.params["code"] as? String == "ArrowDown")
        #expect(up.params["type"] as? String == "keyUp")
        #expect(text.method == "Input.insertText")
        #expect(text.params["text"] as? String == "é")
    }
}
