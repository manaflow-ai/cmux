//! Parity with the Swift menu rules: MenuLookTests, MenuTextSizeTests, GlassMenuTests,
//! GlassMenuTypeSelectTests and GlassMenuStepperTests (sizing) value for value, plus pins of
//! today's Swift outputs (thresholds, constants, colour math), through `ops::call("menu.*")`.

use cmux_design_core::menu::color::{ThemeRgb, css, swift_double};
use cmux_design_core::menu::look::{self, MenuLook, Shadow};
use cmux_design_core::menu::material::{self, MaterialTokens};
use cmux_design_core::menu::rows::{self, MenuItem, Modifiers, RowView, TypeSelect};
use cmux_design_core::menu::text_size::{self, TextSizeAction};
use cmux_design_core::menu::{HIGHLIGHT_INSET, Rect, popup};
use cmux_design_core::ops::{OpError, call};
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("menu.{name}"), &request).unwrap_or_else(|e| panic!("menu.{name}: {e:?}"))
}

/// MenuLookTests.claude: the look the Claude desktop fragment parses to.
fn claude() -> Value {
    json!({
        "cornerRadius": 12, "borderOpacity": 0.1,
        "fill": {"red": 43.0 / 255.0, "green": 43.0 / 255.0, "blue": 43.0 / 255.0},
        "padding": 8, "highlightRadius": 8, "rowHeight": 30,
        "shortcuts": "muted", "sectionLabel": "muted", "separator": "subtle", "submenu": "flush",
        "subtitle": "muted", "popoverPadding": 12, "popoverHeader": "strong", "progressHeight": 6
    })
}

fn rect(x: f64, y: f64, width: f64, height: f64) -> Rect {
    Rect { x, y, width, height }
}

// MARK: MenuLookTests

#[test]
fn the_standard_look_sends_no_tokens() {
    assert_eq!(op("webVariables", json!({"look": {}})), json!({}));
    assert_eq!(op("webVariables", json!({})), json!({}));
    assert_eq!(MenuLook::default().resolved_padding(), HIGHLIGHT_INSET);
    assert_eq!(Shadow::Standard.elevation(), Some(look::ELEVATION_2));
}

#[test]
fn the_claude_fragment_reaches_the_menu_tokens() {
    let tokens = op("webVariables", json!({"look": claude()}));
    let t = |k: &str| tokens.get(k).and_then(Value::as_str).map(str::to_string);
    assert_eq!(t("--menu-radius").as_deref(), Some("12px"));
    assert_eq!(t("--menu-fill").as_deref(), Some("rgba(43, 43, 43, 1.0)"));
    assert_eq!(
        t("--menu-border").as_deref(),
        Some("color-mix(in srgb, currentColor 10%, transparent)")
    );
    assert_eq!(t("--menu-padding").as_deref(), Some("8px"));
    assert_eq!(t("--menu-hover-radius").as_deref(), Some("8px"));
    assert_eq!(t("--menu-row-height").as_deref(), Some("30px"));
    assert_eq!(
        t("--menu-shortcut-color").as_deref(),
        Some("color-mix(in srgb, currentColor 45%, transparent)")
    );
    assert_eq!(
        t("--menu-separator").as_deref(),
        Some("color-mix(in srgb, currentColor 6%, transparent)")
    );
    assert_eq!(t("--menu-submenu-offset").as_deref(), Some("8px"));
    assert_eq!(t("--menu-submenu-align-offset").as_deref(), Some("-8px"));
    assert_eq!(t("--popover-progress-height").as_deref(), Some("6px"));
    assert_eq!(t("--menu-shadow"), None);
    let keys: Vec<&String> = tokens.as_object().unwrap().keys().collect();
    assert!(keys.iter().all(|k| k.starts_with("--menu-") || k.starts_with("--popover-")));
}

