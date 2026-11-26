//! Parity tests for `tokens::themes`: the Swift suites GroupFillContrastTests, NeedsInputDotTests
//! and HomeFailedBadgeSystemRedTests ported value for value, plus pins worked by hand from the
//! Swift formulas and one JSON op per function.

use cmux_design_core::ops::{OpError, call};
use cmux_design_core::tokens::color::{Color, Rgb};
use cmux_design_core::tokens::themes::audit::{
    Appearances, AuditColors, PLAYGROUND_STRINGS, PlaygroundEntry, Resolved, ThemeElement,
    ThemeElementGround, ThemeElementSample, audit_failures, audit_samples, name_matches,
    playground_failing, playground_failing_count, playground_files, playground_sample_help,
    playground_shown, playground_sorted, playground_summary,
};
use cmux_design_core::tokens::themes::fills::{
    DEFAULT_OPAQUE_OVERLAY_LIFT, group_fill, group_fill_on, group_fill_target, group_stroke,
    group_stroke_for, menu_highlight_share, spinner_ink,
};
use cmux_design_core::tokens::themes::glass_text::{
    DIALOG_MINIMUM_CONTRAST, ThemeInk, Veil, card_text, fit_readable, toast_ground,
    toast_ink_title, toast_text, veil_rgb,
};
use cmux_design_core::tokens::themes::status_dot::{
    StatusDotHue, readable_dot, status_dot, status_dot_rows,
};
use cmux_design_core::tokens::themes::swatch::{PALETTE_INDICES, css_hex, strip};
use cmux_theme_tokens::{
    GHOSTTY_DEFAULT_PALETTE, MINIMUM_MARK_CONTRAST, MINIMUM_TEXT_CONTRAST, ThemeInput, ThemeTokens,
    readable, readable_over,
};
use serde_json::{Value, json};

const EPS: f64 = 1e-9;

fn close(a: Rgb, b: Rgb) -> bool {
    (a.r - b.r).abs() < EPS
        && (a.g - b.g).abs() < EPS
        && (a.b - b.b).abs() < EPS
        && (a.a - b.a).abs() < EPS
}

fn op(name: &str, request: Value) -> Value {
    call(&format!("tokens.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e:?}"))
}

fn rgb_of(v: &Value) -> Rgb {
    let c: Color = serde_json::from_value(v.clone()).expect("a color");
    c.into()
}

fn cj(c: Rgb) -> Value {
    json!({ "r": c.r, "g": c.g, "b": c.b, "a": c.a })
}

fn tokens(background: u32, foreground: u32) -> ThemeTokens {
    ThemeTokens::derive(&ThemeInput {
        background: Rgb::hex(background),
        foreground: Rgb::hex(foreground),
        ..ThemeInput::GHOSTTY_DEFAULT
    })
}

fn tokens_json(background: u32, foreground: u32) -> Value {
    json!({ "background": cj(Rgb::hex(background)), "foreground": cj(Rgb::hex(foreground)) })
}

fn rgb8(r: u8, g: u8, b: u8) -> Rgb {
    Rgb::new(f64::from(r) / 255.0, f64::from(g) / 255.0, f64::from(b) / 255.0, 1.0)
}

// GroupFillContrastTests

const GROUP_THEMES: [(&str, u32, u32); 7] = [
    ("dark", 0x1E1E1E, 0xE6E6E6),
    ("light", 0xFFFFFF, 0x1D1D1F),
    ("solarized dark", 0x002B36, 0x839496),
    ("solarized light", 0xFDF6E3, 0x657B83),
    ("low-contrast grey", 0x3A3A3A, 0xA8A8A8),
    ("hot dog stand", 0xFF0000, 0xFFFF00),
    ("nord", 0x2E3440, 0xD8DEE9),
];

#[test]
fn group_fill_keeps_text_contrast_in_every_theme() {
    for (name, bg, fg) in GROUP_THEMES {
        let t = tokens(bg, fg);
        let surface = t.opaque_overlay_fill(DEFAULT_OPAQUE_OVERLAY_LIFT);
        let fill = group_fill(&t, DEFAULT_OPAQUE_OVERLAY_LIFT);
        let ground = fill.composited(surface);
        let bare = t.text_secondary.composited(surface).contrast(surface);
        let on = t.text_secondary.composited(surface).contrast(ground);
        assert!(on >= MINIMUM_TEXT_CONTRAST.min(bare) - 0.01, "{name}: {on} vs {bare}");
    }
}

