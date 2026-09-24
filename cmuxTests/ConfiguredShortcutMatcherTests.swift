import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
private typealias MatcherStoredShortcut = cmux_DEV.StoredShortcut
#elseif canImport(cmux)
@testable import cmux
private typealias MatcherStoredShortcut = cmux.StoredShortcut
#endif

final class ConfiguredShortcutMatcherTests: XCTestCase {
    func testMatchesConfiguredStrokeAndRejectsDifferentModifier() throws {
        let matcher = ConfiguredShortcutMatcher()
        let shortcut = MatcherStoredShortcut(key: "k", command: true, shift: false, option: false, control: false)
        let event = try XCTUnwrap(keyEvent(key: "k", modifiers: [.command], keyCode: 40))
        let wrongModifier = try XCTUnwrap(keyEvent(key: "k", modifiers: [.option], keyCode: 40))

        XCTAssertTrue(matcher.matches(event: event, shortcut: shortcut))
        XCTAssertFalse(matcher.matches(event: wrongModifier, shortcut: shortcut))
    }

    func testMatchesSecondStrokeOnlyWhenActivePrefixMatches() throws {
        let matcher = ConfiguredShortcutMatcher()
        let prefix = ShortcutStroke(key: "k", command: true, shift: false, option: false, control: false)
        let shortcut = MatcherStoredShortcut(
            first: prefix,
            second: ShortcutStroke(key: "c", command: true, shift: false, option: false, control: false)
        )
        let event = try XCTUnwrap(keyEvent(key: "c", modifiers: [.command], keyCode: 8))

        XCTAssertTrue(matcher.matches(event: event, shortcut: shortcut, activeChordPrefix: prefix))
        XCTAssertFalse(matcher.matches(event: event, shortcut: shortcut))
    }

    func testNumberedDigitUsesShiftSymbolAndKeyboardLayoutFallback() throws {
        let shiftedMatcher = ConfiguredShortcutMatcher()
        let shifted = MatcherStoredShortcut(key: "1", command: true, shift: true, option: false, control: false)
        let shiftedEvent = try XCTUnwrap(keyEvent(key: "!", modifiers: [.command, .shift], keyCode: 18))
        XCTAssertEqual(shiftedMatcher.numberedDigit(event: shiftedEvent, shortcut: shifted), 1)

        let layoutMatcher = ConfiguredShortcutMatcher { _, _ in "2" }
        let layoutEvent = try XCTUnwrap(keyEvent(key: "한", modifiers: [.command], keyCode: 0))
        let layoutShortcut = MatcherStoredShortcut(key: "2", command: true, shift: false, option: false, control: false)
        XCTAssertEqual(layoutMatcher.numberedDigit(event: layoutEvent, shortcut: layoutShortcut), 2)
    }

    func testDirectionalAndTabMatchingUseKeyCodes() throws {
        let matcher = ConfiguredShortcutMatcher()
        let arrow = MatcherStoredShortcut(key: "←", command: true, shift: false, option: false, control: false)
        let arrowEvent = try XCTUnwrap(keyEvent(key: "", modifiers: [.command, .numericPad], keyCode: 123))
        let tab = MatcherStoredShortcut(key: "\t", command: true, shift: false, option: false, control: false)
        let tabEvent = try XCTUnwrap(keyEvent(key: "\t", modifiers: [.command], keyCode: 48))

        XCTAssertTrue(matcher.matchesDirectional(event: arrowEvent, shortcut: arrow, arrowGlyph: "←", arrowKeyCode: 123))
        XCTAssertTrue(matcher.matchesTab(event: tabEvent, shortcut: tab))

        let unbound = MatcherStoredShortcut.unbound
        XCTAssertFalse(matcher.matchesTab(event: tabEvent, shortcut: unbound))
    }

    private func keyEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
