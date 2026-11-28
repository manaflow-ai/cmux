//! Parity tests for `tokens::density`: Swift's `PageRowScaleTests`, `ChatTextScaleTests`,
//! `CardScaleDensityTests` and the pure parts of `DensityPlaygroundTests`, plus pins computed by
//! hand from DensityPreset.swift, DensityTokens.swift, DensityTokenCatalog.swift,
//! Typography+PageDensity.swift and CardScale.swift.

use cmux_design_core::ops::{OpError, call};
use cmux_design_core::tokens::density::catalog::{self, Fallback, Field, Group, Unit};
use cmux_design_core::tokens::density::page::{self, type_scale};
use cmux_design_core::tokens::density::tokens::{
    self as dt, DensityPreset, DensityTokens, Family, half, reference_tokens,
};
use cmux_design_core::tokens::metrics;
use serde_json::{Value, json};
use std::collections::BTreeMap;

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-9
}

fn op(name: &str, request: Value) -> Value {
    call(&format!("tokens.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e:?}"))
}

fn tokens(preset: DensityPreset) -> &'static DensityTokens {
    preset.tokens()
}

fn json_of(d: &DensityTokens) -> Value {
    serde_json::to_value(d).unwrap()
}

fn custom(
    level: f64,
    spacing: f64,
    font_size: Option<f64>,
    pairs: &[(&str, f64)],
) -> DensityTokens {
    let map: BTreeMap<String, f64> = pairs.iter().map(|(k, v)| (k.to_string(), *v)).collect();
    DensityTokens::new("mine", "Mine", None, level, spacing, font_size, map)
}

/// `Typography.userScale` with Text Size and Interface Size off.
fn user(d: &DensityTokens) -> f64 {
    dt::user_scale(d, None, 1.0)
}

fn row(d: &DensityTokens, is: f64) -> f64 {
    metrics::density_row_height(d, is, None, 2.0)
}

fn page_density(d: &DensityTokens, is: f64) -> f64 {
    page::page_density_scale(d, is, row(d, is), metrics::default_density_row_height(2.0))
}

fn spaces(d: &DensityTokens, is: f64) -> [f64; 6] {
    metrics::SPACE_BASES.map(|b| metrics::space(d, is, b))
}

// MARK: - DensityTokens / DensityPreset

#[test]
fn half_rounds_to_the_half_point_grid() {
    assert_eq!(half(2.7), 2.5);
    assert_eq!(half(2.75), 3.0);
    assert_eq!(half(9.714), 9.5);
    assert_eq!(half(-1.3), -1.5);
}

#[test]
fn init_clamps_level_spacing_font_and_drops_bad_tokens() {
    let d = custom(
        9.0,
        0.1,
        Some(40.0),
        &[("a", 3.0), ("b", -1.0), ("c", f64::NAN), ("d", f64::INFINITY)],
    );
    assert_eq!(d.level, 2.5);
    assert_eq!(d.spacing, 0.5);
    assert_eq!(d.font_size, Some(20.0));
    assert_eq!(d.tokens.keys().collect::<Vec<_>>(), vec!["a"]);
    let low = custom(-5.0, 9.0, Some(1.0), &[]);
    assert_eq!((low.level, low.spacing, low.font_size), (-1.0, 2.0, Some(9.0)));
}

#[test]
fn reference_is_default_unscaled() {
    let r = reference_tokens();
    assert_eq!(
        (r.id.as_str(), r.name.as_str(), r.level, r.spacing, r.font_size),
        ("cozy", "Default", 0.5, 1.0, Some(14.0))
    );
    assert_eq!(r.tokens.len(), 39);
    assert_eq!(r.token("sidebarRowHeight"), Some(28.0));
    assert_eq!(r.token("omnibarHeight"), Some(28.0 / 0.9));
    assert_eq!(r.uniform_scale(), None);
    assert_eq!(r.text_size(12.0, 13.0), 14.0);
    assert_eq!(dt::reference_values().len(), 39);
}

