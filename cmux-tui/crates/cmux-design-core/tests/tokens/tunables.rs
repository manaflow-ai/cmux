//! Parity tests for `tokens::tunables`: BrowserChromeTuningTests, TokenMemoTests and the
//! NoBounceSpringTests clamp case, plus pins of today's Swift outputs computed from the formulas.

use cmux_design_core::ops::{OpError, call};
use cmux_design_core::tokens::density::{DensityPreset, DensityTokens};
use cmux_design_core::tokens::tunables::browser_chrome::{self as bc, BrowserChromeMetric as M};
use cmux_design_core::tokens::tunables::descriptor::{
    self as d, SpringParameters, TunableChoiceOption, TunableKind, TunableReadCadence, TunableUnit,
    TunableValue,
};
use cmux_design_core::tokens::tunables::floating_pane as fp;
use cmux_design_core::tokens::tunables::memo::{self, MemoEvent, MemoRead, MemoState};
use serde_json::json;
use std::collections::{BTreeMap, HashSet};

fn half(v: f64) -> f64 {
    (v * 2.0).round() / 2.0
}

fn custom(tokens: &[(&str, f64)]) -> DensityTokens {
    DensityTokens::new(
        "custom-1",
        "Mine",
        None,
        0.5,
        1.0,
        None,
        tokens.iter().map(|(k, v)| (k.to_string(), *v)).collect(),
    )
}

fn overrides(pairs: &[(&str, TunableValue)]) -> BTreeMap<String, TunableValue> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

// MARK: BrowserChromeTuningTests

#[test]
fn every_density_lists_every_metric_once() {
    let keys: Vec<String> = bc::descriptors().into_iter().map(|d| d.key).collect();
    assert_eq!(keys.len(), bc::DENSITIES.len() * M::ALL.len());
    assert_eq!(keys.len(), 36);
    assert_eq!(keys.iter().collect::<HashSet<_>>().len(), keys.len());
    assert!(keys.contains(&"browserChrome.cozy.closeSize".to_string()));
    assert_eq!(keys[0], "browserChrome.compact.rowHeight");
    assert_eq!(keys[35], "browserChrome.spacious.textOrigin");
}

#[test]
fn an_override_belongs_to_one_density() {
    let store = overrides(&[
        (&bc::key(M::CloseSize, DensityPreset::Cozy), TunableValue::Number(16.0)),
        ("browserChrome.ultraCompact.closeSize", TunableValue::Number(9.0)),
    ]);
    assert_eq!(bc::override_value(M::CloseSize, "cozy", &store), Some(16.0));
    assert_eq!(bc::override_value(M::CloseSize, "compact", &store), None);
    // Ultra-compact is not a tunable density, even with a key stored.
    assert_eq!(bc::override_value(M::CloseSize, "ultraCompact", &store), None);
    assert_eq!(bc::override_value(M::CloseSize, "custom-1", &store), None);
    let wrong = overrides(&[("browserChrome.cozy.closeSize", TunableValue::Bool(true))]);
    assert_eq!(bc::override_value(M::CloseSize, "cozy", &wrong), None);
    let reply = call(
        "tokens.tunables_browser_chrome_override",
        &json!({"metric": "closeSize", "tokensId": "cozy", "overrides": {"browserChrome.cozy.closeSize": {"number": 16}}}),
    );
    assert_eq!(reply, Ok(json!(16.0)));
}

