import CmuxMobileTerminal
import CmuxMobileTerminalKit
import Foundation
import Testing

@testable import CmuxMobileShellUI

/// Behavioral tests for the custom key-combo / macro toolbar actions added for
/// issue #6087: the editor's pure ``CustomToolbarActionDraft`` (seed → build →
/// validity), and that a macro action persists through
/// ``TerminalAccessoryConfiguration``. These run in the iOS simulator test plan
/// (`cmuxFeatureTests`), so they guard the feature on CI.
@Suite("CustomToolbarActionDraft")
struct CustomToolbarActionDraftTests {
    // MARK: - Seeding

    @Test("a nil action seeds an empty text draft that submits on tap")
    func seedsNewAsText() {
        let draft = CustomToolbarActionDraft(action: nil)
        #expect(draft.mode == .text)
        #expect(draft.commandText.isEmpty)
        #expect(draft.runAfterTyping)
        #expect(draft.steps.isEmpty)
        #expect(!draft.isValid) // no label, no command yet
    }

    @Test("a Return-terminated text action seeds text mode with Run after typing on")
    func seedsRunAfterTyping() {
        let draft = CustomToolbarActionDraft(action: CustomToolbarAction(title: "Claude", payload: .text("claude\n")))
        #expect(draft.mode == .text)
        #expect(draft.commandText == "claude")
        #expect(draft.runAfterTyping)
    }

    @Test("a text action without a trailing Return seeds with Run after typing off")
    func seedsNoRun() {
        let draft = CustomToolbarActionDraft(action: CustomToolbarAction(title: "cd", payload: .text("cd ")))
        #expect(draft.mode == .text)
        #expect(draft.commandText == "cd ")
        #expect(!draft.runAfterTyping)
    }

    @Test("a key-combo action seeds the key-sequence editor with one step")
    func seedsKeyComboAsSingleStep() {
        let action = CustomToolbarAction(title: "Mode", payload: .keyCombo(modifiers: [.shift], key: .tab))
        let draft = CustomToolbarActionDraft(action: action)
        #expect(draft.mode == .keySequence)
        #expect(draft.steps == [.keyCombo(modifiers: [.shift], key: .tab)])
    }

    @Test("a macro action seeds the key-sequence editor with its steps")
    func seedsMacroSteps() {
        let steps: [ToolbarMacroStep] = [.keyCombo(modifiers: [.shift], key: .tab), .text("go\n")]
        let draft = CustomToolbarActionDraft(action: CustomToolbarAction(title: "M", payload: .macro(steps)))
        #expect(draft.mode == .keySequence)
        #expect(draft.steps == steps)
    }

    // MARK: - Validity

    @Test("a key sequence needs a label and at least one resolvable step")
    func keySequenceValidity() {
        var draft = CustomToolbarActionDraft(title: "", mode: .keySequence, steps: [.keyCombo(modifiers: [], key: .tab)])
        #expect(!draft.isValid) // empty label

        draft.title = "Tab"
        #expect(draft.isValid)

        draft.steps = [] // no steps
        #expect(!draft.isValid)

        // A step the encoder can't encode makes the whole sequence invalid, so a
        // saved macro never carries a dead step.
        draft.steps = [.keyCombo(modifiers: [.control], key: .upArrow)]
        #expect(!draft.isValid)

        draft.steps = [.text("")] // empty text step
        #expect(!draft.isValid)

        draft.steps = Array(repeating: .text("x"), count: CustomToolbarActionDraft.maximumKeySequenceStepCount)
        #expect(draft.isValid)

        draft.steps = Array(repeating: .text("x"), count: CustomToolbarActionDraft.maximumKeySequenceStepCount + 1)
        #expect(!draft.isValid)
    }

    // MARK: - Building

    @Test("building text mode appends Return only when Run after typing is on")
    func buildsTextPayload() {
        let id = UUID()
        let withReturn = CustomToolbarActionDraft(title: "Claude", mode: .text, commandText: "claude", runAfterTyping: true)
        #expect(withReturn.build(id: id) == CustomToolbarAction(id: id, title: "Claude", payload: .text("claude\n")))

        let withoutReturn = CustomToolbarActionDraft(title: "cd", mode: .text, commandText: "cd ", runAfterTyping: false)
        #expect(withoutReturn.build(id: id) == CustomToolbarAction(id: id, title: "cd", payload: .text("cd ")))
    }

