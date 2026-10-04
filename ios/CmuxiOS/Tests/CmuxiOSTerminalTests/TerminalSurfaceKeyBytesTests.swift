import Foundation
import Testing
import UIKit
@testable import CmuxiOSTerminal

/// Bytes a real ghostty-next surface writes for the router's actions
/// (manual-mirror mode, default terminal modes). Proves the physical key
/// table and the event fields reach Ghostty's encoder correctly (D5, D6).
@MainActor
@Suite(.serialized) struct TerminalSurfaceKeyBytesTests {
    private func bytes(_ actions: [TerminalInputAction]) throws -> [UInt8] {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let view = GhosttyTerminalView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }
        try #require(view.surface != nil, "surface: \(view.diagnostics)")
        var out: [UInt8] = []
        view.onInput = { out += Array($0) }
        view.perform(actions)
        return out
    }

    private func press(_ usage: UInt16, _ mods: TerminalKeyMods = [], text: String? = nil, unshifted: UInt32 = 0)
        -> [TerminalInputAction] {
        let event = TerminalKeyEvent(keyCode: TerminalHIDUsage.macKeyCode(usage), mods: mods, text: text,
                                     unshiftedCodepoint: unshifted)
        return [.key(event), .key(event.released)]
    }

    @Test func ctrlC() throws {
        #expect(try bytes(press(0x06, .control, text: "c", unshifted: 0x63)) == [0x03])
    }

    @Test func enterAndBackspace() throws {
        #expect(try bytes(press(TerminalHIDUsage.enter)) == [0x0D])
        #expect(try bytes(press(TerminalHIDUsage.backspace)) == [0x7F])
    }

    @Test func arrowsEscapeTabAndF1() throws {
        #expect(try bytes(press(TerminalHIDUsage.up)) == Array("\u{1b}[A".utf8))
        #expect(try bytes(press(TerminalHIDUsage.escape)) == [0x1B])
        #expect(try bytes(press(TerminalHIDUsage.tab)) == [0x09])
        #expect(try bytes(press(0x3A)) == Array("\u{1b}OP".utf8))
    }

    @Test func altAsMetaPrefixesEscape() throws {
        #expect(try bytes(press(0x1B, .alternate, text: "x", unshifted: 0x78)) == Array("\u{1b}x".utf8))
    }

    @Test func typedTextGoesAsTyped() throws {
        #expect(try bytes([.text("echo 'hi'")]) == Array("echo 'hi'".utf8))
    }

    @Test func preeditSendsNothing() throws {
        #expect(try bytes([.preedit("にほ")]).isEmpty)
    }
}