#[test]
fn group_fill_is_at_least_hover_in_plain_themes() {
    for (name, bg, fg) in &GROUP_THEMES[..2] {
        let t = tokens(*bg, *fg);
        assert!(group_fill(&t, DEFAULT_OPAQUE_OVERLAY_LIFT).a >= t.hover_fill.a, "{name}");
    }
}

#[test]
fn group_stroke_shows_only_when_fill_is_cut() {
    for (name, bg, fg) in GROUP_THEMES {
        let t = tokens(bg, fg);
        let fill = group_fill(&t, DEFAULT_OPAQUE_OVERLAY_LIFT);
        let stroke = group_stroke(&t, DEFAULT_OPAQUE_OVERLAY_LIFT);
        if t.is_dark && fill.a < 0.08 {
            assert!(stroke.a > 0.0, "{name}");
        } else if !t.is_dark {
            assert!(fill.a >= 0.059, "{name}");
            assert_eq!(stroke.a, 0.0, "{name}");
        } else {
            assert_eq!(stroke.a, 0.0, "{name}");
        }
    }
}

#[test]
fn group_fill_pins() {
    assert_eq!(group_fill_target(true), 0.08);
    assert_eq!(group_fill_target(false), 0.06);
    let t = tokens(0x1E1E1E, 0xE6E6E6);
    // Plain dark: secondary reads at the full 8%, so the fill is text_primary at 16/200.
    let fill = group_fill_on(&t, t.window_background);
    let secondary = t.text_secondary.composited(t.window_background.with_alpha(1.0));
    let ground = t.window_background.with_alpha(1.0);
    let expect_steps = (0..=16)
        .rev()
        .find(|s| {
            *s == 0
                || secondary
                    .contrast(t.text_primary.with_alpha(*s as f64 / 200.0).composited(ground))
                    >= 4.5f64.min(secondary.contrast(ground))
        })
        .unwrap();
    assert!(close(fill, t.text_primary.with_alpha(expect_steps as f64 / 200.0)));
    assert!(close(
        group_stroke_for(&t, t.text_primary.with_alpha(0.08)),
        t.separator.with_alpha(0.0)
    ));
    assert!(close(group_stroke_for(&t, t.text_primary.with_alpha(0.075)), t.separator));
    let light = tokens(0xFFFFFF, 0x1D1D1F);
    assert!(close(
        group_stroke_for(&light, light.text_primary.with_alpha(0.06)),
        light.separator.with_alpha(0.0)
    ));
}

#[test]
fn group_fill_ops() {
    let t = tokens(0x002B36, 0x839496);
    let v = op("themes_group_fill", json!({ "tokens": tokens_json(0x002B36, 0x839496) }));
    let fill = group_fill(&t, DEFAULT_OPAQUE_OVERLAY_LIFT);
    assert!(close(rgb_of(&v["fill"]), fill));
    assert!(close(rgb_of(&v["stroke"]), group_stroke_for(&t, fill)));
    let v =
        op("themes_group_fill", json!({ "tokens": tokens_json(0x002B36, 0x839496), "lift": 0.3 }));
    assert!(close(rgb_of(&v["fill"]), group_fill(&t, 0.3)));
    let g = Rgb::hex(0x223344);
    let v = op(
        "themes_group_fill_on",
        json!({ "tokens": tokens_json(0x002B36, 0x839496), "ground": cj(g) }),
    );
    assert!(close(rgb_of(&v), group_fill_on(&t, g)));
    let f = t.text_primary.with_alpha(0.01);
    let v = op(
        "themes_group_stroke_for",
        json!({ "tokens": tokens_json(0x002B36, 0x839496), "fill": cj(f) }),
    );
    assert!(close(rgb_of(&v), t.separator));
    assert_eq!(
        op("themes_group_fill_target", json!({ "tokens": tokens_json(0xFFFFFF, 0x000000) })),
        json!(0.06)
    );
}

// NeedsInputDotTests

const DOT_PALETTE: [u32; 8] =
    [0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6];

fn dot_input(background: u32, foreground: u32) -> ThemeInput {
    let mut palette = GHOSTTY_DEFAULT_PALETTE;
    for (slot, hex) in palette.iter_mut().zip(DOT_PALETTE) {
        *slot = Rgb::hex(hex);
    }
    ThemeInput {
        background: Rgb::hex(background),
        foreground: Rgb::hex(foreground),
        palette,
        ..ThemeInput::GHOSTTY_DEFAULT
    }
}

