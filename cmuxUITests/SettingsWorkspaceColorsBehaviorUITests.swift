import XCTest

/// Behavioral UI tests for the Settings **Workspace Colors** section.
///
/// Section controls and their catalog keys (see
/// `Packages/macOS/CmuxSettingsUI/.../Sections/WorkspaceColorsSection.swift`
/// and `Packages/macOS/CmuxSettings/.../Keys/WorkspaceColorsCatalogSection.swift`):
///
/// - **Workspace Color Indicator** (`workspaceColors.indicatorStyle`,
///   UserDefaults `sidebarActiveTabIndicatorStyle`): menu Picker, Left
///   Rail / Solid Fill.
/// - **Selection Highlight** (`workspaceColors.selectionColor`,
///   UserDefaults `sidebarSelectionColorHex`): `ColorPicker` + a "Reset"
///   button shown only when a custom hex is stored.
/// - **Notification Badge** (`workspaceColors.notificationBadgeColor`,
///   UserDefaults `sidebarNotificationBadgeColorHex`): same shape.
/// - **Palette entry colors** (`workspaceColors.colors`, UserDefaults
///   `workspaceTabColor.colors`): one row per effective palette entry,
///   each rendering the entry's hex as monospaced `Text` plus a
///   `ColorPicker`; custom entries also get a "Remove" button.
/// - **Reset Palette** (action): restores the built-in palette and
///   removes extra named colors.
///
/// ## Tiering
///
/// The *visible* runtime effect of every color/style setting lives in
/// the sidebar workspace-tab rendering and is pixel-only:
///
/// - `WorkspaceTabTitleView.activeBorderLineWidth` / `activeBorderColor`
///   switch on `activeTabIndicatorStyle` (left rail vs solid fill) — a
///   `CGFloat` border width and a `Color`, no accessibility surface.
/// - `selectedWorkspaceBackgroundNSColor` is derived from
///   `sidebarSelectionColorHex` and used only as a fill.
/// - `activeUnreadBadgeFillColor` is derived from
///   `sidebarNotificationBadgeColorHex` and used only as a fill.
/// - palette entry colors feed `WorkspaceTabColorSettings.palette()`,
///   consumed as `NSColor`/`Color` fills for workspace tab swatches and
///   the per-workspace color context menu.
///
/// The sidebar workspace row exposes `accessibilityIdentifier`
/// `sidebarWorkspace.<uuid>` but no accessibility *value* that reflects
/// the resolved indicator style or any color, so none of these effects
/// are assertable through XCUITest without adding a runtime seam (e.g.
/// publishing the resolved color/style as an accessibility value, or a
/// pixel sampler). Per the task constraints, no app seam is added, so
/// those effects are documented as TIER 2 below.
///
/// What *is* seam-free observable: the section renders one row per
/// effective palette entry, and each row prints that entry's hex as a
/// monospaced static text. The effective palette is computed directly
/// from the `workspaceColors.colors` catalog default (the 16 built-in
/// named colors when no override is stored). So the built-in palette
/// hexes appearing as static text in the running Settings surface is a
/// genuine, effect-level reflection of the palette setting's resolved
/// value, not just "a control flipped". `testBuiltInPaletteEntriesRenderTheirEffectiveHexValues`
/// asserts that effect. The Selection / Badge `ColorPicker`s and the
/// per-row Reset buttons cannot be exercised here: editing a color
/// requires driving the native `NSColorPanel` (no stable identifier,
/// flaky under XCUITest), and the per-row Reset buttons only appear once
/// a custom hex is stored, which there is no seam-free way to set up.
///
// TIER 2 (needs runtime seam): Workspace Color Indicator (left rail vs
//   solid fill) — only changes `activeBorderLineWidth`/`activeBorderColor`
//   on the active workspace tab; pixel-only, no accessibility value.
// TIER 2 (needs runtime seam): Selection Highlight color — only changes
//   the selected workspace tab background fill; pixel-only, and the
//   ColorPicker drives NSColorPanel which XCUITest cannot reliably set.
// TIER 2 (needs runtime seam): Notification Badge color — only changes
//   the unread-badge fill on workspace tabs; pixel-only, same
//   NSColorPanel limitation.
// TIER 2 (needs runtime seam): palette entry color edit — editing one
//   entry persists the whole effective palette, but the edit path is the
//   per-row ColorPicker (NSColorPanel), unreachable seam-free; the *fill*
//   it changes on workspace swatches is pixel-only.
// TIER 2 (needs runtime seam): Reset Palette effect — the only seam-free
//   way to observe the reset is for a custom/overridden palette row to
//   disappear and built-in hexes to revert, but reaching the non-default
//   state first requires the ColorPicker/NSColorPanel or editing
//   cmux.json, neither reachable from XCUITest without a seam. Verifying
//   the reset removes custom rows is therefore TIER 2.
final class SettingsWorkspaceColorsBehaviorUITests: SettingsUITestCase {

    /// UserDefaults keys (raw `userDefaultsKey`s) backing this section.
    private static let workspaceColorKeys = [
        "sidebarActiveTabIndicatorStyle",
        "sidebarSelectionColorHex",
        "sidebarNotificationBadgeColorHex",
        "workspaceTabColor.colors",
    ]

    /// Built-in palette default hexes (mirrors
    /// `WorkspaceColorsSection.builtInPalette`). When no override is
    /// stored, these are the effective palette and each is rendered as a
    /// monospaced static text in its entry row.
    private static let builtInHexes: [(name: String, hex: String)] = [
        ("Red", "#C0392B"),
        ("Green", "#196F3D"),
        ("Blue", "#1565C0"),
        ("Purple", "#6A1B9A"),
    ]