#[test]
fn preset_tables() {
    let raws: Vec<_> = DensityPreset::ALL.iter().map(|p| p.raw()).collect();
    assert_eq!(raws, ["ultraCompact", "compact", "cozy", "comfortable", "spacious"]);
    let names: Vec<_> = DensityPreset::ALL.iter().map(|p| p.name()).collect();
    assert_eq!(names, ["Ultra-compact", "Compact", "Default", "Comfortable", "Spacious"]);
    let scales: Vec<_> = DensityPreset::ALL.iter().map(|p| p.scale_factor()).collect();
    assert_eq!(scales, [0.8, 0.9, 1.0, 1.1, 1.2]);
    let rows: Vec<_> = DensityPreset::ALL.iter().map(|p| p.row_height()).collect();
    assert_eq!(rows, [24.0, 28.0, 30.0, 32.0, 36.0]);
    let stars: Vec<_> = DensityPreset::ALL.iter().map(|p| p.star_glyph_side()).collect();
    assert_eq!(stars, [21.0, 23.5, 28.0, 29.5, 32.0]);
    assert_eq!(DensityPreset::Cozy.omnibar_scale_factor(), 0.9);
    assert_eq!(DensityPreset::Spacious.omnibar_scale_factor(), 1.2);
    assert_eq!(DensityPreset::from_raw("compact"), Some(DensityPreset::Compact));
    assert_eq!(DensityPreset::from_raw("Compact"), None);
    assert!(DensityPreset::is_omnibar_token("omnibarHeight"));
    assert!(DensityPreset::is_omnibar_token("toolbarGlyphSize"));
    assert!(!DensityPreset::is_omnibar_token("tabGap"));
}

#[test]
fn cozy_tokens_pinned() {
    let d = tokens(DensityPreset::Cozy);
    assert_eq!((d.id.as_str(), d.name.as_str()), ("cozy", "Default"));
    assert_eq!((d.level, d.spacing, d.font_size), (0.5, 1.0, Some(14.0)));
    let t = |k: &str| d.token(k).unwrap();
    assert_eq!(t("sidebarRowHeight"), 28.0);
    assert_eq!(t("browserRowHeight"), 30.0);
    assert_eq!(t("browserRowGap"), 5.0);
    assert_eq!(t("tabStripHeight"), 40.0);
    assert_eq!(t("omnibarRowGap"), 6.0);
    assert_eq!(t("omnibarHeight"), 34.0);
    assert_eq!(t("omnibarCornerRadius"), 9.5);
    assert_eq!(t("omnibarButtonSize"), 28.0);
    assert_eq!(t("omnibarStarPlateSize"), 28.0);
    assert_eq!(t("omnibarStarGlyphSize"), 28.0);
    assert_eq!(t("omnibarFontSize"), (11.0 - 0.31) / 0.70459);
    assert_eq!(t("omnibarIconSize"), 18.0);
    assert_eq!(t("tabTitleSize"), 14.0);
    assert_eq!(t("tabCornerRadius"), 9.0);
    assert_eq!(t("densityScale"), 1.0);
    assert_eq!(t("composerZoom"), 1.0);
    assert_eq!(t("sidebarLineBoxBaseline"), 1.0);
    assert_eq!(d.token("tabToOmnibarGap"), None);
    assert_eq!(d.family(), Family::Comfortable);
    assert!(d.is_built_in() && d.uses_default_row_fill());
    assert_eq!(d.body_size(), 14.0);
    assert_eq!(dt::sidebar_title_size(d), 14.0);
}

#[test]
fn other_presets_pinned() {
    let c = tokens(DensityPreset::Compact);
    assert_eq!(c.token("sidebarRowHeight"), Some(26.0));
    assert_eq!(c.token("browserRowGap"), Some(2.5));
    assert_eq!(c.token("tabStripHeight"), Some(33.0));
    assert_eq!(c.token("tabToOmnibarGap"), Some(3.5));
    assert_eq!(c.token("tabCornerRadius"), Some(8.0));
    assert_eq!(c.token("omnibarHeight"), Some(28.0));
    assert_eq!(c.token("omnibarRowGap"), None);
    assert_eq!(c.token("omnibarStarGlyphSize"), Some(23.5));
    assert!(close(c.level, 3.5 * 0.9 - 3.0));
    assert_eq!(c.family(), Family::Compact);
    assert_eq!(c.spacing, 0.9);
    assert_eq!(c.font_size, Some(14.0 * 0.9));

    let s = tokens(DensityPreset::Spacious);
    assert_eq!(s.token("browserRowGap"), Some(6.5));
    assert_eq!(s.token("tabStripHeight"), Some(49.0));
    assert_eq!(s.token("omnibarRowGap"), Some(7.5));
    assert_eq!(s.token("sidebarRowHeight"), Some(33.5));

    let u = tokens(DensityPreset::UltraCompact);
    assert_eq!(u.token("sidebarRowHeight"), Some(22.5));
    assert_eq!(u.token("tabStripHeight"), Some(29.0));
    assert!(close(u.level, -0.2));

    let m = tokens(DensityPreset::Comfortable);
    assert_eq!(m.token("browserRowGap"), Some(5.5));
    assert_eq!(m.token("tabStripHeight"), Some(43.0));
    assert_eq!(m.token("omnibarRowGap"), Some(6.5));
    assert_eq!(m.token("sidebarRowHeight"), Some(30.0));
}

