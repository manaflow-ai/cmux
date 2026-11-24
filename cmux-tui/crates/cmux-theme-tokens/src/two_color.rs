//! A whole theme from two colors: a canvas and an accent. Every key a
//! scheme file has (background, foreground, cursor, selection, ANSI 0...15
//! and the chrome accent) comes from them, and the chrome surfaces (sidebar,
//! chat, borders) follow from the scheme through `ThemeTokens::derive`, as
//! for any theme. Text is held to the spec's `minimumTextContrast` on the
//! canvas, the accent, cursor and ANSI colors to `minimumMarkContrast`.
//!
//! Deterministic: no random seeds; the same two colors give the same bytes.

use crate::image_palette::{ANSI_HUES, chroma, from_hsl, hsl};
use crate::spec::spec;
use crate::{Appearance, Rgb, Scheme, ThemeTokens, readable};

/// Relative luminance where black and white text read equally well; a
/// canvas above it is light, below it dark.
const MIDPOINT: f64 = 0.179;

/// What two colors give.
#[derive(Clone, Debug, PartialEq)]
pub struct TwoColorTheme {
    /// The terminal scheme (its `accent` is the chrome accent).
    pub scheme: Scheme,
    /// Dark or light, from the canvas's luminance unless asked.
    pub appearance: Appearance,
    /// The chrome accent, at least `minimumMarkContrast` on the canvas.
    pub accent: Rgb,
    /// The window's glass tint, as `ThemeTokens::derive` makes it from the scheme.
    pub glass_tint: Rgb,
}

fn opaque(c: Rgb) -> Rgb {
    Rgb::hex(c.to_hex())
}

/// `color` as an opaque 8-bit color that reads at `minimum` on `surface`
/// after quantizing (a small margin keeps rounding from dropping under).
fn fit(color: Rgb, surface: Rgb, minimum: f64) -> Rgb {
    let mut out = opaque(readable(color, surface, minimum + 0.05));
    if out.contrast(surface) < minimum {
        let pole = if surface.relative_luminance() < MIDPOINT { Rgb::WHITE } else { Rgb::BLACK };
        out = opaque(pole);
    }
    out
}

