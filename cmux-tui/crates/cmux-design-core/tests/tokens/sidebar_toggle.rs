//! Parity tests for `tokens::sidebar_toggle` (`SidebarToggleGlyph.swift`): names, the name parse,
//! the image size and every glyph's marks at 13 pt, worked by hand from the Swift formulas.

use cmux_design_core::ops::call;
use cmux_design_core::tokens::sidebar_toggle::*;
use serde_json::{Value, json};

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-9
}

fn assert_pt(p: Point, x: f64, y: f64) {
    assert!(close(p.x, x) && close(p.y, y), "{p:?} != ({x}, {y})");
}

fn assert_rect(r: Rect, x: f64, y: f64, w: f64, h: f64) {
    assert!(
        close(r.x, x) && close(r.y, y) && close(r.width, w) && close(r.height, h),
        "{r:?} != ({x}, {y}, {w}, {h})"
    );
}

fn op(name: &str, request: Value) -> Value {
    call(&format!("tokens.{name}"), &request).unwrap()
}

/// The 13 pt image's canvas: 18 x 14.
fn canvas() -> Rect {
    Rect::new(0.0, 0.0, 18.0, 14.0)
}

fn drawn(glyph: Glyph, hidden: bool, progress: f64) -> Drawing {
    draw(glyph, hidden, progress, canvas(), 13.0)
}

fn rounded(m: &Mark) -> (Rect, f64, Paint) {
    match m {
        Mark::RoundedRect { rect, radius, paint } => (*rect, *radius, *paint),
        other => panic!("not a rounded rect: {other:?}"),
    }
}

fn lines(m: &Mark) -> (Vec<Vec<Point>>, f64) {
    match m {
        Mark::Lines { subpaths, alpha } => (subpaths.clone(), *alpha),
        other => panic!("not lines: {other:?}"),
    }
}

fn assert_outline(m: &Mark) {
    let (r, radius, paint) = rounded(m);
    assert_rect(r, 0.9425, 0.9425, 16.115, 12.115);
    assert!(close(radius, 2.6653));
    assert_eq!(paint, Paint::Stroke);
}

fn assert_divider(m: &Mark) {
    let (sub, alpha) = lines(m);
    assert_eq!(alpha, 1.0);
    assert_eq!(sub.len(), 1);
    assert_pt(sub[0][0], 5.9425, 0.9425);
    assert_pt(sub[0][1], 5.9425, 13.0575);
}

#[test]
fn names() {
    assert_eq!(PREFIX, "cmux.sidebarToggle.");
    assert_eq!(SLIDE_STEPS, 48);
    let raws: Vec<&str> = Glyph::ALL.iter().map(|g| g.raw_value()).collect();
    assert_eq!(
        raws,
        ["panel", "railFilled", "railOnly", "chevronPanel", "twoColumn", "listRail", "thickEdge"]
    );
    for g in Glyph::ALL {
        assert_eq!(Glyph::from_raw(g.raw_value()), Some(g));
    }
    assert_eq!(Glyph::from_raw("Panel"), None);
    assert_eq!(Glyph::RailFilled.name(true), "cmux.sidebarToggle.railFilled.hidden");
    assert_eq!(Glyph::Panel.name(false), "cmux.sidebarToggle.panel.shown");
}

#[test]
fn slide_names() {
    assert_eq!(slide_name(0.0), "cmux.sidebarToggle.panel.shown");
    assert_eq!(slide_name(-1.0), "cmux.sidebarToggle.panel.shown");
    assert_eq!(slide_name(1.0), "cmux.sidebarToggle.panel.hidden");
    assert_eq!(slide_name(7.0), "cmux.sidebarToggle.panel.hidden");
    assert_eq!(slide_name(0.5), "cmux.sidebarToggle.panel.24");
    // 0.01 * 48 = 0.48 -> 0; 0.0105 * 48 = 0.504 -> 1; 0.99 * 48 = 47.52 -> 48.
    assert_eq!(slide_name(0.01), "cmux.sidebarToggle.panel.shown");
    assert_eq!(slide_name(0.0105), "cmux.sidebarToggle.panel.1");
    assert_eq!(slide_name(0.99), "cmux.sidebarToggle.panel.hidden");
    // 1/96 * 48 = 0.5 rounds away from zero.
    assert_eq!(slide_name(1.0 / 96.0), "cmux.sidebarToggle.panel.1");
}

