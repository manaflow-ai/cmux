//! Parity tests for `tokens::corner_flush`: Swift's `CornerFlushTests` (the pure cases),
//! `ConcentricCornersTests` and `ConcentricContainerTests`, plus pins worked by hand from the Swift
//! formulas in `CornerFlush.swift`, `ConcentricContainer.swift` and `ConcentricCorners.swift`.

use cmux_design_core::ops::call;
use cmux_design_core::tokens::corner_flush::*;
use serde_json::json;

fn near(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-9
}

fn op(name: &str, request: serde_json::Value) -> serde_json::Value {
    call(&format!("tokens.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e:?}"))
}

fn card() -> Rect {
    Rect::new(100.0, 0.0, 400.0, 300.0)
}

// MARK: - CornerFlush values and metrics

#[test]
fn values_raw_titles_and_order() {
    let raws: Vec<_> = CornerFlush::ALL.iter().map(|v| v.raw_value()).collect();
    assert_eq!(raws, ["off", "flush", "flush-tight", "flush-goo"]);
    for v in CornerFlush::ALL {
        assert_eq!(CornerFlush::from_raw(v.raw_value()), Some(v));
    }
    assert_eq!(CornerFlush::from_raw("tight"), None);
    assert_eq!(CornerFlush::Off.tunable_title(), "Off: a gray pill on the frame");
    assert_eq!(
        CornerFlush::Goo.tunable_title(),
        "Flush, goo: the selected tab flows into the card"
    );
    assert_eq!(TUNABLE_KEY, "chrome.cornerFlush");
    let values = op("corner_flush_values", json!({}));
    assert_eq!(values[2]["value"], "flush-tight");
    assert_eq!(values[1]["title"], "Flush: the first tab rises from the card's edge");
}

/// Swift `flushWithoutGooIsTheDefault`.
#[test]
fn flush_without_goo_is_the_default() {
    assert_eq!(DEFAULT, CornerFlush::Flush);
    assert_eq!(CornerFlush::Flush.feet_radius(1.0), 0.0);
    assert!(CornerFlush::Goo.is_on());
    assert!(CornerFlush::Flush.is_on());
    assert!(CornerFlush::Tight.is_on());
    assert!(!CornerFlush::Off.is_on());
}

/// Swift `onlyGooHasFeet`.
#[test]
fn only_goo_has_feet() {
    assert_eq!(CornerFlush::Goo.feet_radius(1.0), 8.0);
    assert_eq!(CornerFlush::Goo.feet_radius(1.25), 10.0);
    for v in [CornerFlush::Off, CornerFlush::Flush, CornerFlush::Tight] {
        assert_eq!(v.feet_radius(1.25), 0.0);
    }
}

/// Swift `tightHasNoGapOnTheSidebarSide`.
#[test]
fn tight_has_no_gap_on_the_sidebar_side() {
    assert_eq!(CornerFlush::Tight.sidebar_gap(1.0), Some(0.0));
    assert_eq!(CornerFlush::Flush.sidebar_gap(1.0), Some(4.0));
    assert_eq!(CornerFlush::Goo.sidebar_gap(1.5), Some(6.0));
    assert_eq!(CornerFlush::Off.sidebar_gap(1.0), None);
    let m = op("corner_flush_metrics", json!({"value": "flush-tight"}));
    assert_eq!(m["sidebarGap"], 0.0);
    assert_eq!(op("corner_flush_metrics", json!({"value": "off"}))["sidebarGap"], json!(null));
}

/// Swift's fullscreen card test: `max(0, standardWindowCornerRadius - gap)`.
#[test]
fn fullscreen_card_radius_is_the_windowed_one() {
    assert_eq!(CornerFlush::Flush.card_radius(16.0, 1.0), 12.0);
    assert_eq!(CornerFlush::Flush.card_radius(10.0, 1.0), 6.0);
    assert_eq!(CornerFlush::Flush.card_radius(16.0, 1.25), 11.0);
    assert_eq!(CornerFlush::Flush.card_radius(2.0, 1.0), 0.0);
    let m = op(
        "corner_flush_metrics",
        json!({"value": "flush-goo", "scale": 1.25, "standardWindowCornerRadius": 16}),
    );
    assert_eq!(
        m,
        json!({"isOn": true, "feetRadius": 10.0, "gap": 5.0, "cardRadius": 11.0, "sidebarGap": 5.0})
    );
}