#[test]
fn attention_dot_reads_on_every_row_and_is_not_orange() {
    for (dark, bg, fg) in [(true, 0x1D1F21, 0xC5C8C6), (false, 0xFFFFFF, 0x24292F)] {
        let t = ThemeTokens::derive(&dot_input(bg, fg));
        assert_eq!(t.is_dark, dark);
        let dot = status_dot(&t, StatusDotHue::Attention);
        for row in status_dot_rows(&t) {
            assert!(dot.contrast(row) >= MINIMUM_MARK_CONTRAST, "dark {dark}");
        }
        let orange = if dark { rgb8(255, 159, 10) } else { rgb8(255, 149, 0) };
        assert!(!close(dot, orange));
        if dark {
            assert!(close(dot, t.attention.with_alpha(1.0)));
        }
    }
}

#[test]
fn attention_dot_op() {
    let t = ThemeTokens::derive(&dot_input(0xFFFFFF, 0x24292F));
    let palette: Vec<Value> = DOT_PALETTE.iter().map(|h| cj(Rgb::hex(*h))).collect();
    let wire = json!({
        "background": cj(Rgb::hex(0xFFFFFF)), "foreground": cj(Rgb::hex(0x24292F)), "palette": palette,
    });
    let v = op("themes_status_dot", json!({ "tokens": wire, "mark": "attention" }));
    assert!(close(rgb_of(&v), status_dot(&t, StatusDotHue::Attention)));
    let v = op("themes_status_dot_rows", json!({ "tokens": wire }));
    let rows = status_dot_rows(&t);
    for (i, row) in rows.iter().enumerate() {
        assert!(close(rgb_of(&v[i]), *row));
    }
}

// HomeFailedBadgeSystemRedTests

#[test]
fn error_dot_is_system_red_not_the_theme_danger() {
    let palette = [
        0x2F2F2F, 0xF06C63, 0x5FC28A, 0xF0B54A, 0x5A8EE6, 0xB58CF0, 0x4FBFD0, 0xD4D4D4, 0x6B6B6B,
        0xFF8A80, 0x7ED6A3, 0xF6C770, 0x7AA7F0, 0xC9A6F5, 0x7AD3DF, 0xFFFFFF,
    ]
    .map(Rgb::hex);
    let t = ThemeTokens::derive(&ThemeInput {
        background: Rgb::hex(0x181818),
        foreground: Rgb::hex(0xFFFFFF),
        palette,
        selection_background: Some(Rgb::hex(0x24395A)),
        selection_foreground: Some(Rgb::hex(0xFFFFFF)),
        ..ThemeInput::GHOSTTY_DEFAULT
    });
    let dot = status_dot(&t, StatusDotHue::Error);
    assert!((dot.r - t.danger.r).abs() + (dot.g - t.danger.g).abs() > 0.1);
}

// Status dot pins

#[test]
fn status_dot_hues() {
    use StatusDotHue::*;
    assert!(close(Unread.hue(true), rgb8(10, 132, 255)));
    assert!(close(Unread.hue(false), rgb8(0, 122, 255)));
    assert!(close(Attention.hue(true), rgb8(255, 214, 10)));
    assert!(close(Attention.hue(false), rgb8(255, 204, 0)));
    assert!(close(Error.hue(true), rgb8(255, 69, 58)));
    assert!(close(Error.hue(false), rgb8(255, 59, 48)));
    assert!(close(Notification.hue(true), rgb8(57, 130, 245)));
    assert!(close(Notification.hue(false), rgb8(57, 130, 245)));
    assert_eq!(StatusDotHue::ALL.len(), 4);
    let v = op("themes_status_dot_hue", json!({ "mark": "error", "isDark": false }));
    assert!(close(rgb_of(&v), rgb8(255, 59, 48)));
}

#[test]
fn status_dot_starts_from_the_hue_and_walks_to_the_pole() {
    // Plain black: system blue already reads at 3:1 on black-ish rows, so it stays.
    let t = tokens(0x000000, 0xFFFFFF);
    let rows = status_dot_rows(&t);
    let expect = readable_over(rgb8(10, 132, 255), &rows, Rgb::WHITE, 3.0);
    assert!(close(status_dot(&t, StatusDotHue::Unread), expect));
    // Light: yellow attention walks toward black.
    let t = tokens(0xFFFFFF, 0x000000);
    let rows = status_dot_rows(&t);
    let dot = status_dot(&t, StatusDotHue::Unread);
    assert!(close(dot, readable_over(rgb8(0, 122, 255), &rows, Rgb::BLACK, 3.0)));
    assert!(close(rows[0], t.window_background.with_alpha(1.0)));
    assert!(close(rows[1], t.selection_fill.composited(rows[0])));
    assert!(close(rows[2], t.pressed_fill.composited(rows[0])));
}