#[test]
fn defaults_follow_the_reference() {
    for preset in [
        DensityPreset::Compact,
        DensityPreset::Cozy,
        DensityPreset::Comfortable,
        DensityPreset::Spacious,
    ] {
        let tokens = preset.tokens();
        let derived = |m: M| bc::default_value(m, tokens, None);
        let t = preset.scale_factor();
        assert_eq!(Some(derived(M::RowHeight)), tokens.token("browserRowHeight"), "{preset:?}");
        let nudge = if preset == DensityPreset::Spacious { 0.5 } else { 0.0 };
        let row_gap = if t >= 1.0 { half(5.0 * t) + nudge } else { half(3.0 * t) };
        assert_eq!(derived(M::RowGap), row_gap, "{preset:?}");
        assert_eq!(derived(M::CloseSize), half(15.0 * t), "{preset:?}");
        assert_eq!(derived(M::CloseCorner), half(4.5 * t), "{preset:?}");
        assert_eq!(derived(M::CloseInk), half(8.5 * t), "{preset:?}");
        assert_eq!(derived(M::CloseTrailing), half(6.5 * t), "{preset:?}");
        let o = preset.omnibar_scale_factor();
        assert_eq!(derived(M::ChipLeading), half(2.0 * o), "{preset:?}");
        let bar = if preset == DensityPreset::Cozy { 34.0 } else { half(28.0 / 0.9 * o) };
        let expected =
            half(2.0 * o) + (half(25.0 * o)).min(bar - 2.0 * half(2.0 * o)) + half(5.0 * o);
        assert_eq!(derived(M::TextOrigin), expected, "{preset:?}");
        assert_eq!(derived(M::CloseHoverOpacity), 16.0);
    }
}

// MARK: Pinned values

#[test]
fn default_and_compact_by_hand() {
    let cozy = DensityPreset::Cozy.tokens();
    assert_eq!(bc::default_value(M::CloseSize, cozy, None), 15.0);
    assert_eq!(bc::default_value(M::CloseCorner, cozy, None), 4.5);
    assert_eq!(bc::default_value(M::CloseInk, cozy, None), 8.5);
    assert_eq!(bc::default_value(M::CloseTrailing, cozy, None), 6.5);
    assert_eq!(bc::default_value(M::ChipLeading, cozy, None), 2.0);
    assert_eq!(bc::default_value(M::TextOrigin, cozy, None), 29.0);
    assert_eq!(bc::default_value(M::RowHeight, cozy, None), 30.0);
    assert_eq!(bc::default_value(M::RowGap, cozy, None), 5.0);
    let compact = DensityPreset::Compact.tokens();
    assert_eq!(bc::default_value(M::CloseSize, compact, None), 13.5);
    assert_eq!(bc::default_value(M::CloseCorner, compact, None), 4.0);
    assert_eq!(bc::default_value(M::CloseInk, compact, None), 7.5);
    assert_eq!(bc::default_value(M::CloseTrailing, compact, None), 6.0);
    // A uniform scale sizes from the reference row, not the live one.
    assert_eq!(bc::default_value(M::CloseSize, cozy, Some(40.0)), 15.0);
}

