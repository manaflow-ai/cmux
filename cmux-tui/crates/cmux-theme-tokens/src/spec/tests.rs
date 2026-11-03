//! The token oracle (cmux-next-spec decisions.md B11): `themes.*` in the
//! spec holds Swift `ThemeTokens.derive` of five reference themes (computed by
//! the spec's tools/derive_theme_tokens.py). Each one derived here must give
//! the same `isDark`, every token, every composited color and the three pane
//! ring levels, as the spec's hex (channels rounded half away from zero).
//! A theme's `input.accent` (`appearance.accent`) and `input.cursor`
//! (`cursor-color`) cover the hued accent (Swift `AppTheme`) and the caret;
//! `input.accentColor` is the theme's own accent (wins over `accent`).

use super::json::{self, Value};
use super::*;
use crate::{ThemeAccent, ThemeInput, ThemeTokens};

fn hex(s: &str) -> Rgb {
    let v =
        s.strip_prefix('#').filter(|v| v.len() == 6).and_then(|v| u32::from_str_radix(v, 16).ok());
    Rgb::hex(v.unwrap_or_else(|| panic!("{s:?} is not #RRGGBB")))
}

fn css(c: Rgb) -> String {
    let ch = |v: f64| (v * 255.0).round() as u32;
    let rgb = format!("#{:02X}{:02X}{:02X}", ch(c.r), ch(c.g), ch(c.b));
    if c.a < 1.0 { format!("{rgb}{:02X}", ch(c.a)) } else { rgb }
}

fn token(t: &ThemeTokens, name: &str) -> Option<Rgb> {
    Some(match name {
        "windowBackground" => t.window_background,
        "sidebarBackground" => t.sidebar_background,
        "contentBackground" => t.content_background,
        "chromeBackground" => t.chrome_background,
        "elevatedBackground" => t.elevated_background,
        "stripBackground" => t.strip_background,
        "sidebarStep" => t.sidebar_step,
        "stripStep" => t.strip_step,
        "textPrimary" => t.text_primary,
        "textSecondary" => t.text_secondary,
        "textTertiary" => t.text_tertiary,
        "hoverFill" => t.hover_fill,
        "selectionFill" => t.selection_fill,
        "secondarySelectionFill" => t.secondary_selection_fill,
        "pressedFill" => t.pressed_fill,
        "badgeFill" => t.badge_fill,
        "separator" => t.separator,
        "paneBorder" => t.pane_border,
        "focusRing" => t.focus_ring,
        "glassTint" => t.glass_tint,
        "shadow" => t.shadow,
        "textSelection" => t.text_selection,
        "attention" => t.attention,
        "danger" => t.danger,
        "success" => t.success,
        "highlight" => t.highlight,
        "highlightText" => t.highlight_text,
        "accent" => t.accent,
        "onAccent" => t.on_accent,
        "caret" => t.caret,
        _ => return None,
    })
}

#[test]
fn derive_matches_the_spec_reference_themes() {
    let doc = json::parse(DESIGN_TOKENS).expect("design-tokens.json parses");
    let Some(Value::Object(themes)) = doc.get("themes") else { panic!("no themes object") };
    assert!(!themes.is_empty(), "no reference themes");
    let ring =
        doc.get("settings").and_then(|s| s.get("focusRing.contrast")).and_then(|c| c.get("value"));
    let ring_alpha = |level: &str| {
        ring.and_then(|r| r.get("values"))
            .and_then(|v| v.get(level))
            .and_then(Value::as_f64)
            .unwrap()
    };
    let mut errors = Vec::new();
    for (name, theme) in themes {
        let input_of = |key: &str| theme.get("input").and_then(|i| i.get(key));
        let palette: Vec<Rgb> = input_of("palette")
            .and_then(Value::as_array)
            .unwrap()
            .iter()
            .map(|p| hex(p.as_str().unwrap()))
            .collect();
        let background = hex(input_of("background").and_then(Value::as_str).unwrap());
        let input = ThemeInput {
            background,
            foreground: hex(input_of("foreground").and_then(Value::as_str).unwrap()),
            palette: palette.try_into().expect("16 palette entries"),
            selection_background: input_of("selectionBackground").and_then(Value::as_str).map(hex),
            selection_foreground: None,
            background_opacity: 1.0,
            background_blur: 0,
            cursor: input_of("cursor").and_then(Value::as_str).map(hex),
            accent_color: input_of("accentColor").and_then(Value::as_str).map(hex),
            accent: input_of("accent").and_then(Value::as_str).map_or(ThemeAccent::Neutral, |a| {
                ThemeAccent::parse(a).unwrap_or_else(|| panic!("{name}.input.accent {a:?}"))
            }),
        };
        let t = ThemeTokens::derive(&input);
        if theme.get("isDark").and_then(Value::as_bool) != Some(t.is_dark) {
            errors.push(format!("{name}.isDark: derive {}", t.is_dark));
        }
        for section in ["tokens", "composited"] {
            let Some(Value::Object(entries)) = theme.get(section) else {
                panic!("{name}.{section}")
            };
            for (key, spec) in entries {
                let Some(color) = token(&t, key) else {
                    errors.push(format!("{name}.{section}.{key}: not derived"));
                    continue;
                };
                let color =
                    if section == "composited" { color.composited(background) } else { color };
                if spec.as_str() != Some(css(color).as_str()) {
                    errors.push(format!(
                        "{name}.{section}.{key}: spec {spec:?}, derive {}",
                        css(color)
                    ));
                }
            }
        }
        for level in ["subtle", "standard", "strong"] {
            let spec = theme.get("focusRing").and_then(|r| r.get(level)).and_then(Value::as_str);
            let got = css(t.focus_ring.with_alpha(ring_alpha(level)));
            if spec != Some(got.as_str()) {
                errors.push(format!("{name}.focusRing.{level}: spec {spec:?}, derive {got}"));
            }
        }
    }
    assert!(
        errors.is_empty(),
        "derive differs from design-tokens.json themes.*:\n  {}",
        errors.join("\n  ")
    );
}

