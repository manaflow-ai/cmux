//! Parity with the Swift overlay rules: SurfaceRoleTests, FloatingGlassStyleTests,
//! OverlayGlassVariantTests, FindPillTests, HoverSurfaceStaysPutTests, NativePopupColumnsTests and
//! NativePopupPressReleaseTests (their pure parts) value for value, plus pins of today's Swift
//! outputs (presets, thresholds, knob ranges, deadlines), through `ops::call("overlay.*")`.

use cmux_design_core::menu::color::ThemeRgb;
use cmux_design_core::ops::{OpError, call};
use cmux_design_core::overlay::glass::{
    self, ELEVATION_2, Elevation, FloatingGlassStyle, GlassLevel, HoverSurfaceLook,
    OverlayGlassVariant, Rim, SurfaceRole,
};
use cmux_design_core::overlay::pane::{
    self, FloatingPaneCornerMode, FloatingPaneLook, FloatingPaneMaterial,
};
use cmux_design_core::overlay::popup::{
    self, ColumnKey, ColumnsInput, KeyColumn, KeyRow, LaidColumn, LaidRow, Point, PressOutcome,
    Rect, RowKind, RowLists,
};
use cmux_design_core::overlay::{find, quit};
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("overlay.{name}"), &request).unwrap_or_else(|e| panic!("overlay.{name}: {e:?}"))
}

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-9
}

// MARK: SurfaceRoleTests

#[test]
fn the_neutral_looks_keep_their_values() {
    let toast = FloatingGlassStyle {
        corner_depth: 0,
        dark_veil_alpha: 0.42,
        light_veil_alpha: 0.55,
        dark_rim: Rim { top: 0.30, bottom: 0.06 },
        light_rim: Rim { top: 0.85, bottom: 0.10 },
        casts_shadow: true,
        veil_takes_theme_tint: true,
    };
    assert_eq!(FloatingGlassStyle::TOAST, toast);
    assert_eq!(
        FloatingGlassStyle::DIALOG,
        FloatingGlassStyle {
            dark_veil_alpha: 0.48,
            light_veil_alpha: 0.62,
            dark_rim: Rim { top: 0.28, bottom: 0.05 },
            veil_takes_theme_tint: false,
            ..toast
        }
    );
    assert_eq!(
        FloatingGlassStyle::CARD,
        FloatingGlassStyle {
            dark_veil_alpha: 0.42,
            light_veil_alpha: 0.45,
            dark_rim: Rim { top: 0.22, bottom: 0.04 },
            light_rim: Rim { top: 0.80, bottom: 0.08 },
            casts_shadow: false,
            veil_takes_theme_tint: false,
            ..toast
        }
    );
    // Pins of the other presets.
    assert_eq!(FloatingGlassStyle::GROUP.dark_veil_alpha, 0.06);
    assert_eq!(FloatingGlassStyle::GROUP.light_veil_alpha, 0.2);
    assert_eq!(FloatingGlassStyle::PROMPT.dark_veil_alpha, 0.74);
    assert_eq!(FloatingGlassStyle::PROMPT.light_veil_alpha, 0.8);
    let prompt = FloatingGlassStyle::named("prompt").unwrap();
    assert!(prompt.veil_takes_theme_tint && prompt.casts_shadow);
    let tag = FloatingGlassStyle::named("agentTag").unwrap();
    assert!(tag.casts_shadow && !tag.veil_takes_theme_tint);
    assert_eq!(
        FloatingGlassStyle::AGENT_TAG.dark_veil_alpha,
        FloatingGlassStyle::TOAST.dark_veil_alpha
    );
    assert_eq!(FloatingGlassStyle::TRANSIENT, FloatingGlassStyle::TOAST);
}

#[test]
fn each_role_has_its_glass() {
    assert_eq!(SurfaceRole::Toast.neutral_style(), Some(FloatingGlassStyle::TOAST));
    assert_eq!(SurfaceRole::Sheet.neutral_style(), Some(FloatingGlassStyle::DIALOG));
    assert_eq!(SurfaceRole::Card.neutral_style(), Some(FloatingGlassStyle::CARD));
    assert_eq!(SurfaceRole::Group.neutral_style(), Some(FloatingGlassStyle::GROUP));
    assert_eq!(SurfaceRole::Prompt.neutral_style(), Some(FloatingGlassStyle::PROMPT));
    for role in [SurfaceRole::Popover, SurfaceRole::Menu, SurfaceRole::Tooltip] {
        assert_eq!(role.neutral_style(), None, "{role:?}");
    }
    let named = |n: &str| FloatingGlassStyle::named(n).unwrap();
    assert!(named("toast").veil_takes_theme_tint);
    assert!(!named("dialog").veil_takes_theme_tint && !named("card").veil_takes_theme_tint);
    assert!(!SurfaceRole::Card.casts_shadow());
    assert!(!SurfaceRole::Group.casts_shadow());
    assert!(SurfaceRole::Toast.casts_shadow() && SurfaceRole::Tooltip.casts_shadow());
    assert_eq!(SurfaceRole::Tooltip.corner_depth(), 2);
    assert_eq!(SurfaceRole::Popover.corner_depth(), 0);
    assert_eq!(SurfaceRole::Toast.corner_depth(), FloatingGlassStyle::TOAST.corner_depth);
}

