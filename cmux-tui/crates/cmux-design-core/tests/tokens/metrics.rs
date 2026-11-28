//! Parity tests for `tokens::metrics`: Swift's `ButtonCornerRadiusTests`, the chrome row corner
//! (`HeliumTabCornerTests`), `TabsFollowRows`, the tab bar control side and the
//! `ConcentricContainer` cases, plus pins computed by hand from the Metrics+*.swift formulas.

use cmux_design_core::ops::{OpError, call};
use cmux_design_core::tokens::density::tokens::{DensityPreset, DensityTokens, half};
use cmux_design_core::tokens::metrics::*;

fn sz(width: f64, height: f64) -> Size {
    Size { width, height }
}
use serde_json::{Value, json};
use std::collections::BTreeMap;

fn op(name: &str, request: Value) -> Value {
    call(&format!("tokens.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e:?}"))
}

fn custom(level: f64, pairs: &[(&str, f64)]) -> DensityTokens {
    let map: BTreeMap<String, f64> = pairs.iter().map(|(k, v)| (k.to_string(), *v)).collect();
    DensityTokens::new("mine", "Mine", None, level, 1.0, None, map)
}

const TAB: f64 = 9.0;

// MARK: - Concentric containers

#[test]
fn concentric_container() {
    let c = ConcentricContainer::new(8.0, 8.0);
    assert_eq!((c.outer_radius(), c.text_inset()), (16.0, 16.0));
    let control = ConcentricContainer::corner_control(14.0, 16.0, 2.0);
    assert_eq!((control.padding, control.child_radius), (6.0, 8.0));
    assert_eq!(control.child_radius_fitting(sz(16.0, 16.0)), 8.0);
    // The minimum padding wins when the corner is small for the side.
    let small = ConcentricContainer::corner_control(6.0, 16.0, 2.0);
    assert_eq!((small.padding, small.child_radius), (2.0, 4.0));
    // Negative inputs floor at 0; an outer radius under the padding leaves a square child.
    assert_eq!(
        ConcentricContainer::new(-3.0, -1.0),
        ConcentricContainer { padding: 0.0, child_radius: 0.0 }
    );
    let flat = ConcentricContainer::with_outer(4.0, 6.0);
    assert_eq!(
        (flat.padding, flat.child_radius, flat.outer_radius(), flat.text_inset()),
        (6.0, 0.0, 6.0, 6.0)
    );
    assert_eq!(ConcentricContainer::new(0.0, 4.0).text_inset(), 4.0);
    let c = ConcentricContainer::new(10.0, 4.0);
    assert_eq!(c.child_radius_fitting(sz(12.0, 30.0)), 6.0);
    assert_eq!(c.outer_radius_fitting(sz(12.0, 30.0)), 6.0);
    assert_eq!(c.outer_radius_fitting(sz(100.0, 100.0)), 14.0);
    assert_eq!(ConcentricCorners::default().radius_fitting(sz(10.0, 40.0), 9.0), 5.0);
    assert_eq!(ConcentricCorners::default().radius_fitting(sz(-2.0, 40.0), 9.0), 0.0);
    assert_eq!(
        (
            ConcentricCorners::default().nested(12.0, 4.0),
            ConcentricCorners::default().nested(3.0, 5.0)
        ),
        (8.0, 0.0)
    );
}

#[test]
fn container_ops() {
    assert_eq!(
        op("metrics_button_container", json!({"buttonCornerRadius": 8, "padding": 8})),
        json!({"padding": 8.0, "childRadius": 8.0, "outerRadius": 16.0, "textInset": 16.0})
    );
    assert_eq!(
        op(
            "metrics_corner_control",
            json!({"outerRadius": 14, "side": 16, "space1": 2, "fitting": {"width": 16, "height": 16}})
        ),
        json!({"padding": 6.0, "childRadius": 8.0, "outerRadius": 14.0, "textInset": 14.0, "childRadiusFitting": 8.0, "outerRadiusFitting": 8.0})
    );
}

// MARK: - Add glyph

#[test]
fn add_glyph_metrics() {
    assert_eq!(add_glyph_extent(16.0), 12.0);
    assert_eq!(add_glyph_extent(15.0), 11.5);
    assert_eq!(add_glyph_extent(13.0), 10.0);
    assert_eq!(add_glyph_line_width(2.0), 2.0 * 0.6);
    assert_eq!(add_glyph_line_width(2.5), 2.5 * 0.6);
    assert_eq!(add_menu_chevron_point_size(16.0, 2.0), 13.0);
    assert_eq!(add_menu_chevron_point_size(15.0, 2.0), 13.0);
    assert_eq!(add_menu_chevron_point_size(13.0, 1.0), 11.0);
}