#[test]
fn parse_names() {
    let p = parse_name("cmux.sidebarToggle.listRail.hidden").unwrap();
    assert_eq!((p.glyph, p.hidden, p.progress), (Glyph::ListRail, true, 1.0));
    let p = parse_name("cmux.sidebarToggle.panel.shown").unwrap();
    assert_eq!((p.glyph, p.hidden, p.progress), (Glyph::Panel, false, 0.0));
    let p = parse_name("cmux.sidebarToggle.panel.24").unwrap();
    assert_eq!((p.hidden, p.progress), (false, 0.5));
    // Any other second part is the shown form; empty parts are dropped as Swift's split does.
    assert_eq!(parse_name("cmux.sidebarToggle.panel.whatever").unwrap().progress, 0.0);
    assert_eq!(parse_name("cmux.sidebarToggle..panel..hidden").unwrap().glyph, Glyph::Panel);
    assert_eq!(parse_name("cmux.sidebarToggle.panel.-48").unwrap().progress, -1.0);
    assert_eq!(parse_name("sidebar.left"), None);
    assert_eq!(parse_name("cmux.sidebarToggle.panel"), None);
    assert_eq!(parse_name("cmux.sidebarToggle.panel.shown.x"), None);
    assert_eq!(parse_name("cmux.sidebarToggle.nope.shown"), None);
}

#[test]
fn image_sizes() {
    assert_eq!(image_size(13.0), (18.0, 14.0));
    assert_eq!(image_size(8.0), (11.0, 9.0));
    assert_eq!(image_size(0.0), (0.0, 0.0));
}

#[test]
fn shared_frame() {
    let d = drawn(Glyph::Panel, false, 0.0);
    assert!(close(d.line_width, 1.105));
    assert_rect(d.outer, 0.9425, 0.9425, 16.115, 12.115);
    assert!(close(d.radius, 2.6653));
    assert_eq!(d.rail_width, 5.0);
    assert!(close(d.divider_x, 5.9425));
    // Small sizes keep a 1 pt line.
    assert_eq!(draw(Glyph::Panel, false, 0.0, Rect::new(0.0, 0.0, 11.0, 9.0), 8.0).line_width, 1.0);
}

#[test]
fn panel_slides() {
    let shown = drawn(Glyph::Panel, false, 0.0);
    assert_eq!(shown.marks.len(), 2);
    assert_outline(&shown.marks[0]);
    assert_divider(&shown.marks[1]);
    let half = drawn(Glyph::Panel, false, 0.5);
    let (sub, _) = lines(&half.marks[1]);
    assert_pt(sub[0][0], 4.82375, 2.578025);
    assert_pt(sub[0][1], 4.82375, 11.421975);
    let hidden = drawn(Glyph::Panel, true, 1.0);
    let (sub, _) = lines(&hidden.marks[1]);
    assert_pt(sub[0][0], 3.705, 4.21355);
    assert_pt(sub[0][1], 3.705, 9.78645);
}

#[test]
fn rail_filled() {
    let shown = drawn(Glyph::RailFilled, false, 0.0);
    assert_outline(&shown.marks[0]);
    let (r, radius, paint) = rounded(&shown.marks[1]);
    assert_rect(r, 2.6, 2.6, 2.79, 8.8);
    assert!(close(radius, 1.465915));
    assert_eq!(paint, Paint::Fill);
    let hidden = drawn(Glyph::RailFilled, true, 1.0);
    assert_outline(&hidden.marks[0]);
    assert_divider(&hidden.marks[1]);
}

#[test]
fn rail_only() {
    for hidden in [false, true] {
        let d = drawn(Glyph::RailOnly, hidden, 0.0);
        assert_eq!(d.marks.len(), 2);
        let (r, radius, paint) = rounded(&d.marks[0]);
        assert_rect(r, 3.24, 0.9425, 5.0, 12.115);
        assert!(close(radius, 2.1));
        assert_eq!(paint, if hidden { Paint::Stroke } else { Paint::Fill });
        let (sub, alpha) = lines(&d.marks[1]);
        assert_eq!(alpha, 1.0);
        assert_pt(sub[0][0], 10.671, 4.577);
        assert_pt(sub[0][1], 15.9525, 4.577);
        assert_pt(sub[1][0], 10.671, 9.423);
        assert_pt(sub[1][1], 13.7425, 9.423);
    }
}

#[test]
fn chevron_panel() {
    let shown = drawn(Glyph::ChevronPanel, false, 0.0);
    assert_outline(&shown.marks[0]);
    assert_divider(&shown.marks[1]);
    let (sub, _) = lines(&shown.marks[2]);
    assert_pt(sub[0][0], 12.7115, 4.577);
    assert_pt(sub[0][1], 10.2885, 7.0);
    assert_pt(sub[0][2], 12.7115, 9.423);
    let hidden = drawn(Glyph::ChevronPanel, true, 1.0);
    let (sub, _) = lines(&hidden.marks[2]);
    assert_pt(sub[0][0], 10.2885, 4.577);
    assert_pt(sub[0][1], 12.7115, 7.0);
}