#[test]
fn shade_reads_the_theme_tunable() {
    assert_eq!(shade(true, MAIN_PANE_SHADE_DARK, MAIN_PANE_SHADE_LIGHT), 0.28);
    assert_eq!(shade(false, MAIN_PANE_SHADE_DARK, MAIN_PANE_SHADE_LIGHT), 0.045);
    assert_eq!(op("corner_flush_shade", json!({"isDark": true})), json!(0.28));
    assert_eq!(op("corner_flush_shade", json!({"isDark": false, "shadeLight": 0.1})), json!(0.1));
}

// MARK: - Resolution

#[test]
fn current_resolves_in_swift_order() {
    let base = CurrentInputs { default_fits: true, ..Default::default() };
    assert_eq!(current(&base), CornerFlush::Flush);
    assert!(!is_chosen(&base));
    assert_eq!(current(&CurrentInputs { default_fits: false, ..base }), CornerFlush::Off);
    let compact = CurrentInputs { compact: true, gooey_tabs: true, ..base };
    assert_eq!(current(&compact), CornerFlush::Off);
    assert!(!is_chosen(&compact), "chosen but compact keeps the pill");
    let goo = CurrentInputs { gooey_tabs: true, tunable_override: Some(CornerFlush::Off), ..base };
    assert_eq!(current(&goo), CornerFlush::Goo);
    let tunable = CurrentInputs {
        tunable_override: Some(CornerFlush::Tight),
        setting: Some(CornerFlush::Goo),
        default_fits: false,
        ..base
    };
    assert_eq!(current(&tunable), CornerFlush::Tight);
    assert!(is_chosen(&tunable));
    let setting = CurrentInputs { setting: Some(CornerFlush::Off), ..base };
    assert_eq!(current(&setting), CornerFlush::Off);
    assert!(!is_chosen(&setting));
    let r = op("corner_flush_current", json!({"setting": "flush-goo"}));
    assert_eq!(r, json!({"current": "flush-goo", "chosen": "flush-goo", "isChosen": true}));
}

#[test]
fn default_fits_only_the_stock_chrome() {
    let stock = DefaultFitsInputs {
        chrome_style: "flat".into(),
        tab_bar_position: "top".into(),
        tab_bar_order: "aboveToolbar".into(),
        ..Default::default()
    };
    assert!(default_fits(&stock));
    assert!(default_fits(&DefaultFitsInputs { chrome_style: "default".into(), ..stock.clone() }));
    for style in ["card", "card-outlined", "flat-sidebar-line", "bare", "panes", "two-tone"] {
        assert!(
            !default_fits(&DefaultFitsInputs { chrome_style: style.into(), ..stock.clone() }),
            "{style}"
        );
    }
    assert!(!default_fits(&DefaultFitsInputs {
        tab_bar_position: "bottom".into(),
        ..stock.clone()
    }));
    assert!(!default_fits(&DefaultFitsInputs {
        tab_bar_order: "belowToolbar".into(),
        ..stock.clone()
    }));
    assert!(!default_fits(&DefaultFitsInputs { vertical_tabs: true, ..stock.clone() }));
    let set: [fn(&mut DefaultFitsInputs); 10] = [
        |i| i.padding_set = true,
        |i| i.corner_radius_set = true,
        |i| i.corner_padding_set = true,
        |i| i.border_set = true,
        |i| i.border_color_set = true,
        |i| i.border_width_set = true,
        |i| i.separation_set = true,
        |i| i.main_pane_curved_set = true,
        |i| i.main_pane_gutter_set = true,
        |i| i.main_pane_corner_radius_set = true,
    ];
    for f in set {
        let mut i = stock.clone();
        f(&mut i);
        assert!(!default_fits(&i));
    }
    let ok = json!({"chromeStyle": "flat", "tabBarPosition": "top", "tabBarOrder": "aboveToolbar"});
    assert_eq!(op("corner_flush_default_fits", ok), json!(true));
    let border = json!({"chromeStyle": "flat", "tabBarPosition": "top", "tabBarOrder": "aboveToolbar", "borderSet": true});
    assert_eq!(op("corner_flush_default_fits", border), json!(false));
}