/// Pins every token the Claude fragment sends today, the ones MenuLookTests leaves unchecked too.
#[test]
fn the_claude_fragment_sends_exactly_these_tokens() {
    let muted = "color-mix(in srgb, currentColor 45%, transparent)";
    assert_eq!(
        op("webVariables", json!({"look": claude()})),
        json!({
            "--menu-radius": "12px",
            "--menu-border": "color-mix(in srgb, currentColor 10%, transparent)",
            "--menu-fill": "rgba(43, 43, 43, 1.0)",
            "--menu-padding": "8px",
            "--menu-hover-radius": "8px",
            "--menu-row-height": "30px",
            "--menu-shortcut-color": muted,
            "--menu-label-color": muted,
            "--menu-label-weight": "var(--weight-regular, 400)",
            "--menu-separator": "color-mix(in srgb, currentColor 6%, transparent)",
            "--menu-submenu-offset": "8px",
            "--menu-submenu-align-offset": "-8px",
            "--menu-subtitle-color": muted,
            "--popover-padding": "12px",
            "--popover-header-color": "currentColor",
            "--popover-header-size": "var(--text-body, 13px)",
            "--popover-header-weight": "var(--weight-emphasis, 600)",
            "--popover-progress-height": "6px",
        })
    );
}

#[test]
fn every_shadow_fits_the_native_band() {
    for shadow in Shadow::ALL {
        let Some(e) = shadow.elevation() else { continue };
        assert!(e.blur + e.offset <= look::shadow_margin(), "{shadow:?}");
    }
    assert_eq!(look::shadow_margin(), 8.0);
    assert_eq!(
        op("webVariables", json!({"look": {"shadow": "none"}})),
        json!({"--menu-shadow": "none"})
    );
    assert_eq!(
        op("webVariables", json!({"look": {"shadow": "subtle"}})),
        json!({"--menu-shadow": "0 1px 2px rgba(0, 0, 0, 0.07)"})
    );
    assert_eq!(
        op("webVariables", json!({"look": {"shadow": "strong"}})),
        json!({"--menu-shadow": "0 2px 6px rgba(0, 0, 0, 0.28)"})
    );
    assert_eq!(op("shadowElevation", json!({"shadow": "none"})), Value::Null);
    assert_eq!(
        op("shadowElevation", json!({"shadow": "standard"})),
        json!({"offset": 2.0, "blur": 6.0, "alpha": 0.11})
    );
}

#[test]
fn the_other_enum_steps_send_their_tokens() {
    assert_eq!(
        op("webVariables", json!({"look": {"separator": "none", "destructiveInk": "plain"}})),
        json!({"--menu-separator": "transparent", "--menu-destructive": "currentColor"})
    );
    assert_eq!(
        op("webVariables", json!({"look": {"progressFill": "muted"}})),
        json!({"--popover-progress-fill": "color-mix(in srgb, currentColor 55%, transparent)"})
    );
    assert_eq!(
        op("webVariables", json!({"look": {"progressFill": "strong"}})),
        json!({"--popover-progress-fill": "currentColor"})
    );
    // Flush with no padding: the highlight inset.
    assert_eq!(
        op("webVariables", json!({"look": {"submenu": "flush"}})),
        json!({"--menu-submenu-offset": "5px", "--menu-submenu-align-offset": "-5px"})
    );
}

#[test]
fn css_numbers_drop_the_trailing_zero_and_keep_three_decimals() {
    for (value, text) in [
        (12.0, "12"),
        (0.5, "0.5"),
        (1.23456, "1.235"),
        (-8.0, "-8"),
        (0.0004, "0"),
        (6.0005, "6.001"),
        (45.0, "45"),
    ] {
        assert_eq!(op("cssNumber", json!({"value": value})), json!(text), "{value}");
    }
    assert_eq!(look::number(0.1 * 100.0), "10");
    assert_eq!(look::number(0.45 * 100.0), "45");
}

#[test]
fn the_separator_ink_shares() {
    assert_eq!(look::Separator::Standard.ink_share(), 1.0);
    assert_eq!(look::Separator::Subtle.ink_share(), 0.5);
    assert_eq!(look::Separator::None.ink_share(), 0.0);
    assert_eq!(look::MUTED_SHARE, 0.45);
}

