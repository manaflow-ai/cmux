import CmuxMobileTerminal
import CmuxMobileTerminalKit
import Foundation
import Testing

/// Behavioral tests for ``TerminalAccessoryConfiguration``: the source of truth
/// for the reorderable terminal accessory bar. These verify the fresh-install
/// default layout (modifiers leading, zoom trailing), reorder + hide/show
/// round-trips, and the v1/v2 → v3 widening migration that folds the
/// previously-pinned modifier/zoom/paste built-ins into the configurable region.
///
/// Each test injects a private `UserDefaults` suite so it never touches the live
/// `.shared` settings.
@MainActor
@Suite("TerminalAccessoryConfiguration")
struct TerminalAccessoryConfigurationTests {
    /// A fresh suite-scoped defaults store, cleared so each test starts empty.
    private func freshDefaults() -> UserDefaults {
        let name = "cmux.toolbar.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func id(_ action: TerminalInputAccessoryAction) -> ToolbarItemID { action.itemID }

    private func persistedV4Rows(in defaults: UserDefaults) -> [[String]]? {
        guard let rows = defaults.array(forKey: "cmux.terminal.toolbar.rows.v4") else { return nil }
        return rows.map { row in
            (row as? [String]) ?? []
        }
    }

    // MARK: - Gating test #1: fresh-install default order

    @Test("fresh install puts modifiers (incl. ⇧) at the front and zoom at the back, all shown")
    func freshInstallDefaultOrder() throws {
        let config = TerminalAccessoryConfiguration(defaults: freshDefaults())
        let order = config.displayOrder

        // Leading region: ⌃ ⌥ ⌘ ⇧ then paste — all four modifiers adjacent.
        #expect(Array(order.prefix(5)) == [
            id(.control), id(.alternate), id(.command), id(.shift), id(.paste),
        ])
        // Trailing region: the two zoom controls, in that order.
        #expect(Array(order.suffix(2)) == [id(.zoomOut), id(.zoomIn)])
        // Esc sits right after Tab, then Return, in the redesigned default, so the
        // three most common terminal keys are adjacent.
        let tabIndex = try #require(order.firstIndex(of: id(.tab)))
        #expect(order[tabIndex + 1] == id(.escape))
        #expect(order[tabIndex + 2] == id(.returnKey))
        // Everything is shown on a fresh install, including the now-configurable
        // modifiers (⇧ among them)/zoom/paste.
        for action in TerminalInputAccessoryAction.configurableActions {
            #expect(config.isEnabled(action.itemID))
        }
        // ⇧ is now a surfaced, shown, user-configurable bar button.
        #expect(order.contains(id(.shift)))
        #expect(config.isEnabled(id(.shift)))
    }

    // MARK: - Return key

    @Test("Return is shown by default, adjacent to Tab/Esc, and sends CR")
    func returnKeyDefaultsAndOutput() throws {
        let config = TerminalAccessoryConfiguration(defaults: freshDefaults())
        let order = config.displayOrder

        let returnIndex = try #require(order.firstIndex(of: id(.returnKey)))
        let escIndex = try #require(order.firstIndex(of: id(.escape)))
        // Return sits immediately after Esc.
        #expect(returnIndex == escIndex + 1)
        #expect(config.isEnabled(id(.returnKey)))
        // Return sends a carriage return (Enter).
        #expect(TerminalInputAccessoryAction.returnKey.output == Data([0x0D]))
        #expect(TerminalInputAccessoryAction.returnKey.isUserConfigurable)
    }

    @Test("Return's persisted identifier is stable")
    func returnKeyStableIdentifier() {
        // The persisted key is `builtin.<rawValue>`; Return is appended last in the
        // enum so existing built-ins keep their raw values. Lock the storage key so
        // a future reorder of the enum cannot silently shift it.
        let stored = TerminalInputAccessoryAction.returnKey.itemID.storageKey
        #expect(stored == "builtin.\(TerminalInputAccessoryAction.returnKey.rawValue)")
        let parsed = ToolbarItemID(storageKey: stored)
        #expect(parsed == id(.returnKey))
        // Appended last: its raw value is the max across all cases.
        let maxRaw = TerminalInputAccessoryAction.allCases.map(\.rawValue).max()
        #expect(TerminalInputAccessoryAction.returnKey.rawValue == maxRaw)
    }

    // MARK: - Reorder + hide/show round-trips

    @Test("moving a modifier to the end persists across reload")
    func reorderModifierPersists() throws {
        let defaults = freshDefaults()
        let config = TerminalAccessoryConfiguration(defaults: defaults)
        let controlIndex = try #require(config.displayOrder.firstIndex(of: id(.control)))

        // Move ⌃ to the end of the configurable region.
        config.moveItems(from: IndexSet(integer: controlIndex), to: config.displayOrder.count)
        #expect(config.displayOrder.last == id(.control))

        // A fresh instance over the same defaults sees the moved order.
        let reloaded = TerminalAccessoryConfiguration(defaults: defaults)
        #expect(reloaded.displayOrder.last == id(.control))
    }

    @Test("hiding a modifier persists across reload and keeps it in the order")
    func hideModifierPersists() {
        let defaults = freshDefaults()
        let config = TerminalAccessoryConfiguration(defaults: defaults)

        config.setEnabled(id(.command), false)
        #expect(!config.isEnabled(id(.command)))
        #expect(config.displayOrder.contains(id(.command)))
        #expect(!config.enabledItems.contains { $0.id == id(.command) })

        // The hidden state survives a reload (v3 enabled set is authoritative).
        let reloaded = TerminalAccessoryConfiguration(defaults: defaults)
        #expect(!reloaded.isEnabled(id(.command)))
        #expect(reloaded.displayOrder.contains(id(.command)))
    }

    // MARK: - Gating test #2: v2 → v3 widening migration

    @Test("v2 config without modifiers gains them force-enabled at front/back")
    func migratesV2ConfigForceEnablingModifiers() throws {
        let defaults = freshDefaults()
        // Seed a v2-era config: only the trailing shortcuts were configurable, the
        // user kept Tab + Esc shown and reordered Esc before Tab.
        defaults.set(
            [id(.escape).storageKey, id(.tab).storageKey],
            forKey: "cmux.terminal.toolbar.order.v2"
        )
        defaults.set(
            [id(.escape).storageKey, id(.tab).storageKey],
            forKey: "cmux.terminal.toolbar.enabled.v2"
        )

        let config = TerminalAccessoryConfiguration(defaults: defaults)

        // The previously-pinned modifiers/zoom/paste are now present AND shown,
        // and ⇧ folds in alongside them as a newly-configurable leading modifier.
        for action: TerminalInputAccessoryAction in [.control, .alternate, .command, .shift, .paste, .zoomOut, .zoomIn] {
            #expect(config.displayOrder.contains(action.itemID))
            #expect(config.isEnabled(action.itemID))
        }
        // Modifiers (incl. ⇧)/paste fold in at the very front. (Zoom is force-enabled
        // and inserted after the saved shortcuts by the migration, but the reducer's
        // forward-compat pass then appends the other shortcuts the partial v2 seed
        // omitted, so zoom is no longer the absolute tail here — only on a fresh
        // install, asserted in `freshInstallDefaultOrder`.)
        #expect(Array(config.displayOrder.prefix(5)) == [
            id(.control), id(.alternate), id(.command), id(.shift), id(.paste),
        ])
        // Zoom lands after the user's saved shortcuts (Esc/Tab).
        let escIndex = try #require(config.displayOrder.firstIndex(of: id(.escape)))
        let tabIndex = try #require(config.displayOrder.firstIndex(of: id(.tab)))
        let zoomOutIndex = try #require(config.displayOrder.firstIndex(of: id(.zoomOut)))
        #expect(escIndex < tabIndex)
        #expect(zoomOutIndex > tabIndex)
    }

    @Test("v2 migration preserves a hidden shortcut while still force-showing modifiers")
    func migratesV2ConfigPreservingHiddenShortcut() {
        let defaults = freshDefaults()
        // The user had Tab + Esc in the order but hid Esc.
        defaults.set(
            [id(.tab).storageKey, id(.escape).storageKey],
            forKey: "cmux.terminal.toolbar.order.v2"
        )
        defaults.set([id(.tab).storageKey], forKey: "cmux.terminal.toolbar.enabled.v2")

        let config = TerminalAccessoryConfiguration(defaults: defaults)

        // Esc stays hidden; the forced modifiers/zoom (incl. the new ⇧) are shown.
        #expect(!config.isEnabled(id(.escape)))
        #expect(config.isEnabled(id(.tab)))
        #expect(config.isEnabled(id(.control)))
        #expect(config.isEnabled(id(.shift)))
        #expect(config.isEnabled(id(.zoomIn)))
    }

    @Test("an upgraded config re-persists under the v4 rows so the migration runs once")
    func migrationPersistsUnderV4Rows() throws {
        let defaults = freshDefaults()
        defaults.set([id(.tab).storageKey], forKey: "cmux.terminal.toolbar.order.v2")
        defaults.set([id(.tab).storageKey], forKey: "cmux.terminal.toolbar.enabled.v2")

        _ = TerminalAccessoryConfiguration(defaults: defaults)

        // After init, v4 rows exist; a second load takes the v4 path (no second
        // force-enable), so hiding a modifier then would persist.
        let v4Rows = try #require(persistedV4Rows(in: defaults))
        #expect(v4Rows.flatMap { $0 }.contains(id(.control).storageKey))

        let reloaded = TerminalAccessoryConfiguration(defaults: defaults)
        reloaded.setEnabled(id(.control), false)
        let reloadedAgain = TerminalAccessoryConfiguration(defaults: defaults)
        // The v4 path honored the hidden modifier rather than re-forcing it on.
        #expect(!reloadedAgain.isEnabled(id(.control)))
    }

    @Test("v2 config carrying a custom action keeps the custom in place when modifiers fold in")
    func migratesV2ConfigWithCustomAction() throws {
        let defaults = freshDefaults()
        let custom = CustomToolbarAction(title: "Claude", payload: .text("claude\n"))

        // A v2 user with one custom action sitting between Tab and Esc, all shown.
        let customData = try JSONEncoder().encode([custom])
        defaults.set(customData, forKey: "cmux.terminal.toolbar.custom.v2")
        defaults.set(
            [id(.tab).storageKey, custom.itemID.storageKey, id(.escape).storageKey],
            forKey: "cmux.terminal.toolbar.order.v2"
        )
        defaults.set(
            [id(.tab).storageKey, custom.itemID.storageKey, id(.escape).storageKey],
            forKey: "cmux.terminal.toolbar.enabled.v2"
        )

        let config = TerminalAccessoryConfiguration(defaults: defaults)

        // The custom action survives migration in its saved slot, still shown.
        #expect(config.customActions.contains { $0.id == custom.id })
        #expect(config.isEnabled(custom.itemID))
        let customIndex = try #require(config.displayOrder.firstIndex(of: custom.itemID))
        let tabIndex = try #require(config.displayOrder.firstIndex(of: id(.tab)))
        let escIndex = try #require(config.displayOrder.firstIndex(of: id(.escape)))
        #expect(tabIndex < customIndex)
        #expect(customIndex < escIndex)
        // Modifiers fold in at the front and stay ahead of the custom; zoom is
        // force-enabled and inserted after the saved shortcuts (the reducer then
        // appends the omitted shortcuts, so zoom is not the absolute tail here).
        let controlIndex = try #require(config.displayOrder.firstIndex(of: id(.control)))
        #expect(controlIndex < customIndex)
        #expect(config.isEnabled(id(.control)))
        let zoomOutIndex = try #require(config.displayOrder.firstIndex(of: id(.zoomOut)))
        #expect(zoomOutIndex > customIndex)
        #expect(config.isEnabled(id(.zoomOut)))
        #expect(config.isEnabled(id(.zoomIn)))
    }

    // MARK: - Gating test #3: existing v3 layout gains ⇧

    @Test("an existing v3 layout without ⇧ gains it force-enabled right after ⌘")
    func migratesExistingV3LayoutForceEnablingShift() throws {
        let defaults = freshDefaults()
        // A v3 layout persisted before ⇧ became configurable: the modifiers,
        // paste, a couple of shortcuts, and zoom — no ⇧ anywhere.
        let preShift: [TerminalInputAccessoryAction] = [
            .control, .alternate, .command, .paste, .tab, .escape, .zoomOut, .zoomIn,
        ]
        defaults.set(preShift.map { id($0).storageKey }, forKey: "cmux.terminal.toolbar.order.v3")
        defaults.set(preShift.map { id($0).storageKey }, forKey: "cmux.terminal.toolbar.enabled.v3")

        let config = TerminalAccessoryConfiguration(defaults: defaults)

        // ⇧ folds in, is shown, and sits immediately after ⌘ (with the modifiers).
        #expect(config.displayOrder.contains(id(.shift)))
        #expect(config.isEnabled(id(.shift)))
        let commandIndex = try #require(config.displayOrder.firstIndex(of: id(.command)))
        #expect(config.displayOrder[commandIndex + 1] == id(.shift))
        // The user's existing items are untouched and still shown.
        for action in preShift {
            #expect(config.displayOrder.contains(id(action)))
            #expect(config.isEnabled(id(action)))
        }
    }

    @Test("⇧ folded into a v3 layout stays hidden once the user hides it")
    func foldedShiftHonorsLaterHide() {
        let defaults = freshDefaults()
        let preShift: [TerminalInputAccessoryAction] = [.control, .alternate, .command, .paste, .tab]
        defaults.set(preShift.map { id($0).storageKey }, forKey: "cmux.terminal.toolbar.order.v3")
        defaults.set(preShift.map { id($0).storageKey }, forKey: "cmux.terminal.toolbar.enabled.v3")

        // First launch folds ⇧ in and shows it.
        let config = TerminalAccessoryConfiguration(defaults: defaults)
        #expect(config.isEnabled(id(.shift)))

        // The user hides ⇧; the choice must survive a reload. The fold is one-shot
        // (keyed off ⇧'s absence from the persisted order, which now includes it),
        // so it does not re-show ⇧ on the next launch.
        config.setEnabled(id(.shift), false)
        let reloaded = TerminalAccessoryConfiguration(defaults: defaults)
        #expect(!reloaded.isEnabled(id(.shift)))
        #expect(reloaded.displayOrder.contains(id(.shift)))
    }

    @Test("a v3 layout already carrying a hidden ⇧ is not re-folded")
    func v3LayoutWithHiddenShiftIsNotRefolded() {
        let defaults = freshDefaults()
        // ⇧ is already in the order but hidden — a user who had it and chose to
        // hide it. The fold must respect that rather than re-showing it.
        let order: [TerminalInputAccessoryAction] = [.control, .alternate, .command, .shift, .paste, .tab]
        let enabled: [TerminalInputAccessoryAction] = [.control, .alternate, .command, .paste, .tab]
        defaults.set(order.map { id($0).storageKey }, forKey: "cmux.terminal.toolbar.order.v3")
        defaults.set(enabled.map { id($0).storageKey }, forKey: "cmux.terminal.toolbar.enabled.v3")

        let config = TerminalAccessoryConfiguration(defaults: defaults)
        #expect(config.displayOrder.contains(id(.shift)))
        #expect(!config.isEnabled(id(.shift)))
    }

    // MARK: - Gating test #4: existing v3 layout gains Return

    @Test("an existing v3 layout without Return gains it force-enabled right after Esc")
    func migratesExistingV3LayoutForceEnablingReturn() throws {
        let defaults = freshDefaults()
        // A v3 layout persisted before Return became configurable: modifiers (incl.
        // ⇧, so the ⇧ fold is a no-op here), paste, Tab, Esc, zoom — no Return.
        let preReturn: [TerminalInputAccessoryAction] = [
            .control, .alternate, .command, .shift, .paste, .tab, .escape, .zoomOut, .zoomIn,
        ]
        defaults.set(preReturn.map { id($0).storageKey }, forKey: "cmux.terminal.toolbar.order.v3")
        defaults.set(preReturn.map { id($0).storageKey }, forKey: "cmux.terminal.toolbar.enabled.v3")

        let config = TerminalAccessoryConfiguration(defaults: defaults)

        // Return folds in, is shown, and sits immediately after Esc.
        #expect(config.displayOrder.contains(id(.returnKey)))
        #expect(config.isEnabled(id(.returnKey)))
        let escIndex = try #require(config.displayOrder.firstIndex(of: id(.escape)))
        #expect(config.displayOrder[escIndex + 1] == id(.returnKey))
        // The user's existing items are untouched and still shown.
        for action in preReturn {
            #expect(config.displayOrder.contains(id(action)))
            #expect(config.isEnabled(id(action)))
        }
    }

    @Test("a v3 layout missing both ⇧ and Return gains both, each after its own anchor")
    func migratesExistingV3LayoutFoldingShiftAndReturn() throws {
        let defaults = freshDefaults()
        // Predates both ⇧ and Return: only ⌃ ⌥ ⌘, paste, Tab, Esc, zoom.
        let pre: [TerminalInputAccessoryAction] = [
            .control, .alternate, .command, .paste, .tab, .escape, .zoomOut, .zoomIn,
        ]
        defaults.set(pre.map { id($0).storageKey }, forKey: "cmux.terminal.toolbar.order.v3")
        defaults.set(pre.map { id($0).storageKey }, forKey: "cmux.terminal.toolbar.enabled.v3")

        let config = TerminalAccessoryConfiguration(defaults: defaults)

        // ⇧ after ⌘, Return after Esc, both shown.
        let commandIndex = try #require(config.displayOrder.firstIndex(of: id(.command)))
        #expect(config.displayOrder[commandIndex + 1] == id(.shift))
        let escIndex = try #require(config.displayOrder.firstIndex(of: id(.escape)))
        #expect(config.displayOrder[escIndex + 1] == id(.returnKey))
        #expect(config.isEnabled(id(.shift)))
        #expect(config.isEnabled(id(.returnKey)))
    }

    @Test("Return folded into a v3 layout stays hidden once the user hides it")
    func foldedReturnHonorsLaterHide() {
        let defaults = freshDefaults()
        let preReturn: [TerminalInputAccessoryAction] = [.control, .alternate, .command, .shift, .paste, .tab, .escape]
        defaults.set(preReturn.map { id($0).storageKey }, forKey: "cmux.terminal.toolbar.order.v3")
        defaults.set(preReturn.map { id($0).storageKey }, forKey: "cmux.terminal.toolbar.enabled.v3")

        // First launch folds Return in and shows it.
        let config = TerminalAccessoryConfiguration(defaults: defaults)
        #expect(config.isEnabled(id(.returnKey)))

        // The user hides Return; the choice must survive a reload. The fold is
        // one-shot (keyed off Return's absence from the persisted order, which now
        // includes it), so it does not re-show Return on the next launch.
        config.setEnabled(id(.returnKey), false)
        let reloaded = TerminalAccessoryConfiguration(defaults: defaults)
        #expect(!reloaded.isEnabled(id(.returnKey)))
        #expect(reloaded.displayOrder.contains(id(.returnKey)))
    }

    @Test("a v3 layout already carrying a hidden Return is not re-folded")
    func v3LayoutWithHiddenReturnIsNotRefolded() {
        let defaults = freshDefaults()
        // Return is already in the order but hidden — a user who had it and chose
        // to hide it. The fold must respect that rather than re-showing it.
        let order: [TerminalInputAccessoryAction] = [.control, .alternate, .command, .shift, .paste, .tab, .escape, .returnKey]
        let enabled: [TerminalInputAccessoryAction] = [.control, .alternate, .command, .shift, .paste, .tab, .escape]
        defaults.set(order.map { id($0).storageKey }, forKey: "cmux.terminal.toolbar.order.v3")
        defaults.set(enabled.map { id($0).storageKey }, forKey: "cmux.terminal.toolbar.enabled.v3")

        let config = TerminalAccessoryConfiguration(defaults: defaults)
        #expect(config.displayOrder.contains(id(.returnKey)))
        #expect(!config.isEnabled(id(.returnKey)))
    }

    @Test("the Return fold re-persists under v4 rows so it runs once")
    func returnFoldPersistsUnderV4Rows() throws {
        let defaults = freshDefaults()
        let preReturn: [TerminalInputAccessoryAction] = [.control, .alternate, .command, .shift, .paste, .tab, .escape]
        defaults.set(preReturn.map { id($0).storageKey }, forKey: "cmux.terminal.toolbar.order.v3")
        defaults.set(preReturn.map { id($0).storageKey }, forKey: "cmux.terminal.toolbar.enabled.v3")

        _ = TerminalAccessoryConfiguration(defaults: defaults)

        // After init, Return lives in the persisted v4 rows, so the next load
        // takes the no-op path and a later hide would persist.
        let v4Rows = try #require(persistedV4Rows(in: defaults))
        #expect(v4Rows.flatMap { $0 }.contains(id(.returnKey).storageKey))
    }

    @Test("a v2 upgrade also surfaces Return force-enabled")
    func migratesV2ConfigForceEnablingReturn() throws {
        let defaults = freshDefaults()
        // A v2-era config predates Return entirely; only Tab + Esc were shown.
        defaults.set(
            [id(.tab).storageKey, id(.escape).storageKey],
            forKey: "cmux.terminal.toolbar.order.v2"
        )
        defaults.set(
            [id(.tab).storageKey, id(.escape).storageKey],
            forKey: "cmux.terminal.toolbar.enabled.v2"
        )

        let config = TerminalAccessoryConfiguration(defaults: defaults)

        // Return folds in next to Esc and is shown after the v2→v3 widening.
        #expect(config.displayOrder.contains(id(.returnKey)))
        #expect(config.isEnabled(id(.returnKey)))
        let escIndex = try #require(config.displayOrder.firstIndex(of: id(.escape)))
        #expect(config.displayOrder[escIndex + 1] == id(.returnKey))
    }
}