#[test]
fn a_custom_density_keeps_heliums_values() {
    let empty = custom(&[]);
    assert_eq!(bc::default_value(M::RowHeight, &empty, None), 0.0);
    assert_eq!(bc::default_value(M::RowGap, &empty, None), 0.0);
    assert_eq!(bc::default_value(M::CloseSize, &empty, None), 14.0);
    assert_eq!(bc::default_value(M::CloseCorner, &empty, None), 4.0);
    assert_eq!(bc::default_value(M::CloseInk, &empty, None), 8.0);
    assert_eq!(bc::default_value(M::CloseTrailing, &empty, None), 6.0);
    assert_eq!(bc::default_value(M::ChipLeading, &empty, None), 2.0);
    assert_eq!(bc::default_value(M::TextOrigin, &empty, None), 31.0);
    // A 20 pt row: 10, 3, 5.5, 4.5 of Helium's shares.
    assert_eq!(bc::default_value(M::CloseSize, &empty, Some(20.0)), 10.0);
    assert_eq!(bc::default_value(M::CloseCorner, &empty, Some(20.0)), 3.0);
    assert_eq!(bc::default_value(M::CloseInk, &empty, Some(20.0)), 5.5);
    assert_eq!(bc::default_value(M::CloseTrailing, &empty, Some(20.0)), 4.5);
    // The density's own tokens win.
    let own =
        custom(&[("tabCloseSize", 11.0), ("tabCloseGlyphSize", 7.0), ("browserRowHeight", 26.0)]);
    assert_eq!(bc::default_value(M::CloseSize, &own, None), 11.0);
    assert_eq!(bc::default_value(M::CloseInk, &own, None), 7.0);
    assert_eq!(bc::default_value(M::RowHeight, &own, None), 26.0);
    // The bar is under the view: min(25, 20 - 2 * 4) = 12.
    let bar = custom(&[
        ("omnibarIconLeading", 2.0),
        ("omnibarIconViewSize", 25.0),
        ("omnibarTextGap", 5.0),
        ("omnibarHeight", 20.0),
        ("omnibarEdgeInset", 4.0),
    ]);
    assert_eq!(bc::default_value(M::TextOrigin, &bar, None), 19.0);
    assert_eq!(bc::default_value(M::ChipLeading, &bar, None), 2.0);
    // Chrome's column.
    let chrome = custom(&[("omnibarChromeColumn", 1.0), ("omnibarHeight", 30.0)]);
    assert!(bc::uses_chrome_column(&chrome));
    assert_eq!(bc::default_value(M::ChipLeading, &chrome, None), 9.0);
    assert_eq!(bc::default_value(M::TextOrigin, &chrome, None), 45.0);
    let reply = call(
        "tokens.tunables_browser_chrome_default",
        &json!({"metric": "textOrigin", "tokens": {"id": "x", "name": "X", "tokens": {"omnibarChromeColumn": 1, "omnibarHeight": 30}}}),
    );
    assert_eq!(reply, Ok(json!(45.0)));
    let reply = call(
        "tokens.tunables_browser_chrome_default",
        &json!({"metric": "closeSize", "density": "compact"}),
    );
    assert_eq!(reply, Ok(json!(13.5)));
    assert!(matches!(
        call("tokens.tunables_browser_chrome_default", &json!({"metric": "closeSize"})),
        Err(OpError::Invalid(_))
    ));
}

#[test]
fn chip_and_text_by_bar() {
    assert_eq!(bc::chip_leading(28.0, false), 2.0);
    assert_eq!(bc::chip_leading(20.0, false), 2.0);
    assert_eq!(bc::chip_leading(56.0, false), 4.0);
    assert_eq!(bc::text_origin(28.0, false), 31.0);
    assert_eq!(bc::text_origin(20.0, false), 22.0);
    assert_eq!(bc::chip_leading(30.0, true), 9.0);
    assert_eq!(bc::text_origin(30.0, true), 45.0);
    assert_eq!(bc::chip_leading(36.0, true), 10.0);
    assert_eq!(bc::text_origin(36.0, true), 53.0);
    // A tiny bar: the chip floor is 2, the text gap floor 5.
    assert_eq!(bc::chip_leading(4.0, true), 3.0);
    assert_eq!(bc::text_origin(4.0, true), 11.0);
    assert_eq!(bc::share(14.0, 30.0), 15.0);
    assert_eq!(bc::share(8.0, 30.0), 8.5);
    assert_eq!(
        call(
            "tokens.tunables_browser_chrome_chip_leading",
            &json!({"bar": 36, "chromeColumn": true})
        ),
        Ok(json!(10.0))
    );
    assert_eq!(
        call("tokens.tunables_browser_chrome_text_origin", &json!({"bar": 28})),
        Ok(json!(31.0))
    );
    assert_eq!(
        call("tokens.tunables_browser_chrome_share", &json!({"points": 6, "row": 30})),
        Ok(json!(6.5))
    );
}

#[test]
fn the_value_is_the_override_else_the_default() {
    let cozy = DensityPreset::Cozy.tokens();
    let store = overrides(&[("browserChrome.cozy.closeInk", TunableValue::Number(10.0))]);
    assert_eq!(bc::value(M::CloseInk, cozy, None, &store), 10.0);
    assert_eq!(bc::value(M::CloseSize, cozy, None, &store), 15.0);
    let reply = call(
        "tokens.tunables_browser_chrome_value",
        &json!({"metric": "closeInk", "density": "cozy", "overrides": {"browserChrome.cozy.closeInk": {"number": 10}}}),
    );
    assert_eq!(reply, Ok(json!(10.0)));
}

