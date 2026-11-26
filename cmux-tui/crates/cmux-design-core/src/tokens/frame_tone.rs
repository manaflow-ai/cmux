//! The flush corner's frame shade: a port of CmuxNextDesign's FrameTone.swift (the rung a theme's
//! ink washes its surface by) and FrameTone+Metrics.swift (when the ink frame draws, its shade,
//! ink, hover and pressed fills and lift surface).
//!
//! Settings and the active theme are inputs: `ThemeTokens.surfaceBackground`, `textPrimary`,
//! `isDark`, `Metrics.mainPaneCurved`, `CornerFlush.current.isOn`, `titleAreaTone` and
//! `titleAreaContrast`.
//!
//! The rungs, `washed`, `share` and `wash` are `cmux_config::theme_file::frame_tone`'s (the same
//! port); the FrameTone+Metrics rules are here.
//!
//! Ops: `tokens.frame_tone_*`.

use crate::ops::{OpError, OpResult, parse, reply};
use crate::tokens::color::{Color, Rgb};
use crate::tokens::density::tokens::{smax, smin};
use crate::tokens::metrics::FOLDER_TAB_MINIMUM_SHADE;
use cmux_config::theme_file::frame_tone::wash_over;
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub use cmux_config::theme_file::frame_tone::{FRAME_RUNG, SELECTED_RUNG, STEP, share, washed};

/// `FrameTone.hoverRung`: the hover rung.
pub const HOVER_RUNG: f64 = 0.08;
/// `FrameTone`'s bisection rounds (`cmux_config`'s private `ROUNDS`).
pub const ROUNDS: usize = 24;

/// `FrameTone.wash(rung:over:)`: the alpha that brings a wash of `under` up to `rung`
/// (`cmux_config`'s `wash_over`).
pub fn wash(rung: f64, under: f64) -> f64 {
    wash_over(rung, under)
}

/// `FrameTone.share(_:)`: a theme's share (its surface and primary text, opaque).
pub fn theme_share(surface_background: Rgb, text_primary: Rgb) -> f64 {
    share(surface_background.with_alpha(1.0), text_primary.with_alpha(1.0))
}

/// The theme a frame read takes (`ThemeTokens`' fields it reads).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FrameTheme {
    /// `surfaceBackground`.
    pub surface_background: Color,
    /// `textPrimary`.
    pub text_primary: Color,
    /// `isDark`.
    pub is_dark: bool,
}

/// The settings a frame read takes.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FrameSettings {
    /// `Metrics.mainPaneCurved`.
    pub main_pane_curved: bool,
    /// `CornerFlush.current.isOn`.
    pub corner_flush_on: bool,
    /// `titleAreaTone == .subtleTone`.
    pub subtle_tone: bool,
    /// `titleAreaContrast`.
    #[serde(default = "one")]
    pub title_area_contrast: f64,
}

fn one() -> f64 {
    1.0
}

/// `Metrics.drawsInkFrame`: a curved main pane, the flush corner on and Subtle Tone.
pub fn draws_ink_frame(settings: &FrameSettings) -> bool {
    settings.main_pane_curved && settings.corner_flush_on && settings.subtle_tone
}

/// `Metrics.inkFrameShade(isDark:tokens:)`: the theme's share (the frame rung for the other
/// appearance) times the title area contrast, in 0...1; nil without the ink frame.
pub fn ink_frame_shade(is_dark: bool, theme: &FrameTheme, settings: &FrameSettings) -> Option<f64> {
    if !draws_ink_frame(settings) {
        return None;
    }
    let share = if theme.is_dark == is_dark {
        theme_share(theme.surface_background.into(), theme.text_primary.into())
    } else {
        FRAME_RUNG
    };
    Some(smin(1.0, smax(0.0, share * settings.title_area_contrast)))
}