#[test]
fn resolve_text_size_space_and_font_token() {
    // Exact token, then uniform scale over the reference, then the level.
    let c = tokens(DensityPreset::Compact);
    assert_eq!(c.resolve(24.0, 32.0, Some("sidebarRowHeight")), 26.0);
    assert_eq!(c.resolve(24.0, 32.0, None), half(28.0 * 0.9));
    assert_eq!(custom(0.0, 1.0, None, &[]).resolve(24.0, 32.0, None), 24.0);
    assert_eq!(custom(1.0, 1.0, None, &[]).resolve(24.0, 32.0, None), 32.0);
    assert_eq!(custom(0.25, 1.0, None, &[]).resolve(24.0, 32.0, None), 26.0);
    assert_eq!(custom(0.3, 1.0, None, &[]).resolve(24.0, 32.0, None), 26.0);

    assert_eq!(custom(0.0, 1.0, None, &[]).text_size(12.0, 13.0), 12.0);
    assert_eq!(custom(0.5, 1.0, None, &[]).text_size(12.0, 13.0), 12.5);
    assert_eq!(custom(0.5, 1.0, Some(15.0), &[]).text_size(12.0, 13.0), 15.0);
    assert_eq!(custom(0.0, 1.0, Some(13.0), &[]).text_size(11.0, 12.0), half(11.0 * 13.0 / 12.0));
    // Uniform scale with a font override: reference text times scale times font/(14*scale).
    let u = custom(0.5, 1.0, Some(15.0), &[("densityScale", 1.1)]);
    assert!(close(u.text_size(12.0, 13.0), 14.0 * 1.1 * (15.0 / (14.0 * 1.1))));

    assert_eq!(custom(0.0, 1.0, None, &[]).space(7.0), 7.0);
    assert_eq!(custom(0.0, 1.3, None, &[]).space(7.0), half(9.1));
    assert_eq!(c.space(2.0), 2.0);
    assert_eq!(c.space(4.0), 3.5);

    assert_eq!(custom(0.0, 1.0, None, &[]).font_token("x"), None);
    assert_eq!(custom(0.0, 1.0, None, &[("x", 10.0)]).font_token("x"), Some(10.0));
    let based = DensityTokens::new(
        "mine",
        "Mine",
        Some("cozy".into()),
        0.5,
        1.0,
        Some(21.0 * 0.9),
        [("x".to_string(), 10.0)].into(),
    );
    assert!(close(based.font_token("x").unwrap(), 10.0 * 18.9 / 14.0));
}

#[test]
fn level_body_and_user_scale() {
    assert_eq!(custom(0.0, 1.0, None, &[]).level_body_size(), 12.0);
    assert_eq!(custom(1.0, 1.0, None, &[]).level_body_size(), 13.0);
    assert_eq!(custom(0.25, 1.0, None, &[]).level_body_size(), 12.5);
    assert_eq!(custom(2.0, 1.0, None, &[]).body_size(), 14.0);
    let cozy = tokens(DensityPreset::Cozy);
    assert_eq!(dt::user_scale(cozy, None, 1.0), 1.0);
    assert_eq!(dt::user_scale(cozy, Some(21.0), 1.0), 1.5);
    assert_eq!(dt::user_scale(cozy, Some(21.0), 2.0), 3.0);
    assert_eq!(dt::sidebar_title_size(&custom(0.0, 1.0, None, &[])), 12.0);
}

#[test]
fn density_ops() {
    let cozy = json_of(tokens(DensityPreset::Cozy));
    let p = op("density_preset", json!({"preset": "compact"}));
    assert_eq!(p["rawValue"], "compact");
    assert_eq!(p["name"], "Compact");
    assert_eq!(p["scaleFactor"], 0.9);
    assert_eq!(p["omnibarScaleFactor"], 0.9);
    assert_eq!(p["tokens"]["tokens"]["tabToOmnibarGap"], 3.5);
    assert_eq!(
        op(
            "density_resolve",
            json!({"density": cozy, "compact": 24, "comfortable": 32, "token": "sidebarRowHeight"})
        ),
        28.0
    );
    assert_eq!(
        op(
            "density_resolve",
            json!({"density": {"id": "x", "name": "X"}, "compact": 24, "comfortable": 32})
        ),
        24.0
    );
    assert_eq!(
        op(
            "density_text_size",
            json!({"density": {"id": "x", "name": "X", "level": 1}, "compact": 12, "comfortable": 13})
        ),
        13.0
    );
    assert_eq!(
        op(
            "density_space",
            json!({"density": {"id": "x", "name": "X", "spacing": 1.3}, "value": 7})
        ),
        9.0
    );
    assert_eq!(op("density_font_token", json!({"density": cozy, "key": "tabTitleSize"})), 14.0);
    assert_eq!(op("density_font_token", json!({"density": cozy, "key": "nope"})), Value::Null);
    let info = op("density_info", json!({"density": cozy}));
    assert_eq!(
        info,
        json!({"family": "comfortable", "isBuiltIn": true, "uniformScale": 1.0, "usesDefaultRowFill": true,
        "levelBodySize": 12.5, "bodySize": 14.0, "sidebarTitleSize": 14.0})
    );
    assert_eq!(
        op("density_user_scale", json!({"density": cozy, "fontOverride": 21, "interfaceScale": 2})),
        3.0
    );
    assert!(matches!(call("tokens.density_nope", &json!({})), Err(OpError::Unknown)));
    assert!(matches!(
        call("tokens.density_preset", &json!({"preset": "huge"})),
        Err(OpError::Invalid(_))
    ));
}

