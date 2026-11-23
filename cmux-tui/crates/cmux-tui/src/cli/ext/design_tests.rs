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
fn an_apple_title_style_off_the_roles_is_a_rename_hint() {
    let ops = scene(&[("Text", json!({"text": "Monday", "font": "largeTitle", "lineLimit": 1}))]);
    let findings = check(&[&ops], Surface::Other);
    assert_eq!(findings.len(), 1, "{findings:?}");
    assert_eq!(findings[0].check, "type-style");
    // One table draws it in both renderers now (RFD 0009 slice 2): no per-renderer sizes to report.
    assert!(findings[0].message.contains("draws 34 pt regular"), "{}", findings[0].message);
    assert_eq!(findings[0].fix, "rename it: font \"numeral\" or BigNumber(...)");
}

#[test]
fn role_names_and_apple_names_at_a_role_are_clean() {
    let ops = scene(&[
        ("Text", json!({"text": "72", "font": "numeral", "lineLimit": 1})),
        ("Text", json!({"text": "Monday", "font": "title", "lineLimit": 1})),
        ("Text", json!({"text": "Lisbon", "font": "headline", "lineLimit": 1})),
        ("Text", json!({"text": "Sunny", "font": "caption2", "lineLimit": 1})),
    ]);
    assert!(check(&[&ops], Surface::Widget).is_empty());
}

#[test]
fn a_font_name_and_its_size_count_as_one_text_style() {
    let ops = scene(&[
        ("Text", json!({"text": "a", "font": "numeral", "lineLimit": 1})),
        ("Text", json!({"text": "b", "font": 34, "weight": "semibold", "lineLimit": 1})),
        ("Text", json!({"text": "c", "font": "headline", "lineLimit": 1})),
        ("Text", json!({"text": "d", "font": "label", "lineLimit": 1})),
        ("Text", json!({"text": "e", "font": "caption", "lineLimit": 1})),
        ("Text", json!({"text": "f", "font": "footnote", "lineLimit": 1})),
        ("Text", json!({"text": "g", "font": "caption2", "lineLimit": 1})),
    ]);
    // numeral, label, caption, footnote: four styles, within the limit.
    assert!(check(&[&ops], Surface::Widget).is_empty());
}

#[test]
fn a_font_name_no_renderer_knows_is_named() {
    let ops = scene(&[("Text", json!({"text": "Hi", "font": "display", "lineLimit": 1}))]);
    let findings = check(&[&ops], Surface::Other);
    assert_eq!(findings[0].check, "type-style");
    assert!(findings[0].message.contains("draws as body"), "{}", findings[0].message);
    assert!(findings[0].fix.contains("numeral"), "{}", findings[0].fix);
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
    assert!(contrast_checks[0].message.contains("light background"));
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
        contrast
            .iter()
            .any(|f| f.message.contains("tinted background over cmux's light background")),
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
    assert!(contrast.iter().any(|f| f.message.contains("light background")), "{contrast:?}");
}

#[test]
fn stat_and_chart_with_their_variants_and_states_have_no_design_warnings() {
    let ops = scene(&[
        (
            "Stat",
            json!({"value": "1,284", "label": "Requests", "delta": "+12%", "trend": "up", "variant": "prominent"}),
        ),
        ("Stat", json!({"value": "—", "state": "loading"})),
        ("Chart", json!({"values": [1, 4, 2, 8], "kind": "bar", "variant": "subtle"})),
        (
            "Chart",
            json!({"values": [], "kind": "line", "state": "empty", "stateMessage": "No data"}),
        ),
        ("Badge", json!({"text": "3", "tone": "accent", "variant": "standard"})),
        ("Row", json!({"title": "Build", "state": "error", "stateMessage": "Offline"})),
        ("Toggle", json!({"value": true, "state": null})),
    ]);
    assert_eq!(checks(&ops, Surface::Widget), Vec::<&str>::new());
}