#[test]
fn metric_tables() {
    assert_eq!(M::RowHeight.token(), Some("browserRowHeight"));
    assert_eq!(M::RowGap.token(), Some("browserRowGap"));
    assert_eq!(M::CloseSize.token(), None);
    assert_eq!(M::CloseSize.density_key(), Some("tabCloseSize"));
    assert_eq!(M::CloseInk.density_key(), Some("tabCloseGlyphSize"));
    assert_eq!(M::CloseCorner.density_key(), Some("tabCloseCornerRadius"));
    assert_eq!(M::CloseTrailing.density_key(), Some("tabTrailingInset"));
    assert_eq!(M::TextOrigin.density_key(), None);
    assert_eq!(M::RowHeight.range(), (16.0, 48.0));
    assert_eq!(M::RowGap.range(), (0.0, 12.0));
    assert_eq!(M::CloseInk.range(), (4.0, 28.0));
    assert_eq!(M::ChipLeading.range(), (0.0, 16.0));
    assert_eq!(M::TextOrigin.range(), (10.0, 60.0));
    assert_eq!(M::CloseHoverOpacity.range(), (0.0, 40.0));
    assert_eq!(M::CloseTrailing.label(), "Close to tab end");
    for m in M::ALL {
        assert_eq!(M::from_raw(m.raw()), Some(m));
    }
    assert_eq!(bc::key(M::CloseSize, DensityPreset::Spacious), "browserChrome.spacious.closeSize");
    let reply =
        call("tokens.tunables_browser_chrome_metric", &json!({"metric": "closeInk"})).unwrap();
    assert_eq!(reply["densityKey"], json!("tabCloseGlyphSize"));
    assert_eq!(reply["help"], json!("Side of the x's ink. Helium: 8."));
    assert_eq!(reply["range"], json!([4.0, 28.0]));
    assert_eq!(
        call(
            "tokens.tunables_browser_chrome_key",
            &json!({"metric": "rowGap", "density": "compact"})
        ),
        Ok(json!("browserChrome.compact.rowGap"))
    );
}

#[test]
fn browser_chrome_descriptors() {
    let all = bc::descriptors();
    let cozy_close = all.iter().find(|d| d.key == "browserChrome.cozy.closeSize").unwrap();
    assert_eq!(cozy_close.label, "Default: Close square");
    assert_eq!(cozy_close.code_name.as_deref(), Some("BrowserChromeTuning.closeSize"));
    assert_eq!(cozy_close.kind, TunableKind::number((4.0, 28.0), 0.5, TunableUnit::Points));
    assert_eq!(cozy_close.default_value(), &TunableValue::Number(15.0));
    assert_eq!(cozy_close.section, bc::section());
    assert_eq!(cozy_close.section.order, 14);
    assert_eq!(cozy_close.read_cadence, TunableReadCadence::Live);
    let reply = call("tokens.tunables_browser_chrome_descriptors", &json!({})).unwrap();
    assert_eq!(reply["descriptors"].as_array().unwrap().len(), 36);
    assert_eq!(reply["section"]["id"], json!("browserChrome"));
}

// MARK: Descriptor, kind, formatting

#[test]
fn a_spring_override_is_clamped_to_the_limits() {
    let lowest = TunableKind::Spring
        .clamp(&TunableValue::Spring(SpringParameters { response: 0.2, damping_fraction: 0.0 }));
    assert_eq!(
        lowest,
        Some(TunableValue::Spring(SpringParameters { response: 0.2, damping_fraction: 1.0 }))
    );
    let high = TunableKind::Spring
        .clamp(&TunableValue::Spring(SpringParameters { response: 5.0, damping_fraction: 2.0 }));
    assert_eq!(
        high,
        Some(TunableValue::Spring(SpringParameters { response: 2.0, damping_fraction: 1.5 }))
    );
    let fast = TunableKind::Spring
        .clamp(&TunableValue::Spring(SpringParameters { response: 0.0, damping_fraction: 1.2 }));
    assert_eq!(
        fast,
        Some(TunableValue::Spring(SpringParameters { response: 0.02, damping_fraction: 1.2 }))
    );
    let nan = TunableKind::Spring.clamp(&TunableValue::Spring(SpringParameters {
        response: f64::NAN,
        damping_fraction: 1.0,
    }));
    assert_eq!(nan, None);
    let reply = call(
        "tokens.tunables_clamp",
        &json!({"kind": "spring", "value": {"spring": {"response": 0.2, "dampingFraction": 0}}}),
    );
    assert_eq!(reply, Ok(json!({"spring": {"response": 0.2, "dampingFraction": 1.0}})));
}

