//! Parity tests for `tokens::frame_tone` (FrameTone.swift, FrameTone+Metrics.swift). Swift has no
//! tests for these files; the pins are computed by hand from the Swift formulas.

use cmux_design_core::ops::{OpError, call};
use cmux_design_core::tokens::color::{Color, Rgb};
use cmux_design_core::tokens::frame_tone::*;
use cmux_theme_tokens::oklch;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("tokens.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e:?}"))
}

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-9
}

const BLACK: Rgb = Rgb::hex(0x000000);
const WHITE: Rgb = Rgb::hex(0xFFFFFF);

fn step(base: Rgb, ink: Rgb, share: f64) -> f64 {
    (oklch(washed(base, ink, share)).l - oklch(base).l).abs()
}

fn dark_theme() -> FrameTheme {
    FrameTheme { surface_background: BLACK.into(), text_primary: WHITE.into(), is_dark: true }
}

fn on(contrast: f64) -> FrameSettings {
    FrameSettings {
        main_pane_curved: true,
        corner_flush_on: true,
        subtle_tone: true,
        title_area_contrast: contrast,
    }
}

#[test]
fn constants() {
    assert_eq!((FRAME_RUNG, HOVER_RUNG, SELECTED_RUNG, STEP, ROUNDS), (0.04, 0.08, 0.12, 0.03, 24));
    assert_eq!(
        op("frame_tone_constants", json!({})),
        json!({"frameRung": 0.04, "hoverRung": 0.08, "selectedRung": 0.12, "step": 0.03})
    );
}

#[test]
fn washed_mixes_opaque_colours() {
    let grey = washed(WHITE, BLACK, 0.5);
    assert_eq!((grey.r, grey.g, grey.b, grey.a), (0.5, 0.5, 0.5, 1.0));
    // Alphas are dropped on both sides.
    assert_eq!(washed(WHITE.with_alpha(0.2), BLACK.with_alpha(0.3), 0.0), WHITE);
    assert_eq!(
        op(
            "frame_tone_washed",
            json!({"base": {"r": 1, "g": 1, "b": 1, "a": 0.5}, "ink": {"r": 0, "g": 0, "b": 0}, "share": 0.25})
        ),
        json!({"r": 0.75, "g": 0.75, "b": 0.75, "a": 1.0})
    );
}

#[test]
fn share_picks_the_least_rung_that_moves_lightness() {
    // A dark base moves by far more than the step at the frame rung.
    assert_eq!(share(BLACK, WHITE), FRAME_RUNG);
    assert_eq!(share(BLACK, Rgb::hex(0xEEEEEE)), FRAME_RUNG);
    // Ink equal to the base never moves: the selected rung.
    assert_eq!(share(Rgb::hex(0x808080), Rgb::hex(0x808080)), SELECTED_RUNG);
    // White under black moves 0.0305 at the frame rung (L 1 to 0.9696): the frame rung.
    assert_eq!(share(WHITE, BLACK), FRAME_RUNG);
    assert!(step(WHITE, BLACK, FRAME_RUNG) >= STEP);
    // White under mid grey moves 0.015 at the frame rung and 0.046 at the selected one: bisected.
    let grey = Rgb::hex(0x808080);
    let s = share(WHITE, grey);
    assert!(s > FRAME_RUNG && s < SELECTED_RUNG, "{s}");
    assert!(step(WHITE, grey, FRAME_RUNG) < STEP);
    assert!(step(WHITE, grey, SELECTED_RUNG) > STEP);
    assert!(step(WHITE, grey, s) >= STEP);
    assert!(step(WHITE, grey, s - (SELECTED_RUNG - FRAME_RUNG) / f64::from(1 << ROUNDS)) < STEP);
    assert_eq!(theme_share(WHITE.with_alpha(0.1), grey.with_alpha(0.4)), s);
    let g = 128.0 / 255.0;
    assert_eq!(
        op(
            "frame_tone_share",
            json!({"base": {"r": 1, "g": 1, "b": 1}, "ink": {"r": g, "g": g, "b": g}})
        ),
        s
    );
    assert_eq!(
        op(
            "frame_tone_share",
            json!({"base": {"r": 0, "g": 0, "b": 0}, "ink": {"r": 1, "g": 1, "b": 1}})
        ),
        FRAME_RUNG
    );
}

