//! Text on floating glass (`FloatingGlass/Palette+GlassText.swift`): a toast's, a sheet's and a
//! floating prompt's ink fitted to its ground, and the veil a neutral glass style lays down. The
//! fitting is `CmuxDialogButtonLook.readable(_:over:minimum:)`, ported here as [`fit_readable`].

use crate::tokens::color::Rgb;
use cmux_theme_tokens::{MINIMUM_MARK_CONTRAST, MINIMUM_TEXT_CONTRAST, ThemeTokens, readable};
use serde::{Deserialize, Serialize};

/// `CmuxDialogButtonLook.minimumContrast`: the default floor of [`fit_readable`].
pub const DIALOG_MINIMUM_CONTRAST: f64 = 4.5;

/// The theme text colour a label draws (Swift `ThemeInk`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ThemeInk {
    /// `textPrimary`.
    Primary,
    /// `textSecondary`.
    Secondary,
    /// `textTertiary`.
    Tertiary,
    /// `danger`.
    Danger,
}

impl ThemeInk {
    /// The text colour in `tokens` (Swift `ThemeInk.rgb(_:)`).
    pub fn rgb(self, tokens: &ThemeTokens) -> Rgb {
        match self {
            Self::Primary => tokens.text_primary,
            Self::Secondary => tokens.text_secondary,
            Self::Tertiary => tokens.text_tertiary,
            Self::Danger => tokens.danger,
        }
    }

    /// The least contrast it reads at: tertiary 3:1, the rest 4.5:1.
    pub fn minimum_contrast(self) -> f64 {
        if self == Self::Tertiary { MINIMUM_MARK_CONTRAST } else { MINIMUM_TEXT_CONTRAST }
    }
}

/// A glass style's veil for one appearance: a gray (`white`) at `alpha` (`FloatingGlassLook.veil`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Veil {
    /// The gray's level, 0...1.
    pub white: f64,
    /// The veil's opacity.
    pub alpha: f64,
}

/// The veil a neutral glass style lays over its glass: the gray, or with `takes_theme_tint` the
/// theme's glass tint at the same opacity (Swift `Palette.veilRGB(of:tokens:)`).
pub fn veil_rgb(veil: Veil, takes_theme_tint: bool, glass_tint: Rgb) -> Rgb {
    if !takes_theme_tint {
        return Rgb::new(veil.white, veil.white, veil.white, veil.alpha);
    }
    glass_tint.with_alpha(veil.alpha)
}

/// `ink` moved toward its pole until it reads at `minimum` (+0.05) on every surface, up to four
/// passes; when none reads on all, the one of the result, white and black that reads on the most
/// surfaces, then has the best worst contrast (Swift `CmuxDialogButtonLook.readable`).
pub fn fit_readable(ink: Rgb, surfaces: &[Rgb], minimum: f64) -> Rgb {
    let target = minimum + 0.05;
    let all = |c: Rgb| surfaces.iter().all(|s| c.contrast(*s) >= target);
    let mut fitted = ink;
    for _ in 0..4 {
        if all(fitted) {
            continue;
        }
        fitted = surfaces.iter().fold(fitted, |f, s| readable(f, *s, target));
    }
    if all(fitted) {
        return fitted;
    }
    let score = |c: Rgb| {
        let reads = surfaces.iter().filter(|s| c.contrast(**s) >= target).count();
        let worst = surfaces.iter().map(|s| c.contrast(*s)).reduce(f64::min).unwrap_or(0.0);
        (reads, worst)
    };
    // Swift's `max(by:)` keeps the first of equal maxima.
    let mut best = fitted;
    for candidate in [Rgb::WHITE, Rgb::BLACK] {
        let (a, b) = (score(best), score(candidate));
        if a.0 < b.0 || (a.0 == b.0 && a.1 < b.1) {
            best = candidate;
        }
    }
    best
}

/// The ground a toast's text is fitted to: the opaque popup surface with Reduce Transparency,
/// else the toast's veil over the window.
pub fn toast_ground(
    tokens: &ThemeTokens,
    reduce_transparency: bool,
    lift: f64,
    veil: Veil,
    veil_takes_theme_tint: bool,
) -> Rgb {
    if reduce_transparency {
        tokens.opaque_overlay_fill(lift)
    } else {
        veil_rgb(veil, veil_takes_theme_tint, tokens.glass_tint)
            .composited(tokens.window_background.with_alpha(1.0))
    }
}

/// A toast's text (Swift `Palette.toastTextRGB`): `ink` fitted to [`toast_ground`].
pub fn toast_text(
    tokens: &ThemeTokens,
    ink: ThemeInk,
    reduce_transparency: bool,
    lift: f64,
    veil: Veil,
    veil_takes_theme_tint: bool,
) -> Rgb {
    let ground = toast_ground(tokens, reduce_transparency, lift, veil, veil_takes_theme_tint);
    fit_readable(ink.rgb(tokens).with_alpha(1.0), &[ground], ink.minimum_contrast())
}

/// The title on a toast's ink-filled button: the window background fitted to the toast's
/// primary text (Swift `Palette.toastInkTitle`).
pub fn toast_ink_title(
    tokens: &ThemeTokens,
    reduce_transparency: bool,
    lift: f64,
    veil: Veil,
    veil_takes_theme_tint: bool,
) -> Rgb {
    let fill = toast_text(
        tokens,
        ThemeInk::Primary,
        reduce_transparency,
        lift,
        veil,
        veil_takes_theme_tint,
    );
    fit_readable(tokens.window_background.with_alpha(1.0), &[fill], DIALOG_MINIMUM_CONTRAST)
}

/// A sheet's or a floating prompt's text (Swift `Palette.sheetText` / `promptText`): `ink`
/// fitted on the card surfaces (`CmuxDialogButtonLook.cardSurfaces` / `promptCardSurfaces`).
pub fn card_text(tokens: &ThemeTokens, ink: ThemeInk, surfaces: &[Rgb]) -> Rgb {
    fit_readable(ink.rgb(tokens).with_alpha(1.0), surfaces, ink.minimum_contrast())
}