#[test]
fn every_role_stays_glass_in_both_appearances() {
    for role in SurfaceRole::ALL {
        let style = role.neutral_style().unwrap_or(FloatingGlassStyle::TRANSIENT);
        for is_dark in [true, false] {
            assert!(
                style.look(is_dark).veil.alpha < glass::NEAR_OPAQUE,
                "{role:?} isDark {is_dark}"
            );
        }
    }
    let roles = op("surfaceRoles", json!({}));
    assert_eq!(roles["nearOpaque"], json!(0.9));
    assert_eq!(roles["roles"].as_array().unwrap().len(), 8);
    assert_eq!(roles["roles"][6]["role"], json!("prompt"));
}

#[test]
fn roles_name_their_glass_level() {
    assert_eq!(SurfaceRole::Menu.glass_level(), GlassLevel::Menu);
    assert_eq!(SurfaceRole::Tooltip.glass_level(), GlassLevel::Chip);
    assert_eq!(SurfaceRole::Card.glass_level(), GlassLevel::Chrome);
    for role in [SurfaceRole::Popover, SurfaceRole::Toast, SurfaceRole::Sheet, SurfaceRole::Prompt]
    {
        assert_eq!(role.glass_level(), GlassLevel::Popover);
    }
    assert_eq!(GlassLevel::Chrome.tint_strength(), 1.0);
    assert_eq!(GlassLevel::Popover.tint_strength(), 1.25);
    assert_eq!(GlassLevel::Menu.tint_strength(), 1.25);
    assert_eq!(GlassLevel::Chip.tint_strength(), 1.5);
    assert_eq!(glass::scaled_alpha(0.3, 1.0), 0.3);
    assert!(close(glass::scaled_alpha(0.4, 1.25), 0.5));
    assert_eq!(glass::scaled_alpha(0.8, 1.5), 1.0);
    let level = op("glassLevel", json!({"level": "chip", "alpha": 0.5}));
    assert_eq!(level, json!({"tintStrength": 1.5, "alpha": 0.75}));
    let role = op("surfaceRole", json!({"role": "tooltip"}));
    assert_eq!(role["glassLevel"], json!("chip"));
    assert_eq!(role["cornerDepth"], json!(2));
    assert_eq!(role["neutralStyle"], Value::Null);
}

#[test]
fn concentric_corners_step_in_by_the_padding() {
    assert_eq!(glass::corner_radius(12.0, 4.0, 0), 12.0);
    assert_eq!(glass::corner_radius(12.0, 4.0, 2), 4.0);
    assert_eq!(glass::corner_radius(12.0, 4.0, 5), 0.0);
    assert_eq!(op("cornerRadius", json!({"outer": 10, "padding": 3, "depth": 1})), json!(7.0));
}

// MARK: FloatingGlassStyleTests

#[test]
fn every_preset_reads_as_glass_with_a_lit_top_rim() {
    for name in ["transient", "toast", "card", "group", "dialog", "prompt", "agentTag", "findPill"]
    {
        let style = FloatingGlassStyle::named(name).unwrap();
        for is_dark in [true, false] {
            let look = style.look(is_dark);
            assert!(look.veil.alpha > 0.0 && look.veil.alpha < 1.0, "{name} {is_dark}");
            assert!(look.rim_top.alpha > look.rim_bottom.alpha, "{name} {is_dark}");
            assert!(look.rim_top.alpha > 0.0, "{name} {is_dark}");
        }
    }
    assert!(FloatingGlassStyle::named("nope").is_none());
}

#[test]
fn the_toast_veil_follows_the_appearance() {
    for is_dark in [true, false] {
        let toast = FloatingGlassStyle::TOAST.look(is_dark);
        assert!(if is_dark { toast.veil.white < 0.5 } else { toast.veil.white > 0.5 });
    }
    let dark = op("glassLook", json!({"style": "toast", "isDark": true}));
    assert_eq!(dark["veil"], json!({"white": 0.11, "alpha": 0.42}));
    assert_eq!(dark["rimTop"], json!({"white": 1.0, "alpha": 0.3}));
    let light = op("glassLook", json!({"style": "card", "isDark": false}));
    assert_eq!(light["veil"], json!({"white": 0.99, "alpha": 0.45}));
    assert_eq!(light["rimBottom"], json!({"white": 0.0, "alpha": 0.08}));
}