#[test]
fn sidebar_row_flows_only_under_goo_on_a_block_shape() {
    assert!(sidebar_row_flows(CornerFlush::Goo, true));
    assert!(!sidebar_row_flows(CornerFlush::Goo, false));
    assert!(!sidebar_row_flows(CornerFlush::Flush, true));
    let r = op(
        "corner_flush_sidebar_row_flows",
        json!({"current": "flush-goo", "tabShapeRunsIntoCard": true}),
    );
    assert_eq!(r, json!(true));
}

// MARK: - Chrome decisions

#[test]
fn top_inset_rounds_to_the_backing_pixel() {
    // pillCenter = 4 + 3 + 24/2 = 19.
    assert_eq!(top_inset(true, false, Some(19.0), 2.0, 4.0, 3.0, 24.0), Some(0.0));
    // (20.3 - 18) * 2 = 4.6 -> 5 -> 2.5.
    assert!(near(top_inset(true, false, Some(20.3), 2.0, 4.0, 3.0, 22.0).unwrap(), 2.5));
    // (10 - 18.25) * 2 = -16.5 -> -17 (half away from zero) -> -8.5.
    assert_eq!(top_inset(true, false, Some(10.0), 2.0, 4.25, 3.0, 22.0), Some(-8.5));
    assert_eq!(top_inset(false, false, Some(19.0), 2.0, 4.0, 3.0, 24.0), None);
    assert_eq!(top_inset(true, true, Some(19.0), 2.0, 4.0, 3.0, 24.0), None);
    assert_eq!(top_inset(true, false, None, 2.0, 4.0, 3.0, 24.0), None);
    let r = op(
        "corner_flush_top_inset",
        json!({"isOn": true, "centerFromTop": 10, "backingScale": 2, "panePadding": 4.25, "pillTop": 3, "tabHeight": 22}),
    );
    assert_eq!(r, json!(-8.5));
}

#[test]
fn chrome_shows_only_on_a_drawing_card() {
    assert!(content_on(true, false, false));
    assert!(!content_on(true, true, false));
    assert!(!content_on(true, false, true));
    assert!(!content_on(false, false, false));
    assert!(chrome_shows(true, 0.28, 12.0, true));
    assert!(!chrome_shows(true, 0.0, 12.0, true));
    assert!(!chrome_shows(true, 0.28, 0.0, true));
    assert!(!chrome_shows(true, 0.28, 12.0, false));
    assert!(!chrome_shows(false, 0.28, 12.0, true));
    let r = op(
        "corner_flush_chrome_shows",
        json!({"isOn": true, "page": true, "shadeBase": 0.3, "radius": 12, "inRoot": true}),
    );
    assert_eq!(r, json!({"on": false, "shows": false}));
}

fn strip(x: f64, min_y: f64, pane_max_y: f64) -> StripReport {
    StripReport {
        frame: Rect::new(x, min_y, 200.0, 30.0),
        pane: Some(Rect::new(x, 0.0, 200.0, pane_max_y)),
        ..Default::default()
    }
}