#[test]
fn kinds_clamp_their_own_values() {
    let fraction = TunableKind::number((0.0, 1.0), 0.05, TunableUnit::Fraction);
    assert_eq!(fraction.clamp(&TunableValue::Number(2.0)), Some(TunableValue::Number(1.0)));
    assert_eq!(fraction.clamp(&TunableValue::Number(-1.0)), Some(TunableValue::Number(0.0)));
    assert_eq!(fraction.clamp(&TunableValue::Number(0.4)), Some(TunableValue::Number(0.4)));
    assert_eq!(fraction.clamp(&TunableValue::Number(f64::INFINITY)), None);
    assert_eq!(fraction.clamp(&TunableValue::Number(f64::NAN)), None);
    assert_eq!(fraction.clamp(&TunableValue::Bool(true)), None);
    assert_eq!(
        TunableKind::Bool.clamp(&TunableValue::Bool(false)),
        Some(TunableValue::Bool(false))
    );
    assert_eq!(
        TunableKind::Color.clamp(&TunableValue::Color("danger".into())),
        Some(TunableValue::Color("danger".into()))
    );
    assert_eq!(TunableKind::Color.clamp(&TunableValue::Number(1.0)), None);
    let choice = TunableKind::Choice(vec![
        TunableChoiceOption::new("a", "A"),
        TunableChoiceOption::new("b", "B"),
    ]);
    assert_eq!(
        choice.clamp(&TunableValue::Choice("b".into())),
        Some(TunableValue::Choice("b".into()))
    );
    assert_eq!(choice.clamp(&TunableValue::Choice("c".into())), None);
    let reply = call(
        "tokens.tunables_clamp",
        &json!({"kind": {"number": {"range": [4, 24], "step": 1, "unit": "points"}}, "value": {"number": 30}}),
    );
    assert_eq!(reply, Ok(json!({"number": 24.0})));
    let reply = call(
        "tokens.tunables_clamp",
        &json!({"kind": {"choice": [{"value": "a", "title": "A"}]}, "value": {"choice": "z"}}),
    );
    assert_eq!(reply, Ok(json!(null)));
}

#[test]
fn read_cadence() {
    assert_eq!(TunableReadCadence::default(), TunableReadCadence::Live);
    assert_eq!(TunableReadCadence::from_raw("launch"), Some(TunableReadCadence::Launch));
    assert_eq!(TunableReadCadence::from_raw("later"), None);
    assert_eq!(call("tokens.tunables_read_cadences", &json!({})), Ok(json!(["live", "launch"])));
}

