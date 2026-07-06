import XCTest
import CmuxSettings
@testable import CmuxSettingsUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private typealias ShortcutStroke = CmuxSettings.ShortcutStroke

final class KeyboardShortcutSavedLayoutTemplateTests: XCTestCase {
    func testSaveLayoutTemplateSettingsPackageActionStaysAligned() {
        guard let settingsAction = ShortcutAction(
            rawValue: KeyboardShortcutSettings.Action.saveLayoutTemplate.rawValue
        ) else {
            XCTFail("Expected CmuxSettings.ShortcutAction for saveLayoutTemplate")
            return
        }
        XCTAssertEqual(settingsAction.defaultStroke, ShortcutStroke(key: "s", command: true, shift: true))
        XCTAssertEqual(settingsAction.displayName, KeyboardShortcutSettings.Action.saveLayoutTemplate.label)
    }
}
