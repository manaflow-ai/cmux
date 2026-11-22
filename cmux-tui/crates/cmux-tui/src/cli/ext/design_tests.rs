use serde_json::{Value, json};

use super::{Surface, check, contrast, scenes_in};

/// A scene of `nodes` (`(type, props)`) under one VStack root.
fn scene(nodes: &[(&str, Value)]) -> Value {
    let mut ops =
        vec![json!({"op": "create", "id": "root", "type": "VStack", "props": {"spacing": 4}})];
    let mut children = Vec::new();
    for (i, (kind, props)) in nodes.iter().enumerate() {
        let id = format!("n{i}");
        ops.push(json!({"op": "create", "id": id, "type": kind, "props": props}));
        children.push(id);
    }
    ops.push(json!({"op": "children", "id": "root", "children": children}));
    ops.push(json!({"op": "root", "id": "root"}));
    Value::Array(ops)
}

fn checks(ops: &Value, surface: Surface) -> Vec<&'static str> {
    check(&[ops], surface).iter().map(|f| f.check).collect()
}

#[test]
fn a_view_on_the_scales_has_no_design_warnings() {
    let ops = scene(&[
        ("Text", json!({"text": "72°", "font": 34, "weight": "semibold", "lineLimit": 1})),
        (
            "Text",
            json!({"text": "Sunny", "font": 13, "weight": "semibold", "color": "accent", "lineLimit": 1}),
        ),
        ("Text", json!({"text": "H 75 L 60", "font": 12, "color": "secondary", "lineLimit": 1})),
    ]);
    assert_eq!(checks(&ops, Surface::Widget), Vec::<&str>::new());
}

#[test]
fn an_off_scale_font_size_names_the_nearest_roles() {
    let ops = scene(&[("Text", json!({"text": "9:41", "font": 40, "lineLimit": 1}))]);
    let findings = check(&[&ops], Surface::Widget);
    assert_eq!(findings[0].check, "type-size");
    assert!(findings[0].fix.contains("BigNumber(...)"), "{}", findings[0].fix);
}

#[test]
fn a_title_style_that_drifts_between_renderers_is_named() {
    let ops = scene(&[("Text", json!({"text": "Monday", "font": "largeTitle", "lineLimit": 1}))]);
    let findings = check(&[&ops], Surface::Other);
    assert_eq!(findings[0].check, "type-style");
    assert!(findings[0].message.contains("26 pt"), "{}", findings[0].message);
}

#[test]
fn more_than_four_text_styles_warn_once_in_a_widget() {
    let ops = scene(&[
        ("Text", json!({"text": "a", "font": 34, "weight": "semibold"})),
        ("Text", json!({"text": "b", "font": 20, "weight": "semibold"})),
        ("Text", json!({"text": "c", "font": 15, "weight": "semibold"})),
        ("Text", json!({"text": "d", "font": 13})),
        ("Text", json!({"text": "e", "font": 11})),
    ]);
    assert_eq!(checks(&ops, Surface::Widget), vec!["line-limit", "type-roles"]);
    // A pane (or a specimen page that shows every role) may use more.
    assert_eq!(checks(&ops, Surface::Other), Vec::<&str>::new());
}

#[test]
fn off_scale_spacing_and_padding_name_the_nearest_step() {
    let ops = scene(&[("HStack", json!({"spacing": 5, "padding": {"top": 10, "leading": 16}}))]);
    let findings = check(&[&ops], Surface::Other);
    let found: Vec<_> = findings.iter().map(|f| (f.check, f.fix.as_str())).collect();
    assert_eq!(found.len(), 2, "{found:?}");
    assert!(found[0].1.starts_with("use 4") || found[0].1.starts_with("use 6"), "{found:?}");
    assert!(found[1].1.starts_with("use 8") || found[1].1.starts_with("use 12"), "{found:?}");
}

