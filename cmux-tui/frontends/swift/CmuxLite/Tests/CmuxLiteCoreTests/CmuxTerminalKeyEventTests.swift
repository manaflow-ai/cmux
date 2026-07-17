@testable import CmuxLiteCore
import Testing

@Suite
struct CmuxTerminalKeyEventTests {
    @Test
    func namedKeysPreserveTerminalModifiers() {
        let event = CmuxTerminalKeyEvent(key: "ArrowLeft", control: true, shift: true)
        #expect(event.terminalAction() == .key("ctrl+shift+left"))
    }

    @Test
    func plainAndControlTextUseTheSendPath() {
        #expect(CmuxTerminalKeyEvent(key: "x").terminalAction() == .text("x"))
        #expect(CmuxTerminalKeyEvent(key: "c", control: true).terminalAction() == .text("\u{3}"))
        #expect(CmuxTerminalKeyEvent(key: "x", option: true).terminalAction() == .text("\u{1B}x"))
    }

    @Test
    func controlTransformedCharactersUseIgnoringModifiersThroughAdapter() throws {
        let key = try #require(CmuxTerminalKeyEvent.adaptedCharacters(
            characters: "\u{3}",
            charactersIgnoringModifiers: "c",
            control: true
        ))
        let event = CmuxTerminalKeyEvent(key: key, control: true)

        #expect(event.terminalAction() == .text("\u{3}"))
    }

    @Test
    func commandInputStaysWithTheApplication() {
        #expect(CmuxTerminalKeyEvent(key: "x", command: true).terminalAction() == nil)
    }
}
