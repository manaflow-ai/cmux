import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct KeyboardShortcutControlCharacterTests {
    @Test(
        "Control characters preserve their logical shortcut key",
        arguments: [
            ("u", "\u{15}", UInt16(30)),
            ("[", "\u{1B}", UInt16(27)),
            ("\\", "\u{1C}", UInt16(30)),
            ("]", "\u{1D}", UInt16(27)),
        ]
    )
    func controlCharacterMatchesLogicalKey(
        storedKey: String,
        eventCharacter: String,
        nonANSIKeyCode: UInt16
    ) throws {
        let shortcut = StoredShortcut(
            key: storedKey,
            command: true,
            shift: false,
            option: false,
            control: true
        )
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .control],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: eventCharacter,
            charactersIgnoringModifiers: eventCharacter,
            isARepeat: false,
            keyCode: nonANSIKeyCode
        ))

        #expect(shortcut.matches(event: event, layoutCharacterProvider: { _, _ in nil }))
    }
}