#[test]
fn readable_dot_steps() {
    // Already reads: unchanged.
    assert!(close(readable_dot(Rgb::WHITE, &[Rgb::BLACK], Rgb::WHITE), Rgb::WHITE));
    // Mid grey on white walks toward black in 2% steps until 3:1.
    let grey = Rgb::new(0.7, 0.7, 0.7, 1.0);
    let out = readable_dot(grey, &[Rgb::WHITE], Rgb::BLACK);
    assert!(out.contrast(Rgb::WHITE) >= 3.0);
    let prev = (1..=50)
        .map(|i| grey.mixed(Rgb::BLACK, f64::from(i) * 0.02))
        .find(|c| c.contrast(Rgb::WHITE) >= 3.0)
        .unwrap();
    assert!(close(out, prev));
    let v = op(
        "themes_readable_dot",
        json!({ "color": cj(grey), "surfaces": [cj(Rgb::WHITE)], "pole": cj(Rgb::BLACK) }),
    );
    assert!(close(rgb_of(&v), out));
}

// Menu highlight and spinner

#[test]
fn menu_highlight_share_pins() {
    // Grey accent on white with black text: 20% wash keeps 4.5:1, share stays 0.2.
    let mut t = tokens(0xFFFFFF, 0x000000);
    t.text_primary = Rgb::BLACK;
    t.accent = Rgb::hex(0x808080);
    assert_eq!(menu_highlight_share(&t, Rgb::WHITE), 0.2);
    // Black accent under grey 0x595959 text on white (7:1 bare): the wash drops in 0.01 steps
    // (the same float walk) to the first share where the text keeps 4.5:1.
    t.text_primary = Rgb::hex(0x595959);
    t.accent = Rgb::BLACK;
    let share = menu_highlight_share(&t, Rgb::WHITE);
    let ink = Rgb::hex(0x595959);
    let reads = |s: f64| ink.contrast(Rgb::BLACK.with_alpha(s).composited(Rgb::WHITE)) >= 4.5;
    let mut walk = 0.2f64;
    while walk > 0.0 && !reads(walk) {
        walk = (walk - 0.01).max(0.0);
    }
    assert!(share < 0.2 && share > 0.0, "{share}");
    assert_eq!(share, walk);
    assert!(reads(share) && !reads(share + 0.01));
    // Black on black never reads: share bottoms out at zero.
    let mut d = tokens(0x000000, 0xFFFFFF);
    d.text_primary = Rgb::BLACK;
    d.accent = Rgb::BLACK;
    assert_eq!(menu_highlight_share(&d, Rgb::BLACK), 0.0);
    let v = op(
        "themes_menu_highlight_share",
        json!({ "tokens": { "textPrimary": cj(Rgb::hex(0x595959)), "accent": cj(Rgb::BLACK) }, "ground": cj(Rgb::WHITE) }),
    );
    assert!((v.as_f64().unwrap() - share).abs() < EPS);
}

#[test]
fn spinner_ink_pins() {
    // Plain dark: white at 66% reads 3:1 on every row; the share stays.
    let t = tokens(0x000000, 0xFFFFFF);
    let ink = spinner_ink(&t);
    assert!(close(ink, t.text_primary.with_alpha(t.text_primary.a * 0.66)));
    // Low-contrast grey: the share rises.
    let t = tokens(0x3A3A3A, 0xA8A8A8);
    let ink = spinner_ink(&t);
    assert!(ink.a >= 0.66 * t.text_primary.a - EPS);
    let v = op("themes_spinner_ink", json!({ "tokens": tokens_json(0x3A3A3A, 0xA8A8A8) }));
    assert!(close(rgb_of(&v), ink));
}

// Glass text

#[test]
fn veil_and_ink_pins() {
    let tint = Rgb::new(0.1, 0.2, 0.3, 0.5);
    let veil = Veil { white: 0.99, alpha: 0.7 };
    assert!(close(veil_rgb(veil, false, tint), Rgb::new(0.99, 0.99, 0.99, 0.7)));
    assert!(close(veil_rgb(veil, true, tint), Rgb::new(0.1, 0.2, 0.3, 0.7)));
    let v = op(
        "themes_veil_rgb",
        json!({ "veil": { "white": 0.99, "alpha": 0.7 }, "takesThemeTint": true, "glassTint": cj(tint) }),
    );
    assert!(close(rgb_of(&v), Rgb::new(0.1, 0.2, 0.3, 0.7)));
    assert_eq!(ThemeInk::Tertiary.minimum_contrast(), 3.0);
    assert_eq!(ThemeInk::Danger.minimum_contrast(), 4.5);
    assert_eq!(DIALOG_MINIMUM_CONTRAST, 4.5);
    let t = tokens(0x1E1E1E, 0xE6E6E6);
    assert!(close(ThemeInk::Secondary.rgb(&t), t.text_secondary));
    assert!(close(ThemeInk::Danger.rgb(&t), t.danger));
}