/// The theme for `canvas` and `accent`. `appearance` `None` picks dark or
/// light from the canvas's luminance; a canvas on the wrong side of an
/// asked appearance is pushed toward black (white) until text can read on it.
pub fn theme_from_two_colors(
    canvas: Rgb,
    accent: Rgb,
    appearance: Option<Appearance>,
) -> TwoColorTheme {
    let spec = spec();
    let (text_min, mark_min) = (spec.minimum_text_contrast, spec.minimum_mark_contrast);
    let canvas = opaque(canvas.with_alpha(1.0));
    let accent = opaque(accent.with_alpha(1.0));
    let appearance = appearance.unwrap_or(if canvas.relative_luminance() < MIDPOINT {
        Appearance::Dark
    } else {
        Appearance::Light
    });
    let dark = appearance == Appearance::Dark;

    // Both poles read on the canvas only at the midpoint; off its side, walk
    // the canvas toward the asked pole until the far pole reads at the text minimum.
    let pole = if dark { Rgb::WHITE } else { Rgb::BLACK };
    let mut background = canvas;
    let mut step = 0.0;
    while step < 1.0 && pole.contrast(background) < text_min + 0.3 {
        step += 0.02;
        background = canvas.mixed(if dark { Rgb::BLACK } else { Rgb::WHITE }, step);
    }
    let background = opaque(background);

    // Foreground: the pole with the accent's hue a little in it.
    let foreground = fit(pole.mixed(accent, 0.10), background, text_min);

    // Accent held to the mark floor on the canvas.
    let accent = fit(accent, background, mark_min);
    let (accent_hue, accent_saturation, _) = hsl(accent);
    // ANSI saturation follows the accent's, within a range that stays colorful.
    let saturation = if chroma(accent) < 0.05 { 0.55 } else { accent_saturation.clamp(0.45, 0.80) };

    let (normal_l, bright_l) = if dark { (0.62, 0.72) } else { (0.40, 0.32) };
    let mut palette = [Rgb::BLACK; 16];
    for (i, hue) in ANSI_HUES.iter().enumerate() {
        let index = i.saturating_add(1);
        // The hue nearest the accent's takes the accent's exact hue, so the
        // ANSI colors and the chrome agree.
        let hue = if (hue - accent_hue).abs().min(360.0 - (hue - accent_hue).abs()) <= 20.0
            && chroma(accent) >= 0.05
        {
            accent_hue
        } else {
            *hue
        };
        if let Some(slot) = palette.get_mut(index) {
            *slot = fit(from_hsl(hue, saturation, normal_l), background, mark_min);
        }
        if let Some(slot) = palette.get_mut(index.saturating_add(8)) {
            *slot = fit(from_hsl(hue, saturation, bright_l), background, mark_min);
        }
    }
    if let Some(slot) = palette.get_mut(0) {
        *slot = opaque(background.mixed(foreground, 0.12));
    }
    if let Some(slot) = palette.get_mut(7) {
        *slot = fit(foreground.mixed(background, 0.15), background, text_min);
    }
    if let Some(slot) = palette.get_mut(8) {
        *slot = fit(background.mixed(foreground, 0.45), background, mark_min);
    }
    if let Some(slot) = palette.get_mut(15) {
        *slot = foreground;
    }

    // Selection: the accent a third of the way into the canvas, text on it.
    let selection_background = opaque(background.mixed(accent, 0.30));
    let selection_foreground = fit(foreground, selection_background, text_min);
    let scheme = Scheme {
        name: None,
        author: None,
        background,
        foreground,
        cursor: Some(accent),
        cursor_text: Some(fit(background, accent, text_min)),
        selection_background: Some(selection_background),
        selection_foreground: Some(selection_foreground),
        palette,
        accent: Some(accent),
        base16: None,
    };
    let glass_tint = ThemeTokens::derive(&scheme.theme_input()).glass_tint;
    TwoColorTheme { scheme, appearance, accent, glass_tint }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn canvases() -> [u32; 7] {
        [0x101418, 0x000000, 0x1e1e2e, 0xfafafa, 0xffffff, 0xf4ecd8, 0x808080]
    }

    fn accents() -> [u32; 5] {
        [0x7aa2f7, 0xff0000, 0x00ff00, 0x222222, 0xeeeeee]
    }

    #[test]
    fn every_key_is_set() {
        let t = theme_from_two_colors(Rgb::hex(0x101418), Rgb::hex(0x7aa2f7), None);
        let s = &t.scheme;
        assert!(s.cursor.is_some() && s.cursor_text.is_some());
        assert!(s.selection_background.is_some() && s.selection_foreground.is_some());
        assert_eq!(s.accent, Some(t.accent));
        assert_eq!(s.background.to_hex(), 0x101418);
        let text = s.export(crate::SchemeFormat::Ghostty);
        for key in [
            "background",
            "foreground",
            "cursor-color",
            "cursor-text",
            "selection-background",
            "selection-foreground",
            "cmux-accent",
        ] {
            assert!(text.contains(key), "{key} missing:\n{text}");
        }
        assert_eq!(text.matches("palette = ").count(), 16, "{text}");
    }

    #[test]
    fn appearance_follows_the_canvas() {
        let dark = theme_from_two_colors(Rgb::hex(0x101418), Rgb::hex(0x7aa2f7), None);
        let light = theme_from_two_colors(Rgb::hex(0xfafafa), Rgb::hex(0x7aa2f7), None);
        assert_eq!(dark.appearance, Appearance::Dark);
        assert_eq!(light.appearance, Appearance::Light);
    }

    #[test]
    fn contrast_holds_on_every_canvas_and_accent() {
        let spec = spec();
        let (text, mark) = (spec.minimum_text_contrast, spec.minimum_mark_contrast);
        for canvas in canvases() {
            for accent in accents() {
                for asked in [None, Some(Appearance::Dark), Some(Appearance::Light)] {
                    let t = theme_from_two_colors(Rgb::hex(canvas), Rgb::hex(accent), asked);
                    let s = &t.scheme;
                    let ctx = format!("canvas {canvas:06x} accent {accent:06x} {asked:?}");
                    assert!(s.foreground.contrast(s.background) >= text, "foreground {ctx}");
                    for (i, c) in s.palette.iter().enumerate() {
                        let floor = if matches!(i, 0) {
                            1.0
                        } else if i == 7 {
                            text
                        } else {
                            mark
                        };
                        assert!(c.contrast(s.background) >= floor, "ansi {i} {ctx}");
                    }
                    assert!(t.accent.contrast(s.background) >= mark, "accent {ctx}");
                    let (sb, sf) =
                        (s.selection_background.unwrap(), s.selection_foreground.unwrap());
                    assert!(sf.contrast(sb) >= text, "selection {ctx}");
                    assert!(s.cursor_text.unwrap().contrast(t.accent) >= text, "cursor text {ctx}");
                }
            }
        }
    }

    #[test]
    fn same_colors_same_theme() {
        let a = theme_from_two_colors(Rgb::hex(0x1e1e2e), Rgb::hex(0xcba6f7), None);
        let b = theme_from_two_colors(Rgb::hex(0x1e1e2e), Rgb::hex(0xcba6f7), None);
        assert_eq!(a, b);
    }
}
