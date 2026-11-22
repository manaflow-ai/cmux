import Foundation
import Testing
import UIKit
@testable import CmuxiOSTerminal

/// Bytes a real ghostty-next surface writes for the router's actions
/// (manual-mirror mode, default terminal modes). Proves the physical key
/// codes (USB HID usages on iOS since ghostty-next 59a70ffc6) and the event
/// fields reach Ghostty's encoder correctly (D5, D6).
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

    /// The actions of a hardware press and its release, through the router.
    private func hardware(_ usage: UInt16, _ mods: TerminalKeyMods = [], _ characters: String, _ unmodified: String)
        -> [TerminalInputAction] {
        var router = TerminalInputRouter()
        guard case .handled(let actions) = router.pressBegan(usage: usage, mods: mods, characters: characters,
                                                             unmodified: unmodified) else { return [] }
        return actions + router.pressEnded(actions)
    }

    private func bar(_ key: TerminalKeyBarKey) -> [TerminalInputAction] {
        var router = TerminalInputRouter()
        return router.keyBar(key, at: 0)
    }

    @Test func ctrlC() throws {
        #expect(try bytes(hardware(0x06, .control, "\u{3}", "c")) == [0x03])
    }

    @Test func enterAndBackspace() throws {
        var router = TerminalInputRouter()
        #expect(try bytes(router.insertText("\n")) == [0x0D])
        #expect(try bytes(router.deleteBackward()) == [0x7F])
    }

    @Test func arrowsEscapeTabAndF1() throws {
        #expect(try bytes(bar(.up)) == Array("\u{1b}[A".utf8))
        #expect(try bytes(bar(.escape)) == [0x1B])
        #expect(try bytes(bar(.tab)) == [0x09])
        #expect(try bytes(hardware(0x3A, [], "", "")) == Array("\u{1b}OP".utf8))
    }

    @Test func altAsMetaPrefixesEscape() throws {
        #expect(try bytes(hardware(0x1B, .alternate, "≈", "x")) == Array("\u{1b}x".utf8))
    }

    @Test func typedTextGoesAsTyped() throws {
        #expect(try bytes([.text("echo 'hi'")]) == Array("echo 'hi'".utf8))
    }

    @Test func preeditSendsNothing() throws {
        #expect(try bytes([.preedit("にほ")]).isEmpty)
    }
}