#[test]
fn raw_and_unknown_colors_warn_and_repeats_merge() {
    let ops = scene(&[
        ("Text", json!({"text": "a", "color": "#336699", "lineLimit": 1})),
        ("Text", json!({"text": "b", "color": "#336699", "lineLimit": 1})),
        ("Text", json!({"text": "c", "color": "blue", "lineLimit": 1})),
    ]);
    let findings = check(&[&ops], Surface::Widget);
    let raw = findings.iter().find(|f| f.message.contains("raw color")).expect("raw color");
    assert_eq!(raw.count, 2);
    assert!(findings.iter().any(|f| f.message.contains("draws nothing")));
}

#[test]
fn more_than_two_accents_warn() {
    let ops = scene(&[
        ("Text", json!({"text": "a", "color": "accent", "lineLimit": 1})),
        ("Text", json!({"text": "b", "color": "success", "lineLimit": 1})),
        ("Icon", json!({"symbol": "x", "color": "warning"})),
    ]);
    assert_eq!(checks(&ops, Surface::Widget), vec!["accents"]);
}

#[test]
fn hex_text_reads_against_its_background_or_both_cmux_surfaces() {
    assert!((contrast([0.0; 3], [1.0; 3]) - 21.0).abs() < 0.01);
    // A light grey on the theme's surface fails on light; on its own dark background it passes.
    let on_theme = scene(&[("Text", json!({"text": "a", "color": "#dddddd", "lineLimit": 1}))]);
    let contrast_checks: Vec<_> = check(&[&on_theme], Surface::Widget)
        .into_iter()
        .filter(|f| f.check == "contrast")
        .collect();
    assert_eq!(contrast_checks.len(), 1);
    assert!(contrast_checks[0].message.contains("light surface"));
    let on_dark = json!([
        {"op": "create", "id": "bg", "type": "VStack", "props": {"background": "#101010"}},
        {"op": "create", "id": "t", "type": "Text", "props": {"text": "a", "color": "#dddddd", "lineLimit": 1}},
        {"op": "children", "id": "bg", "children": ["t"]},
        {"op": "root", "id": "bg"}
    ]);
    assert!(!checks(&on_dark, Surface::Widget).contains(&"contrast"));
}

#[test]
fn a_widget_text_with_no_line_limit_warns_but_a_pane_does_not() {
    let ops = scene(&[("Text", json!({"text": "A long reminder title"}))]);
    assert_eq!(checks(&ops, Surface::Widget), vec!["line-limit"]);
    assert_eq!(checks(&ops, Surface::Other), Vec::<&str>::new());
}

#[test]
fn recorded_files_hold_one_scene_or_scenes_by_name() {
    let one = scene(&[]);
    assert_eq!(scenes_in("a.json", &one).len(), 1);
    let fixture = json!({"clock.small": one, "clock.medium": one});
    assert_eq!(scenes_in("f.json", &fixture).len(), 2);
    let preview = json!({"small-rain": {"size": "small", "ops": one}});
    assert_eq!(scenes_in("p.json", &preview)[0].0, "p.json:small-rain");
    assert!(scenes_in("x.json", &json!(3)).is_empty());
}

#[test]
fn a_translucent_tint_is_blended_over_the_surface_not_read_as_solid() {
    // Calendar's event rows: an 18% tint of the event color behind text in the same color.
    let ops = json!([
        {"op": "create", "id": "row", "type": "HStack", "props": {"background": "#1badf82e"}},
        {"op": "create", "id": "t", "type": "Text", "props": {"text": "Room 4", "color": "#1badf8", "lineLimit": 1}},
        {"op": "children", "id": "row", "children": ["t"]},
        {"op": "root", "id": "row"}
    ]);
    let findings = check(&[&ops], Surface::Widget);
    let contrast: Vec<_> = findings.iter().filter(|f| f.check == "contrast").collect();
    assert!(contrast.iter().all(|f| !f.message.starts_with("text contrast 1.0")), "{contrast:?}");
    assert!(
        contrast.iter().any(|f| f.message.contains("tinted background over cmux's light surface")),
        "{contrast:?}"
    );
}