#[test]
fn numbers_format_as_debug_settings_shows_them() {
    assert_eq!(d::format_number(1.0), "1");
    assert_eq!(d::format_number(-0.0), "0");
    assert_eq!(d::format_number(0.35), "0.35");
    assert_eq!(d::format_number(2.5), "2.5");
    assert_eq!(d::format_number(1.0 / 3.0), "0.3333");
    assert_eq!(d::format_number(-4.25), "-4.25");
    assert_eq!(d::format_number(0.00004), "0");
    assert_eq!(d::format_number(1e12), "1000000000000.");
    assert_eq!(d::format_with_unit(0.35, TunableUnit::Fraction), "35%");
    assert_eq!(d::format_with_unit(0.123, TunableUnit::Fraction), "12.3%");
    assert_eq!(d::format_with_unit(14.0, TunableUnit::Points), "14 pt");
    assert_eq!(d::format_with_unit(0.25, TunableUnit::Seconds), "0.25 s");
    assert_eq!(d::format_with_unit(1.5, TunableUnit::Multiplier), "1.5×");
    assert_eq!(d::format_with_unit(800.0, TunableUnit::PointsPerSecond), "800 pt/s");
    assert_eq!(d::format_with_unit(3.0, TunableUnit::Count), "3");
    assert_eq!(d::display_number(0.35, TunableUnit::Fraction), 35.0);
    assert_eq!(d::display_number(0.35, TunableUnit::Points), 0.35);
    let suffixes: Vec<&str> = TunableUnit::ALL.iter().map(|u| u.suffix()).collect();
    assert_eq!(suffixes, ["pt", "s", "%", "×", "pt/s", ""]);
    assert_eq!(
        call("tokens.tunables_format_number", &json!({"number": 0.5, "unit": "fraction"})),
        Ok(json!("50%"))
    );
    assert_eq!(call("tokens.tunables_format_number", &json!({"number": 0.5})), Ok(json!("0.5")));
    assert_eq!(
        call("tokens.tunables_display", &json!({"number": 0.5, "unit": "fraction"})),
        Ok(json!(50.0))
    );
    assert_eq!(
        call("tokens.tunables_unit_suffix", &json!({"unit": "pointsPerSecond"})),
        Ok(json!("pt/s"))
    );
}

#[test]
fn values_format_by_kind() {
    let choice = TunableKind::Choice(vec![TunableChoiceOption::new("none", "None")]);
    assert_eq!(d::format_value(&TunableValue::Choice("none".into()), &choice, "On", "Off"), "None");
    assert_eq!(
        d::format_value(&TunableValue::Choice("other".into()), &choice, "On", "Off"),
        "other"
    );
    assert_eq!(d::format_value(&TunableValue::Bool(true), &TunableKind::Bool, "On", "Off"), "On");
    assert_eq!(
        d::format_value(&TunableValue::Color("danger".into()), &TunableKind::Color, "On", "Off"),
        "danger"
    );
    let spring = TunableValue::Spring(SpringParameters { response: 0.35, damping_fraction: 1.0 });
    assert_eq!(d::format_value(&spring, &TunableKind::Spring, "On", "Off"), "0.35 s / 1");
    assert_eq!(d::format_value(&TunableValue::Number(2.0), &TunableKind::Bool, "On", "Off"), "2");
    let reply = call(
        "tokens.tunables_format_value",
        &json!({"value": {"number": 4}, "kind": {"number": {"range": [0, 6], "step": 0.5, "unit": "points"}}}),
    );
    assert_eq!(reply, Ok(json!("4 pt")));
}

#[test]
fn numbers_snap_to_the_step_from_the_lower_bound() {
    assert_eq!(d::snap(0.37, (0.0, 1.0), 0.05), 0.35);
    assert_eq!(d::snap(7.6, (4.0, 24.0), 1.0), 8.0);
    assert_eq!(d::snap(4.3, (4.0, 24.0), 0.5), 4.5);
    assert_eq!(d::snap(0.37, (0.0, 1.0), 0.0), 0.37);
    assert_eq!(
        call("tokens.tunables_snap", &json!({"number": 0.72, "range": [0, 1], "step": 0.05})),
        Ok(json!(0.7))
    );
}

// MARK: Floating pane