#[test]
fn redraw_picks_its_look() {
    assert_eq!(
        card_below_strip(Rect::new(0.0, 0.0, 400.0, 330.0), 30.0),
        Rect::new(0.0, 0.0, 400.0, 300.0)
    );
    assert_eq!(card_below_strip(Rect::new(0.0, 0.0, 400.0, 20.0), 30.0).height, 0.0);
    assert_eq!(redraw_mode(false, 0.5), RedrawMode::NoTopStrip);
    assert_eq!(redraw_mode(true, 0.0109), RedrawMode::Pill);
    assert_eq!(redraw_mode(true, FOLDER_TAB_MINIMUM_SHADE), RedrawMode::Folder);
    assert!(sidebar_hole_without_top_strip(0.011));
    assert!(!sidebar_hole_without_top_strip(0.01));
    let top = StripReport { selects_leading_tab: true, ..strip(0.0, 300.0, 330.0) };
    let r = op(
        "corner_flush_redraw",
        json!({"content": {"x": 0, "y": 0, "width": 400, "height": 330}, "stripHeight": 30, "alpha": 0.28, "strips": [top]}),
    );
    assert_eq!(r["mode"], "folder");
    assert_eq!(r["squareLeading"], true);
    assert_eq!(r["card"]["height"], 300.0);
    assert_eq!(r["edge"]["height"], 300.0);
}

/// Swift's dividerLine test.
#[test]
fn divider_line_runs_between_the_rounded_corners() {
    assert_eq!(divider_line(card(), 12.0, true), Rect::new(100.0, 300.0, 388.0, 0.0));
    assert_eq!(divider_line(card(), 12.0, false), Rect::new(112.0, 300.0, 376.0, 0.0));
    assert_eq!(divider_line(card(), 0.0, true), Rect::new(100.0, 300.0, 400.0, 0.0));
    // r caps at half the height: 5; the width 20 - 10.
    assert_eq!(
        divider_line(Rect::new(0.0, 0.0, 20.0, 10.0), 12.0, false),
        Rect::new(5.0, 10.0, 10.0, 0.0)
    );
    let r = op("corner_flush_divider_line", json!({"card": card(), "radius": 12}));
    assert_eq!(r, json!({"x": 112.0, "y": 300.0, "width": 376.0, "height": 0.0}));
}

#[test]
fn divider_segments_leave_the_gaps_out() {
    let line = Rect::new(0.0, 10.0, 100.0, 0.0);
    let gaps = [Span { lower: 60.0, upper: 70.0 }, Span { lower: 20.0, upper: 30.0 }];
    assert_eq!(
        divider_segments(line, &gaps),
        vec![
            Rect::new(0.0, 10.0, 20.0, 0.0),
            Rect::new(30.0, 10.0, 30.0, 0.0),
            Rect::new(70.0, 10.0, 30.0, 0.0)
        ]
    );
    assert_eq!(
        divider_segments(line, &[Span { lower: -10.0, upper: 5.0 }]),
        vec![Rect::new(5.0, 10.0, 95.0, 0.0)]
    );
    assert_eq!(divider_segments(line, &[Span { lower: 100.0, upper: 120.0 }]), vec![line]);
    assert_eq!(divider_segments(line, &[Span { lower: -1.0, upper: 101.0 }]), vec![]);
    assert_eq!(divider_segments(Rect::new(0.0, 10.0, 0.0, 0.0), &[]), vec![]);
    let r = op(
        "corner_flush_divider_segments",
        json!({"line": line, "gaps": [{"lower": 20, "upper": 30}]}),
    );
    assert_eq!(r.as_array().unwrap().len(), 2);
}