#[test]
fn the_native_menu_reads_the_look() {
    // MenuLookTests.theNativeMenuReadsTheLook: Settings…, a separator, Sign Out.
    let views = json!([{"height": 20}, {"separator": true}, {"height": 20}]);
    let claude_size = op("fittingSize", json!({"views": views, "look": claude()}));
    assert_eq!(claude_size["height"], json!(8.0 * 2.0 + 30.0 * 2.0 + rows::SEPARATOR_HEIGHT));
    let standard = op("fittingSize", json!({"views": views}));
    assert_eq!(
        standard["height"],
        json!(HIGHLIGHT_INSET * 2.0 + material::ROW_HEIGHT * 2.0 + rows::SEPARATOR_HEIGHT)
    );
}

#[test]
fn a_flush_submenu_meets_the_menu_edge_and_its_row() {
    let card = rect(100.0, 100.0, 240.0, 300.0);
    let row = rect(108.0, 300.0, 224.0, 30.0);
    let anchor = look::flush_anchor(row, card, 8.0, look::SIDE_GAP);
    // The submenu placed beside the anchor, side gap 4, starts at the card's edge.
    assert_eq!(anchor.x + anchor.width + look::SIDE_GAP, card.x + card.width);
    assert_eq!(anchor, rect(104.0, 300.0, 232.0, 38.0));
    // Its top is the row's top plus the padding: its first row is level with `row`.
    assert_eq!(anchor.y + anchor.height - 8.0, row.y + row.height);
    let reply = op("flushAnchor", json!({"row": row, "card": card, "padding": 8}));
    assert_eq!(reply, json!({"x": 104.0, "y": 300.0, "width": 232.0, "height": 38.0}));
    // A card narrower than two gaps collapses to zero width.
    assert_eq!(look::flush_anchor(row, rect(0.0, 0.0, 6.0, 10.0), 8.0, 4.0).width, 0.0);
}

#[test]
fn the_submenu_anchor_is_the_row_unless_flush() {
    let card = rect(100.0, 100.0, 240.0, 300.0);
    let row = rect(108.0, 300.0, 224.0, 30.0);
    assert_eq!(
        op("submenuAnchor", json!({"row": row, "card": card})),
        serde_json::to_value(row).unwrap()
    );
    assert_eq!(
        op("submenuAnchor", json!({"look": {"submenu": "flush"}, "row": row, "card": card})),
        json!({"x": 104.0, "y": 300.0, "width": 232.0, "height": 35.0})
    );
}

#[test]
fn apply_look_picks_the_radius_drop_and_look_view() {
    assert_eq!(
        op("applyLook", json!({"look": {}, "surfaceRadius": 8})),
        json!({"cornerRadius": 8.0, "elevation": {"offset": 2.0, "blur": 6.0, "alpha": 0.11},
               "drawsLookView": false, "padding": 5.0, "separatorInkShare": 1.0})
    );
    assert_eq!(
        op("applyLook", json!({"look": claude(), "surfaceRadius": 8})),
        json!({"cornerRadius": 12.0, "elevation": {"offset": 2.0, "blur": 6.0, "alpha": 0.11},
               "drawsLookView": true, "padding": 8.0, "separatorInkShare": 0.5})
    );
    let only_edge = op(
        "applyLook",
        json!({"look": {"borderOpacity": 0.2, "shadow": "none"}, "surfaceRadius": 0}),
    );
    assert_eq!(only_edge["drawsLookView"], json!(true));
    assert_eq!(only_edge["elevation"], Value::Null);
    assert_eq!(only_edge["cornerRadius"], json!(0.0));
}

// MARK: MenuTextSizeTests

#[test]
fn a_context_menu_draws_at_the_text_scale_and_back_at_default() {
    let base = 14.0;
    let scale = 16.0 / 14.0;
    let points = text_size::size(base, scale);
    assert_eq!(points, 16.0);
    assert!(points > base);
    assert_eq!(
        text_size::action(base, scale, Some(base), false, false),
        TextSizeAction::Set { point_size: 16.0 }
    );
    assert_eq!(
        text_size::action(base, 1.0, Some(16.0), false, true),
        TextSizeAction::Restore { point_size: 14.0 }
    );
    assert_eq!(
        op("textSizeAction", json!({"base": 14, "scale": scale, "current": 14})),
        json!({"action": "set", "pointSize": 16.0})
    );
    assert_eq!(
        op("textSizeAction", json!({"base": 14, "scale": 1, "current": 16, "wasSized": true})),
        json!({"action": "restore", "pointSize": 14.0})
    );
}