/// Every bundled theme's inks and popup surface as Swift derives them
/// (schemas/theme/theme-ink-vectors.json, which Swift's
/// `ThemeInkVectorsTests` keeps equal to its output): this port gives the same.
const INK_VECTORS: &str = include_str!("../../../../../schemas/theme/theme-ink-vectors.json");

#[test]
fn derive_matches_the_swift_ink_vectors() {
    let doc = json::parse(INK_VECTORS).expect("theme-ink-vectors.json parses");
    let lift = doc.get("lift").and_then(Value::as_f64).expect("theme-ink-vectors.json lift");
    let cases = doc.get("cases").and_then(Value::as_array).expect("theme-ink-vectors.json cases");
    assert!(cases.len() > 500, "only {} themes", cases.len());
    let mut errors = Vec::new();
    for case in cases {
        let name = case.get("theme").and_then(Value::as_str).unwrap_or("?");
        let input_of = |key: &str| case.get("input").and_then(|i| i.get(key));
        let color = |key: &str| input_of(key).and_then(Value::as_str).map(hex);
        // Only a theme with its own accent lists its palette (the inks read it through AppTheme).
        let palette = input_of("palette").and_then(Value::as_array).map_or(
            ThemeInput::GHOSTTY_DEFAULT.palette,
            |p| {
                let p: Vec<Rgb> = p.iter().map(|c| hex(c.as_str().unwrap_or_default())).collect();
                p.try_into().unwrap_or_else(|_| panic!("{name}: 16 palette entries"))
            },
        );
        let input = ThemeInput {
            background: color("background").unwrap_or_else(|| panic!("{name}: background")),
            foreground: color("foreground").unwrap_or_else(|| panic!("{name}: foreground")),
            palette,
            accent_color: color("accentColor"),
            ..ThemeInput::GHOSTTY_DEFAULT
        };
        let t = ThemeTokens::derive(&input);
        if case.get("isDark").and_then(Value::as_bool) != Some(t.is_dark) {
            errors.push(format!("{name}.isDark: derive {}", t.is_dark));
        }
        for (key, got) in [
            ("textPrimary", t.text_primary),
            ("textSecondary", t.text_secondary),
            ("textTertiary", t.text_tertiary),
            ("opaqueOverlayFill", t.opaque_overlay_fill(lift)),
        ] {
            let want = case.get(key).and_then(Value::as_str);
            if want != Some(css(got).as_str()) {
                errors.push(format!("{name}.{key}: Swift {want:?}, derive {}", css(got)));
            }
        }
    }
    assert!(
        errors.is_empty(),
        "derive differs from schemas/theme/theme-ink-vectors.json in {} values:\n  {}",
        errors.len(),
        errors.join("\n  ")
    );
}

#[test]
fn constants_match_the_spec() {
    assert!(Spec::parse(DESIGN_TOKENS).is_ok(), "design-tokens.json theme section parses");
    let spec = spec();
    assert_eq!(spec.minimum_text_contrast, crate::MINIMUM_TEXT_CONTRAST);
    assert_eq!(spec.minimum_mark_contrast, crate::MINIMUM_MARK_CONTRAST);
}

/// In a see-through window the quieter inks hold their minimums over the tint
/// on the worst desktop for the theme (Swift `SeeThroughInkTests`), as far as
/// the primary ink reaches there; an opaque window keeps the spec's inks.
#[test]
fn see_through_inks_hold_over_the_worst_desktop() {
    for (background, foreground) in [(0xFEFFFF, 0x000000), (0x1E1E1E, 0xFFFFFF)] {
        for opacity in [0.3, 0.6, 0.85] {
            let input = ThemeInput {
                background: Rgb::hex(background),
                foreground: Rgb::hex(foreground),
                background_opacity: opacity,
                background_blur: -1,
                ..ThemeInput::GHOSTTY_DEFAULT
            };
            let t = ThemeTokens::derive(&input);
            let surfaces = crate::tokens::see_through_surfaces(
                input.background,
                opacity,
                t.is_dark,
                &[t.pressed_fill, t.selection_fill],
            );
            for surface in surfaces {
                let reach = t.text_primary.contrast(surface);
                let secondary = t.text_secondary.contrast(surface);
                let tertiary = t.text_tertiary.contrast(surface);
                assert!(secondary >= crate::MINIMUM_TEXT_CONTRAST.min(reach) - 1e-9, "{opacity}");
                assert!(tertiary >= crate::MINIMUM_MARK_CONTRAST.min(reach) - 1e-9, "{opacity}");
            }
        }
    }
}
