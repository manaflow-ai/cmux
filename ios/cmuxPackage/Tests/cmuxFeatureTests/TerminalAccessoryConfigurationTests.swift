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

    // MARK: - Gating test #1: fresh-install default order

    @Test("fresh install puts modifiers at the front and zoom at the back, all shown")
    func freshInstallDefaultOrder() throws {
        let config = TerminalAccessoryConfiguration(defaults: freshDefaults())
        let order = config.displayOrder

        // Leading region: ⌃ ⌥ ⌘ then paste, in that order.
        #expect(Array(order.prefix(4)) == [
            id(.control), id(.alternate), id(.command), id(.paste),
        ])
        // Trailing region: the two zoom controls, in that order.
        #expect(Array(order.suffix(2)) == [id(.zoomOut), id(.zoomIn)])
        // Esc sits right after Tab in the redesigned default.
        let tabIndex = try #require(order.firstIndex(of: id(.tab)))
        #expect(order[tabIndex + 1] == id(.escape))
        // Everything is shown on a fresh install, including the now-configurable
        // modifiers/zoom/paste.
        for action in TerminalInputAccessoryAction.configurableActions {
            #expect(config.isEnabled(action.itemID))
        }
        // Shift is never surfaced as a bar button.
        #expect(!order.contains(id(.shift)))
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

        // The previously-pinned modifiers/zoom/paste are now present AND shown.
        for action: TerminalInputAccessoryAction in [.control, .alternate, .command, .paste, .zoomOut, .zoomIn] {
            #expect(config.displayOrder.contains(action.itemID))
            #expect(config.isEnabled(action.itemID))
        }
        // Modifiers/paste fold in at the very front. (Zoom is force-enabled and
        // inserted after the saved shortcuts by the migration, but the reducer's
        // forward-compat pass then appends the other shortcuts the partial v2 seed
        // omitted, so zoom is no longer the absolute tail here — only on a fresh
        // install, asserted in `freshInstallDefaultOrder`.)
        #expect(Array(config.displayOrder.prefix(4)) == [
            id(.control), id(.alternate), id(.command), id(.paste),
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

        // Esc stays hidden; the forced modifiers/zoom are shown.
        #expect(!config.isEnabled(id(.escape)))
        #expect(config.isEnabled(id(.tab)))
        #expect(config.isEnabled(id(.control)))
        #expect(config.isEnabled(id(.zoomIn)))
    }

    @Test("an upgraded config re-persists under the v3 keys so the migration runs once")
    func migrationPersistsUnderV3Keys() {
        let defaults = freshDefaults()
        defaults.set([id(.tab).storageKey], forKey: "cmux.terminal.toolbar.order.v2")
        defaults.set([id(.tab).storageKey], forKey: "cmux.terminal.toolbar.enabled.v2")

        _ = TerminalAccessoryConfiguration(defaults: defaults)

        // After init, v3 keys exist; a second load takes the v3 path (no second
        // force-enable), so hiding a modifier then would persist.
        let v3Order = defaults.array(forKey: "cmux.terminal.toolbar.order.v3") as? [String]
        #expect(v3Order != nil)
        #expect(v3Order?.contains(id(.control).storageKey) == true)

        let reloaded = TerminalAccessoryConfiguration(defaults: defaults)
        reloaded.setEnabled(id(.control), false)
        let reloadedAgain = TerminalAccessoryConfiguration(defaults: defaults)
        // The v3 path honored the hidden modifier rather than re-forcing it on.
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
}