// MARK: - Catalog

#[test]
fn catalog_table_shape() {
    assert_eq!(catalog::ALL.len(), 67);
    assert_eq!(catalog::ALL[0].key, "sidebarRowHeight");
    let mut keys: Vec<_> = catalog::ALL.iter().map(|e| e.key).collect();
    keys.sort_unstable();
    keys.dedup();
    assert_eq!(keys.len(), 67, "keys are unique");
    for e in catalog::ALL {
        assert!(e.range_lower < e.range_upper, "{}", e.key);
        assert!(e.step > 0.0, "{}", e.key);
        assert!(!catalog::UNLISTED_KEYS.contains(&e.key), "{} is listed and unlisted", e.key);
    }
    let row = catalog::entry("sidebarRowHeight").unwrap();
    assert_eq!(
        (row.group, row.section, row.label),
        (Group::VerticalTabs, "Sidebar rows", "Row height")
    );
    assert_eq!((row.range_lower, row.range_upper, row.step), (14.0, 56.0, 0.5));
    assert_eq!(
        (row.unit, row.field, row.fallback),
        (Unit::Points, Field::Token, Fallback::Derived)
    );
    let gap = catalog::entry("sidebarRowGap").unwrap();
    assert_eq!((gap.range_lower, gap.range_upper, gap.fallback), (0.0, 12.0, Fallback::None));
    let spacing = catalog::entry("spacing").unwrap();
    assert_eq!(
        (spacing.range_lower, spacing.range_upper, spacing.step, spacing.unit, spacing.field),
        (0.5, 2.0, 0.05, Unit::Factor, Field::Spacing)
    );
    let font = catalog::entry("fontSize").unwrap();
    assert_eq!(
        (font.range_lower, font.range_upper, font.step, font.field),
        (9.0, 20.0, 0.25, Field::FontSize)
    );
    assert_eq!(catalog::entry("tabTitleDrop").unwrap().fallback, Fallback::Constant(0.0));
    assert_eq!(catalog::entry("densityScale").unwrap().fallback, Fallback::Constant(1.0));
    assert_eq!(catalog::entry("composerZoom").unwrap().fallback, Fallback::Constant(1.0));
    assert!(catalog::entry("nope").is_none());
    assert_eq!(catalog::UNLISTED_KEYS.len(), 19);
    let titles: Vec<_> = Group::ALL.iter().map(|g| g.title()).collect();
    assert_eq!(titles, ["Vertical tabs", "Horizontal tabs", "Other"]);
}

/// DensityPlaygroundTests.builtInsDoNotSetThePlaygroundsNewKeys.
#[test]
fn built_ins_do_not_set_the_playgrounds_new_keys() {
    let added = [
        "sidebarRowGap",
        "sidebarCornerRadius",
        "sidebarGroupIndent",
        "sidebarHeadingSize",
        "sidebarSectionGap",
        "sidebarBandGap",
        "sidebarStatusDot",
        "verticalTabRowHeight",
        "verticalTabRowGap",
        "verticalTabPadding",
        "verticalTabIconSize",
        "verticalTabHeaderHeight",
        "verticalTabIndent",
        "verticalTabCornerRadius",
        "verticalTabTileSize",
        "verticalTabWidth",
        "tabStripEndGap",
        "tabCloseSize",
        "tabCloseGlyphSize",
        "tabCloseCornerRadius",
        "tabTrailingInset",
        "chatTextScale",
        "homeTextScale",
    ];
    for p in DensityPreset::ALL {
        let set: Vec<_> = added.iter().filter(|k| p.tokens().token(k).is_some()).collect();
        assert!(set.is_empty(), "{p:?} sets {set:?}");
    }
}