#[test]
fn add_glyph_path_snaps_the_center() {
    let p = |x, y| Point { x, y };
    assert_eq!(
        add_glyph_path(p(10.3, 7.6), 2.0, 16.0),
        [[p(4.5, 7.5), p(16.5, 7.5)], [p(10.5, 1.5), p(10.5, 13.5)]]
    );
    // A scale under 1 snaps to whole points.
    assert_eq!(
        add_glyph_path(p(10.3, 7.6), 0.5, 16.0),
        [[p(4.0, 8.0), p(16.0, 8.0)], [p(10.0, 2.0), p(10.0, 14.0)]]
    );
}

#[test]
fn add_glyph_ops() {
    assert_eq!(
        op("metrics_add_glyph", json!({"smallIconSize": 16, "space1": 2})),
        json!({"extent": 12.0, "lineWidth": 2.0 * 0.6, "chevronPointSize": 13.0})
    );
    assert_eq!(
        op(
            "metrics_add_glyph_path",
            json!({"center": {"x": 10.3, "y": 7.6}, "scale": 2, "smallIconSize": 16})
        ),
        json!([[{"x": 4.5, "y": 7.5}, {"x": 16.5, "y": 7.5}], [{"x": 10.5, "y": 1.5}, {"x": 10.5, "y": 13.5}]])
    );
    assert_eq!(
        op("metrics_add_glyph_path", json!({"center": {"x": 1.4, "y": 1.6}, "smallIconSize": 16}))
            [0][0],
        json!({"x": -5.0, "y": 2.0})
    );
}

// MARK: - Button corners

/// ButtonCornerRadiusTests.
#[test]
fn button_corner_radius_cases() {
    assert_eq!(button_corner_radius_fitting(TAB, 40.0, 40.0), TAB);
    assert_eq!(button_corner_radius_fitting(TAB, 40.0, 6.0), TAB.min(3.0));
    assert_eq!(button_corner_radius_nested(TAB, None, 2.0), (TAB - 2.0).max(0.0));
    assert_eq!(button_corner_radius_nested(TAB, Some(12.0), 4.0), 8.0);
    assert_eq!(button_corner_radius_nested(TAB, Some(3.0), 5.0), 0.0);
    let container = button_container(TAB, 4.0);
    assert_eq!((container.child_radius, container.outer_radius()), (TAB, 13.0));
    assert_eq!(
        corner_control(14.0, 16.0, 2.0),
        ConcentricContainer { padding: 6.0, child_radius: 8.0 }
    );
}

#[test]
fn button_corner_radius_proportional_pins() {
    // Unset: Helium's 8 on 28, on the half-point grid, capped at half the side.
    assert_eq!(button_corner_radius_proportional(TAB, 28.0, false), 8.0);
    assert_eq!(button_corner_radius_proportional(TAB, 20.0, false), 5.5);
    assert_eq!(button_corner_radius_proportional(TAB, 2.0, false), 0.5);
    // Set: the set corner, capped at half.
    assert_eq!(button_corner_radius_proportional(TAB, 28.0, true), 9.0);
    assert_eq!(button_corner_radius_proportional(TAB, 12.0, true), 6.0);
}

#[test]
fn button_corner_ops() {
    let r = |v: Value| op("metrics_button_corner_radius", v);
    assert_eq!(r(json!({"buttonCornerRadius": 9, "fitting": {"width": 40, "height": 6}})), 3.0);
    assert_eq!(r(json!({"buttonCornerRadius": 9, "proportionalTo": 20})), 5.5);
    assert_eq!(
        r(json!({"buttonCornerRadius": 9, "proportionalTo": 12, "cornerRadiusIsSet": true})),
        6.0
    );
    assert_eq!(r(json!({"buttonCornerRadius": 9, "nestedIn": 12, "inset": 4})), 8.0);
    assert_eq!(r(json!({"buttonCornerRadius": 9, "inset": 2})), 7.0);
    assert!(matches!(
        call("tokens.metrics_button_corner_radius", &json!({"buttonCornerRadius": 9})),
        Err(OpError::Invalid(_))
    ));
}

