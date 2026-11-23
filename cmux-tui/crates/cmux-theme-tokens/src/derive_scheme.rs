//! A whole terminal scheme from two colors: the canvas (the background) and
//! the accent. Every other color derives from them: dark or light from the
//! canvas luminance, the foreground a near-pole tinted with the canvas hue,
//! ANSI 1...6 at the accent's colorfulness (the slot nearest the accent's
//! hue takes its hue), the grays mixed between background and foreground,
//! and selection and cursor from the accent. Every text color is held to
//! the spec's `minimumTextContrast` (at least WCAG 4.5:1) on the canvas, the
//! accent and bright black to `minimumMarkContrast` (at least 3:1), and the
//! selection keeps its text readable. Lightness moves in OKLCH, so a fitted
//! color keeps its hue.

use crate::spec::spec;
use crate::{Appearance, Oklch, Rgb, Scheme, fit_contrast, from_oklch, oklch};

/// What [`scheme_from_colors`] gives.
#[derive(Clone, Debug, PartialEq)]
pub struct DerivedScheme {
    /// The scheme (its `accent` is the chrome accent).
    pub scheme: Scheme,
    /// Dark or light, from the canvas luminance.
    pub appearance: Appearance,
}

/// ANSI 1...6's OKLCH hues: red, green, yellow, blue, magenta, cyan.
const ANSI_HUES: [f64; 6] = [29.0, 142.0, 100.0, 264.0, 328.0, 195.0];

/// The foreground's own target; it falls back to the text minimum.
const FOREGROUND_CONTRAST: f64 = 7.0;

fn quantized(color: Rgb) -> Rgb {
    Rgb::hex(color.to_hex())
}

fn hue_distance(a: f64, b: f64) -> f64 {
    let d = (a - b).rem_euclid(360.0);
    d.min(360.0 - d)
}

/// The scheme of a `canvas` (background) and an `accent` color.
pub fn scheme_from_colors(canvas: Rgb, accent: Rgb) -> DerivedScheme {
    let spec = spec();
    let text_minimum = spec.minimum_text_contrast.max(4.5);
    let mark_minimum = spec.minimum_mark_contrast.max(3.0);
    let background = quantized(canvas.with_alpha(1.0));
    // Dark when white text reads better than black on it.
    let dark = background.contrast(Rgb::WHITE) >= background.contrast(Rgb::BLACK);
    let pole = if dark { Rgb::WHITE } else { Rgb::BLACK };
    let canvas_lch = oklch(background);
    let accent_lch = oklch(quantized(accent.with_alpha(1.0)));

    // Foreground: near the pole, with a trace of the canvas hue.
    let seed = from_oklch(Oklch {
        l: if dark { 0.93 } else { 0.24 },
        c: canvas_lch.c.min(0.02),
        h: canvas_lch.h,
    });
    let mut foreground = fit_contrast(seed, &[(background, FOREGROUND_CONTRAST)], Some(dark));
    if foreground.contrast(background) < text_minimum {
        foreground = fit_contrast(seed, &[(background, text_minimum)], Some(dark));
    }
    if foreground.contrast(background) < text_minimum {
        foreground = pole;
    }
    let foreground = quantized(foreground);

    let accent = quantized(fit_contrast(accent, &[(background, mark_minimum)], Some(dark)));
    let read = |color: Rgb, minimum: f64| {
        quantized(fit_contrast(color, &[(background, minimum)], Some(dark)))
    };

    // ANSI 1...6 (and 9...14 brighter): the accent's chroma at each hue.
    let chroma = accent_lch.c.clamp(0.10, 0.20);
    let nearest = ANSI_HUES
        .iter()
        .enumerate()
        .min_by(|a, b| {
            hue_distance(*a.1, accent_lch.h).total_cmp(&hue_distance(*b.1, accent_lch.h))
        })
        .map(|(i, _)| i)
        .filter(|_| accent_lch.c >= 0.05);
    let (normal_l, bright_l) = if dark { (0.72, 0.80) } else { (0.50, 0.42) };
    let mut palette = [Rgb::BLACK; 16];
    for (i, hue) in ANSI_HUES.iter().enumerate() {
        let hue = if nearest == Some(i) && hue_distance(*hue, accent_lch.h) <= 40.0 {
            accent_lch.h
        } else {
            *hue
        };
        let index = i.saturating_add(1);
        if let Some(slot) = palette.get_mut(index) {
            *slot = read(from_oklch(Oklch { l: normal_l, c: chroma, h: hue }), text_minimum);
        }
        if let Some(slot) = palette.get_mut(index.saturating_add(8)) {
            *slot = read(from_oklch(Oklch { l: bright_l, c: chroma, h: hue }), text_minimum);
        }
    }
    if let Some(slot) = palette.get_mut(0) {
        *slot = quantized(background.mixed(foreground, 0.12));
    }
    if let Some(slot) = palette.get_mut(7) {
        *slot = read(foreground.mixed(background, 0.15), text_minimum);
    }
    if let Some(slot) = palette.get_mut(8) {
        *slot = read(background.mixed(foreground, 0.45), mark_minimum);
    }
    if let Some(slot) = palette.get_mut(15) {
        *slot = foreground;
    }

    // Selection: the accent over the canvas, as strong as the text allows,
    // and its text fitted to it.
    let mut selection = quantized(background.mixed(accent, 0.15));
    for step in [0.35, 0.3, 0.25, 0.2, 0.15] {
        let candidate = quantized(background.mixed(accent, step));
        if foreground.contrast(candidate) >= text_minimum {
            selection = candidate;
            break;
        }
    }
    let selection_foreground =
        quantized(fit_contrast(foreground, &[(selection, text_minimum)], Some(dark)));
    let cursor_text = if background.contrast(accent) >= foreground.contrast(accent) {
        background
    } else {
        foreground
    };

    DerivedScheme {
        scheme: Scheme {
            name: None,
            author: None,
            background,
            foreground,
            cursor: Some(accent),
            cursor_text: Some(cursor_text),
            selection_background: Some(selection),
            selection_foreground: Some(selection_foreground),
            palette,
            accent: Some(accent),
            base16: None,
        },
        appearance: if dark { Appearance::Dark } else { Appearance::Light },
    }
}