    @Test("building a key sequence yields a macro payload and trims the label")
    func buildsMacroPayload() {
        let id = UUID()
        let steps: [ToolbarMacroStep] = [.keyCombo(modifiers: [.shift], key: .tab), .text("go\n")]
        let draft = CustomToolbarActionDraft(title: "  Plan  ", mode: .keySequence, steps: steps)
        #expect(draft.build(id: id) == CustomToolbarAction(id: id, title: "Plan", payload: .macro(steps)))
    }

    @Test("an invalid draft builds nothing")
    func invalidBuildsNil() {
        #expect(CustomToolbarActionDraft(title: "", mode: .text, commandText: "x").build(id: UUID()) == nil)
        #expect(CustomToolbarActionDraft(title: "x", mode: .keySequence, steps: []).build(id: UUID()) == nil)
    }

    // MARK: - Round-trips

    @Test("text and macro actions round-trip through seed → build unchanged")
    func roundTrips() {
        for action in [
            CustomToolbarAction(title: "Claude", payload: .text("claude\n")),
            CustomToolbarAction(title: "Type", payload: .text("npm run dev")),
            CustomToolbarAction(title: "Macro", payload: .macro([.keyCombo(modifiers: [.shift], key: .tab), .text("hi\n")])),
        ] {
            let rebuilt = CustomToolbarActionDraft(action: action).build(id: action.id)
            #expect(rebuilt == action)
        }
    }

    @Test("editing a legacy key-combo action preserves the bytes it sends")
    func keyComboRoundTripPreservesOutput() {
        // The editor folds a standalone .keyCombo into a one-step macro, so the
        // payload representation changes but the bytes sent stay identical.
        let action = CustomToolbarAction(title: "Mode", payload: .keyCombo(modifiers: [.shift], key: .tab))
        let rebuilt = CustomToolbarActionDraft(action: action).build(id: action.id)
        #expect(rebuilt?.output == action.output)
        #expect(rebuilt?.output == Data([0x1B, 0x5B, 0x5A])) // ESC [ Z
    }

    // MARK: - Issue scenario

    @Test("a single ⇧Tab key sequence rotates permission mode (ESC[Z)")
    func rotatePermissionModeScenario() {
        // The motivating example from #6087: one toolbar button that rotates an
        // agent's permission mode, built entirely through the editor's draft.
        let draft = CustomToolbarActionDraft(
            title: "Mode",
            mode: .keySequence,
            steps: [.keyCombo(modifiers: [.shift], key: .tab)]
        )
        let action = draft.build(id: UUID())
        #expect(action?.output == Data([0x1B, 0x5B, 0x5A]))
    }

    // MARK: - Editor presentation helpers

    @Test("the editor offers the three encoder-supported modifiers in ⇧⌃⌥ order")
    func modifierOptions() {
        let options = TerminalKeyModifier.editorModifierOptions
        #expect(options.map(\.modifier) == [.shift, .control, .alternate])
        #expect(options.map(\.glyph) == ["⇧", "⌃", "⌥"])
        #expect(options.allSatisfy { !$0.name.isEmpty })
    }

    @Test("the key picker offers every special key with a distinct name")
    func keyPickerOrder() {
        let keys = TerminalSpecialKey.editorPickerOrder
        #expect(Set(keys) == Set(TerminalSpecialKey.allCases)) // every key is reachable
        #expect(keys.first == .tab) // most common terminal key first
        #expect(Set(keys.map(\.editorDisplayName)).count == keys.count) // names are distinct
    }
}

/// A macro custom action survives a persistence round-trip through
/// ``TerminalAccessoryConfiguration`` (JSON in `UserDefaults`), so a user's
/// macro buttons come back after relaunch.
@MainActor
@Suite("TerminalAccessoryConfiguration macro persistence")
struct TerminalAccessoryConfigurationMacroTests {
    private func freshDefaults() -> UserDefaults {
        let name = "cmux.toolbar.macro.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("a macro action persists and reloads with its steps intact, shown on the bar")
    func macroPersists() throws {
        let defaults = freshDefaults()
        let config = TerminalAccessoryConfiguration(defaults: defaults)
        let macro = CustomToolbarAction(
            title: "Plan",
            payload: .macro([.keyCombo(modifiers: [.shift], key: .tab), .text("go\n")])
        )
        config.addCustomAction(macro)

        #expect(config.customActions.contains(macro))
        #expect(config.isEnabled(macro.itemID))

        let reloaded = TerminalAccessoryConfiguration(defaults: defaults)
        let restored = try #require(reloaded.customActions.first { $0.id == macro.id })
        #expect(restored == macro)
        #expect(restored.output == Data([0x1B, 0x5B, 0x5A]) + Data("go\r".utf8))
        #expect(reloaded.enabledItems.contains { $0.id == macro.itemID })
    }
}