// MARK: - Chrome row corner

/// HeliumTabCornerTests: 8 on 28, whole points.
#[test]
fn chrome_row_corner_radius_cases() {
    for (h, r) in [(20.0, 6.0), (28.0, 8.0), (31.0, 9.0), (34.0, 10.0)] {
        assert_eq!(chrome_row_corner_radius(h), r, "{h}");
    }
    assert_eq!(chrome_row_corner_radius(0.0), 0.0);
    assert_eq!(op("metrics_chrome_row_corner_radius", json!({"height": 31})), 9.0);
}

#[test]
fn corner_radius_is_set_and_row_corner() {
    assert!(!corner_radius_is_set(None, None));
    assert!(corner_radius_is_set(Some(0.0), None));
    assert!(corner_radius_is_set(None, Some(4.0)));
    assert!(uses_chrome_row_corner(false, false));
    assert!(!uses_chrome_row_corner(true, false));
    assert!(!uses_chrome_row_corner(false, true));
    assert_eq!(
        op("metrics_corner_radius_is_set", json!({"floatingPanes": false})),
        json!({"cornerRadiusIsSet": false, "usesChromeRowCorner": true})
    );
    assert_eq!(
        op("metrics_corner_radius_is_set", json!({"densityPaneCornerRadius": 6})),
        json!({"cornerRadiusIsSet": true, "usesChromeRowCorner": false})
    );
}

// MARK: - Row match

#[test]
fn density_row_height_pins() {
    let cozy = DensityPreset::Cozy.tokens();
    let compact = DensityPreset::Compact.tokens();
    assert_eq!(density_row_height(cozy, 1.0, None, 2.0), 30.0);
    assert_eq!(density_row_height(compact, 1.0, None, 2.0), 28.0);
    assert_eq!(density_row_height(cozy, 2.0, None, 2.0), 60.0);
    assert_eq!(density_row_height(cozy, 1.0, Some(40.0), 2.0), 42.0);
    assert_eq!(density_row_height(cozy, 1.0, None, 4.0), 32.0);
    // No uniform scale and not Default: no row fill.
    assert_eq!(density_row_height(&custom(1.0, &[]), 1.0, None, 2.0), 32.0);
    assert_eq!(density_row_height(&custom(0.0, &[]), 1.0, None, 2.0), 24.0);
    assert_eq!(
        density_row_height(&custom(0.0, &[("sidebarRowHeight", 21.0)]), 1.0, None, 2.0),
        21.0
    );
    // A uniform scale resolves Default's 28 times the scale, plus space1.
    assert_eq!(density_row_height(&custom(0.0, &[("densityScale", 1.1)]), 1.0, None, 2.0), 33.0);
    assert_eq!(default_density_row_height(2.0), 30.0);
    assert_eq!(default_density_row_height(4.0), 32.0);
    assert_eq!(
        (SIDEBAR_ROW_COMPACT, SIDEBAR_ROW_COMFORTABLE, SIDEBAR_ROW_TOKEN),
        (24.0, 32.0, "sidebarRowHeight")
    );
}

#[test]
fn tabs_follow_rows_and_growth() {
    assert!(tabs_follow_rows(false, false, false));
    assert!(!tabs_follow_rows(true, false, false));
    assert!(!tabs_follow_rows(false, true, false));
    assert!(!tabs_follow_rows(false, false, true));
    assert_eq!(tab_row_growth(true, 30.0, 26.0), 4.0);
    assert_eq!(tab_row_growth(true, 24.0, 26.0), -2.0);
    assert_eq!(tab_row_growth(false, 30.0, 26.0), 0.0);
}

/// TabsFollowRows: a preset's tab corner is `half(9 t)`.
#[test]
fn preset_tab_corner_radius_is_half_nine_t() {
    for p in DensityPreset::ALL {
        assert_eq!(
            p.tokens().token("tabCornerRadius"),
            Some(half(9.0 * p.scale_factor())),
            "{p:?}"
        );
    }
}

