//! Parity tests for `tokens::plus_button` (`PlusButtonLook.swift`): the Swift cases of
//! TabSplitButtonLookTests, TabBarPlusShapeTests and PlusButtonUnityTests, plus pins worked by
//! hand from the Swift formulas.

use cmux_design_core::ops::call;
use cmux_design_core::tokens::color::Rgb;
use cmux_design_core::tokens::plus_button::*;
use serde_json::{Value, json};

/// The default density's metrics: space 4/8/12, tab corner 6, a 28 pt control, a 10.5 pt +.
fn metrics() -> PlusMetrics {
    PlusMetrics {
        space1: 4.0,
        space2: 8.0,
        space3: 12.0,
        tab_corner_radius: 6.0,
        tab_bar_control_side: 28.0,
        add_glyph_extent: 10.5,
        corner_radius_is_set: false,
    }
}

fn metrics_json() -> Value {
    json!({"space1": 4.0, "space2": 8.0, "space3": 12.0, "tabCornerRadius": 6.0,
           "tabBarControlSide": 28.0, "addGlyphExtent": 10.5})
}

fn input(bounds: Rect) -> GeometryInput {
    GeometryInput {
        bounds,
        segment: Segment::Alone,
        hover_style: HoverStyle::Plate,
        shows_chevron: false,
        rounds_as_tab_bar_control: false,
        scale: 2.0,
        metrics: metrics(),
    }
}

fn state(hovering: bool, pressed: bool, menu_open: bool, sibling_hovered: bool) -> State {
    State { hovering, pressed, menu_open, sibling_hovered }
}

fn op(name: &str, request: Value) -> Value {
    call(&format!("tokens.{name}"), &request).unwrap()
}

// MARK: Swift tests

/// TabSplitButtonLookTests.noFillAtRest...: the leading segment at rest, hovered, held, and
/// softer while its sibling is hovered.
#[test]
fn leading_segment_fills() {
    let s = Segment::Leading;
    let p = HoverStyle::Plate;
    assert_eq!(fill(State::default(), p, s, true), Fill::None);
    assert_eq!(fill(state(true, false, false, false), p, s, true), Fill::Hover);
    assert_eq!(fill(state(true, true, false, false), p, s, true), Fill::Pressed);
    assert_eq!(fill(state(false, false, false, true), p, s, true), Fill::HalfHover);
    let hover = Rgb::new(1.0, 1.0, 1.0, 0.12);
    let pressed = Rgb::new(1.0, 1.0, 1.0, 0.2);
    let soft = fill_color(Fill::HalfHover, hover, pressed).unwrap();
    assert!((soft.a - 0.06).abs() < 1e-9);
    assert!(soft.a < hover.a);
    assert_eq!(fill_color(Fill::None, hover, pressed), None);
    assert_eq!(fill_color(Fill::Hover, hover, pressed), Some(hover));
    assert_eq!(fill_color(Fill::Pressed, hover, pressed), Some(pressed));
}

/// TabBarPlusShapeTests.everyTabBarPlusLookRoundsAsATab.
#[test]
fn every_tab_bar_plus_rounds_as_a_tab() {
    let m = metrics();
    let side = m.tab_bar_control_side;
    for segment in [Segment::Alone, Segment::Leading] {
        let bounds = Rect::new(0.0, 0.0, side, side);
        let g =
            geometry(&GeometryInput { segment, rounds_as_tab_bar_control: true, ..input(bounds) });
        assert_eq!(g.corner_radius, m.tab_corner_radius.min(side / 2.0));
        assert_eq!((g.fill.width, g.fill.height), (bounds.width, bounds.height));
    }
    // A plate outside the tab bar keeps the proportional corner: 20 pt -> 5.5 (< 10, not a circle).
    let g = geometry(&input(Rect::new(0.0, 0.0, 20.0, 20.0)));
    assert_eq!(g.corner_radius, button_corner_radius_proportional(&m, 20.0));
    assert_eq!(g.corner_radius, 5.5);
    assert!(g.corner_radius < 10.0);
}