#[test]
fn strips_on_the_top_row() {
    let c = Rect::new(0.0, 0.0, 400.0, 300.0);
    let a = StripReport { meets_toolbar: true, ..strip(0.0, 299.0, 330.0) };
    let b = strip(200.0, 301.5, 330.0);
    let lower = strip(0.0, 150.0, 180.0);
    let hidden = StripReport { hidden_in_tree: true, ..strip(0.0, 301.9, 330.0) };
    assert_eq!(tab_row_edge(c, &[a, b, lower, hidden]).height, 301.5);
    assert_eq!(tab_row_edge(c, &[lower]), c);
    assert_eq!(toolbar_panes(c, &[a, b, lower]), vec![Span { lower: 0.0, upper: 200.0 }]);
    assert!(has_top_strip(c, &[a, b, lower]));
    assert!(!has_top_strip(c, &[]));
    assert!(!has_top_strip(c, &[lower]), "only a pane below the top row");
    let pane_without_strip = StripReport { hidden: true, ..b };
    assert!(!has_top_strip(c, &[a, pane_without_strip]));
    let panned = strip(200.0, 320.0, 360.0);
    assert!(!has_top_strip(c, &[a, panned]));
    let hidden_pane = StripReport { pane_hidden_in_tree: true, ..panned };
    assert!(has_top_strip(c, &[a, hidden_pane]));
    let leading =
        StripReport { selects_leading_tab: true, frame: Rect::new(0.5, 300.0, 200.0, 30.0), ..a };
    assert!(leading_tab_selected(c, &[b, leading]));
    assert!(!leading_tab_selected(c, &[StripReport { selects_leading_tab: false, ..leading }]));
    assert!(!leading_tab_selected(c, &[StripReport { hidden_in_tree: true, ..leading }]));
    let r = op("corner_flush_has_top_strip", json!({"card": c, "strips": [a, lower]}));
    assert_eq!(r, json!(true));
    let r = op("corner_flush_tab_row_edge", json!({"card": c, "strips": [a, b]}));
    assert_eq!(r["height"], 301.5);
    let r = op("corner_flush_toolbar_panes", json!({"card": c, "strips": [a]}));
    assert_eq!(r, json!([{"lower": 0.0, "upper": 200.0}]));
    let r = op("corner_flush_leading_tab_selected", json!({"card": c, "strips": [leading]}));
    assert_eq!(r, json!(true));
}

#[test]
fn mark_top_row_tells_each_strip() {
    let c = Rect::new(0.0, 0.0, 400.0, 300.0);
    let top = strip(0.0, 300.0, 330.0);
    let lower = strip(0.0, 150.0, 180.0);
    let hidden_lower = StripReport { hidden: true, ..lower };
    let marks = mark_top_row(Some(c), 12.0, true, true, &[top, lower, hidden_lower]);
    assert_eq!(
        marks[0],
        TopRowMark {
            runs_into_card: true,
            toned_in_card: false,
            clip: Some(Rect::new(-12.0, 0.0, 412.0, 300.0))
        }
    );
    assert_eq!(marks[1], TopRowMark { runs_into_card: false, toned_in_card: true, clip: None });
    assert_eq!(marks[2], TopRowMark { runs_into_card: false, toned_in_card: false, clip: None });
    let rounded = mark_top_row(Some(c), 12.0, false, false, &[top]);
    assert_eq!(
        rounded[0],
        TopRowMark { runs_into_card: false, toned_in_card: false, clip: Some(c) }
    );
    let none = mark_top_row(None, 0.0, false, true, &[top, lower]);
    assert!(none.iter().all(|m| !m.runs_into_card && !m.toned_in_card && m.clip.is_none()));
    let r = op(
        "corner_flush_mark_top_row",
        json!({"card": null, "tabShapeRunsIntoCard": true, "strips": [top]}),
    );
    assert_eq!(r, json!([{"runsIntoCard": false, "tonedInCard": false, "clip": null}]));
}