#[test]
fn row_match_ops() {
    let cozy = serde_json::to_value(DensityPreset::Cozy.tokens()).unwrap();
    assert_eq!(op("metrics_density_row_height", json!({"density": cozy})), 30.0);
    assert_eq!(
        op(
            "metrics_density_row_height",
            json!({"density": cozy, "interfaceScale": 2, "rowOverride": 40})
        ),
        84.0
    );
    assert_eq!(op("metrics_default_density_row_height", json!({})), 30.0);
    assert_eq!(op("metrics_default_density_row_height", json!({"space1Base": 4})), 32.0);
    assert_eq!(op("metrics_tabs_follow_rows", json!({})), true);
    assert_eq!(op("metrics_tabs_follow_rows", json!({"compactTabs": true})), false);
    assert_eq!(
        op(
            "metrics_tab_row_growth",
            json!({"tabsFollowRows": true, "densityRowHeight": 30, "tabHeightValue": 26})
        ),
        4.0
    );
}

// MARK: - Tab bar control, grid, shape key

#[test]
fn tab_bar_control() {
    // TabBarControlSide == tabHeight.
    for h in [24.0, 28.0, 33.5] {
        assert_eq!(tab_bar_control_side(h), h);
    }
    assert_eq!(tab_bar_control_corner_radius(28.0, 9.0, None), 9.0);
    assert_eq!(tab_bar_control_corner_radius(28.0, 20.0, None), 14.0);
    assert_eq!(tab_bar_control_corner_radius(28.0, 9.0, Some((40.0, 10.0))), 5.0);
    assert_eq!(
        op("metrics_tab_bar_control", json!({"tabHeight": 28, "tabCornerRadius": 20})),
        json!({"side": 28.0, "cornerRadius": 14.0})
    );
    assert_eq!(
        op(
            "metrics_tab_bar_control",
            json!({"tabHeight": 28, "tabCornerRadius": 9, "fitting": {"width": 40, "height": 10}})
        )["cornerRadius"],
        5.0
    );
}

#[test]
fn grid_spaces() {
    assert_eq!(SPACE_BASES, [2.0, 4.0, 6.0, 8.0, 12.0, 16.0]);
    assert_eq!(scale(7.0, 2.0), 14.0);
    let cozy = DensityPreset::Cozy.tokens();
    let compact = DensityPreset::Compact.tokens();
    assert_eq!(SPACE_BASES.map(|b| space(cozy, 1.0, b)), SPACE_BASES);
    assert_eq!(SPACE_BASES.map(|b| space(compact, 1.0, b)), [2.0, 3.5, 5.5, 7.0, 11.0, 14.5]);
    assert_eq!(space(compact, 2.0, 4.0), 7.0);
    let compact_json = serde_json::to_value(compact).unwrap();
    assert_eq!(
        op("metrics_spaces", json!({"density": compact_json})),
        json!([2.0, 3.5, 5.5, 7.0, 11.0, 14.5])
    );
    assert_eq!(
        op(
            "metrics_spaces",
            json!({"density": compact_json, "interfaceScale": 2, "bases": [1, 2, 3, 4, 5, 6]})
        ),
        json!([2.0, 4.0, 5.0, 7.0, 9.0, 11.0])
    );
}

#[test]
fn chrome_shape_key_pins() {
    assert_eq!(CORNER_FLUSH_CASES, ["off", "flush", "flush-tight", "flush-goo"]);
    assert_eq!(TAB_SHAPE_CASES, ["block", "rounded"]);
    assert_eq!(chrome_shape_key(false, "off", "block", 0.0), 0.0);
    assert_eq!(chrome_shape_key(true, "flush-tight", "rounded", 10.0), 165.25);
    assert_eq!(chrome_shape_key(false, "flush-goo", "block", 0.5), 14.0);
    assert_eq!(chrome_shape_key(false, "nope", "nope", 0.0), 0.0);
    // Every combination is distinct at one radius.
    let mut keys: Vec<f64> = Vec::new();
    for f in [false, true] {
        for c in CORNER_FLUSH_CASES {
            for t in TAB_SHAPE_CASES {
                keys.push(chrome_shape_key(f, c, t, 0.0));
            }
        }
    }
    let n = keys.len();
    keys.sort_by(f64::total_cmp);
    keys.dedup();
    assert_eq!(keys.len(), n);
    assert_eq!(
        op(
            "metrics_chrome_shape_key",
            json!({"floatingPanes": true, "cornerFlush": "flush-tight", "tabShape": "rounded", "mainPaneCornerRadius": 10})
        ),
        165.25
    );
    assert!(matches!(call("tokens.metrics_nope", &json!({})), Err(OpError::Unknown)));
}