#[test]
fn the_veil_is_grey_or_the_theme_tint() {
    let tint = ThemeRgb::new(0.2, 0.4, 0.6, 1.0);
    let toast = FloatingGlassStyle::TOAST.veil_rgb(true, tint);
    assert_eq!(toast, tint.with_alpha(0.42));
    let card = FloatingGlassStyle::CARD.veil_rgb(false, tint);
    assert_eq!(card, ThemeRgb::new(0.99, 0.99, 0.99, 0.45));
    let reply = op(
        "veil",
        json!({"style": "dialog", "isDark": true, "glassTint": {"red": 1, "green": 0, "blue": 0}}),
    );
    assert_eq!(reply["red"], json!(0.11));
    assert_eq!(reply["alpha"], json!(0.48));
    let whole = serde_json::to_value(FloatingGlassStyle::GROUP).unwrap();
    assert_eq!(
        op("glassStyle", json!({"style": whole})),
        op("glassStyle", json!({"style": "group"}))
    );
    assert!(matches!(
        call("overlay.glassStyle", &json!({"style": "bogus"})),
        Err(OpError::Invalid(_))
    ));
}

#[test]
fn the_transient_material_pins_the_design_scale() {
    let m = op("transientMaterial", json!({}));
    assert_eq!(
        m,
        json!({
            "darkVeilAlpha": 0.42, "lightVeilAlpha": 0.55, "darkRimTop": 0.3, "darkRimBottom": 0.06,
            "lightRimTop": 0.85, "lightRimBottom": 0.1, "hostVeil": 0.4, "nativeTintStrength": 1.25,
            "webTint": 80.0, "webTintDark": 72.0, "webBlur": 32.0, "webSaturation": 1.6,
            "neutralDark": 0.11, "neutralLight": 0.99
        })
    );
}

// MARK: FindPillTests

#[test]
fn the_find_pill_veil_is_at_least_seventy_percent() {
    let pill = FloatingGlassStyle::find_pill();
    assert!(pill.dark_veil_alpha >= 0.7);
    assert_eq!(pill.dark_veil_alpha, 0.7);
    assert_eq!(pill.light_veil_alpha, FloatingGlassStyle::TRANSIENT.light_veil_alpha);
    assert_eq!(op("glassStyle", json!({"style": "findPill"}))["darkVeilAlpha"], json!(0.7));
}

fn flags(names: &[&str]) -> Vec<String> {
    names.iter().map(|s| s.to_string()).collect()
}

#[test]
fn the_find_pill_forwards_plain_and_selecting_arrows() {
    assert!(find::should_forward_arrow(123, &flags(&[]), false));
    assert!(find::should_forward_arrow(124, &flags(&["shift"]), false));
    assert!(find::should_forward_arrow(125, &flags(&["option", "shift"]), false));
    assert!(find::should_forward_arrow(126, &flags(&["command", "shift"]), false));
    assert!(!find::should_forward_arrow(122, &flags(&[]), false));
    assert!(!find::should_forward_arrow(123, &flags(&["control"]), false));
    assert!(!find::should_forward_arrow(123, &flags(&[]), true));
    // Pins: the pad, function and caps-lock bits never count; Option with Command does not forward.
    assert!(find::should_forward_arrow(
        123,
        &flags(&["numericPad", "function", "capsLock"]),
        false
    ));
    assert!(find::should_forward_arrow(124, &flags(&["option"]), false));
    assert!(find::should_forward_arrow(124, &flags(&["command"]), false));
    assert!(!find::should_forward_arrow(124, &flags(&["option", "command"]), false));
    assert_eq!(op("findForwardsArrow", json!({"keyCode": 126, "flags": ["shift"]})), json!(true));
}

#[test]
fn the_find_pill_steps_only_with_matches() {
    assert!(find::steps_enabled("2 of 3", false, None));
    assert!(!find::steps_enabled("No matches", true, None));
    assert!(!find::steps_enabled("", false, None));
    assert!(find::steps_enabled("", false, Some(true)));
    assert_eq!(op("findStepsEnabled", json!({"text": "2 of 3"})), json!(true));
}

// MARK: OverlayGlassVariantTests

#[test]
fn the_picked_variant_is_apples_glass() {
    assert_eq!(OverlayGlassVariant::PICKED, OverlayGlassVariant::AppKitRegular);
    assert_eq!(OverlayGlassVariant::PICKED.number(), 1);
    assert!(!OverlayGlassVariant::AppKitRegular.tints_glass(false), "no veil over Apple's glass");
    assert!(
        OverlayGlassVariant::AppKitRegular.tints_glass(true),
        "the theme's tint on the toast's glass"
    );
    assert!(!OverlayGlassVariant::AppKitRegular.draws_rim());
    assert!(
        OverlayGlassVariant::VeilTinted.tints_glass(false)
            && OverlayGlassVariant::VeilTinted.draws_rim()
    );
    assert!(
        OverlayGlassVariant::Frost.prefers_frost()
            && !OverlayGlassVariant::VeilTinted.prefers_frost()
    );
    assert_eq!(OverlayGlassVariant::VeilTinted.number(), 3);
    assert_eq!(OverlayGlassVariant::Frost.number(), 11);
    assert_eq!(
        op("glassVariant", json!({})),
        json!({"variant": "appKitRegular", "number": 1, "tintsGlass": false, "drawsRim": false, "prefersFrost": false})
    );
}

