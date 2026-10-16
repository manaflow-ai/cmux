import CmuxBrowser
import CoreGraphics
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chromium raw input is encoded as trusted DevTools input commands.
struct BrowserRawInputDevToolsTests {
    @Test func clickStepsUseTheLastPointerAndModifiers() {
        var pointer = CGPoint.zero
        let point = CGPoint(x: 120, y: 48)
        let press = TerminalController.v2DevToolsInputCommand(
            for: .mousePressed(point, button: .left, clickCount: 1, modifiers: []),
            pointer: &pointer
        )
        let release = TerminalController.v2DevToolsInputCommand(
            for: .mouseReleased(pointer, button: .left, clickCount: 1, modifiers: [.shift]),
            pointer: &pointer
        )
        #expect(press.method == "Input.dispatchMouseEvent")
        #expect(press.params["type"] as? String == "mousePressed")
        #expect(press.params["x"] as? CGFloat == 120)
        #expect(press.params["y"] as? CGFloat == 48)
        #expect(release.params["type"] as? String == "mouseReleased")
        #expect(release.params["modifiers"] as? Int == 8)
        #expect(pointer == point)
    }

    @Test func printableAndModifiedKeysUseTheCorrectProtocolShape() {
        var pointer = CGPoint.zero
        let printable = TerminalController.v2DevToolsInputCommand(
            for: .keyDown("a", modifiers: []), pointer: &pointer
        )
        let shortcut = TerminalController.v2DevToolsInputCommand(
            for: .keyDown("a", modifiers: [.meta]), pointer: &pointer
        )
        let up = TerminalController.v2DevToolsInputCommand(
            for: .keyUp("a", modifiers: []), pointer: &pointer
        )
        #expect(printable.params["type"] as? String == "keyDown")
        #expect(printable.params["text"] as? String == "a")
        #expect(shortcut.params["type"] as? String == "rawKeyDown")
        #expect(shortcut.params["text"] == nil)
        #expect(up.params["type"] as? String == "keyUp")
    }
}