#[test]
fn the_menu_bar_keeps_the_system_size() {
    assert_eq!(text_size::action(14.0, 1.3, Some(14.0), true, false), TextSizeAction::Keep);
    assert_eq!(
        op("textSizeAction", json!({"base": 14, "scale": 1.3, "inMenuBar": true})),
        json!({"action": "keep"})
    );
}

#[test]
fn at_the_default_size_a_menu_with_its_own_font_keeps_it() {
    assert_eq!(text_size::action(14.0, 1.0, Some(11.0), false, false), TextSizeAction::Keep);
    // Within 0.001 of 1 is the default size.
    assert_eq!(text_size::action(14.0, 1.0009, Some(11.0), false, false), TextSizeAction::Keep);
    assert_eq!(
        text_size::action(14.0, 1.0011, Some(11.0), false, false),
        TextSizeAction::Set { point_size: 14.0 }
    );
    // Already at the size: untouched.
    assert_eq!(text_size::action(14.0, 1.5, Some(21.0), false, false), TextSizeAction::Keep);
    // No font yet: set.
    assert_eq!(
        text_size::action(13.0, 1.2, None, false, false),
        TextSizeAction::Set { point_size: 15.5 }
    );
}

#[test]
fn the_text_size_rounds_to_half_points() {
    for (base, scale, points) in [
        (13.0, 1.0, 13.0),
        (13.0, 1.1, 14.5),
        (13.0, 1.15, 15.0),
        (14.0, 0.9, 12.5),
        (13.0, 1.25, 16.5),
    ] {
        assert_eq!(
            op("textSize", json!({"base": base, "scale": scale})),
            json!(points),
            "{base} x {scale}"
        );
    }
}

// MARK: GlassMenuTests

fn item(title: &str, key: &str) -> MenuItem {
    MenuItem {
        title: title.into(),
        key_equivalent: key.into(),
        enabled: true,
        ..MenuItem::default()
    }
}

fn separator() -> MenuItem {
    MenuItem { separator: true, enabled: true, ..MenuItem::default() }
}

#[test]
fn rows_skip_hidden_and_custom_view_items_and_collapse_separators() {
    let items = vec![
        separator(),
        item("Settings…", ","),
        MenuItem { hidden: true, ..item("Hidden", "") },
        separator(),
        separator(),
        MenuItem { has_view: true, ..item("Header", "") },
        item("Sign Out", ""),
        separator(),
    ];
    let shown: Vec<String> = rows::rows(&items)
        .into_iter()
        .map(|r| r.map_or_else(|| "—".to_string(), |i| items[i].title.clone()))
        .collect();
    assert_eq!(shown, ["Settings…", "—", "Sign Out"]);
    assert_eq!(op("rows", json!({"items": items})), json!([1, null, 6]));
}

#[test]
fn shortcuts_read_as_the_menu_draws_them() {
    assert_eq!(op("shortcut", json!({"keyEquivalent": ","})), json!("⌘,"));
    assert_eq!(
        op("shortcut", json!({"keyEquivalent": "F", "modifiers": {"command": true}})),
        json!("⇧⌘F")
    );
    assert_eq!(op("shortcut", json!({"keyEquivalent": ""})), Value::Null);
}

#[test]
fn shortcut_glyphs_and_named_keys() {
    let all = Modifiers { command: true, option: true, control: true, shift: true };
    assert_eq!(rows::shortcut("k", all).as_deref(), Some("⌃⌥⇧⌘K"));
    let none = Modifiers::default();
    for (key, name) in
        [("\r", "↩"), ("\u{1b}", "⎋"), ("\t", "⇥"), (" ", "Space"), ("\u{8}", "⌫"), ("\u{7f}", "⌫")]
    {
        assert_eq!(rows::shortcut(key, none).as_deref(), Some(name), "{key:?}");
    }
    assert_eq!(rows::shortcut("=", Modifiers { command: true, ..none }).as_deref(), Some("⌘="));
}