#[test]
fn floating_pane_descriptors() {
    let all = fp::descriptors();
    let keys: Vec<&str> = all.iter().map(|d| d.key.as_str()).collect();
    assert_eq!(
        keys,
        [
            "floatingPane.backgroundOpacity",
            "floatingPane.material",
            "floatingPane.tint",
            "floatingPane.tintStrength",
            "floatingPane.borderWidth",
            "floatingPane.borderOpacity",
            "floatingPane.shadowOpacity",
            "floatingPane.shadowBlur",
            "floatingPane.shadowOffset",
            "floatingPane.cornerMode",
            "floatingPane.cornerFloor",
            "floatingPane.resizeBand",
            "floatingPane.cornerZone",
        ]
    );
    assert_eq!(fp::section().order, 15);
    let shadow = &all[6];
    assert_eq!(shadow.default_value(), &TunableValue::Number(0.35));
    assert_eq!(shadow.kind, TunableKind::number((0.0, 1.0), 0.05, TunableUnit::Fraction));
    assert_eq!(shadow.code_name.as_deref(), Some("FloatingPaneTunables.shadowOpacity"));
    assert_eq!(all[8].kind, TunableKind::number((-30.0, 30.0), 1.0, TunableUnit::Points));
    assert_eq!(all[10].default_value(), &TunableValue::Number(6.0));
    assert_eq!(all[11].kind, TunableKind::number((4.0, 24.0), 1.0, TunableUnit::Points));
    assert_eq!(all[12].default_value(), &TunableValue::Number(20.0));
    assert_eq!(all[2].default_value(), &TunableValue::Color("glassTint".into()));
    let TunableKind::Choice(materials) = &all[1].kind else { panic!("material is a choice") };
    assert_eq!(materials.len(), 14);
    assert_eq!(materials[13], TunableChoiceOption::new("fullScreenUI", "Full screen UI"));
    let TunableKind::Choice(modes) = &all[9].kind else { panic!("corner mode is a choice") };
    assert_eq!(modes[2], TunableChoiceOption::new("mainPane", "Main pane's radius"));
    assert_eq!(all[9].default_value(), &TunableValue::Choice("concentric".into()));
    let reply = call("tokens.tunables_floating_pane_descriptors", &json!({})).unwrap();
    assert_eq!(reply["descriptors"].as_array().unwrap().len(), 13);
}

#[test]
fn floating_pane_look_clamps_its_knobs() {
    let defaults = fp::look(&BTreeMap::new());
    assert_eq!(defaults, fp::FloatingPaneLook::default());
    assert!(!defaults.is_see_through());
    assert_eq!(defaults.shadow_opacity, 0.35);
    assert_eq!(defaults.corner_floor, 6.0);
    let tuned = fp::look(&overrides(&[
        ("floatingPane.backgroundOpacity", TunableValue::Number(0.8)),
        ("floatingPane.tintStrength", TunableValue::Number(1.4)),
        ("floatingPane.borderWidth", TunableValue::Number(-3.0)),
        ("floatingPane.shadowBlur", TunableValue::Number(-1.0)),
        ("floatingPane.shadowOffset", TunableValue::Number(-40.0)),
        ("floatingPane.resizeBand", TunableValue::Number(2.0)),
        ("floatingPane.cornerZone", TunableValue::Number(55.0)),
        ("floatingPane.cornerFloor", TunableValue::Number(-2.0)),
        ("floatingPane.material", TunableValue::Choice("popover".into())),
        ("floatingPane.cornerMode", TunableValue::Choice("bogus".into())),
        ("floatingPane.tint", TunableValue::Color("danger".into())),
        ("floatingPane.borderOpacity", TunableValue::Bool(true)),
    ]));
    assert_eq!(tuned.background_opacity, 0.8);
    assert!(tuned.is_see_through());
    assert_eq!(tuned.tint_strength, 1.0);
    assert_eq!(tuned.border_width, 0.0);
    assert_eq!(tuned.shadow_blur, 0.0);
    assert_eq!(tuned.shadow_offset, -40.0);
    assert_eq!(tuned.resize_band, 4.0);
    assert_eq!(tuned.corner_zone, 40.0);
    assert_eq!(tuned.corner_floor, 0.0);
    assert_eq!(tuned.material, "popover");
    assert_eq!(tuned.corner_mode, "concentric");
    assert_eq!(tuned.tint, "danger");
    assert_eq!(tuned.border_opacity, 1.0);
    let reply = call(
        "tokens.tunables_floating_pane_look",
        &json!({"overrides": {"floatingPane.backgroundOpacity": {"number": -0.5}, "floatingPane.resizeBand": {"number": 30}}}),
    )
    .unwrap();
    assert_eq!(reply["backgroundOpacity"], json!(0.0));
    assert_eq!(reply["resizeBand"], json!(24.0));
    assert_eq!(reply["isSeeThrough"], json!(true));
    assert_eq!(reply["material"], json!("none"));
}