#[test]
fn hex_text_on_a_theme_background_is_not_measured_against_cmuxs_surfaces() {
    // A "NEW" pill: white text on the accent. The accent's value is the theme's, so no ratio.
    let ops = json!([
        {"op": "create", "id": "pill", "type": "HStack", "props": {"background": "accent"}},
        {"op": "create", "id": "t", "type": "Text", "props": {"text": "NEW", "color": "#ffffff", "lineLimit": 1}},
        {"op": "children", "id": "pill", "children": ["t"]},
        {"op": "root", "id": "pill"}
    ]);
    assert!(!checks(&ops, Surface::Widget).contains(&"contrast"));
}

#[test]
fn a_translucent_text_color_is_measured_as_drawn() {
    // Black at 20% on white draws a light grey: below 4.5:1, though opaque black is 21:1.
    let ops = scene(&[("Text", json!({"text": "a", "color": "#00000033", "lineLimit": 1}))]);
    let contrast: Vec<_> =
        check(&[&ops], Surface::Widget).into_iter().filter(|f| f.check == "contrast").collect();
    assert!(contrast.iter().any(|f| f.message.contains("light surface")), "{contrast:?}");
}

// Slice 3: the checks a widget's size and second tick add.

use super::System;
use super::{Tile, check_tile, merge_sizes};

fn at(ops: &Value, size: &str) -> Vec<super::Finding> {
    check_tile(&[ops], Surface::Widget, &System::cmux(), Tile::of(size).as_ref())
}

fn named<'a>(findings: &'a [super::Finding], check: &str) -> Vec<&'a super::Finding> {
    findings.iter().filter(|f| f.check == check).collect()
}

#[test]
fn tiles_are_the_new_tab_grid_sizes() {
    let size = |name: &str| Tile::of(name).map(|t| (t.width, t.height));
    assert_eq!(size("small"), Some((148.0, 148.0)));
    assert_eq!(size("medium"), Some((312.0, 148.0)));
    assert_eq!(size("large"), Some((312.0, 312.0)));
    assert_eq!(size("huge"), None);
}

#[test]
fn a_long_title_cut_by_its_line_limit_overflows_a_small_tile_and_not_a_medium_one() {
    let ops = scene(&[(
        "Text",
        json!({"text": "Quarterly planning review with the design team", "font": 15, "weight": "semibold", "lineLimit": 1}),
    )]);
    let small = at(&ops, "small");
    let overflow = named(&small, "overflow");
    assert_eq!(overflow.len(), 1, "{small:?}");
    assert!(overflow[0].message.contains("small tile"), "{}", overflow[0].message);
    assert!(overflow[0].fix.contains("ctx.size"), "{}", overflow[0].fix);
    assert_eq!(overflow[0].sizes, vec!["small".to_string()]);
    assert!(named(&at(&ops, "medium"), "overflow").is_empty());
}

#[test]
fn rows_taller_than_the_tile_overflow_at_the_sizes_they_do_not_fit() {
    let rows: Vec<(&str, Value)> = (0..8)
        .map(|i| ("Text", json!({"text": format!("Item {i}"), "font": 13, "lineLimit": 1})))
        .collect();
    let ops = scene(&rows);
    let small = at(&ops, "small");
    assert!(named(&small, "overflow").iter().any(|f| f.message.contains("tall")), "{small:?}");
    assert!(named(&at(&ops, "large"), "overflow").is_empty());
}

#[test]
fn the_roots_own_padding_is_its_inset() {
    // Edge to edge with no padding: the 16 pt inset is assumed; a root padding of 4 gives room.
    let text =
        json!({"text": "Standup with the design team at ten thirty", "font": 13, "lineLimit": 1});
    let tight = json!([
        {"op": "create", "id": "root", "type": "VStack", "props": {"padding": 4}},
        {"op": "create", "id": "t", "type": "Text", "props": text},
        {"op": "children", "id": "root", "children": ["t"]},
        {"op": "root", "id": "root"}
    ]);
    assert!(named(&at(&tight, "small"), "overflow").is_empty(), "{:?}", at(&tight, "small"));
    let ops = scene(&[("Text", text)]);
    assert_eq!(named(&at(&ops, "small"), "overflow").len(), 1);
}