#[test]
fn two_column() {
    for hidden in [false, true] {
        let d = drawn(Glyph::TwoColumn, hidden, 0.0);
        let (left, small, paint) = rounded(&d.marks[0]);
        assert_rect(left, 0.9425, 0.9425, 4.0055, 12.115);
        assert!(close(small, 2.13224));
        assert_eq!(paint, if hidden { Paint::Stroke } else { Paint::Fill });
        let (right, _, paint) = rounded(&d.marks[1]);
        assert_rect(right, 6.937, 0.9425, 10.1205, 12.115);
        assert_eq!(paint, Paint::Stroke);
    }
}

#[test]
fn list_rail() {
    for (hidden, want_alpha) in [(false, 1.0), (true, 0.4)] {
        let d = drawn(Glyph::ListRail, hidden, 0.0);
        assert_outline(&d.marks[0]);
        assert_divider(&d.marks[1]);
        let (rows, alpha) = lines(&d.marks[2]);
        assert_eq!(alpha, want_alpha);
        for (row, y) in rows.iter().zip([4.577, 7.0, 9.423]) {
            assert_pt(row[0], 3.3735, y);
            assert_pt(row[1], 3.5115, y);
        }
    }
}

#[test]
fn thick_edge() {
    let hidden = drawn(Glyph::ThickEdge, true, 1.0);
    assert_outline(&hidden.marks[0]);
    let (sub, _) = lines(&hidden.marks[1]);
    assert_pt(sub[0][0], 4.1655, 0.9425);
    assert_pt(sub[0][1], 4.1655, 13.0575);
    let shown = drawn(Glyph::ThickEdge, false, 0.0);
    match &shown.marks[1] {
        Mark::ClippedFill { rect, clip, clip_radius } => {
            assert_rect(*rect, 0.9425, 0.9425, 3.223, 12.115);
            assert_eq!(*clip, shown.outer);
            assert!(close(*clip_radius, 2.6653));
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn image_draws_in_its_own_rect() {
    let (parsed, size, d) = image("cmux.sidebarToggle.panel.24", 13.0).unwrap();
    assert_eq!(parsed.progress, 0.5);
    assert_eq!(size, (18.0, 14.0));
    assert_eq!(d, drawn(Glyph::Panel, false, 0.5));
    assert!(image("square.and.arrow.up", 13.0).is_none());
}

#[test]
fn ops() {
    assert_eq!(
        op("sidebar_toggle_name", json!({"glyph": "twoColumn", "sidebarHidden": false})),
        json!("cmux.sidebarToggle.twoColumn.shown")
    );
    assert_eq!(
        op("sidebar_toggle_slide_name", json!({"progress": 0.5})),
        json!("cmux.sidebarToggle.panel.24")
    );
    assert_eq!(
        op("sidebar_toggle_parse", json!({"name": "cmux.sidebarToggle.thickEdge.hidden"})),
        json!({"glyph": "thickEdge", "hidden": true, "progress": 1.0})
    );
    assert_eq!(op("sidebar_toggle_parse", json!({"name": "gear"})), Value::Null);
    assert_eq!(
        op("sidebar_toggle_image_size", json!({"pointSize": 13.0})),
        json!({"width": 18.0, "height": 14.0})
    );
    let d = op(
        "sidebar_toggle_draw",
        json!({"glyph": "railFilled", "canvas": {"x": 0.0, "y": 0.0, "width": 18.0, "height": 14.0}, "pointSize": 13.0}),
    );
    assert_eq!(d["railWidth"], json!(5.0));
    assert_eq!(d["marks"][0]["kind"], json!("roundedRect"));
    assert_eq!(d["marks"][0]["paint"], json!("stroke"));
    assert_eq!(d["marks"][1]["paint"], json!("fill"));
    let thick = op(
        "sidebar_toggle_draw",
        json!({"glyph": "thickEdge", "canvas": {"x": 0.0, "y": 0.0, "width": 18.0, "height": 14.0}, "pointSize": 13.0}),
    );
    assert_eq!(thick["marks"][1]["kind"], json!("clippedFill"));
    assert!(close(thick["marks"][1]["clipRadius"].as_f64().unwrap(), 2.6653));
    let img = op(
        "sidebar_toggle_image",
        json!({"name": "cmux.sidebarToggle.listRail.hidden", "pointSize": 13.0}),
    );
    assert_eq!(img["size"], json!({"width": 18.0, "height": 14.0}));
    assert_eq!(img["drawing"]["marks"][2]["alpha"], json!(0.4));
    assert_eq!(op("sidebar_toggle_image", json!({"name": "gear", "pointSize": 13.0})), Value::Null);
    assert_eq!(op("sidebar_toggle_glyphs", json!({})).as_array().unwrap().len(), 7);
    assert!(call("tokens.sidebar_toggle_nope", &json!({})).is_err());
}