// MARK: TokenMemoTests

fn read() -> MemoEvent {
    MemoEvent::Read { scoped: false, active: false, drops_during_compute: 0 }
}

#[test]
fn keeps_the_value_until_an_input_changes() {
    let events =
        [read(), read(), MemoEvent::Drop, read(), read(), MemoEvent::Settle, read(), read()];
    let (reads, state) = memo::run(MemoState::default(), &events);
    let reads: Vec<MemoRead> = reads.into_iter().flatten().collect();
    assert_eq!(
        reads,
        [
            MemoRead::Kept { tracks_store: false },
            MemoRead::Hit,
            MemoRead::Settling,
            MemoRead::Settling,
            MemoRead::Kept { tracks_store: false },
            MemoRead::Hit,
        ]
    );
    // Computes: 1 before the change, 3 after the two settling reads, 4 after the main turn.
    assert_eq!(reads.iter().filter(|r| r.computed()).count(), 4);
    assert_eq!(
        state,
        MemoState {
            has_stored: true,
            stored_epoch: 1,
            stored_active: false,
            epoch: 1,
            settling: 0
        }
    );
}

#[test]
fn a_scoped_density_is_never_kept() {
    let scoped = MemoEvent::Read { scoped: true, active: false, drops_during_compute: 0 };
    let (reads, _) = memo::run(MemoState::default(), &[read(), scoped, read()]);
    assert_eq!(
        reads,
        [Some(MemoRead::Kept { tracks_store: false }), Some(MemoRead::Scoped), Some(MemoRead::Hit)]
    );
    let mut empty = MemoState::default();
    assert_eq!(empty.read(true, false, 0), MemoRead::Scoped);
    assert_eq!(empty, MemoState::default());
}

#[test]
fn the_stores_activation_rekeys_the_memo() {
    let mut state = MemoState::default();
    assert_eq!(state.read(false, false, 0), MemoRead::Kept { tracks_store: false });
    assert_eq!(state.read(false, true, 0), MemoRead::Kept { tracks_store: true });
    assert_eq!(state.read(false, true, 0), MemoRead::Hit);
    assert_eq!(state.read(false, false, 0), MemoRead::Kept { tracks_store: false });
}

#[test]
fn a_drop_during_the_compute_keeps_nothing() {
    let mut state = MemoState::default();
    assert_eq!(state.read(false, true, 1), MemoRead::Discarded { tracks_store: true });
    assert!(!state.has_stored);
    assert_eq!((state.epoch, state.settling), (1, 1));
    assert_eq!(state.read(false, true, 0), MemoRead::Settling);
    state.settle();
    assert_eq!(state.read(false, true, 0), MemoRead::Kept { tracks_store: true });
    // Two drops need two turns.
    state.drop_value();
    state.drop_value();
    state.settle();
    assert_eq!(state.read(false, true, 0), MemoRead::Settling);
    state.settle();
    assert_eq!(state.read(false, true, 0), MemoRead::Kept { tracks_store: true });
    assert_eq!(state.stored_epoch, 3);
    let reply = call(
        "tokens.tunables_memo_run",
        &json!({"events": [{"event": "read"}, {"event": "read"}, {"event": "drop"}, {"event": "read", "active": true}]}),
    )
    .unwrap();
    assert_eq!(reply["reads"], json!([{"kept": {"tracksStore": false}}, "hit", null, "settling"]));
    assert_eq!(reply["state"]["epoch"], json!(1));
    assert_eq!(reply["state"]["settling"], json!(1));
}

#[test]
fn unknown_names_fall_through() {
    assert_eq!(
        cmux_design_core::tokens::tunables::call("density_entry", &json!({})),
        Err(OpError::Unknown)
    );
    assert_eq!(call("tokens.tunables_nope", &json!({})), Err(OpError::Unknown));
}