#[test]
fn the_menu_material_constants() {
    let c = op("material", json!({}));
    assert_eq!(c["veil"], json!(0.4));
    assert_eq!(material::veil(), 0.4);
    assert_eq!(c["veilPercent"], json!(40.0));
    assert_eq!(c["defaultCornerRadius"], json!(8.0));
    assert_eq!(c["rowHeight"], json!(28.0));
    assert_eq!(c["maximumVeil"], json!(0.9));
    assert_eq!(c["contrastHeadroom"], json!(0.1));
    assert_eq!(c["webSecondaryInkShare"], json!(0.68));
    assert_eq!(c["tintStrength"], json!(1.25));
}

#[test]
fn rows_sit_on_the_menu_grid_and_fit_their_width() {
    let views = [
        RowView { width: 120.0, height: 18.0, separator: false },
        RowView { separator: true, ..RowView::default() },
        RowView { width: 90.0, height: 18.0, separator: false },
    ];
    let (width, height) = rows::fitting_size(&views, HIGHLIGHT_INSET, material::ROW_HEIGHT);
    assert!(width >= rows::LIST_MIN_WIDTH);
    assert_eq!(height, HIGHLIGHT_INSET * 2.0 + material::ROW_HEIGHT * 2.0 + rows::SEPARATOR_HEIGHT);
    // A wide row widens the list up to the max, and fractional sizes round up.
    let wide = [RowView { width: 300.4, height: 28.2, separator: false }];
    assert_eq!(rows::fitting_size(&wide, 5.0, 28.0), (311.0, 39.0));
    let widest = [RowView { width: 900.0, height: 10.0, separator: false }];
    assert_eq!(rows::fitting_size(&widest, 5.0, 28.0), (360.0, 38.0));
}

#[test]
fn the_list_lays_rows_down_from_the_padding() {
    let views = json!([{"height": 18}, {"separator": true}, {"height": 40}]);
    assert_eq!(
        op("layout", json!({"views": views, "boundsWidth": 240})),
        json!([
            {"x": 5.0, "y": 5.0, "width": 230.0, "height": 28.0},
            {"x": 5.0, "y": 33.0, "width": 230.0, "height": 9.0},
            {"x": 5.0, "y": 42.0, "width": 230.0, "height": 40.0},
        ])
    );
}

#[test]
fn an_empty_or_separator_only_menu_has_no_rows() {
    assert!(rows::rows(&[]).is_empty());
    assert!(rows::rows(&[separator(), separator()]).is_empty());
}

#[test]
fn a_shortcut_finds_its_row_while_the_menu_is_open() {
    let command = Modifiers { command: true, ..Modifiers::default() };
    let items = vec![
        item("Settings…", ","),
        MenuItem { submenu: Some(vec![item("Keyboard Shortcuts", "/")]), ..item("Help", "") },
        MenuItem { enabled: false, ..item("Off", "k") },
    ];
    assert_eq!(rows::item_matching(",", command, &items), Some(vec![0]));
    assert_eq!(rows::item_matching("/", command, &items), Some(vec![1, 0]));
    assert_eq!(rows::item_matching(",", Modifiers { option: true, ..command }, &items), None);
    assert_eq!(rows::item_matching("k", command, &items), None);
    assert_eq!(
        op("matchKey", json!({"characters": "/", "flags": {"command": true}, "items": items})),
        json!([1, 0])
    );
}

#[test]
fn key_matching_ignores_case_and_reads_uppercase_as_shift() {
    let command = Modifiers { command: true, ..Modifiers::default() };
    let shift_command = Modifiers { shift: true, ..command };
    let items =
        vec![item("Find", "F"), MenuItem { hidden: true, ..item("Hidden", "h") }, separator()];
    assert_eq!(rows::item_matching("f", shift_command, &items), Some(vec![0]));
    assert_eq!(rows::item_matching("F", shift_command, &items), Some(vec![0]));
    assert_eq!(rows::item_matching("f", command, &items), None);
    assert_eq!(rows::item_matching("h", command, &items), None);
    assert_eq!(rows::item_matching("", command, &items), None);
    // A submenu's item is found before later rows; a submenu row's own key is never matched.
    let items = vec![MenuItem { submenu: Some(vec![]), ..item("More", "m") }, item("Mine", "m")];
    assert_eq!(rows::item_matching("m", command, &items), Some(vec![1]));
}