#[test]
fn wash_lifts_under_to_the_rung() {
    let w = wash(0.08, 0.05);
    assert_eq!(w, 0.03 / 0.95);
    assert!(close(1.0 - (1.0 - 0.05) * (1.0 - w), 0.08));
    assert_eq!(wash(0.04, 0.05), 0.0);
    assert_eq!(wash(0.05, 0.05), 0.0);
    assert_eq!(wash(1.5, 1.0), 0.0);
    assert_eq!(wash(0.5, 0.0), 0.5);
    assert_eq!(op("frame_tone_wash", json!({"rung": 0.08, "under": 0.05})), 0.03 / 0.95);
}

#[test]
fn draws_ink_frame_needs_all_three() {
    assert!(draws_ink_frame(&on(1.0)));
    for (c, f, t) in [(false, true, true), (true, false, true), (true, true, false)] {
        let s = FrameSettings {
            main_pane_curved: c,
            corner_flush_on: f,
            subtle_tone: t,
            title_area_contrast: 1.0,
        };
        assert!(!draws_ink_frame(&s));
    }
    assert_eq!(
        op(
            "frame_tone_draws_ink_frame",
            json!({"settings": {"mainPaneCurved": true, "cornerFlushOn": true, "subtleTone": true}})
        ),
        true
    );
    assert_eq!(
        op(
            "frame_tone_draws_ink_frame",
            json!({"settings": {"mainPaneCurved": true, "cornerFlushOn": false, "subtleTone": true}})
        ),
        false
    );
}

#[test]
fn ink_frame_shade_pins() {
    let theme = dark_theme();
    assert_eq!(ink_frame_shade(true, &theme, &on(1.0)), Some(FRAME_RUNG));
    assert_eq!(ink_frame_shade(true, &theme, &on(2.0)), Some(0.08));
    assert_eq!(ink_frame_shade(true, &theme, &on(30.0)), Some(1.0));
    assert_eq!(ink_frame_shade(true, &theme, &on(-1.0)), Some(0.0));
    // The other appearance reads the frame rung.
    let light =
        FrameTheme { surface_background: WHITE.into(), text_primary: BLACK.into(), is_dark: false };
    assert_eq!(ink_frame_shade(true, &light, &on(0.5)), Some(FRAME_RUNG * 0.5));
    assert_eq!(ink_frame_shade(false, &light, &on(1.0)), Some(share(WHITE, BLACK)));
    let off = FrameSettings { subtle_tone: false, ..on(1.0) };
    assert_eq!(ink_frame_shade(true, &theme, &off), None);

    let theme_json = json!({"surfaceBackground": {"r": 0, "g": 0, "b": 0}, "textPrimary": {"r": 1, "g": 1, "b": 1}, "isDark": true});
    let settings = json!({"mainPaneCurved": true, "cornerFlushOn": true, "subtleTone": true, "titleAreaContrast": 2});
    assert_eq!(
        op("frame_tone_ink_frame_shade", json!({"theme": theme_json, "settings": settings})),
        0.08
    );
    assert_eq!(
        op(
            "frame_tone_ink_frame_shade",
            json!({"theme": theme_json, "settings": settings, "isDark": false})
        ),
        0.08
    );
    let off_json = json!({"mainPaneCurved": false, "cornerFlushOn": true, "subtleTone": true});
    assert_eq!(
        op("frame_tone_ink_frame_shade", json!({"theme": theme_json, "settings": off_json})),
        Value::Null
    );
}

