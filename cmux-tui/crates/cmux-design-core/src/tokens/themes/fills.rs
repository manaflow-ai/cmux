//! Fills and inks fitted to contrast: the menu highlight's share
//! (`ThemeTokens+MenuHighlight.swift`), the spinner ink (`ThemeTokens+SpinnerInk.swift`) and the
//! grouped form's fill and edge (`ThemeTokens+GroupFill.swift`).

use crate::tokens::color::Rgb;
use cmux_theme_tokens::{MINIMUM_MARK_CONTRAST, MINIMUM_TEXT_CONTRAST, ThemeTokens};

/// `ChromeTunables.opaqueOverlayLift`'s default (the popup surface's lift toward the text).
pub const DEFAULT_OPAQUE_OVERLAY_LIFT: f64 = 0.14;

/// The share of `accent` in a highlighted row's wash on `ground`: 20%, lowered in 1% steps only
/// as far as it takes `text_primary` to keep 4.5:1 on it (Swift `menuHighlightShare(on:)`).
pub fn menu_highlight_share(tokens: &ThemeTokens, ground: Rgb) -> f64 {
    let ink = tokens.text_primary.composited(ground);
    let mut share = 0.2;
    while share > 0.0
        && ink.contrast(tokens.accent.with_alpha(share).composited(ground)) < MINIMUM_TEXT_CONTRAST
    {
        share = (share - 0.01).max(0.0);
    }
    share
}

/// The loading spinner's ink: `text_primary` at 66%, raised in 2% steps only as far as it takes
/// to reach 3:1 on the bare, hovered, selected and pressed rows (Swift `spinnerInk`).
pub fn spinner_ink(tokens: &ThemeTokens) -> Rgb {
    let row = tokens.window_background.with_alpha(1.0);
    let rows = [
        row,
        tokens.hover_fill.composited(row),
        tokens.selection_fill.composited(row),
        tokens.pressed_fill.composited(row),
    ];
    let primary = tokens.text_primary;
    let reads = |share: f64| {
        let ink = primary.with_alpha(primary.a * share);
        rows.iter().all(|r| ink.composited(*r).contrast(*r) >= MINIMUM_MARK_CONTRAST)
    };
    let mut share = 0.66;
    while share < 1.0 && !reads(share) {
        share = (share + 0.02).min(1.0);
    }
    primary.with_alpha(primary.a * share)
}

/// The group fill's alpha when text contrast allows it: 8% dark, 6% light (`groupFillTarget`).
pub fn group_fill_target(is_dark: bool) -> f64 {
    if is_dark { 0.08 } else { 0.06 }
}

/// The group fill on `surface`: the strongest of the target alpha of the text colour, in 0.5%
/// steps, on which secondary text keeps 4.5:1 (or what it has on the bare surface when less).
pub fn group_fill_on(tokens: &ThemeTokens, surface: Rgb) -> Rgb {
    let ground = surface.with_alpha(1.0);
    let secondary = tokens.text_secondary.composited(ground);
    let floor = MINIMUM_TEXT_CONTRAST.min(secondary.contrast(ground));
    let mut steps = (group_fill_target(tokens.is_dark) * 200.0).round() as i64;
    while steps > 0
        && secondary
            .contrast(tokens.text_primary.with_alpha(steps as f64 / 200.0).composited(ground))
            < floor
    {
        steps -= 1;
    }
    tokens.text_primary.with_alpha(steps as f64 / 200.0)
}

/// The group fill on the popup surface (`opaque_overlay_fill(lift)`; Swift `groupFill`).
pub fn group_fill(tokens: &ThemeTokens, lift: f64) -> Rgb {
    group_fill_on(tokens, tokens.opaque_overlay_fill(lift))
}

/// The group's edge for `fill`: the separator where the fill sits under its target, else clear.
pub fn group_stroke_for(tokens: &ThemeTokens, fill: Rgb) -> Rgb {
    if fill.a < group_fill_target(tokens.is_dark) - 0.001 {
        tokens.separator
    } else {
        tokens.separator.with_alpha(0.0)
    }
}

/// The grouped form's edge (Swift `groupStroke`), from [`group_fill`] at `lift`.
pub fn group_stroke(tokens: &ThemeTokens, lift: f64) -> Rgb {
    group_stroke_for(tokens, group_fill(tokens, lift))
}