    override func setUp() {
        super.setUp()
        resetDefaults(Self.workspaceColorKeys)
    }

    override func tearDown() {
        resetDefaults(Self.workspaceColorKeys)
        super.tearDown()
    }

    /// TIER 1: with no stored palette override, the section renders the
    /// built-in palette and each entry row prints its effective hex. This
    /// asserts the *effect* of the `workspaceColors.colors` setting's
    /// resolved value (the 16 built-in named colors) on the live Settings
    /// surface, not merely that a control exists.
    func testBuiltInPaletteEntriesRenderTheirEffectiveHexValues() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        navigate(window, to: "Workspace Colors")

        // Section anchor: the indicator row title must render so we know
        // the Workspace Colors detail is on screen.
        let indicatorTitle = window.staticTexts["Workspace Color Indicator"]
        XCTAssertTrue(
            poll(timeout: 6.0) { indicatorTitle.exists },
            "Workspace Colors section did not render its indicator row"
        )

        // The selection / badge color rows render their titles too.
        XCTAssertTrue(
            window.staticTexts["Selection Highlight"].exists,
            "Selection Highlight row missing"
        )
        XCTAssertTrue(
            window.staticTexts["Notification Badge"].exists,
            "Notification Badge row missing"
        )

        // Effect: each built-in entry row prints its resolved default
        // hex. These come straight from the effective palette computed
        // from the `workspaceColors.colors` catalog default.
        for entry in Self.builtInHexes {
            let hexText = window.staticTexts[entry.hex]
            XCTAssertTrue(
                poll(timeout: 4.0) { hexText.exists },
                "Expected palette entry \(entry.name) to render hex \(entry.hex)"
            )
            XCTAssertTrue(
                window.staticTexts[entry.name].exists,
                "Expected palette entry row titled \(entry.name)"
            )
        }

        // The Reset Palette action row is present (its observable reset
        // effect is documented TIER 2 above).
        XCTAssertTrue(
            window.staticTexts["Reset Palette"].exists,
            "Reset Palette row missing"
        )
    }

    /// TIER 1 (regression, #7137): the **Workspace Color Indicator** menu
    /// Picker must round-trip both directions. The reporter could switch
    /// Left Rail → Solid Fill but then the Left Rail item became
    /// unselectable, trapping the setting on Solid Fill with no way back
    /// from the UI.
    ///
    /// The picker renders as a `.menu` Picker → an AppKit popUpButton whose
    /// displayed `value` is the selected style's localized label. Driving
    /// the popUpButton and its menu items is the same seam-free path the
    /// Sidebar branch-layout picker test uses. This asserts the *behavior*
    /// (the selected value returns to Left Rail), not merely that a control
    /// exists — and that the Left Rail menu item is enabled and hittable
    /// while Solid Fill is the current value, which is exactly what the bug
    /// report says is broken.
    func testIndicatorStylePickerCanReturnToLeftRailAfterSolidFill() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        navigate(window, to: "Workspace Colors")

        // Anchor: the Workspace Colors detail is on screen.
        XCTAssertTrue(
            poll(timeout: 6.0) { window.staticTexts["Workspace Color Indicator"].exists },
            "Workspace Colors section did not render its indicator row"
        )

        // Default value is Left Rail, so the picker shows "Left Rail".
        let leftRailPicker = requireElement(
            candidates: [
                window.popUpButtons["Left Rail"],
                window.popUpButtons.matching(NSPredicate(format: "value == %@", "Left Rail")).firstMatch,
            ],
            timeout: 6.0,
            description: "indicator picker showing Left Rail"
        )

        // Switch Left Rail → Solid Fill (the direction the reporter says works).
        leftRailPicker.click()
        let solidFillItem = requireElement(
            candidates: [app.menuItems["Solid Fill"], window.menuItems["Solid Fill"]],
            timeout: 4.0,
            description: "Solid Fill menu item"
        )
        solidFillItem.click()

        // The picker now displays Solid Fill.
        let solidFillPicker = requireElement(
            candidates: [
                window.popUpButtons["Solid Fill"],
                window.popUpButtons.matching(NSPredicate(format: "value == %@", "Solid Fill")).firstMatch,
            ],
            timeout: 5.0,
            description: "indicator picker showing Solid Fill"
        )
        XCTAssertEqual(
            solidFillPicker.value as? String,
            "Solid Fill",
            "Picker should show Solid Fill after selecting it"
        )

        // Reopen and select Left Rail again — the regression. The Left Rail
        // menu item must be enabled and hittable while Solid Fill is the
        // current value.
        solidFillPicker.click()
        let leftRailItem = requireElement(
            candidates: [app.menuItems["Left Rail"], window.menuItems["Left Rail"]],
            timeout: 4.0,
            description: "Left Rail menu item"
        )
        XCTAssertTrue(
            leftRailItem.isEnabled,
            "Left Rail menu item must be enabled while Solid Fill is selected (#7137)"
        )
        XCTAssertTrue(
            leftRailItem.isHittable,
            "Left Rail menu item must be hittable while Solid Fill is selected (#7137)"
        )
        leftRailItem.click()

        // Effect: the picker returns to Left Rail — the setting is no longer
        // trapped on Solid Fill.
        let backToLeftRail = requireElement(
            candidates: [
                window.popUpButtons["Left Rail"],
                window.popUpButtons.matching(NSPredicate(format: "value == %@", "Left Rail")).firstMatch,
            ],
            timeout: 5.0,
            description: "indicator picker back on Left Rail"
        )
        XCTAssertEqual(
            backToLeftRail.value as? String,
            "Left Rail",
            "Picker should return to Left Rail after selecting it again (#7137)"
        )
    }
}