#[test]
fn findings_seen_at_several_sizes_merge_into_one_naming_them() {
    let ops = scene(&[("Text", json!({"text": "x", "font": 40, "lineLimit": 1}))]);
    let merged = merge_sizes(vec![at(&ops, "small"), at(&ops, "medium"), at(&ops, "large")]);
    let size = named(&merged, "type-size");
    assert_eq!(size.len(), 1, "{merged:?}");
    assert_eq!(size[0].sizes, ["small", "medium", "large"].map(String::from).to_vec());
    assert!(size[0].text().starts_with("type-size [small, medium, large]: "), "{}", size[0].text());
    assert_eq!(size[0].to_json()["sizes"], json!(["small", "medium", "large"]));
}

#[test]
fn a_hex_icon_that_vanishes_in_one_mode_has_no_dark_mode_pair() {
    let ops = scene(&[
        ("Icon", json!({"name": "star.fill", "color": "#f5f5f5"})),
        ("Circle", json!({"fill": "#1a1a1a"})),
        ("Icon", json!({"name": "bolt", "color": "#ff3b30"})),
    ]);
    let findings = check(&[&ops], Surface::Widget);
    let pairs = named(&findings, "dark-mode-pair");
    assert_eq!(pairs.len(), 2, "{findings:?}");
    assert!(pairs[0].message.contains("#f5f5f5") && pairs[0].message.contains("light surface"));
    assert!(pairs[1].message.contains("#1a1a1a") && pairs[1].message.contains("dark surface"));
    assert!(pairs[0].fix.contains("role"), "{}", pairs[0].fix);
}

#[test]
fn a_hex_ink_on_its_own_opaque_background_and_roles_are_not_judged_by_mode() {
    let ops = json!([
        {"op": "create", "id": "root", "type": "VStack", "props": {"background": "#000000"}},
        {"op": "create", "id": "i", "type": "Icon", "props": {"name": "star", "color": "#1a1a1a"}},
        {"op": "create", "id": "j", "type": "Icon", "props": {"name": "star", "color": "secondary"}},
        {"op": "children", "id": "root", "children": ["i", "j"]},
        {"op": "root", "id": "root"}
    ]);
    assert!(named(&check(&[&ops], Surface::Widget), "dark-mode-pair").is_empty());
}

#[test]
fn a_widget_rounding_its_own_tile_or_a_card_is_told_the_host_draws_it() {
    let ops = json!([
        {"op": "create", "id": "root", "type": "VStack", "props": {"cornerRadius": 22, "background": "selected"}},
        {"op": "create", "id": "card", "type": "VStack", "props": {"cornerRadius": 12}},
        {"op": "create", "id": "chip", "type": "Text", "props": {"text": "9:00", "cornerRadius": 4, "lineLimit": 1}},
        {"op": "create", "id": "glow", "type": "Rectangle", "props": {"shadow": {"radius": 8}}},
        {"op": "children", "id": "root", "children": ["card", "glow"]},
        {"op": "children", "id": "card", "children": ["chip"]},
        {"op": "root", "id": "root"}
    ]);
    let findings = check(&[&ops], Surface::Widget);
    let radius = named(&findings, "corner-radius");
    let messages: Vec<&str> = radius.iter().map(|f| f.message.as_str()).collect();
    assert_eq!(radius.len(), 3, "{messages:?}");
    assert!(messages[0].contains("rounds the tile"), "{messages:?}");
    assert!(messages[1].contains("rounds a card"), "{messages:?}");
    assert!(messages[2].contains("shadow"), "{messages:?}");
    assert!(radius[0].fix.contains("host draws the tile's corner"), "{}", radius[0].fix);
}