// MARK: HoverSurfaceStaysPutTests

#[test]
fn hover_surfaces_default_to_the_solid_hairline() {
    assert_eq!(HoverSurfaceLook::DEFAULT, HoverSurfaceLook::Hairline);
    assert!(HoverSurfaceLook::SOLID.iter().all(|l| l.is_solid()));
    assert!(
        !HoverSurfaceLook::Glass.is_solid(),
        "the glass stays reachable as the setting's other value"
    );
    for look in HoverSurfaceLook::SOLID {
        assert_eq!(look.material(), Some("opaque"));
    }
    assert_eq!(HoverSurfaceLook::Glass.material(), None);
    assert_eq!(HoverSurfaceLook::Hairline.edge_width(), None);
    assert_eq!(HoverSurfaceLook::Shadowed.edge_width(), Some(0.0));
    assert_eq!(HoverSurfaceLook::Framed.edge_width(), Some(1.0));
    let base = Elevation { offset: 1.0, blur: 3.0, alpha: 0.2 };
    assert_eq!(HoverSurfaceLook::Hairline.shadow(base), base);
    assert_eq!(HoverSurfaceLook::Glass.shadow(base), base);
    assert_eq!(HoverSurfaceLook::Shadowed.shadow(base), ELEVATION_2);
    assert_eq!(HoverSurfaceLook::Framed.shadow(base), ELEVATION_2);
    assert_eq!(HoverSurfaceLook::Framed.title(), "3: Solid, one-point rim");
    let reply = op("hoverSurfaceLook", json!({"look": "framed"}));
    assert_eq!(reply["edgeWidth"], json!(1.0));
    assert_eq!(reply["shadow"], json!({"offset": 2.0, "blur": 6.0, "alpha": 0.11}));
    assert_eq!(op("hoverSurfaceLooks", json!({}))["default"], json!("hairline"));
}

// MARK: FloatingPane (pins)

#[test]
fn the_floating_pane_knobs_keep_their_ranges() {
    assert_eq!(FloatingPaneMaterial::ALL.len(), 14);
    assert_eq!(FloatingPaneMaterial::None.system(), None);
    assert_eq!(FloatingPaneCornerMode::ALL.len(), 3);
    assert_eq!(FloatingPaneCornerMode::MainPane.title(), "Main pane's radius");
    assert_eq!(pane::ALL_KEYS.len(), 13);
    assert_eq!(pane::NUMBER_KNOBS.len(), 10);
    let band = pane::NUMBER_KNOBS.iter().find(|k| k.key == "floatingPane.resizeBand").unwrap();
    assert_eq!((band.default, band.min, band.max, band.step), (12.0, 4.0, 24.0, 1.0));
    let materials = op("paneMaterials", json!({}));
    assert_eq!(materials.as_array().unwrap().len(), 14);
    assert!(materials.as_array().unwrap().iter().any(|m| m["material"] == json!("fullScreenUI")));
    assert_eq!(op("paneTunables", json!({}))["keys"][1], json!("floatingPane.material"));
}

#[test]
fn the_floating_pane_look_clamps_its_knobs() {
    let look = FloatingPaneLook::default();
    assert!(!look.is_see_through());
    assert_eq!(look.tint, "glassTint");
    let raw = FloatingPaneLook {
        background_opacity: 1.4,
        tint_strength: -1.0,
        border_width: -2.0,
        shadow_blur: -5.0,
        shadow_offset: -12.0,
        corner_floor: -1.0,
        resize_band: 40.0,
        corner_zone: 2.0,
        ..look
    };
    let clamped = FloatingPaneLook::from_knobs(&raw);
    assert_eq!(clamped.background_opacity, 1.0);
    assert_eq!(clamped.tint_strength, 0.0);
    assert_eq!(clamped.border_width, 0.0);
    assert_eq!(clamped.shadow_blur, 0.0);
    assert_eq!(clamped.shadow_offset, -12.0);
    assert_eq!(clamped.corner_floor, 0.0);
    assert_eq!(clamped.resize_band, 24.0);
    assert_eq!(clamped.corner_zone, 10.0);
    let reply = op("paneLook", json!({"backgroundOpacity": 0.5, "cornerMode": "window"}));
    assert_eq!(reply["isSeeThrough"], json!(true));
    assert_eq!(reply["cornerMode"], json!("window"));
    assert_eq!(reply["shadowOpacity"], json!(0.35));
}

// MARK: NativePopupColumnsTests

fn key_row(id: &str, kind: RowKind, checked: bool) -> KeyRow {
    KeyRow { id: id.into(), kind, disabled: false, checked }
}

