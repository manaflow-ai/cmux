//! `GlassMenuMaterial` (GlassMenu/GlassMenuMaterial.swift): the one floating material's numbers,
//! the veil a theme lays on a menu's glass, the web menu's clear share and the panel radius.

use super::HIGHLIGHT_INSET;
use super::color::ThemeRgb;
use serde::{Deserialize, Serialize};

/// CmuxTheme `TransientMaterial.standard.hostVeil`.
pub const HOST_VEIL: f64 = 0.4;
/// CmuxTheme `TransientMaterial.standard.webTint` (percent, light).
pub const WEB_TINT: f64 = 80.0;
/// CmuxTheme `TransientMaterial.standard.webTintDark` (percent, dark).
pub const WEB_TINT_DARK: f64 = 72.0;
/// CmuxTheme `TransientMaterial.standard.nativeTintStrength`: `GlassLevel.menu.tintStrength`.
pub const MENU_TINT_STRENGTH: f64 = 1.25;

/// `veilPercent`: the theme surface laid on the glass, percent.
pub fn veil_percent() -> f64 {
    HOST_VEIL * 100.0
}

/// `veil`: the veil's share of the theme surface, 0...1.
pub fn veil() -> f64 {
    veil_percent() / 100.0
}

/// `defaultCornerRadius`: the one popup radius with no radius of the person's own.
pub const DEFAULT_CORNER_RADIUS: f64 = 8.0;
/// `rowHeight`: `DesignTokens.controlRow`.
pub const ROW_HEIGHT: f64 = 28.0;
/// `maximumVeil`: the glass rule's 90% cap.
pub const MAXIMUM_VEIL: f64 = 0.9;
/// `contrastHeadroom`.
pub const CONTRAST_HEADROOM: f64 = 0.1;
/// `webSecondaryInkShare`.
pub const WEB_SECONDARY_INK_SHARE: f64 = 0.68;

/// The `ThemeTokens` fields the menu material reads.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MaterialTokens {
    pub window_background: ThemeRgb,
    pub surface_background: ThemeRgb,
    pub text_primary: ThemeRgb,
    pub text_secondary: ThemeRgb,
    pub glass_tint: ThemeRgb,
    #[serde(default)]
    pub is_dark: bool,
}

/// `glass(_:veil:over:)`: the menu's glass over `page`: the glass tint at the menu level, then the
/// theme surface at `veil`.
pub fn glass(tokens: &MaterialTokens, veil: f64, page: ThemeRgb) -> ThemeRgb {
    let tint =
        tokens.glass_tint.with_alpha((tokens.glass_tint.alpha * MENU_TINT_STRENGTH).min(1.0));
    tokens.surface_background.with_alpha(veil).composited(tint.composited(page))
}

/// `veil(for:)`: ``veil`` raised in 2% steps up to ``MAXIMUM_VEIL`` until the primary text reads at
/// 4.5:1 and the secondary at 3:1 (each plus headroom) on the glass over the theme's window, white
/// and black.
pub fn veil_for(tokens: &MaterialTokens) -> f64 {
    let pages = [tokens.window_background.with_alpha(1.0), ThemeRgb::WHITE, ThemeRgb::BLACK];
    let surface = tokens.surface_background.with_alpha(1.0);
    let primary = tokens.text_primary.composited(surface);
    let secondary = tokens.text_secondary.composited(surface);
    let wants_primary = (4.5 + CONTRAST_HEADROOM).min(primary.contrast(surface) - 0.05);
    let wants_secondary = (3.0 + CONTRAST_HEADROOM).min(secondary.contrast(surface) - 0.05);
    let mut share = veil();
    while share < MAXIMUM_VEIL {
        let reads = pages.iter().all(|page| {
            let ground = glass(tokens, share, *page);
            primary.contrast(ground) >= wants_primary
                && secondary.contrast(ground) >= wants_secondary
        });
        if reads {
            break;
        }
        share = MAXIMUM_VEIL.min(share + 0.02);
    }
    share
}

/// `webClear(for:)`: the share of a web menu's own glass `tokens` keep (WebTheme's
/// `--cmux-menu-clear`), rounded to 3 decimals.
pub fn web_clear(tokens: &MaterialTokens) -> f64 {
    let base = (if tokens.is_dark { WEB_TINT_DARK } else { WEB_TINT }) / 100.0;
    let surface = tokens.surface_background.with_alpha(1.0);
    let primary = tokens.text_primary.with_alpha(1.0);
    let wants = (4.5 + CONTRAST_HEADROOM).min(primary.contrast(surface) - 0.05);
    let floor = (1.0 - MAXIMUM_VEIL) / (1.0 - veil());
    let reads = |clear: f64| {
        [ThemeRgb::WHITE, ThemeRgb::BLACK].iter().all(|page| {
            let ground = surface.with_alpha(1.0 - (1.0 - base) * clear).composited(*page);
            let secondary = primary.with_alpha(WEB_SECONDARY_INK_SHARE).composited(ground);
            primary.contrast(ground) >= wants
                && secondary.contrast(ground) >= 3.0 + CONTRAST_HEADROOM
        })
    };
    let mut clear = (1.0 - veil_for(tokens)) / (1.0 - veil());
    while clear > floor && !reads(clear) {
        clear = floor.max(clear - 0.02);
    }
    (clear * 1000.0).round() / 1000.0
}

/// WebTheme's `--cmux-menu-clear` string: ``web_clear`` to 3 decimals (`%.3f`).
pub fn web_clear_css(tokens: &MaterialTokens) -> String {
    format!("{:.3}", web_clear(tokens))
}

/// `menuCornerRadius(surface:)`: the surface radius around the hover pill, concentric with it;
/// square stays square.
pub fn menu_corner_radius(surface: f64) -> f64 {
    if surface > 0.0 { surface + HIGHLIGHT_INSET } else { 0.0 }
}

/// The material's fixed numbers, for the app's one read.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MaterialConstants {
    pub veil_percent: f64,
    pub veil: f64,
    pub default_corner_radius: f64,
    pub row_height: f64,
    pub maximum_veil: f64,
    pub contrast_headroom: f64,
    pub web_secondary_ink_share: f64,
    pub tint_strength: f64,
    pub highlight_inset: f64,
}

/// The material's fixed numbers.
pub fn constants() -> MaterialConstants {
    MaterialConstants {
        veil_percent: veil_percent(),
        veil: veil(),
        default_corner_radius: DEFAULT_CORNER_RADIUS,
        row_height: ROW_HEIGHT,
        maximum_veil: MAXIMUM_VEIL,
        contrast_headroom: CONTRAST_HEADROOM,
        web_secondary_ink_share: WEB_SECONDARY_INK_SHARE,
        tint_strength: MENU_TINT_STRENGTH,
        highlight_inset: HIGHLIGHT_INSET,
    }
}