/// DensityPlaygroundTests.editingABuiltInMakesACopy (the catalog part): setting the row gap on a
/// copy sets it there and leaves the built-in alone; resetting goes back.
#[test]
fn setting_on_a_copy_leaves_the_built_in() {
    let compact = tokens(DensityPreset::Compact);
    let copy = DensityTokens::new(
        "c1",
        "Compact Custom",
        Some("compact".into()),
        compact.level,
        compact.spacing,
        compact.font_size,
        compact.tokens.clone(),
    );
    let gap = catalog::entry("sidebarRowGap").unwrap();
    let edited = catalog::setting(gap, 5.0, &copy);
    assert_eq!(edited.token("sidebarRowGap"), Some(5.0));
    assert_eq!(
        (edited.id.as_str(), edited.name.as_str(), edited.based_on.as_deref()),
        ("c1", "Compact Custom", Some("compact"))
    );
    assert_eq!(compact.token("sidebarRowGap"), None);
    assert!(catalog::differs(gap, &edited, catalog::base(&edited)));
    let reset = catalog::resetting(gap, &edited, catalog::base(&edited));
    assert_eq!(reset.token("sidebarRowGap"), None);
    assert!(!catalog::differs(gap, &reset, catalog::base(&reset)));
    // The playground's own settings (DensityPlaygroundTests line 136).
    let mut mine = tokens(DensityPreset::Cozy).clone();
    for (k, v) in
        [("sidebarRowHeight", 40.0), ("verticalTabRowHeight", 44.0), ("sidebarRowGap", 6.0)]
    {
        mine = catalog::setting(catalog::entry(k).unwrap(), v, &mine);
    }
    assert_eq!(
        (
            mine.token("sidebarRowHeight"),
            mine.token("verticalTabRowHeight"),
            mine.token("sidebarRowGap")
        ),
        (Some(40.0), Some(44.0), Some(6.0))
    );
}

#[test]
fn setting_clamps_snaps_and_ignores_non_finite() {
    let d = custom(0.5, 1.0, None, &[]);
    let gap = catalog::entry("sidebarRowGap").unwrap();
    assert_eq!(catalog::setting(gap, 5.3, &d).token("sidebarRowGap"), Some(5.5));
    assert_eq!(catalog::setting(gap, 5.2, &d).token("sidebarRowGap"), Some(5.0));
    assert_eq!(catalog::setting(gap, 100.0, &d).token("sidebarRowGap"), Some(12.0));
    assert_eq!(catalog::setting(gap, -3.0, &d).token("sidebarRowGap"), Some(0.0));
    assert_eq!(catalog::setting(gap, f64::NAN, &d), d);
    let spacing = catalog::entry("spacing").unwrap();
    assert!(close(catalog::setting(spacing, 1.23, &d).spacing, 1.25));
    assert_eq!(catalog::setting(spacing, 9.0, &d).spacing, 2.0);
    let font = catalog::entry("fontSize").unwrap();
    assert_eq!(catalog::setting(font, 13.1, &d).font_size, Some(13.0));
    assert_eq!(catalog::setting(font, 13.2, &d).font_size, Some(13.25));
}

#[test]
fn explicit_value_and_value_reads() {
    let cozy = tokens(DensityPreset::Cozy);
    let mine = custom(0.5, 1.2, None, &[("sidebarRowGap", 4.0)]);
    let e = |k: &str| catalog::entry(k).unwrap();
    assert_eq!(catalog::explicit_value(e("sidebarRowGap"), &mine), Some(4.0));
    assert_eq!(catalog::explicit_value(e("sidebarRowHeight"), &mine), None);
    assert_eq!(catalog::explicit_value(e("spacing"), &mine), Some(1.2));
    assert_eq!(catalog::explicit_value(e("fontSize"), &mine), None);
    // Font size falls back to the body.
    assert_eq!(catalog::value(e("fontSize"), &mine, None, 1.0), Some(12.5));
    // A scoped fallback, then a constant, are divided by the interface scale.
    assert_eq!(catalog::value(e("sidebarRowHeight"), &mine, Some(30.0), 2.0), Some(15.0));
    assert_eq!(catalog::value(e("densityScale"), &mine, None, 2.0), Some(0.5));
    assert_eq!(catalog::value(e("densityScale"), &mine, None, 0.0), Some(100.0));
    assert_eq!(catalog::value(e("tabTitleDrop"), &mine, None, 1.0), Some(0.0));
    // A derived fallback with no scoped value reads the base (Default here).
    assert_eq!(catalog::value(e("sidebarRowHeight"), &mine, None, 1.0), Some(28.0));
    assert_eq!(catalog::value(e("sidebarRowGap"), cozy, None, 1.0), None);
    assert_eq!(catalog::value(e("densityScale"), cozy, None, 2.0), Some(1.0));
}