/// NativePopupColumnsTests.model()'s columns, for the keys.
fn key_columns() -> Vec<KeyColumn> {
    vec![
        KeyColumn {
            rail: true,
            rows: vec![
                key_row("starred", RowKind::Action, false),
                key_row("claude", RowKind::Action, true),
                key_row("codex", RowKind::Action, false),
            ],
        },
        KeyColumn {
            rail: false,
            rows: vec![
                key_row("opus", RowKind::Action, true),
                key_row("sonnet", RowKind::Action, false),
                key_row("haiku", RowKind::Action, false),
            ],
        },
        KeyColumn {
            rail: false,
            rows: vec![
                key_row("effort-head", RowKind::Section, false),
                key_row("high", RowKind::Action, false),
                key_row("medium", RowKind::Action, true),
                key_row("fast", RowKind::Toggle, false),
            ],
        },
    ]
}

fn laid(ids: &[&str], height: f64) -> Vec<LaidRow> {
    ids.iter().map(|id| LaidRow { id: id.to_string(), height }).collect()
}

/// The same model, for the layout (row heights 28, padding 6, hairline 0.5, space1 2).
fn layout_input(models: Vec<LaidRow>) -> ColumnsInput {
    ColumnsInput {
        width: 350.0,
        inset: 6.0,
        hairline: 0.5,
        row_height: 28.0,
        space1: 2.0,
        has_title: false,
        has_search: true,
        has_accessory: true,
        rows: laid(&["auth"], 28.0),
        columns: vec![
            LaidColumn {
                width: Some(48.0),
                rail: true,
                rows: laid(&["starred", "claude", "codex"], 28.0),
            },
            LaidColumn { width: Some(149.0), rail: false, rows: models },
            LaidColumn {
                width: None,
                rail: false,
                rows: laid(&["effort-head", "high", "medium", "fast"], 28.0),
            },
        ],
        footer: laid(&["update"], 28.0),
        columns_height: Some(220.0),
        band_floor: 0.0,
    }
}

#[test]
fn all_rows_run_rail_accessory_rows_columns_footer() {
    let lists = RowLists {
        rail: None,
        search_accessory: Some("account".into()),
        rows: vec!["auth".into()],
        columns: Some(vec![
            vec!["starred".into(), "claude".into(), "codex".into()],
            vec!["opus".into(), "sonnet".into(), "haiku".into()],
            vec!["effort-head".into(), "high".into(), "medium".into(), "fast".into()],
        ]),
        footer: Some(vec!["update".into()]),
    };
    assert_eq!(
        lists.all_rows(),
        [
            "account",
            "auth",
            "starred",
            "claude",
            "codex",
            "opus",
            "sonnet",
            "haiku",
            "effort-head",
            "high",
            "medium",
            "fast",
            "update"
        ]
    );
    assert!(lists.has_columns());
    assert!(!RowLists { columns: Some(vec![]), ..Default::default() }.has_columns());
    let reply = op("allRows", json!({"rail": ["r"], "rows": ["a"], "footer": ["f"]}));
    assert_eq!(reply, json!({"rows": ["r", "a", "f"], "hasColumns": false}));
}

#[test]
fn columns_sit_side_by_side_under_the_search_row() {
    let layout = popup::layout_columns(&layout_input(laid(&["opus", "sonnet", "haiku"], 28.0)));
    let xs: Vec<f64> = layout.columns.iter().map(|c| c.frame.x).collect();
    let widths: Vec<f64> = layout.columns.iter().map(|c| c.frame.width).collect();
    assert_eq!(xs, [0.0, 48.0, 197.0]);
    assert_eq!(widths, [48.0, 149.0, 153.0], "the last column takes the rest");
    let accessory = layout.accessory.unwrap();
    assert!(accessory.x + accessory.width <= 48.0, "the avatar sits over the rail");
    assert_eq!(accessory, Rect::new(10.0, 4.0, 28.0, 28.0));
    let search = layout.search.unwrap();
    assert!(search.x >= 48.0 && search.y + search.height <= popup::COLUMNS_SEARCH_ROW);
    assert_eq!(search, Rect::new(52.0, 4.0, 288.0, 28.0));
    let auth = &layout.rows[0];
    assert!(auth.frame.width > 300.0, "a spanning row crosses every column");
    assert_eq!(auth.frame, Rect::new(6.0, 36.5, 338.0, 28.0));
    let band = layout.columns[1].frame;
    assert!(band.y >= auth.frame.y + auth.frame.height);
    assert_eq!(band.y, 65.0);
    // The rail's tabs sit centred, a tab and a step apart.
    let tabs: Vec<Rect> = layout.columns[0].cells.iter().map(|c| c.frame).collect();
    assert_eq!(
        tabs,
        [
            Rect::new(10.0, 6.0, 28.0, 28.0),
            Rect::new(10.0, 36.0, 28.0, 28.0),
            Rect::new(10.0, 66.0, 28.0, 28.0)
        ]
    );
    assert_eq!(layout.columns[2].cells[3].frame, Rect::new(6.0, 90.0, 141.0, 28.0));
    // The tallest column is the tune column: 6 + 4 * 28 + 6.
    assert_eq!(layout.band_floor, 124.0);
    let update = &layout.footer[0];
    assert!(update.frame.y >= band.y + band.height, "the footer sits under the columns");
    assert_eq!(update.frame.y, 65.0 + 124.0 + 0.5);
    assert!(layout.height >= update.frame.y + update.frame.height);
    assert_eq!(layout.height, 189.5 + 28.0 + 6.0);
    // Lines: the accessory's edge, under search, under the rows, two column seams, over the footer.
    assert_eq!(layout.lines.len(), 6);
    assert_eq!(layout.lines[0], Rect::new(47.5, 0.0, 0.5, 36.0));
    assert_eq!(layout.lines[3], Rect::new(47.5, 65.0, 0.5, 124.0));
    let reply =
        op("columnsLayout", serde_json::to_value(layout_input(laid(&["opus"], 28.0))).unwrap());
    assert_eq!(reply["columns"][2]["frame"]["width"], json!(153.0));
}