/// `Metrics.chromeFrameInk(_:)`: the opaque primary text with the ink frame, else black.
pub fn chrome_frame_ink(theme: &FrameTheme, settings: &FrameSettings) -> Rgb {
    if draws_ink_frame(settings) {
        Rgb::from(theme.text_primary).with_alpha(1.0)
    } else {
        Rgb::new(0.0, 0.0, 0.0, 1.0)
    }
}

/// `Metrics.FrameStateFills`: hover and pressed fills on the frame.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FrameStateFills {
    /// One step over the shade.
    pub hover: Color,
    /// Two steps over the shade.
    pub pressed: Color,
}

/// `Metrics.frameStateFills(_:)`: the ink at the alpha that lifts the shade one and two steps;
/// nil while the shade is under `folderTabMinimumShade`.
pub fn frame_state_fills(theme: &FrameTheme, settings: &FrameSettings) -> Option<FrameStateFills> {
    let under = ink_frame_shade(theme.is_dark, theme, settings)?;
    if under < FOLDER_TAB_MINIMUM_SHADE {
        return None;
    }
    let step = theme_share(theme.surface_background.into(), theme.text_primary.into());
    let ground = under;
    let ink = Rgb::from(theme.text_primary).with_alpha(1.0);
    let fill = |steps: f64| Color::from(ink.with_alpha(wash(ground + step * steps, ground)));
    Some(FrameStateFills { hover: fill(1.0), pressed: fill(2.0) })
}

/// `Metrics.frameLiftSurface(_:)`: the opaque surface with the ink frame, else nil.
pub fn frame_lift_surface(theme: &FrameTheme, settings: &FrameSettings) -> Option<Rgb> {
    draws_ink_frame(settings).then(|| Rgb::from(theme.surface_background).with_alpha(1.0))
}

// MARK: - Ops

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShareRequest {
    base: Color,
    ink: Color,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WashedRequest {
    base: Color,
    ink: Color,
    share: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WashRequest {
    rung: f64,
    under: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FrameRequest {
    theme: FrameTheme,
    settings: FrameSettings,
    #[serde(default)]
    is_dark: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SettingsRequest {
    settings: FrameSettings,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ConstantsReply {
    frame_rung: f64,
    hover_rung: f64,
    selected_rung: f64,
    step: f64,
}

/// Runs the `tokens.frame_tone_*` ops.
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "frame_tone_constants" => reply(&ConstantsReply {
            frame_rung: FRAME_RUNG,
            hover_rung: HOVER_RUNG,
            selected_rung: SELECTED_RUNG,
            step: STEP,
        }),
        "frame_tone_share" => {
            let r: ShareRequest = parse(request)?;
            reply(&share(r.base.into(), r.ink.into()))
        }
        "frame_tone_washed" => {
            let r: WashedRequest = parse(request)?;
            reply(&Color::from(washed(r.base.into(), r.ink.into(), r.share)))
        }
        "frame_tone_wash" => {
            let r: WashRequest = parse(request)?;
            reply(&wash(r.rung, r.under))
        }
        "frame_tone_draws_ink_frame" => {
            let r: SettingsRequest = parse(request)?;
            reply(&draws_ink_frame(&r.settings))
        }
        "frame_tone_ink_frame_shade" => {
            let r: FrameRequest = parse(request)?;
            let is_dark = r.is_dark.unwrap_or(r.theme.is_dark);
            reply(&ink_frame_shade(is_dark, &r.theme, &r.settings))
        }
        "frame_tone_chrome_frame_ink" => {
            let r: FrameRequest = parse(request)?;
            reply(&Color::from(chrome_frame_ink(&r.theme, &r.settings)))
        }
        "frame_tone_state_fills" => {
            let r: FrameRequest = parse(request)?;
            reply(&frame_state_fills(&r.theme, &r.settings))
        }
        "frame_tone_lift_surface" => {
            let r: FrameRequest = parse(request)?;
            reply(&frame_lift_surface(&r.theme, &r.settings).map(Color::from))
        }
        _ => Err(OpError::Unknown),
    }
}