/// PlusButtonUnityTests.aHeldPlus...: inks, held fills, the open menu and the glyph style.
#[test]
fn held_plus_inks_and_fills() {
    assert_eq!(glyph_ink(true, true), Ink::LitGlyph);
    assert_eq!(glyph_ink(false, false), Ink::TextSecondary);
    assert_eq!(glyph_ink(true, false), Ink::TextPrimary);
    assert_eq!(ink(state(true, true, false, false)), ink(state(true, false, false, false)));
    assert_eq!(
        fill(state(true, true, false, false), HoverStyle::Plate, Segment::Alone, true),
        Fill::Pressed
    );
    assert_eq!(ink(state(false, false, true, false)), Ink::LitGlyph);
    assert_eq!(
        fill(state(false, false, true, false), HoverStyle::Plate, Segment::Alone, true),
        Fill::Pressed
    );
    assert_eq!(
        fill(state(true, true, false, false), HoverStyle::Glyph, Segment::Alone, true),
        Fill::None
    );
    // A lone + in a 24 pt tab-bar host rounds as the tab pill.
    let g = geometry(&GeometryInput {
        rounds_as_tab_bar_control: true,
        ..input(Rect::new(0.0, 0.0, 24.0, 24.0))
    });
    assert_eq!(g.corner_radius, metrics().tab_corner_radius.min(12.0));
}

// MARK: Pins

#[test]
fn corner_radii() {
    let m = metrics();
    assert_eq!(radius_fitting(10.0, 4.0, 6.0), 2.0);
    assert_eq!(radius_fitting(10.0, 10.0, -1.0), 0.0);
    assert_eq!(tab_bar_control_corner_radius(&m, None), 6.0);
    assert_eq!(tab_bar_control_corner_radius(&m, Some((40.0, 8.0))), 4.0);
    assert_eq!(split_corner_radius(&m), 6.0);
    // 28 * 8 / 28 = 8 on the half-point grid; 24 -> 6.857.. -> 7; 20 -> 5.714.. -> 5.5.
    assert_eq!(button_corner_radius_proportional(&m, 28.0), 8.0);
    assert_eq!(button_corner_radius_proportional(&m, 24.0), 7.0);
    assert_eq!(button_corner_radius_proportional(&m, 2.0), 0.5);
    assert_eq!(button_corner_radius_proportional(&m, 1.0), 0.5);
    let set = PlusMetrics { corner_radius_is_set: true, ..m };
    assert_eq!(button_corner_radius_proportional(&set, 28.0), 6.0);
    assert_eq!(button_corner_radius_proportional(&set, 8.0), 4.0);
    assert_eq!(ALL_CORNERS, 15);
    assert_eq!(LEADING_CORNERS, 5);
}

#[test]
fn geometry_alone_split_chevron_circle() {
    let alone = geometry(&input(Rect::new(0.0, 0.0, 28.0, 28.0)));
    assert_eq!(alone.fill, Rect::new(0.0, 0.0, 28.0, 28.0));
    assert_eq!(alone.corner_radius, 8.0);
    assert_eq!(alone.corners, ALL_CORNERS);
    assert_eq!(alone.glyph_center, Point::new(14.0, 14.0));

    // A wide host centers the square; the fill is the square.
    let wide = geometry(&input(Rect::new(0.0, 0.0, 40.0, 28.0)));
    assert_eq!(wide.fill, Rect::new(6.0, 0.0, 28.0, 28.0));

    let split = geometry(&GeometryInput {
        segment: Segment::Leading,
        ..input(Rect::new(0.0, 0.0, 36.0, 28.0))
    });
    assert_eq!(split.fill, Rect::new(0.0, 0.0, 36.0, 28.0));
    assert_eq!(split.corner_radius, 8.0);
    assert_eq!(split.corners, LEADING_CORNERS);
    assert_eq!(split.glyph_center, Point::new(20.0, 14.0));

    let chev =
        geometry(&GeometryInput { shows_chevron: true, ..input(Rect::new(0.0, 0.0, 48.0, 28.0)) });
    assert_eq!(chev.fill, Rect::new(4.0, 0.0, 40.0, 28.0));
    assert_eq!(chev.corner_radius, 8.0);
    assert_eq!(chev.corners, ALL_CORNERS);
    assert_eq!(chev.glyph_center, Point::new(16.0, 14.0));

    let circle = geometry(&GeometryInput {
        hover_style: HoverStyle::Circle,
        ..input(Rect::new(0.0, 0.0, 28.0, 28.0))
    });
    assert_eq!(circle.corner_radius, 14.0);
    // A circle with a chevron is a plate again.
    let circle_chev = geometry(&GeometryInput {
        hover_style: HoverStyle::Circle,
        shows_chevron: true,
        ..input(Rect::new(0.0, 0.0, 48.0, 28.0))
    });
    assert_eq!(circle_chev.corner_radius, 8.0);
}