#[test]
fn a_long_column_scrolls_under_the_cap_and_the_band_never_shrinks() {
    let many: Vec<String> = (0..20).map(|i| format!("m{i}")).collect();
    let ids: Vec<&str> = many.iter().map(String::as_str).collect();
    let tall = popup::layout_columns(&layout_input(laid(&ids, 28.0)));
    assert_eq!(tall.columns[1].frame.height, 220.0);
    assert!(
        tall.columns[1].document.height > tall.columns[1].frame.height,
        "the models column scrolls on its own"
    );
    assert_eq!(tall.columns[1].document.height, 6.0 + 20.0 * 28.0 + 6.0);
    let mut fewer = layout_input(laid(&["only"], 28.0));
    fewer.band_floor = tall.band_floor;
    let after = popup::layout_columns(&fewer);
    assert_eq!(after.columns[1].frame.height, 220.0, "a tab with fewer rows keeps the menu's size");
    assert_eq!(after.columns[1].document.height, 220.0);
}

#[test]
fn the_layout_without_an_accessory_or_cap_uses_the_defaults() {
    let mut input = layout_input(laid(&["opus"], 28.0));
    input.has_accessory = false;
    input.has_title = true;
    input.columns_height = None;
    input.rows.clear();
    input.footer.clear();
    let layout = popup::layout_columns(&input);
    assert_eq!(layout.title, Some(Rect::new(13.0, 6.0, 324.0, 24.0)));
    assert_eq!(layout.accessory, None);
    assert_eq!(layout.search, Some(Rect::new(10.0, 34.0, 330.0, 28.0)));
    assert_eq!(layout.columns[0].frame.y, 30.0 + 36.0 + 0.5);
    assert_eq!(layout.band_floor, 124.0);
    assert_eq!(layout.height, 66.5 + 124.0);
    assert_eq!(popup::COLUMNS_DEFAULT_HEIGHT, 220.0);
}

#[test]
fn row_heights_follow_the_kind() {
    assert_eq!(popup::row_height(RowKind::Slider, false, Some(40.0), 28.0), 40.0);
    assert_eq!(popup::row_height(RowKind::Separator, true, None, 28.0), 9.0);
    assert_eq!(popup::row_height(RowKind::TextField, true, None, 28.0), 32.0);
    assert_eq!(popup::row_height(RowKind::Action, true, None, 28.0), 44.0);
    assert_eq!(popup::row_height(RowKind::Action, false, None, 28.0), 28.0);
    assert_eq!(op("rowHeight", json!({"kind": "textField", "standardRowHeight": 28})), json!(32.0));
}

#[test]
fn arrows_move_within_and_between_columns() {
    let columns = key_columns();
    let accessory = Some("account");
    let mut selected = popup::first_list_column_row(&columns, accessory);
    assert_eq!(
        selected.as_deref(),
        Some("opus"),
        "the highlight starts in the models, never on a harness tab"
    );
    let mut highlights = Vec::new();
    let mut press = |key: u16, selected: &mut Option<String>| match popup::column_key(
        &columns,
        accessory,
        selected.as_deref(),
        key,
    ) {
        ColumnKey::Moves { id } => {
            highlights.push(id.clone());
            *selected = Some(id);
        }
        ColumnKey::Stays => {}
        ColumnKey::Unhandled => panic!("an arrow fell through"),
    };
    press(popup::KEY_UP, &mut selected);
    assert_eq!(selected.as_deref(), Some("opus"), "Up stops at the column's top");
    for _ in 0..3 {
        press(popup::KEY_DOWN, &mut selected);
    }
    assert_eq!(selected.as_deref(), Some("haiku"), "Down stays in the column and stops at its end");
    press(popup::KEY_RIGHT, &mut selected);
    assert_eq!(selected.as_deref(), Some("medium"), "Right lands on the checked level");
    press(popup::KEY_DOWN, &mut selected);
    assert_eq!(selected.as_deref(), Some("fast"));
    press(popup::KEY_RIGHT, &mut selected);
    assert_eq!(selected.as_deref(), Some("fast"), "past the last column it stays");
    press(popup::KEY_LEFT, &mut selected);
    press(popup::KEY_LEFT, &mut selected);
    assert_eq!(selected.as_deref(), Some("claude"), "Left reaches the rail's checked tab");
    press(popup::KEY_DOWN, &mut selected);
    assert_eq!(selected.as_deref(), Some("codex"));
    assert_eq!(highlights, ["sonnet", "haiku", "medium", "fast", "opus", "claude", "codex"]);
}