#[test]
fn sidebar_folder_pieces() {
    let c = Rect::new(200.0, 0.0, 600.0, 500.0);
    let row = Rect::new(20.0, 200.0, 180.0, 28.0);
    let f = sidebar_folder(row, c, 12.0, 6.0, 8.0).unwrap();
    assert_eq!(f.side, Side::Left);
    assert_eq!(f.edge, 200.0);
    assert_eq!(f.body, Rect::new(20.0, 200.0, 181.0, 28.0));
    assert_eq!(f.corner, 6.0);
    assert_eq!(f.square, Rect::new(110.5, 200.0, 90.5, 28.0));
    assert_eq!(
        f.feet,
        vec![
            Foot {
                rect: Rect::new(192.0, 228.0, 8.0, 8.0),
                ellipse: Rect::new(184.0, 228.0, 16.0, 16.0)
            },
            Foot {
                rect: Rect::new(192.0, 192.0, 8.0, 8.0),
                ellipse: Rect::new(184.0, 184.0, 16.0, 16.0)
            },
        ]
    );
    let right = sidebar_folder(Rect::new(800.0, 200.0, 100.0, 28.0), c, 12.0, 20.0, 0.0).unwrap();
    assert_eq!(right.side, Side::Right);
    assert_eq!(right.body, Rect::new(799.0, 200.0, 101.0, 28.0));
    assert_eq!(right.corner, 14.0);
    assert_eq!(right.square, Rect::new(799.0, 200.0, 50.5, 28.0));
    assert!(right.feet.is_empty());
    // A row whose fillet reaches the card's rounded corner, one overlapping the card, an empty one.
    assert_eq!(sidebar_folder(Rect::new(20.0, 10.0, 180.0, 28.0), c, 12.0, 6.0, 8.0), None);
    assert_eq!(sidebar_folder(Rect::new(20.0, 471.0, 180.0, 10.0), c, 12.0, 6.0, 8.0), None);
    assert_eq!(sidebar_folder(Rect::new(20.0, 200.0, 181.0, 28.0), c, 12.0, 6.0, 8.0), None);
    assert_eq!(sidebar_folder(Rect::new(20.0, 200.0, 0.0, 28.0), c, 12.0, 6.0, 8.0), None);
    // Exactly on the corner's limit still draws: 20 - 8 >= 0 + 12.
    assert!(sidebar_folder(Rect::new(20.0, 20.0, 180.0, 28.0), c, 12.0, 6.0, 8.0).is_some());
    let r = op(
        "corner_flush_sidebar_folder",
        json!({"row": row, "card": c, "cardRadius": 12, "rowRadius": 6, "feet": 8}),
    );
    assert_eq!(r["side"], "left");
    assert_eq!(r["feet"].as_array().unwrap().len(), 2);
}

/// Swift's wedge test: card (100, 0, 400, 300), radius 12.
#[test]
fn wedges_shade_the_top_corners() {
    let p = |x, y| Point { x, y };
    assert!(wedge_contains(card(), 12.0, false, p(100.5, 299.5)));
    assert!(wedge_contains(card(), 12.0, false, p(499.5, 299.5)));
    assert!(!wedge_contains(card(), 12.0, false, p(300.0, 299.5)));
    assert!(
        !wedge_contains(card(), 12.0, true, p(100.5, 299.5)),
        "squareLeading drops the leading wedge"
    );
    assert!(wedge_contains(card(), 12.0, true, p(499.5, 299.5)));
    assert!(!wedge_contains(card(), 12.0, false, p(110.0, 290.0)), "inside the rounded corner");
    let w = wedges(card(), 12.0, false);
    assert_eq!(w.radius, 12.0);
    assert_eq!(
        w.corners,
        vec![Rect::new(100.0, 288.0, 12.0, 12.0), Rect::new(488.0, 288.0, 12.0, 12.0)]
    );
    assert_eq!(wedges(card(), 12.0, true).corners, vec![Rect::new(488.0, 288.0, 12.0, 12.0)]);
    assert_eq!(wedges(Rect::new(0.0, 0.0, 20.0, 10.0), 12.0, false).radius, 5.0);
    let r = op(
        "corner_flush_wedge_contains",
        json!({"card": card(), "radius": 12, "point": {"x": 100.5, "y": 299.5}}),
    );
    assert_eq!(r, json!(true));
    let r = op("corner_flush_wedges", json!({"card": card(), "radius": 12, "squareLeading": true}));
    assert_eq!(r["corners"].as_array().unwrap().len(), 1);
}

// MARK: - ConcentricCorners (Swift `ConcentricCornersTests`)