#[test]
fn glyph_center_snaps_to_device_pixels() {
    let odd = Rect::new(0.0, 0.0, 27.0, 27.0);
    assert_eq!(geometry(&input(odd)).glyph_center, Point::new(13.5, 13.5));
    let one = GeometryInput { scale: 1.0, ..input(odd) };
    assert_eq!(geometry(&one).glyph_center, Point::new(14.0, 14.0));
    let low = GeometryInput { scale: 0.5, ..input(odd) };
    assert_eq!(geometry(&low).glyph_center, Point::new(14.0, 14.0));
    let three = GeometryInput { scale: 3.0, ..input(Rect::new(0.0, 0.0, 27.1, 27.1)) };
    // 13.55 * 3 = 40.65 -> 41 / 3.
    assert_eq!(geometry(&three).glyph_center.x, 41.0 / 3.0);
}

#[test]
fn null_inset_when_chevron_overflows() {
    let g =
        geometry(&GeometryInput { shows_chevron: true, ..input(Rect::new(0.0, 0.0, 6.0, 6.0)) });
    assert_eq!(g.fill, Rect::NULL);
    assert_eq!(Rect::new(0.0, 0.0, 10.0, 4.0).inset_by(1.0, 2.0), Rect::new(1.0, 2.0, 8.0, 0.0));
}

#[test]
fn calm_mode_and_glyph_style() {
    let p = HoverStyle::Plate;
    assert_eq!(fill(state(true, false, false, false), p, Segment::Alone, false), Fill::None);
    assert_eq!(fill(state(true, true, false, false), p, Segment::Alone, false), Fill::Pressed);
    assert_eq!(fill(state(false, false, true, false), p, Segment::Alone, false), Fill::Pressed);
    assert_eq!(fill(state(false, false, false, true), p, Segment::Leading, false), Fill::None);
    assert_eq!(fill(state(false, false, false, true), p, Segment::Alone, true), Fill::None);
    assert_eq!(
        fill(state(true, false, false, false), HoverStyle::Circle, Segment::Alone, true),
        Fill::Hover
    );
    assert!(!HoverStyle::Glyph.paints_fill());
    assert!(HoverStyle::Plate.paints_fill() && HoverStyle::Circle.paints_fill());
    assert_eq!(DEFAULT_HOVER_STYLE, HoverStyle::Plate);
    let s = state(false, true, false, false);
    assert!(!s.lit() && s.down());
    let m = state(false, false, true, false);
    assert!(m.lit() && m.down());
}

#[test]
fn glyph_and_chevron_paths() {
    assert_eq!(chevron_half_width(10.5), 3.9375);
    assert_eq!(chevron_rise(10.5), 3.9375);
    let plus = add_glyph(Point::new(16.0, 14.0), 2.0, 10.5);
    assert_eq!(plus[0], [Point::new(10.75, 14.0), Point::new(21.25, 14.0)]);
    assert_eq!(plus[1], [Point::new(16.0, 8.75), Point::new(16.0, 19.25)]);
    // 14.3 * 2 = 28.6 -> 29 / 2 = 14.5.
    let snapped = add_glyph(Point::new(14.3, 14.2), 2.0, 10.0);
    assert_eq!(snapped[0][0], Point::new(9.5, 14.0));
    let ch = chevron(Point::new(16.0, 14.0), 10.5, 12.0);
    assert_eq!(
        ch,
        [Point::new(29.3125, 12.03125), Point::new(33.25, 15.96875), Point::new(37.1875, 12.03125)]
    );
    let m = metrics();
    let g =
        geometry(&GeometryInput { shows_chevron: true, ..input(Rect::new(0.0, 0.0, 48.0, 28.0)) });
    let all = path(&g, 2.0, true, &m);
    assert_eq!(all.len(), 3);
    assert_eq!(all[2], ch.to_vec());
    assert_eq!(path(&g, 2.0, false, &m).len(), 2);
    assert_eq!(draw_scale(-3.0), 3.0);
    assert_eq!(draw_scale(0.0), 2.0);
    assert_eq!(draw_scale(1.5), 1.5);
}