// MARK: GlassMenuTypeSelectTests and GlassMenuStepperTests

#[test]
fn letters_match_title_starts_ignoring_case_and_accents() {
    let titles: Vec<Option<String>> = [
        Some("Find…"),
        None,
        Some("Émulate Device…"),
        Some("History"),
        Some("Help"),
        None,
        Some("Settings…"),
    ]
    .into_iter()
    .map(|t| t.map(String::from))
    .collect();
    let mut select = TypeSelect::default();
    assert_eq!(select.pick("e", 0.0, &titles, None), Some(2));
    assert_eq!(select.pick("h", 5.0, &titles, Some(2)), Some(3));
    assert_eq!(select.pick("h", 5.5, &titles, Some(3)), Some(4));
    assert_eq!(select.pick("h", 6.0, &titles, Some(4)), Some(3), "a repeated letter wraps");
    assert_eq!(select.pick("x", 9.0, &titles, None), None);
}

#[test]
fn typing_jumps_and_starts_over_after_a_pause() {
    // GlassMenuStepperTests.typingJumpsToARowAndReturnRunsItAfterTheMenuCloses's titles.
    let titles: Vec<Option<String>> = ["Find…", "Zoom", "History", "Help", "Settings…"]
        .into_iter()
        .map(|t| Some(t.to_string()))
        .collect();
    let mut select = TypeSelect::default();
    let mut current = Some(0);
    current = select.pick("h", 1.0, &titles, current).or(current);
    assert_eq!(current, Some(2));
    current = select.pick("h", 1.2, &titles, current).or(current);
    assert_eq!(current, Some(3), "the same letter again moves to the next row with it");
    current = select.pick("s", 3.0, &titles, current).or(current);
    assert_eq!(current, Some(4), "after a pause typing starts over");
    current = select.pick("h", 5.0, &titles, current).or(current);
    current = select.pick("i", 5.3, &titles, current).or(current);
    assert_eq!(current, Some(2), "letters typed together match a title's start");
    assert_eq!(select.typed, "hi");
    // Exactly the timeout apart still continues; past it starts over.
    let mut select = TypeSelect::default();
    select.pick("h", 0.0, &titles, None);
    select.pick("e", 1.0, &titles, None);
    assert_eq!(select.typed, "he");
    select.pick("e", 2.0001, &titles, None);
    assert_eq!(select.typed, "e");
    assert_eq!(select.pick("", 3.0, &titles, None), None);
}

#[test]
fn type_select_round_trips_its_state_through_the_op() {
    let titles = json!(["Find…", null, "Émulate Device…", "History", "Help"]);
    let first =
        op("typeSelect", json!({"characters": "h", "time": 0, "titles": titles, "current": null}));
    assert_eq!(first["pick"], json!(3));
    assert_eq!(first["state"], json!({"typed": "h", "lastTime": 0.0}));
    let second = op(
        "typeSelect",
        json!({"state": first["state"], "characters": "e", "time": 0.5, "titles": titles, "current": 3}),
    );
    assert_eq!(second["pick"], json!(4));
    assert_eq!(second["state"]["typed"], json!("he"));
}

#[test]
fn folding_drops_case_and_accents() {
    assert_eq!(rows::fold("Émulate"), "emulate");
    assert_eq!(rows::fold("ÇA VA"), "ca va");
    assert_eq!(rows::fold("e\u{301}"), "e");
    assert_eq!(rows::fold("Settings…"), "settings…");
}

#[test]
fn the_stepper_row_sizes_with_the_menu_grid() {
    // GlassMenuStepperTests: 5 rows, 2 separators and the stepper row (one control row).
    let mut views = vec![RowView { width: 100.0, height: 18.0, separator: false }; 6];
    views.push(RowView { separator: true, ..RowView::default() });
    views.push(RowView { separator: true, ..RowView::default() });
    let (_, height) = rows::fitting_size(&views, HIGHLIGHT_INSET, material::ROW_HEIGHT);
    let rows_height = 5.0 * material::ROW_HEIGHT + 2.0 * rows::SEPARATOR_HEIGHT;
    assert_eq!(height, HIGHLIGHT_INSET * 2.0 + rows_height + material::ROW_HEIGHT);
}