#[test]
fn fit_readable_pins() {
    // Reads already: unchanged.
    assert!(close(fit_readable(Rgb::WHITE, &[Rgb::BLACK], 4.5), Rgb::WHITE));
    // One surface: one `readable` at 4.55.
    let grey = Rgb::new(0.6, 0.6, 0.6, 1.0);
    assert!(close(fit_readable(grey, &[Rgb::WHITE], 4.5), readable(grey, Rgb::WHITE, 4.55)));
    // White and black surfaces both: nothing reads at 4.55 on both, the fallback picks the best
    // worst contrast among the fit, white and black (each reads on one).
    let out = fit_readable(grey, &[Rgb::WHITE, Rgb::BLACK], 4.5);
    let worst = |c: Rgb| c.contrast(Rgb::WHITE).min(c.contrast(Rgb::BLACK));
    assert!(worst(out) >= worst(Rgb::WHITE) && worst(out) >= worst(Rgb::BLACK));
    let v = op("themes_fit_readable", json!({ "ink": cj(grey), "surfaces": [cj(Rgb::WHITE)] }));
    assert!(close(rgb_of(&v), readable(grey, Rgb::WHITE, 4.55)));
}

#[test]
fn toast_and_card_text() {
    let t = tokens(0xFDF6E3, 0x657B83);
    let veil = Veil { white: 0.99, alpha: 0.5 };
    let ground = toast_ground(&t, false, 0.14, veil, false);
    assert!(close(
        ground,
        Rgb::new(0.99, 0.99, 0.99, 0.5).composited(t.window_background.with_alpha(1.0))
    ));
    assert!(close(toast_ground(&t, true, 0.14, veil, false), t.opaque_overlay_fill(0.14)));
    let text = toast_text(&t, ThemeInk::Secondary, false, 0.14, veil, false);
    assert!(close(text, fit_readable(t.text_secondary.with_alpha(1.0), &[ground], 4.5)));
    assert!(text.contrast(ground) >= 4.5);
    let primary = toast_text(&t, ThemeInk::Primary, false, 0.14, veil, false);
    let title = toast_ink_title(&t, false, 0.14, veil, false);
    assert!(close(title, fit_readable(t.window_background.with_alpha(1.0), &[primary], 4.5)));
    let v = op(
        "themes_toast_text",
        json!({ "tokens": tokens_json(0xFDF6E3, 0x657B83), "ink": "secondary", "veil": { "white": 0.99, "alpha": 0.5 } }),
    );
    assert!(close(rgb_of(&v["ground"]), ground));
    assert!(close(rgb_of(&v["text"]), text));
    assert!(close(rgb_of(&v["inkTitle"]), title));
    let surfaces = [Rgb::hex(0xEEEEEE), Rgb::hex(0xDDDDDD)];
    let card = card_text(&t, ThemeInk::Tertiary, &surfaces);
    assert!(close(card, fit_readable(t.text_tertiary.with_alpha(1.0), &surfaces, 3.0)));
    let v = op(
        "themes_card_text",
        json!({ "tokens": tokens_json(0xFDF6E3, 0x657B83), "ink": "tertiary", "surfaces": surfaces.map(cj) }),
    );
    assert!(close(rgb_of(&v), card));
}

// Swatch

#[test]
fn css_hex_forms() {
    assert!(close(css_hex("#FF8000").unwrap(), Rgb::new(1.0, 128.0 / 255.0, 0.0, 1.0)));
    assert!(close(css_hex("  f80 ").unwrap(), Rgb::new(1.0, 136.0 / 255.0, 0.0, 1.0)));
    assert!(close(css_hex("#11223380").unwrap(), Rgb::hex(0x112233).with_alpha(128.0 / 255.0)));
    for bad in ["", "#", "#12", "#1234", "#12345", "#GGGGGG", "#1122334455", "+12345"] {
        assert!(css_hex(bad).is_none(), "{bad}");
    }
    assert!(close(rgb_of(&op("themes_css_hex", json!({ "text": "#abc" }))), Rgb::hex(0xAABBCC)));
    assert_eq!(op("themes_css_hex", json!({ "text": "nope" })), Value::Null);
}