#[test]
fn an_unknown_variant_or_state_names_the_ones_the_component_draws() {
    let ops = scene(&[
        ("Badge", json!({"text": "3", "variant": "loud"})),
        ("Stat", json!({"value": "1", "state": "busy"})),
        ("Toggle", json!({"value": true, "variant": "prominent"})),
    ]);
    let findings = check(&[&ops], Surface::Widget);
    let found: Vec<_> = findings.iter().filter(|f| f.check == "component").collect();
    assert_eq!(found.len(), 3, "{findings:?}");
    assert!(found[0].fix.contains("\"standard\", \"prominent\", \"subtle\""), "{}", found[0].fix);
    assert!(found[1].fix.contains("\"loading\", \"error\", \"empty\""), "{}", found[1].fix);
    assert_eq!(found[2].fix, "use \"standard\"");
}

#[test]
fn a_variant_or_state_on_a_layout_node_draws_nothing_and_warns() {
    let ops = scene(&[("VStack", json!({"variant": "prominent", "state": "loading"}))]);
    let findings = check(&[&ops], Surface::Widget);
    let found: Vec<_> = findings.iter().filter(|f| f.check == "component").collect();
    assert_eq!(found.len(), 2, "{findings:?}");
    assert!(found[1].fix.contains("EmptyState"), "{}", found[1].fix);
}

#[test]
fn a_chart_with_no_values_an_unknown_kind_or_too_many_values_warns() {
    let many: Vec<u32> = (0..70).collect();
    let ops = scene(&[
        ("Chart", json!({"values": [], "kind": "line"})),
        ("Chart", json!({"values": [1, 2], "kind": "pie"})),
        ("Chart", json!({"values": many, "kind": "bar"})),
    ]);
    let findings = check(&[&ops], Surface::Widget);
    let messages: Vec<_> =
        findings.iter().filter(|f| f.check == "component").map(|f| f.message.as_str()).collect();
    assert_eq!(messages.len(), 3, "{findings:?}");
    assert!(messages[0].contains("no values"), "{}", messages[0]);
    assert!(messages[1].contains("\"pie\""), "{}", messages[1]);
    assert!(messages[2].contains("more than 64"), "{}", messages[2]);
}

/// The gallery's recorded components (webviews' Components.gallery.tsx, recorded by
/// cmux-app-host/js/test/components.test.ts) pass every check as a widget.
#[test]
fn the_components_gallery_passes_the_design_check() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../webviews/src/apps/scene/fixtures/components-scenes.json"
    );
    let value: Value =
        serde_json::from_str(&std::fs::read_to_string(path).expect("the fixture reads")).unwrap();
    let scenes = scenes_in("components-scenes.json", &value);
    assert_eq!(scenes.len(), 4);
    for (name, ops) in &scenes {
        let findings = check(&[ops], Surface::Widget);
        assert!(findings.is_empty(), "{name}: {findings:?}");
    }
}

/// The `DesignCheck` gallery entry shows each recorded scene's warnings as this check gives them, so
/// the record must follow the check. On a mismatch the message carries the current warnings: put
/// them under each scene's `warnings` in the fixture.
#[test]
fn the_design_check_gallery_fixture_records_this_check() {
    let text =
        include_str!("../../../../../../webviews/src/apps/scene/fixtures/design-check-scenes.json");
    let fixture: Value = serde_json::from_str(text).expect("the fixture reads");
    let mut current = serde_json::Map::new();
    let mut stale = Vec::new();
    for (name, recorded) in fixture.as_object().expect("an object of scenes") {
        let mut sides = serde_json::Map::new();
        for side in ["before", "after"] {
            let got: Vec<Value> = check(&[&recorded[side]], Surface::Widget)
                .iter()
                .map(|f| json!({"check": f.check, "count": f.count, "message": f.message}))
                .collect();
            if recorded["warnings"][side] != Value::Array(got.clone()) {
                stale.push(format!("{name}.{side}"));
            }
            sides.insert(side.into(), Value::Array(got));
        }
        current.insert(name.clone(), Value::Object(sides));
    }
    assert!(
        stale.is_empty(),
        "stale warnings in design-check-scenes.json: {stale:?}\nCURRENT-WARNINGS {}",
        Value::Object(current)
    );
}