// MARK: GlassMenuMaterial

fn tokens(
    window: u32,
    surface: u32,
    primary: u32,
    secondary: u32,
    tint: (u32, f64),
    dark: bool,
) -> MaterialTokens {
    MaterialTokens {
        window_background: ThemeRgb::hex(window, 1.0),
        surface_background: ThemeRgb::hex(surface, 1.0),
        text_primary: ThemeRgb::hex(primary, 1.0),
        text_secondary: ThemeRgb::hex(secondary, 1.0),
        glass_tint: ThemeRgb::hex(tint.0, tint.1),
        is_dark: dark,
    }
}

/// A light theme whose text reads everywhere keeps the shared 40% veil.
#[test]
fn a_theme_whose_text_reads_keeps_the_shared_veil() {
    let light = tokens(0xF5F5F5, 0xFFFFFF, 0x000000, 0x555555, (0xFFFFFF, 0.5), false);
    assert_eq!(material::veil_for(&light), 0.4);
}

#[test]
fn a_veil_never_passes_the_cap() {
    // White text on white reads at once: the target is capped at the text's own contrast less 0.05.
    let blind = tokens(0x000000, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, (0x000000, 0.0), false);
    assert_eq!(material::veil_for(&blind), 0.4);
    // Grey text near 4.5:1 on white over a fully black tint never reads: the veil stops at the cap.
    let dense = tokens(0x000000, 0xFFFFFF, 0x777777, 0x777777, (0x000000, 0.8), false);
    let veil = material::veil_for(&dense);
    assert!((veil - 0.9).abs() < 1e-12, "{veil}");
    // Its web clear drops to the floor, (1 - 0.9) / (1 - 0.4), to 3 decimals.
    assert_eq!(material::web_clear(&dense), 0.167);
    assert_eq!(material::web_clear_css(&dense), "0.167");
}

/// Pins of today's veil and web clear for a dark and a light theme (the Swift loop, step for step).
#[test]
fn the_veil_and_web_clear_pins() {
    let dark = tokens(0x1E1E1E, 0x252526, 0xD4D4D4, 0x9D9D9D, (0x000000, 0.3), true);
    let light = tokens(0xFAF4ED, 0xFFFAF3, 0x575279, 0x797593, (0xFFFFFF, 0.3), false);
    let dark_veil = op("veil", json!({"tokens": dark}));
    let light_veil = op("veil", json!({"tokens": light}));
    assert_eq!(dark_veil, json!(material::veil_for(&dark)));
    // Each veil is the shared 0.4 or a 2% step above it, never past the cap.
    for veil in [dark_veil.as_f64().unwrap(), light_veil.as_f64().unwrap()] {
        let steps = (veil - 0.4) / 0.02;
        assert!(
            (steps - steps.round()).abs() < 1e-9 && (0.4..=0.9 + 1e-12).contains(&veil),
            "{veil}"
        );
    }
    let clear = op("webClear", json!({"tokens": dark}));
    let value = clear["value"].as_f64().unwrap();
    assert_eq!(clear["css"], json!(format!("{value:.3}")));
    assert!((0.166..=1.0 + 1e-9).contains(&value));
}

#[test]
fn the_glass_lays_the_tint_then_the_veil() {
    let t = tokens(0x000000, 0xFFFFFF, 0x000000, 0x000000, (0x000000, 0.4), false);
    // Tint alpha 0.4 x 1.25 = 0.5 black over white: 0.5 grey; then white at 0.4: 0.7.
    let ground = material::glass(&t, 0.4, ThemeRgb::WHITE);
    assert!((ground.red - 0.7).abs() < 1e-12 && ground.alpha == 1.0);
    // The tint's alpha caps at 1.
    let dense = tokens(0x000000, 0xFFFFFF, 0x000000, 0x000000, (0x000000, 0.9), false);
    assert!((material::glass(&dense, 0.0, ThemeRgb::WHITE).red).abs() < 1e-12);
    let reply =
        op("glass", json!({"tokens": t, "veil": 0.4, "page": {"red": 1, "green": 1, "blue": 1}}));
    assert!((reply["red"].as_f64().unwrap() - 0.7).abs() < 1e-12);
}