#[test]
fn swatch_strip() {
    assert_eq!(PALETTE_INDICES, [1, 2, 3, 4, 5, 6]);
    let file = "# comment\nbackground = #101010\npalette = 0=#000000\npalette = 1=#ff0000\n\
                palette = 3=#0000ff\npalette=2=#00ff00\npalette = 1=#aa0000\npalette = 7=#ffffff\n\
                foreground = #eeeeee\nbogus = 1\n";
    let s = strip(file);
    let expect = [0x101010, 0xAA0000, 0x00FF00, 0x0000FF, 0xEEEEEE].map(Rgb::hex);
    assert_eq!(s.len(), expect.len());
    for (a, b) in s.iter().zip(expect) {
        assert!(close(*a, b));
    }
    assert!(strip("font-size = 12\n").is_empty());
    // No value after `=` is not a split; the line is skipped.
    assert!(strip("background =\n").is_empty());
    assert!(strip("background=").is_empty());
    let v = op("themes_swatch_strip", json!({ "text": "foreground=#fff\r\nbackground=#000" }));
    assert_eq!(v.as_array().unwrap().len(), 2);
    assert!(close(rgb_of(&v[0]), Rgb::BLACK));
    assert!(close(rgb_of(&v[1]), Rgb::WHITE));
}

// Audit

fn audit_colors(is_dark: bool) -> AuditColors {
    let a = |hex: u32| Appearances::themed(Rgb::hex(hex));
    AuditColors {
        is_dark,
        card_tint: Rgb::hex(0x202020).with_alpha(0.8).into(),
        window: a(0x1E1E1E),
        hover: Appearances::themed(Rgb::WHITE.with_alpha(0.06)),
        selection: Appearances::themed(Rgb::WHITE.with_alpha(0.12)),
        pressed: Appearances::themed(Rgb::WHITE.with_alpha(0.16)),
        menu_highlight: Appearances::themed(Rgb::WHITE.with_alpha(0.2)),
        text_primary: a(0xE6E6E6),
        text_secondary: a(0xB0B0B0),
        text_tertiary: a(0x8A8A8A),
        status_unread: a(0x0A84FF),
        status_attention: a(0xFFD60A),
        status_error: a(0xFF453A),
        notification: a(0x3982F5),
        spinner: Appearances::themed(Rgb::hex(0xE6E6E6).with_alpha(0.66)),
        attention: a(0xFFD60A),
        danger: a(0xFF453A),
        success: a(0x32D74B),
        lit_glyph: a(0xE6E6E6),
        accent_fill: a(0x0A84FF),
        on_accent: a(0xFFFFFF),
        highlight: a(0x0A84FF),
        highlight_text: Appearances { own: Rgb::WHITE.into(), other: Some(Rgb::BLACK.into()) },
    }
}

#[test]
fn audit_tables() {
    assert_eq!(ThemeElement::ALL.len(), 17);
    assert_eq!(ThemeElementGround::ALL.len(), 8);
    assert_eq!(ThemeElement::DotAttention.raw_value(), "dotAttention");
    assert_eq!(ThemeElement::DotAttention.title(), "Sidebar status dot: needs attention");
    assert_eq!(ThemeElement::Detail.title(), "Sidebar row detail, inactive tab title");
    assert_eq!(ThemeElement::UpdateLabel.title_key(), "theme.audit.element.updateLabel");
    assert_eq!(ThemeElementGround::HoveredRow.title(), "hovered row");
    assert_eq!(ThemeElementGround::UpdateButton.raw_value(), "updateButton");
    for e in ThemeElement::ALL {
        assert_eq!(serde_json::to_value(e).unwrap(), json!(e.raw_value()));
        assert_eq!(e.title_key(), format!("theme.audit.element.{}", e.raw_value()));
    }
    for g in ThemeElementGround::ALL {
        assert_eq!(serde_json::to_value(g).unwrap(), json!(g.raw_value()));
    }
    let v = op("themes_element_table", json!({}));
    assert_eq!(v["elements"].as_array().unwrap().len(), 17);
    assert_eq!(
        v["elements"][0],
        json!({ "element": "title", "titleKey": "theme.audit.element.title", "title": "Sidebar row and tab title" })
    );
    assert_eq!(v["grounds"][4]["title"], json!("popover"));
}