#[test]
fn ink_colors() {
    let (s, p, l) = (Rgb::hex(0x888888), Rgb::hex(0xEEEEEE), Rgb::hex(0x3B82F6));
    assert_eq!(ink_color(Ink::TextSecondary, s, p, l), s);
    assert_eq!(ink_color(Ink::TextPrimary, s, p, l), p);
    assert_eq!(ink_color(Ink::LitGlyph, s, p, l), l);
}

// MARK: Ops

#[test]
fn ops() {
    let g = op(
        "plus_button_geometry",
        json!({"bounds": {"x": 0.0, "y": 0.0, "width": 48.0, "height": 28.0}, "showsChevron": true,
               "scale": 2.0, "metrics": metrics_json()}),
    );
    assert_eq!(g["fill"], json!({"x": 4.0, "y": 0.0, "width": 40.0, "height": 28.0}));
    assert_eq!(g["cornerRadius"], json!(8.0));
    assert_eq!(g["corners"], json!(15));
    assert_eq!(g["glyphCenter"], json!({"x": 16.0, "y": 14.0}));
    assert_eq!(g["path"][2][1], json!({"x": 33.25, "y": 15.96875}));

    let t = op(
        "plus_button_geometry",
        json!({"bounds": {"x": 0.0, "y": 0.0, "width": 28.0, "height": 28.0}, "segment": "leading",
               "roundsAsTabBarControl": true, "scale": 2.0, "metrics": metrics_json()}),
    );
    assert_eq!(t["cornerRadius"], json!(6.0));
    assert_eq!(t["corners"], json!(5));

    assert_eq!(
        op("plus_button_split_corner_radius", json!({"metrics": metrics_json()})),
        json!(6.0)
    );

    let f = op(
        "plus_button_fill",
        json!({"state": {"siblingHovered": true}, "segment": "leading",
               "hoverFill": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 0.5},
               "pressedFill": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 0.8}}),
    );
    assert_eq!(f, json!({"fill": "halfHover", "color": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 0.25}}));
    let calm =
        op("plus_button_fill", json!({"state": {"hovering": true}, "showsHoverFills": false}));
    assert_eq!(calm, json!({"fill": "none", "color": null}));
    let glyph = op("plus_button_fill", json!({"state": {"pressed": true}, "hoverStyle": "glyph"}));
    assert_eq!(glyph["fill"], json!("none"));

    let colors = json!({"textSecondary": {"r": 0.5, "g": 0.5, "b": 0.5},
                        "textPrimary": {"r": 0.9, "g": 0.9, "b": 0.9},
                        "litGlyph": {"r": 0.0, "g": 0.0, "b": 1.0}});
    let gi = op("plus_button_glyph_ink", json!({"hovering": true, "colors": colors}));
    assert_eq!(
        gi,
        json!({"ink": "textPrimary", "color": {"r": 0.9, "g": 0.9, "b": 0.9, "a": 1.0}})
    );
    assert_eq!(op("plus_button_glyph_ink", json!({"pressed": true}))["ink"], json!("litGlyph"));
    assert_eq!(
        op("plus_button_ink", json!({"state": {"menuOpen": true}}))["ink"],
        json!("litGlyph")
    );
    assert_eq!(
        op("plus_button_ink", json!({"state": {"pressed": true}}))["ink"],
        json!("textPrimary")
    );
    assert_eq!(op("plus_button_ink", json!({}))["ink"], json!("textSecondary"));

    let p = op(
        "plus_button_path",
        json!({"center": {"x": 16.0, "y": 14.0}, "scale": 2.0, "addGlyphExtent": 10.5}),
    );
    assert_eq!(p[0][0], json!({"x": 10.75, "y": 14.0}));
    assert_eq!(p[1][1], json!({"x": 16.0, "y": 19.25}));

    let c = op(
        "plus_button_chevron",
        json!({"glyphCenter": {"x": 16.0, "y": 14.0}, "addGlyphExtent": 10.5, "space3": 12.0}),
    );
    assert_eq!(c["halfWidth"], json!(3.9375));
    assert_eq!(c["rise"], json!(3.9375));
    assert_eq!(c["points"][0], json!({"x": 29.3125, "y": 12.03125}));

    assert_eq!(op("plus_button_draw_scale", json!({"transformA": 0.0})), json!(2.0));
    assert_eq!(
        op("plus_button_state", json!({"state": {"menuOpen": true}})),
        json!({"lit": true, "down": true})
    );
    assert!(call("tokens.plus_button_nope", &json!({})).is_err());
}
