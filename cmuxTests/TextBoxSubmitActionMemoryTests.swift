import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct TextBoxSubmitActionMemoryTests {
    @Test
    func testNewTextBoxesReuseLastExplicitModeAfterAgentSubmit() throws {
        let defaults = try makeIsolatedDefaults()
        let submittedPanelState = TerminalPanelTextBoxState(defaults: defaults)
        let codex = try #require(TextBoxSubmitAction.builtInActions.first { $0.id == "codex" })

        submittedPanelState.selectSubmitAction(codex.id, defaults: defaults)
        submittedPanelState.selectedSubmitActionID = TextBoxInputContainer.panelSubmitActionIDAfterSuccessfulSubmit(
            currentSubmitActionID: codex.id,
            submittedAction: codex
        )

        #expect(submittedPanelState.selectedSubmitActionID == TextBoxSubmitAction.textEntryAction.id)
        #expect(TerminalPanelTextBoxState(defaults: defaults).selectedSubmitActionID == codex.id)
        #expect(TerminalPanelTextBoxState(defaults: defaults).selectedSubmitActionID == codex.id)
    }

    @Test
    func testNewTextBoxesReuseLastExplicitCustomMode() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(
            """
            [
              {
                "id": "custom-router",
                "title": "Custom Router",
                "kind": "commandTemplate",
                "commandTemplate": "router --prompt {{prompt}}",
                "systemImage": "wand.and.stars",
                "backgroundColorHex": "#123456"
              }
            ]
            """,
            forKey: TerminalTextBoxInputSettings.submitActionsKey
        )
        let sourcePanelState = TerminalPanelTextBoxState(defaults: defaults)

        sourcePanelState.selectSubmitAction("custom-router", defaults: defaults)

        #expect(TerminalPanelTextBoxState(defaults: defaults).selectedSubmitActionID == "custom-router")
    }

    @Test
    func testConfiguredDefaultChangeClearsRememberedMode() throws {
        let defaults = try makeIsolatedDefaults()
        let panelState = TerminalPanelTextBoxState(defaults: defaults)

        panelState.selectSubmitAction("codex", defaults: defaults)
        defaults.set(TextBoxSubmitAction.textEntryAction.id, forKey: TerminalTextBoxInputSettings.defaultSubmitActionKey)

        #expect(TerminalPanelTextBoxState(defaults: defaults).selectedSubmitActionID == nil)
        #expect(TerminalTextBoxInputSettings.defaultSubmitActionIDValue(defaults: defaults) == TextBoxSubmitAction.textEntryAction.id)

        defaults.removeObject(forKey: TerminalTextBoxInputSettings.defaultSubmitActionKey)
        #expect(TerminalPanelTextBoxState(defaults: defaults).selectedSubmitActionID == nil)
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "TextBoxSubmitActionMemoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