#[test]
fn resolved_rules() {
    let base = Resolved::computed(Rgb::new(0.2, 0.2, 0.2, 0.5));
    assert!(close(base.color, Rgb::new(0.2, 0.2, 0.2, 1.0)));
    assert!(!base.follows_system);
    let r = Resolved::over(Appearances::themed(Rgb::WHITE.with_alpha(0.5)), Some(base));
    assert!(close(r.color, Rgb::new(0.6, 0.6, 0.6, 1.0)));
    assert!(!r.follows_system);
    // No base: over black.
    let r = Resolved::over(Appearances::themed(Rgb::WHITE.with_alpha(0.25)), None);
    assert!(close(r.color, Rgb::new(0.25, 0.25, 0.25, 1.0)));
    // A difference under 0.004 per channel is the same colour.
    let near =
        Appearances { own: Rgb::WHITE.into(), other: Some(Rgb::new(0.997, 1.0, 1.0, 1.0).into()) };
    assert!(!Resolved::over(near, None).follows_system);
    let far =
        Appearances { own: Rgb::WHITE.into(), other: Some(Rgb::new(0.99, 1.0, 1.0, 1.0).into()) };
    let follows = Resolved::over(far, None);
    assert!(follows.follows_system);
    assert!(Resolved::over(Appearances::themed(Rgb::BLACK), Some(follows)).follows_system);
}

#[test]
fn audit_samples_order_and_minimums() {
    let c = audit_colors(true);
    let s = audit_samples(&c);
    // title, detail x4 rows; hint 1; 5 marks x2; 4 status x1; popover 2; highlighted, accent, update.
    assert_eq!(s.len(), 4 + 4 + 1 + 10 + 4 + 2 + 3);
    assert_eq!((s[0].element, s[0].ground), (ThemeElement::Title, ThemeElementGround::Window));
    assert_eq!((s[3].element, s[3].ground), (ThemeElement::Title, ThemeElementGround::PressedRow));
    assert_eq!((s[8].element, s[8].minimum), (ThemeElement::Hint, 3.0));
    assert_eq!((s[9].element, s[9].ground), (ThemeElement::DotUnread, ThemeElementGround::Window));
    assert_eq!(
        (s[10].element, s[10].ground),
        (ThemeElement::DotUnread, ThemeElementGround::SelectedRow)
    );
    assert_eq!(s[19].element, ThemeElement::StatusAttention);
    assert_eq!(
        (s[23].element, s[23].ground, s[23].minimum),
        (ThemeElement::PopoverText, ThemeElementGround::Popover, 4.5)
    );
    assert_eq!(s[25].ground, ThemeElementGround::HighlightedRow);
    assert_eq!(s[26].ground, ThemeElementGround::AccentButton);
    assert_eq!(s[27].element, ThemeElement::UpdateLabel);
    // The hovered row: white 6% over 1E1E1E.
    let window = Rgb::hex(0x1E1E1E);
    assert!(close(
        s[1].surface.into(),
        Rgb::WHITE.with_alpha(0.06).composited(window).with_alpha(1.0)
    ));
    // The popover: the card tint over white (dark theme's worst desktop).
    let popup = Rgb::hex(0x202020).with_alpha(0.8).composited(Rgb::WHITE).with_alpha(1.0);
    assert!(close(s[23].surface.into(), popup));
    let highlighted = Rgb::WHITE.with_alpha(0.2).composited(popup).with_alpha(1.0);
    assert!(close(s[25].surface.into(), highlighted));
    // The spinner ink is composited over its row.
    let spin = Rgb::hex(0xE6E6E6).with_alpha(0.66).composited(window).with_alpha(1.0);
    assert!(close(s[17].ink.into(), spin));
    // The update label follows the system: it fails whatever its contrast.
    assert!(s[27].follows_system_appearance && !s[27].passes());
    let failures = audit_failures(&s);
    assert!(failures.iter().any(|f| f.element == ThemeElement::UpdateLabel));
    let v = op("themes_audit", serde_json::to_value(c).unwrap());
    assert_eq!(v["samples"].as_array().unwrap().len(), s.len());
    assert_eq!(v["failing"], json!(failures.len()));
    assert_eq!(v["samples"][27]["passes"], json!(false));
    assert!((v["samples"][0]["contrast"].as_f64().unwrap() - s[0].contrast()).abs() < EPS);
}

fn sample(ink: Rgb, surface: Rgb, minimum: f64, follows: bool) -> ThemeElementSample {
    ThemeElementSample {
        element: ThemeElement::DotError,
        ground: ThemeElementGround::SelectedRow,
        ink: ink.into(),
        surface: surface.into(),
        minimum,
        follows_system_appearance: follows,
    }
}