#[test]
fn base_resetting_all_and_differs() {
    let compact = tokens(DensityPreset::Compact);
    assert_eq!(catalog::base(compact), compact);
    let based =
        DensityTokens::new("x", "X", Some("spacious".into()), 0.0, 1.0, None, BTreeMap::new());
    assert_eq!(catalog::base(&based), tokens(DensityPreset::Spacious));
    assert_eq!(catalog::base(&custom(0.0, 1.0, None, &[])), tokens(DensityPreset::Cozy));
    let mine = custom(2.0, 1.5, Some(16.0), &[("q", 1.0)]);
    let all = catalog::resetting_all(&mine, compact);
    assert_eq!(
        (all.id.as_str(), all.level, all.spacing, all.font_size),
        ("mine", compact.level, 0.9, compact.font_size)
    );
    assert_eq!(all.tokens, compact.tokens);
    let gap = catalog::entry("sidebarRowGap").unwrap();
    let a = custom(0.0, 1.0, None, &[("sidebarRowGap", 4.0)]);
    let b = custom(0.0, 1.0, None, &[("sidebarRowGap", 4.00005)]);
    let c = custom(0.0, 1.0, None, &[("sidebarRowGap", 4.001)]);
    assert!(!catalog::differs(gap, &a, &b));
    assert!(catalog::differs(gap, &a, &c));
    assert!(catalog::differs(gap, &a, &custom(0.0, 1.0, None, &[])));
    let spacing = catalog::entry("spacing").unwrap();
    assert!(catalog::differs(spacing, &custom(0.0, 1.2, None, &[]), &a));
    let reset = catalog::resetting(spacing, &custom(0.0, 1.2, None, &[]), &a);
    assert_eq!(reset.spacing, 1.0);
}

#[test]
fn catalog_ops() {
    let entries = op("density_entries", json!({}));
    assert_eq!(entries.as_array().unwrap().len(), 67);
    let e = op("density_entry", json!({"key": "densityScale"}));
    assert_eq!(e["key"], "densityScale");
    assert_eq!(e["fallback"], json!({"kind": "constant", "value": 1.0}));
    assert_eq!(e["unit"], "factor");
    assert_eq!(op("density_entry", json!({"key": "nope"})), Value::Null);
    assert_eq!(op("density_group_title", json!({"group": "horizontalTabs"})), "Horizontal tabs");
    assert_eq!(op("density_unlisted_keys", json!({})).as_array().unwrap().len(), 19);
    let mine = json!({"id": "mine", "name": "Mine", "level": 0.5, "tokens": {"sidebarRowGap": 4}});
    assert_eq!(op("density_explicit_value", json!({"key": "sidebarRowGap", "density": mine})), 4.0);
    assert_eq!(
        op("density_value", json!({"key": "densityScale", "density": mine, "interfaceScale": 2})),
        0.5
    );
    assert_eq!(
        op("density_value", json!({"key": "sidebarRowHeight", "density": mine, "fallback": 30})),
        30.0
    );
    let set = op("density_setting", json!({"key": "sidebarRowGap", "value": 5.3, "density": mine}));
    assert_eq!(set["tokens"]["sidebarRowGap"], 5.5);
    let cozy = json_of(tokens(DensityPreset::Cozy));
    let reset =
        op("density_resetting", json!({"key": "sidebarRowGap", "density": mine, "base": cozy}));
    assert_eq!(reset["tokens"].get("sidebarRowGap"), None);
    let all = op("density_resetting_all", json!({"density": mine, "base": cozy}));
    assert_eq!(all["id"], "mine");
    assert_eq!(all["tokens"]["tabStripHeight"], 40.0);
    assert_eq!(
        op("density_differs", json!({"key": "sidebarRowGap", "density": mine, "base": cozy})),
        true
    );
    assert_eq!(
        op("density_base", json!({"density": {"id": "x", "name": "X", "basedOn": "compact"}}))["id"],
        "compact"
    );
    match call("tokens.density_value", &json!({"key": "nope", "density": mine})) {
        Err(OpError::Invalid(m)) => assert_eq!(m, "no density entry nope"),
        other => panic!("{other:?}"),
    }
}

// MARK: - Typography+PageDensity

/// PageRowScaleTests: per preset, the row text scale is `t` times the user scale, the icon scale is
/// the half-point tab icon over Default's, and the page density scale is `t`.
#[test]
fn page_row_scales_follow_the_preset() {
    for p in DensityPreset::ALL {
        let d = p.tokens();
        let t = p.scale_factor();
        assert!((page::page_row_text_scale(d, user(d)) - t * user(d)).abs() < 1e-4, "{p:?}");
        let icon = d.token("tabIconSize").unwrap();
        assert_eq!(page::page_row_icon_scale(icon), (16.5 * t * 2.0).round() / 2.0 / 16.5, "{p:?}");
        assert!((page_density(d, 1.0) - t).abs() < 1e-4, "{p:?}");
    }
}