#[test]
fn the_menu_corner_is_concentric_with_the_pill() {
    assert_eq!(op("menuCornerRadius", json!({"surface": 8})), json!(13.0));
    assert_eq!(material::menu_corner_radius(0.0), 0.0);
    assert_eq!(material::menu_corner_radius(-1.0), 0.0);
}

#[test]
fn css_colours_round_channels_and_alpha_to_8_bits() {
    assert_eq!(css(ThemeRgb::hex(0x2B2B2B, 1.0)), "rgba(43, 43, 43, 1.0)");
    assert_eq!(css(ThemeRgb::new(1.0, 0.0, 0.5, 0.1)), "rgba(255, 0, 128, 0.102)");
    assert_eq!(css(ThemeRgb::new(2.0, -1.0, 0.0, 0.0)), "rgba(255, 0, 0, 0.0)");
    assert_eq!(
        op("css", json!({"color": {"red": 0, "green": 0, "blue": 0, "alpha": 0.5}})),
        json!("rgba(0, 0, 0, 0.502)")
    );
    assert_eq!(swift_double(1.0), "1.0");
    assert_eq!(swift_double(0.25), "0.25");
}

#[test]
fn contrast_matches_wcag() {
    assert!((ThemeRgb::WHITE.contrast(ThemeRgb::BLACK) - 21.0).abs() < 1e-12);
    assert_eq!(ThemeRgb::WHITE.contrast(ThemeRgb::WHITE), 1.0);
}

// MARK: ThemedPopUpButtonCell, NSMenu+SystemItems

#[test]
fn the_pop_up_chevron() {
    let pop = popup::chevron(false, None, true, true, true);
    assert_eq!(pop.symbol, "chevron.up.chevron.down");
    assert!((pop.point_size - 9.1).abs() < 1e-12);
    assert!(pop.themed);
    let pull = popup::chevron(true, Some(12.0), true, false, true);
    assert_eq!(pull.symbol, "chevron.down");
    assert!((pull.point_size - 8.4).abs() < 1e-12);
    assert!(!pull.themed, "no ink: AppKit's own bezel");
    assert_eq!(
        popup::chevron_frame(rect(0.0, 0.0, 120.0, 24.0), 10.0, 8.0, 12.0),
        rect(98.0, 8.0, 10.0, 8.0)
    );
    let reply = op(
        "popUpChevron",
        json!({"pullsDown": true, "fontSize": 10, "hasFill": true, "hasInk": true, "bordered": true,
               "bounds": {"x": 0, "y": 0, "width": 100, "height": 20}, "imageWidth": 8, "imageHeight": 6, "space3": 12}),
    );
    assert_eq!(reply["symbol"], json!("chevron.down"));
    assert_eq!(reply["themed"], json!(true));
    assert_eq!(reply["frame"], json!({"x": 80.0, "y": 7.0, "width": 8.0, "height": 6.0}));
}

#[test]
fn system_items_follow_plugins_and_writing_tools() {
    assert!(popup::allows_system_items(true, None));
    assert!(popup::allows_system_items(false, Some(true)));
    assert!(!popup::allows_system_items(false, Some(false)));
    assert!(!popup::allows_system_items(false, None), "before macOS 15.2: only plugins");
    assert_eq!(
        op("allowsSystemItems", json!({"contextMenuPlugIns": false, "writingTools": false})),
        json!(false)
    );
}

#[test]
fn unknown_and_bad_requests() {
    assert_eq!(call("menu.nope", &json!({})), Err(OpError::Unknown));
    assert!(matches!(call("menu.cssNumber", &json!({})), Err(OpError::Invalid(_))));
    assert!(matches!(
        call("menu.webVariables", &json!({"look": {"shadow": "huge"}})),
        Err(OpError::Invalid(_))
    ));
}