#[test]
fn sample_pass_and_help() {
    let s = sample(Rgb::WHITE, Rgb::BLACK, 3.0, false);
    assert!((s.contrast() - 21.0).abs() < EPS);
    assert!(s.passes());
    assert!(!sample(Rgb::WHITE, Rgb::BLACK, 3.0, true).passes());
    assert!(!sample(Rgb::WHITE, Rgb::WHITE, 3.0, false).passes());
    assert_eq!(
        playground_sample_help(&s),
        "Sidebar status dot: error on selected row: 21.00:1, needs 3.0:1"
    );
    assert_eq!(
        playground_sample_help(&sample(Rgb::WHITE, Rgb::BLACK, 3.0, true)),
        "Sidebar status dot: error on selected row: follows the system appearance, not the theme"
    );
    let v = op("themes_sample", json!({ "sample": serde_json::to_value(s).unwrap() }));
    assert_eq!(v["passes"], json!(true));
    assert_eq!(v["help"], json!("Sidebar status dot: error on selected row: 21.00:1, needs 3.0:1"));
}

fn entry(name: &str, fails: bool) -> PlaygroundEntry {
    let s = sample(Rgb::WHITE, if fails { Rgb::WHITE } else { Rgb::BLACK }, 3.0, false);
    PlaygroundEntry { name: name.into(), is_dark: true, samples: vec![s] }
}

#[test]
fn playground_model() {
    let entries =
        vec![entry("Nord", false), entry("Dracula", true), entry("Ayu", false), entry("Zen", true)];
    let sorted: Vec<String> =
        playground_sorted(entries.clone()).into_iter().map(|e| e.name).collect();
    assert_eq!(sorted, ["Dracula", "Zen", "Ayu", "Nord"]);
    assert_eq!(playground_failing_count(&entries), 2);
    assert_eq!(playground_shown(&entries, "", false), [0, 1, 2, 3]);
    assert_eq!(playground_shown(&entries, "", true), [1, 3]);
    assert_eq!(playground_shown(&entries, "NO", false), [0]);
    assert_eq!(playground_shown(&entries, "a", true), [1]);
    assert!(name_matches("Solarized Dark", "dark"));
    let files = playground_files(&[
        vec!["Nord".into(), ".DS_Store".into(), "Ayu".into()],
        vec!["Nord".into()],
    ]);
    assert_eq!(files, [("Ayu".to_string(), 0), ("Nord".to_string(), 1)]);
    let wire: Vec<Value> = entries.iter().map(|e| serde_json::to_value(e).unwrap()).collect();
    let v = op(
        "themes_playground_shown",
        json!({ "entries": wire, "query": "a", "failuresOnly": true }),
    );
    assert_eq!(v, json!({ "shown": [1], "failingCount": 2 }));
    let v = op("themes_playground_sorted", json!({ "entries": wire }));
    assert_eq!(v, json!(["Dracula", "Zen", "Ayu", "Nord"]));
    let v = op("themes_playground_files", json!({ "folders": [["b", ".x", "a"], ["b"]] }));
    assert_eq!(v, json!([{ "name": "a", "folder": 0 }, { "name": "b", "folder": 1 }]));
}

#[test]
fn playground_strings() {
    assert_eq!(playground_summary(3, 622), "3 of 622 themes fail");
    assert_eq!(playground_failing(2), "2 failing");
    assert_eq!(PLAYGROUND_STRINGS[0], ("theme.playground.windowTitle", "All Themes"));
    assert_eq!(PLAYGROUND_STRINGS[4], ("theme.playground.dark", "Dark"));
    let v = op("themes_playground_strings", json!({ "failing": 3, "total": 622 }));
    assert_eq!(v["summary"], json!("3 of 622 themes fail"));
    assert_eq!(v["failing"], json!("3 failing"));
    assert_eq!(v["fixed"]["theme.playground.search"], json!("Search themes"));
}

#[test]
fn unknown_and_invalid() {
    assert_eq!(call("tokens.themes_nope", &json!({})), Err(OpError::Unknown));
    assert!(matches!(call("tokens.themes_css_hex", &json!({})), Err(OpError::Invalid(_))));
    // Wire tokens with nothing set are the fallback.
    let v = op("themes_spinner_ink", json!({}));
    assert!(close(rgb_of(&v), spinner_ink(&ThemeTokens::fallback())));
}