#[test]
fn page_density_scale_pins() {
    // Uniform scale times interface scale.
    assert_eq!(page_density(tokens(DensityPreset::Compact), 2.0), 1.8);
    // No uniform scale: the row over Default's 30.
    let mine = custom(1.0, 1.0, None, &[]);
    assert_eq!(page_density(&mine, 1.0), 32.0 / 30.0);
    assert_eq!(page::page_density_scale(&mine, 1.0, 45.0, 30.0), 1.5);
    assert_eq!(page::page_row_icon_scale(16.5), 1.0);
    assert_eq!(page::page_row_icon_scale(33.0), 2.0);
    assert_eq!(page::page_row_text_scale(&custom(0.0, 1.0, None, &[]), 2.0), 12.0 / 14.0 * 2.0);
}

/// ChatTextScaleTests.
#[test]
fn chat_text_scale_is_defaults_at_every_preset() {
    let cozy = tokens(DensityPreset::Cozy);
    let default = page::page_chat_text_scale(cozy, None, 1.0);
    assert_eq!(default, 1.0);
    let default_large = page::page_chat_text_scale(cozy, Some(15.6), 1.0);
    assert!(default_large > 1.1);
    for p in DensityPreset::ALL {
        assert_eq!(page::page_chat_text_scale(p.tokens(), None, 1.0), default, "{p:?}");
        assert_eq!(page::page_chat_text_scale(p.tokens(), Some(15.6), 1.0), default_large, "{p:?}");
    }
    let chat = page::chat_user_scale(Some(14.0), 1.0);
    assert_eq!(chat, 1.0);
    assert_eq!(page::chat_user_scale(None, 2.0), 2.0);
    assert_eq!(page::chat_user_scale(Some(21.0), 1.0), 1.5);
    // A density's chat scale token multiplies Default's body.
    let mine = custom(0.0, 1.0, None, &[("chatTextScale", 1.25)]);
    assert_eq!(page::page_chat_text_scale(&mine, None, 2.0), 2.5);
    assert_eq!(page::page_chat_text_scale(&mine, Some(7.0), 1.0), 0.5);
}

#[test]
fn page_density_text_and_home_scale() {
    let compact = tokens(DensityPreset::Compact);
    assert!(close(page::page_density_text_scale(compact, None, 1.0), 0.9));
    assert_eq!(page::page_density_text_scale(compact, Some(21.0), 2.0), 3.0);
    assert_eq!(page::home_chat_density_scale(compact), 1.0);
    assert_eq!(
        page::home_chat_density_scale(&custom(0.0, 1.0, None, &[("homeTextScale", 1.3)])),
        1.3
    );
}

#[test]
fn page_ops() {
    let compact = json_of(tokens(DensityPreset::Compact));
    let mine = json!({"id": "mine", "name": "Mine", "level": 1});
    assert_eq!(
        op("density_page_density_scale", json!({"density": compact, "interfaceScale": 2})),
        1.8
    );
    assert_eq!(op("density_page_density_scale", json!({"density": mine})), 32.0 / 30.0);
    assert_eq!(op("density_page_density_scale", json!({"density": mine, "rowOverride": 45})), 1.5);
    let row_text = op("density_page_row_text_scale", json!({"density": compact})).as_f64().unwrap();
    assert!((row_text - 0.9).abs() < 1e-4);
    assert_eq!(op("density_page_row_icon_scale", json!({"tabIconSize": 15})), 15.0 / 16.5);
    assert_eq!(
        op(
            "density_page_density_text_scale",
            json!({"density": compact, "fontOverride": 21, "interfaceScale": 2})
        ),
        3.0
    );
    assert_eq!(
        op("density_page_chat_text_scale", json!({"density": compact, "fontOverride": 21})),
        1.5
    );
    assert_eq!(op("density_chat_user_scale", json!({"interfaceScale": 2})), 2.0);
    assert_eq!(
        op(
            "density_home_chat_density_scale",
            json!({"density": {"id": "m", "name": "M", "tokens": {"homeTextScale": 1.3}}})
        ),
        1.3
    );
}

// MARK: - CardScale