#[test]
fn concentric_inner() {
    for (outer, padding, inner) in [
        (10.0, 2.0, 8.0),
        (14.0, 6.0, 8.0),
        (6.0, 2.0, 4.0),
        (4.0, 6.0, 0.0),
        (0.0, 2.0, 0.0),
        (8.0, 0.0, 8.0),
    ] {
        assert_eq!(ConcentricCorners::new(outer, padding).inner(), inner, "{outer} {padding}");
    }
}

#[test]
fn concentric_depths() {
    let c = ConcentricCorners::new(16.0, 3.0);
    let radii: Vec<f64> = (0..=6).map(|d| c.radius(d)).collect();
    assert_eq!(radii, [16.0, 13.0, 10.0, 7.0, 4.0, 1.0, 0.0]);
    assert_eq!(c.radius(-1), 19.0);
    let r = op(
        "corner_flush_concentric_corners",
        json!({"outer": 16, "padding": 3, "depths": [0, 1, 6, -1]}),
    );
    assert_eq!(r["radii"], json!([16.0, 13.0, 0.0, 19.0]));
    assert_eq!(r["inner"], json!(13.0));
}

#[test]
fn concentric_negatives_clamp() {
    let c = ConcentricCorners::new(-4.0, -2.0);
    assert_eq!((c.outer, c.padding, c.inner()), (0.0, 0.0, 0.0));
    let r = op("corner_flush_concentric_corners", json!({"outer": -4, "padding": -2}));
    assert_eq!((r["outer"].as_f64(), r["padding"].as_f64()), (Some(0.0), Some(0.0)));
}

#[test]
fn concentric_nested_and_fitting() {
    let c = ConcentricCorners::new(16.0, 3.0);
    assert_eq!(c.nested(8.0, 4.0), 4.0);
    assert_eq!(c.nested(8.0, 12.0), 0.0);
    assert_eq!(c.nested(8.0, -6.0), 14.0);
    assert_eq!(c.radius_fitting(Size { width: 100.0, height: 24.0 }, 20.0), 12.0);
    assert_eq!(c.radius_fitting(Size { width: 6.0, height: 40.0 }, 8.0), 3.0);
    assert_eq!(c.radius_fitting(Size { width: 100.0, height: 100.0 }, 8.0), 8.0);
    let r = op(
        "corner_flush_concentric_corners",
        json!({"outer": 16, "padding": 3, "nested": {"radius": 8, "inset": -6}, "fitting": {"width": 6, "height": 40}, "radius": 8}),
    );
    assert_eq!((r["nested"].as_f64(), r["radiusFitting"].as_f64()), (Some(14.0), Some(3.0)));
}

// MARK: - ConcentricContainer (Swift `ConcentricContainerTests`)

#[test]
fn container_toast() {
    let c = ConcentricContainer::new(8.0, 8.0);
    assert_eq!(c.outer_radius(), 16.0);
    assert_eq!(c.text_inset(), 16.0);
    assert_eq!(
        ConcentricContainer::new(-3.0, -1.0),
        ConcentricContainer { padding: 0.0, child_radius: 0.0 }
    );
}

#[test]
fn container_from_outer() {
    assert_eq!(ConcentricContainer::with_outer(16.0, 6.0).child_radius, 10.0);
    assert_eq!(ConcentricContainer::with_outer(4.0, 6.0).child_radius, 0.0);
    let r = op("corner_flush_concentric_container", json!({"outerRadius": 16, "padding": 6}));
    assert_eq!(r["childRadius"], json!(10.0));
}

#[test]
fn container_capsule() {
    let c = ConcentricContainer::capsule(22.0, 8.0);
    assert_eq!(c.child_radius, 11.0);
    assert_eq!(c.outer_radius(), 19.0);
    assert_eq!(c.outer_radius_fitting(Size { width: 300.0, height: 38.0 }), 19.0);
    assert_eq!(c.child_radius_fitting(Size { width: 20.0, height: 20.0 }), 10.0);
    let r = op(
        "corner_flush_concentric_container",
        json!({"controlHeight": 22, "padding": 8, "fitting": {"width": 20, "height": 20}}),
    );
    assert_eq!(
        (r["childRadius"].as_f64(), r["childRadiusFitting"].as_f64()),
        (Some(11.0), Some(10.0))
    );
}