#[test]
fn a_tick_that_changes_a_texts_length_moves_what_follows_it() {
    use super::super::design_layout::layout_shift;
    let first: Vec<Value> = serde_json::from_value(json!([
        {"op": "create", "id": "row", "type": "HStack", "props": {}},
        {"op": "create", "id": "n", "type": "Text", "props": {"text": "9", "lineLimit": 1}},
        {"op": "create", "id": "u", "type": "Text", "props": {"text": "steps", "lineLimit": 1}},
        {"op": "create", "id": "row2", "type": "HStack", "props": {}},
        {"op": "create", "id": "m", "type": "Text", "props": {"text": "9", "lineLimit": 1}},
        {"op": "create", "id": "s", "type": "Spacer", "props": {}},
        {"op": "create", "id": "v", "type": "Text", "props": {"text": "min", "lineLimit": 1}},
        {"op": "children", "id": "row", "children": ["n", "u"]},
        {"op": "children", "id": "row2", "children": ["m", "s", "v"]},
        {"op": "root", "id": "row"}
    ]))
    .unwrap();
    let tick: Vec<Value> = serde_json::from_value(json!([
        {"op": "update", "id": "n", "props": {"text": "10"}},
        {"op": "update", "id": "m", "props": {"text": "10"}},
        {"op": "update", "id": "u", "props": {"text": "steps"}}
    ]))
    .unwrap();
    let mut findings = super::Findings::default();
    layout_shift(&first, &tick, &mut findings);
    let found = findings.done();
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].check, "layout-shift");
    assert!(found[0].message.contains("\"9\" becomes \"10\""), "{}", found[0].message);
    assert!(found[0].fix.contains(".frame({ width: N })"), "{}", found[0].fix);

    // A tick that rebuilds part of the tree is a new layout, not a shift.
    let mut rebuilt = tick.clone();
    rebuilt.push(json!({"op": "remove", "id": "u"}));
    let mut findings = super::Findings::default();
    layout_shift(&first, &rebuilt, &mut findings);
    assert!(findings.done().is_empty());
}

/// The fixed widgets slice 1 recorded (`design-check-scenes.json`, `after`) and the shipped
/// examples (`widget-scenes.json`) at each size: what the size checks say about them. The
/// overflows are the estimator's, pinned so a change to it shows here.
#[test]
fn the_recorded_widgets_at_their_sizes() {
    let report = |file: &str| -> Vec<String> {
        let tag = if file.contains("\"before\"") { "design-check" } else { "widget" };
        let value: Value = serde_json::from_str(file).unwrap();
        let mut lines = Vec::new();
        for (name, scene) in value.as_object().unwrap() {
            let ops = scene.get("after").unwrap_or(scene);
            let ops = ops.get("ops").unwrap_or(ops);
            let size = name.rsplit('.').next().unwrap();
            for f in at(ops, size) {
                if ["overflow", "dark-mode-pair", "corner-radius"].contains(&f.check) {
                    lines.push(format!("{tag} {name}: {}: {}", f.check, f.message));
                }
            }
        }
        lines
    };
    let fixed = report(include_str!(
        "../../../../../../webviews/src/apps/scene/fixtures/design-check-scenes.json"
    ));
    // Estimated, not seen in a tile: slice 1's fixed clock lists six two-line cities under a
    // 34 pt time, and its fixed to-do keeps four rows, a header and a field at medium.
    assert_eq!(
        fixed,
        vec![
            "design-check clock.large: overflow: the content is about 317 pt tall and a large tile has 280 pt inside its inset: the bottom is cut off".to_string(),
            "design-check todo.medium: overflow: the content is about 173 pt tall and a medium tile has 116 pt inside its inset: the bottom is cut off".to_string(),
        ]
    );
    let shipped = report(include_str!(
        "../../../../../../webviews/src/apps/scene/fixtures/widget-scenes.json"
    ));
    // The shipped to-do keeps four rows, a header, "1 more" and its field at medium too.
    assert_eq!(
        shipped,
        vec!["widget todo.medium: overflow: the content is about 155 pt tall and a medium tile has 116 pt inside its inset: the bottom is cut off".to_string()]
    );
}