/// CardScaleDensityTests.defaultIsTheOldCardSizes.
#[test]
fn card_default_is_the_old_sizes() {
    let cozy = tokens(DensityPreset::Cozy);
    let factor = page::card_text_factor(cozy, user(cozy));
    assert_eq!(factor, 1.0);
    let s = page::card_sizes(factor);
    assert_eq!(
        (s.title, s.message, s.body, s.body_digits, s.button, s.caption, s.dialog_title),
        (13.0, 13.0, 12.0, 12.0, 12.0, 11.0, 15.0)
    );
    let m = page::card_metrics(spaces(cozy, 1.0), 9.0);
    assert_eq!(m.card_padding, 8.0 + 2.0);
    assert_eq!(
        (m.card_text_gap, m.card_row_gap, m.card_corner_radius, m.dialog_padding),
        (2.0, 6.0, 19.0, 16.0)
    );
    // Text Size scales the cards.
    let big = page::card_sizes(page::card_text_factor(cozy, dt::user_scale(cozy, Some(21.0), 1.0)));
    assert_eq!((big.title, big.body, big.caption), (19.5, 18.0, 16.5));
}

/// CardScaleDensityTests: per preset the card sits under the sidebar title, sizes step down and
/// stay on the half-point grid, and the card corner is the button corner around the padding.
#[test]
fn card_scale_follows_every_preset() {
    let mut last: Option<(f64, f64, f64, f64)> = None;
    for p in DensityPreset::ALL {
        let d = p.tokens();
        let u = user(d);
        let s = page::card_sizes(page::card_text_factor(d, u));
        assert!(s.title < dt::sidebar_title_size(d) * u, "{p:?}");
        assert!(s.body < s.title && s.caption < s.body, "{p:?}");
        for v in [s.title, s.body, s.caption] {
            assert_eq!(v, half(v), "{p:?}");
        }
        let bcr = d.token("tabCornerRadius").unwrap();
        let m = page::card_metrics(spaces(d, 1.0), bcr);
        assert_eq!(
            m.card_corner_radius,
            metrics::button_container(bcr, m.card_padding).outer_radius()
        );
        if let Some((title, body, caption, padding)) = last {
            assert!(s.title > title && s.body > body && s.caption > caption, "{p:?} text grows");
            assert!(m.card_padding >= padding, "{p:?} padding never shrinks");
        }
        last = Some((s.title, s.body, s.caption, m.card_padding));
    }
    let titles: Vec<_> = DensityPreset::ALL
        .iter()
        .map(|p| page::card_sizes(page::card_text_factor(p.tokens(), 1.0)).title)
        .collect();
    assert_eq!(titles, [10.5, 11.5, 13.0, 14.5, 15.5]);
    let paddings: Vec<_> = DensityPreset::ALL
        .iter()
        .map(|p| page::card_metrics(spaces(p.tokens(), 1.0), 0.0).card_padding)
        .collect();
    assert_eq!(paddings, [8.0, 9.0, 10.0, 11.0, 12.0]);
}

#[test]
fn card_size_and_type_scale() {
    assert_eq!(
        [
            type_scale::CAPTION,
            type_scale::DETAIL,
            type_scale::BODY,
            type_scale::FIELD,
            type_scale::TITLE,
            type_scale::HEADING
        ],
        [11.0, 12.0, 13.0, 14.0, 15.0, 20.0]
    );
    assert_eq!(page::card_size(13.0, 0.9), 11.5);
    assert_eq!(page::card_size(12.0, 1.125), 13.5);
    // A custom density at level 0 without a font: 12/14 of the old sizes.
    assert_eq!(page::card_text_factor(&custom(0.0, 1.0, None, &[]), 1.0), 12.0 / 14.0);
}

#[test]
fn card_ops() {
    let cozy = json_of(tokens(DensityPreset::Cozy));
    let s = op("density_card_sizes", json!({"density": cozy}));
    assert_eq!(
        s,
        json!({"factor": 1.0, "title": 13.0, "message": 13.0, "body": 12.0, "bodyDigits": 12.0, "button": 12.0, "caption": 11.0, "dialogTitle": 15.0})
    );
    let m = op("density_card_metrics", json!({"density": cozy, "buttonCornerRadius": 9}));
    assert_eq!(
        m,
        json!({"cardPadding": 10.0, "cardTextGap": 2.0, "cardRowGap": 6.0, "cardCornerRadius": 19.0, "dialogPadding": 16.0})
    );
    let scaled = op(
        "density_card_metrics",
        json!({"density": cozy, "buttonCornerRadius": 9, "interfaceScale": 2}),
    );
    assert_eq!(scaled["cardPadding"], 20.0);
    let bases = op(
        "density_card_metrics",
        json!({"density": cozy, "buttonCornerRadius": 0, "spaceBases": [1, 1, 1, 5, 1, 9]}),
    );
    assert_eq!(
        (bases["cardPadding"].as_f64(), bases["dialogPadding"].as_f64()),
        (Some(6.0), Some(9.0))
    );
}