#[test]
fn chrome_frame_ink_and_lift_surface() {
    let theme = FrameTheme {
        surface_background: Color { r: 0.1, g: 0.2, b: 0.3, a: 0.5 },
        text_primary: Color { r: 0.9, g: 0.8, b: 0.7, a: 0.4 },
        is_dark: true,
    };
    assert_eq!(chrome_frame_ink(&theme, &on(1.0)), Rgb::new(0.9, 0.8, 0.7, 1.0));
    assert_eq!(frame_lift_surface(&theme, &on(1.0)), Some(Rgb::new(0.1, 0.2, 0.3, 1.0)));
    let off = FrameSettings { corner_flush_on: false, ..on(1.0) };
    assert_eq!(chrome_frame_ink(&theme, &off), BLACK);
    assert_eq!(frame_lift_surface(&theme, &off), None);

    let theme_json = serde_json::to_value(theme).unwrap();
    let settings = json!({"mainPaneCurved": true, "cornerFlushOn": true, "subtleTone": true});
    assert_eq!(
        op("frame_tone_chrome_frame_ink", json!({"theme": theme_json, "settings": settings})),
        json!({"r": 0.9, "g": 0.8, "b": 0.7, "a": 1.0})
    );
    assert_eq!(
        op("frame_tone_lift_surface", json!({"theme": theme_json, "settings": settings})),
        json!({"r": 0.1, "g": 0.2, "b": 0.3, "a": 1.0})
    );
    let off_json = json!({"mainPaneCurved": true, "cornerFlushOn": false, "subtleTone": true});
    assert_eq!(
        op("frame_tone_chrome_frame_ink", json!({"theme": theme_json, "settings": off_json})),
        json!({"r": 0.0, "g": 0.0, "b": 0.0, "a": 1.0})
    );
    assert_eq!(
        op("frame_tone_lift_surface", json!({"theme": theme_json, "settings": off_json})),
        Value::Null
    );
}

#[test]
fn frame_state_fills_pins() {
    let theme = dark_theme();
    let fills = frame_state_fills(&theme, &on(1.0)).unwrap();
    // Under 0.04, step 0.04: hover lifts to 0.08 and pressed to 0.12.
    assert_eq!((fills.hover.r, fills.hover.g, fills.hover.b), (1.0, 1.0, 1.0));
    assert!(close(fills.hover.a, 0.04 / 0.96), "{}", fills.hover.a);
    assert!(close(fills.pressed.a, 0.08 / 0.96), "{}", fills.pressed.a);
    // Contrast 0.2 leaves a shade of 0.008, under the folder tab minimum 0.011.
    assert_eq!(frame_state_fills(&theme, &on(0.2)), None);
    // Contrast 0.5: under 0.02, the step stays the theme's share.
    let half = frame_state_fills(&theme, &on(0.5)).unwrap();
    assert!(close(half.hover.a, 0.04 / 0.98));
    assert!(close(half.pressed.a, 0.08 / 0.98));
    assert_eq!(
        frame_state_fills(&theme, &FrameSettings { main_pane_curved: false, ..on(1.0) }),
        None
    );

    let theme_json = serde_json::to_value(theme).unwrap();
    let settings = json!({"mainPaneCurved": true, "cornerFlushOn": true, "subtleTone": true});
    let got = op("frame_tone_state_fills", json!({"theme": theme_json, "settings": settings}));
    assert!(close(got["hover"]["a"].as_f64().unwrap(), 0.04 / 0.96));
    assert!(close(got["pressed"]["a"].as_f64().unwrap(), 0.08 / 0.96));
    assert_eq!(got["pressed"]["r"], 1.0);
    let dim = json!({"mainPaneCurved": true, "cornerFlushOn": true, "subtleTone": true, "titleAreaContrast": 0.2});
    assert_eq!(
        op("frame_tone_state_fills", json!({"theme": theme_json, "settings": dim})),
        Value::Null
    );
    assert!(matches!(call("tokens.frame_tone_nope", &json!({})), Err(OpError::Unknown)));
}