/// The doc example: a 16 pt control in a 14 pt window corner with at least 2 pt padding.
#[test]
fn container_corner_control_and_frame() {
    let c = ConcentricContainer::corner_control(14.0, 16.0, 2.0);
    assert_eq!(c.padding, 6.0);
    assert_eq!(c.child_radius_fitting(Size { width: 16.0, height: 16.0 }), 8.0);
    // max(2, 20 - 8) = 12 ... a large corner pushes the control in.
    assert_eq!(ConcentricContainer::corner_control(20.0, 16.0, 2.0).padding, 12.0);
    let bounds = Rect::new(0.0, 0.0, 300.0, 38.0);
    assert_eq!(c.top_trailing_frame(16.0, bounds, false), Rect::new(278.0, 16.0, 16.0, 16.0));
    assert_eq!(c.top_trailing_frame(16.0, bounds, true), Rect::new(278.0, 6.0, 16.0, 16.0));
    let r = op(
        "corner_flush_concentric_container",
        json!({"outerRadius": 14, "side": 16, "minimumPadding": 2, "frameSide": 16, "bounds": bounds, "flipped": true}),
    );
    assert_eq!(r["padding"], json!(6.0));
    assert_eq!(r["topTrailingFrame"], json!({"x": 278.0, "y": 6.0, "width": 16.0, "height": 16.0}));
    assert!(call("tokens.corner_flush_concentric_container", &json!({"padding": 2})).is_err());
}

#[test]
fn container_violations() {
    let bounds = Rect::new(0.0, 0.0, 300.0, 38.0);
    let close = Rect::new(270.0, 8.0, 22.0, 22.0);
    assert!(violations(close, 8.0, bounds, 16.0, 8.0, VIOLATION_TOLERANCE).is_empty());
    let wrong = violations(close, 8.0, bounds, 8.0, 8.0, VIOLATION_TOLERANCE);
    assert!(wrong.iter().any(|m| m.starts_with("child radius 8")), "{wrong:?}");
    assert_eq!(wrong, ["child radius 8 is not 8 - 8 = 0"]);
    let off =
        violations(Rect::new(272.0, 9.0, 20.0, 20.0), 8.0, bounds, 16.0, 8.0, VIOLATION_TOLERANCE);
    assert!(off.contains(&"top inset 9 is not the padding 8".to_string()), "{off:?}");
    assert!(off.contains(&"bottom inset 9 is not the padding 8".to_string()), "{off:?}");
    let middle = violations(
        Rect::new(150.0, 130.0, 100.0, 26.0),
        3.0,
        Rect::new(0.0, 0.0, 400.0, 300.0),
        24.0,
        16.0,
        VIOLATION_TOLERANCE,
    );
    assert!(middle.is_empty());
    let r = op(
        "corner_flush_violations",
        json!({"child": close, "childRadius": 8, "bounds": bounds, "outerRadius": 8, "padding": 8}),
    );
    assert_eq!(r, json!(["child radius 8 is not 8 - 8 = 0"]));
}

#[test]
fn format_prints_two_decimals() {
    assert_eq!(format(9.0), "9");
    assert_eq!(format(8.5), "8.5");
    assert_eq!(format(12.3456), "12.35");
    assert_eq!(format(-0.001), "0");
    assert_eq!(format(0.004), "0");
    assert_eq!(format(-2.5), "-2.5");
    assert_eq!(format(1.999), "2");
    assert_eq!(op("corner_flush_format", json!({"value": 0.125})), json!("0.13"));
}

#[test]
fn unknown_op_is_unknown() {
    assert!(cmux_design_core::tokens::corner_flush::call("corner_flush_nope", &json!({})).is_err());
    assert!(matches!(
        cmux_design_core::tokens::corner_flush::call("two_tone_values", &json!({})),
        Err(cmux_design_core::ops::OpError::Unknown)
    ));
}
