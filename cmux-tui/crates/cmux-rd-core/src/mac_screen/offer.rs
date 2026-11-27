//! A viewer's cmux.rd/1 offer (the Mac's `MacScreenRdDocument.wish`, `customize`,
//! `lacksDisplay`): the stream width and frame rate a quality asks for, the person's bitrate
//! and cursor wishes, and whether a host's answer lost the display a run's link named.

use cmux_rd_proto::rd_doc::RdDocument;
use serde::{Deserialize, Serialize};

/// The toolbar's quality pick (the Mac's `ScreenQuality`).
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum Quality {
    #[default]
    Auto,
    Smooth,
    Low,
    Medium,
    High,
}

/// What a quality asks for: the widest stream (None: the display's own size) and the rate.
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
pub struct Wish {
    pub max_width: Option<u32>,
    pub max_fps: u32,
}

/// The stream a quality asks for. `refresh` is the viewer display's rate (30 to 120 count),
/// `pane_width` the pane's width in pixels (Auto streams no wider, in steps of 16, never under
/// 1280), `max_fps` the person's frame rate limit, which only lowers the rate and is not
/// floored at 30.
pub fn wish(quality: Quality, refresh: i64, pane_width: Option<i64>, max_fps: Option<i64>) -> Wish {
    let refresh = refresh.clamp(30, 120).min(max_fps.unwrap_or(i64::MAX)).max(1);
    let refresh = u32::try_from(refresh).unwrap_or(u32::MAX);
    let width = |w: i64| u32::try_from(w).unwrap_or(u32::MAX);
    match quality {
        Quality::Auto => Wish {
            max_width: pane_width.map(|w| width((w.saturating_add(15) / 16 * 16).max(1280))),
            max_fps: refresh,
        },
        Quality::Smooth => Wish { max_width: Some(1920), max_fps: refresh },
        Quality::Low => Wish { max_width: Some(1280), max_fps: refresh.min(60) },
        Quality::Medium => Wish { max_width: Some(1920), max_fps: refresh.min(60) },
        Quality::High => Wish { max_width: None, max_fps: refresh.min(60) },
    }
}

/// The person's stream wishes (the Mac's `ScreenPreferences`' `maxKbps`, `showCursorInStream`).
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(default)]
pub struct Customize {
    pub max_kbps: Option<u32>,
    pub show_cursor: bool,
}

impl Default for Customize {
    fn default() -> Self {
        Customize { max_kbps: None, show_cursor: true }
    }
}

/// Puts the person's wishes on an offer: a bitrate cap, and a cursor line only to hide it (the
/// default adds no line, so an older host reads the same offer).
pub fn customize(doc: &mut RdDocument, wishes: Customize) {
    doc.max_kbps = wishes.max_kbps;
    doc.cursor = if wishes.show_cursor { None } else { Some(false) };
}

/// Whether an answer that lists its display ids lacks `id` (the run's display is gone). An
/// older host lists none, so it never lacks one.
pub fn lacks_display(doc: &RdDocument, id: u32) -> bool {
    !doc.display_ids.is_empty() && !doc.display_ids.contains(&id)
}

/// Everything one session's offer is made of besides its key.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(default)]
pub struct OfferInputs {
    pub quality: Quality,
    /// The viewer display's refresh rate (60 when unknown).
    pub refresh: i64,
    pub pane_width: Option<i64>,
    pub max_fps: Option<i64>,
    pub customize: Customize,
    /// `ultra`, or None for Balanced (no line).
    pub encode_profile: Option<String>,
}

impl Default for OfferInputs {
    fn default() -> Self {
        OfferInputs {
            quality: Quality::Auto,
            refresh: 60,
            pane_width: None,
            max_fps: None,
            customize: Customize::default(),
            encode_profile: None,
        }
    }
}

/// A session's offer: the quality's wish, the display picked (an index) or else the run's
/// linked display (a CGDirectDisplayID), the person's wishes and profile.
pub fn make_offer(
    key: &str,
    inputs: &OfferInputs,
    wanted_display: Option<i64>,
    linked_display: Option<u32>,
) -> (RdDocument, Wish) {
    let wish = wish(inputs.quality, inputs.refresh, inputs.pane_width, inputs.max_fps);
    let mut doc = RdDocument {
        key: key.to_owned(),
        max_width: wish.max_width,
        max_fps: Some(wish.max_fps),
        display: wanted_display,
        ..RdDocument::default()
    };
    customize(&mut doc, inputs.customize);
    doc.encode_profile.clone_from(&inputs.encode_profile);
    doc.display_id = if wanted_display.is_none() { linked_display } else { None };
    (doc, wish)
}

#[cfg(test)]
#[path = "offer_tests.rs"]
mod tests;