#[test]
fn column_keys_pin_their_edges() {
    let columns = key_columns();
    assert_eq!(
        popup::column_key(&columns, None, Some("opus"), 36),
        ColumnKey::Unhandled,
        "Return is not an arrow"
    );
    assert_eq!(popup::column_key(&[], None, None, popup::KEY_DOWN), ColumnKey::Unhandled);
    // No highlight: Down takes the home column's first row, Up its last.
    assert_eq!(
        popup::column_key(&columns, None, None, popup::KEY_DOWN),
        ColumnKey::Moves { id: "opus".into() }
    );
    assert_eq!(
        popup::column_key(&columns, None, None, popup::KEY_UP),
        ColumnKey::Moves { id: "haiku".into() }
    );
    // The section never takes the highlight; Up from high stops there.
    assert_eq!(popup::column_key(&columns, None, Some("high"), popup::KEY_UP), ColumnKey::Stays);
    // A disabled row is skipped.
    let mut disabled = key_columns();
    disabled[1].rows[1].disabled = true;
    assert_eq!(
        popup::column_key(&disabled, None, Some("opus"), popup::KEY_DOWN),
        ColumnKey::Moves { id: "haiku".into() }
    );
    // A column with nothing reachable is passed over; none left: stays.
    let mut empty = key_columns();
    empty[1].rows.iter_mut().for_each(|r| r.disabled = true);
    assert_eq!(
        popup::column_key(&empty, None, Some("medium"), popup::KEY_LEFT),
        ColumnKey::Moves { id: "claude".into() }
    );
    assert_eq!(
        popup::column_key(&columns, None, Some("starred"), popup::KEY_LEFT),
        ColumnKey::Stays
    );
    // With no checked row, the move lands on the first reachable one.
    let mut unchecked = key_columns();
    unchecked[2].rows.iter_mut().for_each(|r| r.checked = false);
    assert_eq!(
        popup::column_key(&unchecked, None, Some("opus"), popup::KEY_RIGHT),
        ColumnKey::Moves { id: "high".into() }
    );
    // The accessory is never reachable.
    assert_eq!(popup::first_list_column_row(&columns, Some("opus")).as_deref(), Some("sonnet"));
    let reply = op(
        "columnKey",
        json!({"columns": serde_json::to_value(key_columns()).unwrap(), "selected": "haiku", "key": 124}),
    );
    assert_eq!(reply, json!({"outcome": "moves", "id": "medium"}));
    let stays = op(
        "columnKey",
        json!({"columns": serde_json::to_value(key_columns()).unwrap(), "selected": "fast", "key": 124}),
    );
    assert_eq!(stays, json!({"outcome": "stays"}));
}

// MARK: NativePopupPressReleaseTests

#[test]
fn a_press_dragged_onto_a_row_and_released_picks_it() {
    let start = Point { x: 100.0, y: 100.0 };
    let target = Point { x: 150.0, y: 80.0 };
    let moved = popup::press_moved(false, start, target);
    assert!(moved);
    assert!(popup::press_may_pick(moved, 0.4));
    assert_eq!(popup::press_released(moved, 0.4, true), PressOutcome::Picks);
}

#[test]
fn a_quick_release_with_no_move_is_a_click() {
    let start = Point { x: 100.0, y: 100.0 };
    let moved = popup::press_moved(false, start, start);
    assert!(!moved);
    assert!(!popup::press_may_pick(moved, 0.05));
    assert_eq!(popup::press_released(moved, 0.05, false), PressOutcome::None);
}

#[test]
fn a_press_dragged_away_and_released_off_every_row_closes() {
    let start = Point { x: 100.0, y: 100.0 };
    let away = Point { x: -50.0, y: 250.0 };
    let moved = popup::press_moved(false, start, away);
    assert_eq!(popup::press_released(moved, 0.5, false), PressOutcome::Closes);
}

#[test]
fn the_press_thresholds_pin_today() {
    assert_eq!(popup::PRESS_CLICK_TIME, 0.15);
    assert_eq!(popup::PRESS_SLOP, 4.0);
    let start = Point { x: 0.0, y: 0.0 };
    assert!(!popup::press_moved(false, start, Point { x: 3.9, y: 0.0 }));
    assert!(popup::press_moved(false, start, Point { x: 4.0, y: 0.0 }));
    assert!(popup::press_moved(false, start, Point { x: 3.0, y: 3.0 }));
    assert!(popup::press_moved(true, start, start), "a move sticks");
    // A held press with no move picks the row under it; off every row it stays open.
    assert_eq!(popup::press_released(false, 0.15, true), PressOutcome::Picks);
    assert_eq!(popup::press_released(false, 0.5, false), PressOutcome::None);
    // A quick flick off every row stays open; onto a row it picks.
    assert_eq!(popup::press_released(true, 0.1, false), PressOutcome::None);
    assert_eq!(popup::press_released(true, 0.1, true), PressOutcome::Picks);
    let reply = op(
        "pressRelease",
        json!({"start": {"x": 0, "y": 0}, "point": {"x": 10, "y": 0}, "heldFor": 0.5, "rowPicked": false}),
    );
    assert_eq!(reply, json!({"moved": true, "mayPick": true, "outcome": "closes"}));
}

// MARK: MenuTrackingConfinement and popUpAtPointer (pins)

#[test]
fn tracking_is_confined_within_the_original_rect() {
    let bounds = Rect::new(0.0, 0.0, 100.0, 100.0);
    assert_eq!(popup::confinement_rect(bounds, None), bounds);
    assert_eq!(
        popup::confinement_rect(bounds, Some(Rect::new(10.0, 10.0, 0.0, 50.0))),
        bounds,
        "an empty rect is none"
    );
    assert_eq!(
        popup::confinement_rect(bounds, Some(Rect::new(50.0, 50.0, 100.0, 100.0))),
        Rect::new(50.0, 50.0, 50.0, 50.0)
    );
    let apart = Rect::new(200.0, 200.0, 10.0, 10.0);
    assert_eq!(
        popup::confinement_rect(bounds, Some(apart)),
        apart,
        "no overlap keeps the original"
    );
    let touching = Rect::new(100.0, 0.0, 10.0, 10.0);
    assert_eq!(
        popup::confinement_rect(bounds, Some(touching)),
        touching,
        "an edge-only overlap is empty"
    );
    let reply =
        op("confinementRect", json!({"bounds": {"x": 0, "y": 0, "width": 10, "height": 10}}));
    assert_eq!(reply, json!({"x": 0.0, "y": 0.0, "width": 10.0, "height": 10.0}));
}

#[test]
fn the_pointer_menu_confines_only_when_it_overflows() {
    let viewport = Rect::new(0.0, 0.0, 400.0, 300.0);
    let frame = Rect::new(20.0, 30.0, 100.0, 200.0);
    let fits = popup::pointer_menu(frame, 100.0, 200.0, viewport, false);
    assert!(!fits.confines);
    assert_eq!(fits.corner, Point { x: 20.0, y: 230.0 });
    assert!(popup::pointer_menu(frame, 100.0, 301.0, viewport, false).confines);
    assert!(popup::pointer_menu(frame, 401.0, 10.0, viewport, false).confines);
    assert!(!popup::pointer_menu(frame, 400.0, 300.0, viewport, false).confines);
    assert_eq!(
        popup::pointer_menu(frame, 1.0, 1.0, viewport, true).corner,
        Point { x: 120.0, y: 230.0 }
    );
}

// MARK: QuitUnsavedRegistry (pins)

#[test]
fn quit_deadlines_cap_at_thirty_seconds() {
    assert_eq!(quit::MAX_DEADLINE, 30.0);
    assert_eq!(quit::flush_deadline(5.0, None), 5.0);
    assert_eq!(quit::flush_deadline(60.0, None), 30.0);
    assert_eq!(quit::flush_deadline(10.0, Some(quit::NONINTERACTIVE_CAP)), 3.0);
    assert_eq!(quit::flush_deadline(2.0, Some(3.0)), 2.0);
    assert_eq!(quit::flush_deadline(60.0, Some(45.0)), 30.0);
    assert_eq!(op("quitDeadline", json!({"participant": 12, "cap": 3})), json!(3.0));
}

#[test]
fn quit_lists_each_unsaved_participant_once() {
    let p =
        |id: &str, unsaved: bool| quit::Participant { id: id.into(), has_unsaved_changes: unsaved };
    let list = [p("a", true), p("b", false), p("a", true), p("c", true), p("b", true)];
    assert_eq!(quit::unsaved(&list), ["a", "c", "b"]);
    let reply =
        op("quitUnsaved", json!({"participants": [{"id": "x", "hasUnsavedChanges": true}]}));
    assert_eq!(reply, json!(["x"]));
}

#[test]
fn unknown_ops_and_bad_requests_say_so() {
    assert_eq!(call("overlay.nope", &json!({})), Err(OpError::Unknown));
    assert!(matches!(call("overlay.columnKey", &json!({"columns": 3})), Err(OpError::Invalid(_))));
}
