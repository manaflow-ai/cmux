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
    let refresh = refresh.min(120).max(30).min(max_fps.unwrap_or(i64::MAX)).max(1);
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
mod tests {
    use super::*;

    const KEY: &str = "abababababababababababababababababababababababababababababababab";

    /// MacScreenRdWishTests.autoFollowsThePaneWidthAndTheFixedPresetsDoNot
    #[test]
    fn auto_follows_the_pane_width_and_the_fixed_presets_do_not() {
        assert_eq!(wish(Quality::Auto, 60, None, None).max_width, None, "no pane yet");
        assert_eq!(wish(Quality::Auto, 60, Some(2081), None).max_width, Some(2096), "up to 16");
        assert_eq!(wish(Quality::Auto, 60, Some(600), None).max_width, Some(1280), "never < 1280");
        assert_eq!(wish(Quality::High, 60, Some(1000), None).max_width, None, "High: full size");
        assert_eq!(
            wish(Quality::Smooth, 120, Some(1000), None),
            Wish { max_width: Some(1920), max_fps: 120 }
        );
    }

    /// MacScreenRemoteDesktopDefaultsTests.theFrameRateLimitOnlyLowers
    #[test]
    fn the_frame_rate_limit_only_lowers() {
        assert_eq!(wish(Quality::Low, 120, None, Some(90)).max_fps, 60);
        assert_eq!(wish(Quality::Auto, 120, None, Some(15)).max_fps, 15, "not floored at 30");
        assert_eq!(wish(Quality::Auto, 120, None, None).max_fps, 120);
        assert_eq!(wish(Quality::Auto, 240, None, None).max_fps, 120, "a display over 120");
        assert_eq!(wish(Quality::Auto, 24, None, None).max_fps, 30, "a display under 30");
        assert_eq!(wish(Quality::Auto, 60, None, Some(0)).max_fps, 1, "never 0");
        assert_eq!(
            wish(Quality::Medium, 120, Some(1), None),
            Wish { max_width: Some(1920), max_fps: 60 }
        );
    }

    /// MacScreenRemoteDesktopDefaultsTests.theLimitsReachTheOffer
    #[test]
    fn the_limits_reach_the_offer() {
        let inputs = OfferInputs {
            quality: Quality::Smooth,
            refresh: 120,
            pane_width: Some(1000),
            max_fps: Some(30),
            customize: Customize { max_kbps: Some(4000), show_cursor: true },
            encode_profile: None,
        };
        let (offer, wish) = make_offer(KEY, &inputs, None, None);
        assert_eq!(wish, Wish { max_width: Some(1920), max_fps: 30 });
        let text = offer.text();
        assert!(text.contains("a=cmux-rd-max-fps:30\r\n"));
        assert!(text.contains("a=cmux-rd-max-kbps:4000\r\n"));
        assert!(!text.contains("cmux-rd-cursor") && !text.contains("encode-profile"));
        assert_eq!(RdDocument::parse(&text), Some(offer));
    }

    /// MacScreenRdCustomizeTests.customizeWishesRoundTripAndDefaultsAddNothing
    #[test]
    fn customize_wishes_round_trip_and_defaults_add_nothing() {
        let mut doc = RdDocument { key: KEY.into(), ..RdDocument::default() };
        customize(&mut doc, Customize::default());
        assert!(!doc.text().contains("max-kbps") && !doc.text().contains("cmux-rd-cursor"));
        customize(&mut doc, Customize { max_kbps: Some(10_000), show_cursor: false });
        assert!(doc.text().contains("a=cmux-rd-max-kbps:10000\r\n"));
        assert!(doc.text().contains("a=cmux-rd-cursor:0\r\n"));
        assert_eq!(RdDocument::parse(&doc.text()), Some(doc));
    }

    /// MacScreenRunLinkTests.theOfferNamesTheDisplayAndTheAnswerListsTheIDs
    #[test]
    fn the_offer_names_the_display_and_the_answer_lists_the_ids() {
        let (offer, _) = make_offer(KEY, &OfferInputs::default(), None, Some(69_734_208));
        assert!(offer.text().contains("a=cmux-rd-display-id:69734208\r\n"));
        assert_eq!(RdDocument::parse(&offer.text()).unwrap().display_id, Some(69_734_208));
        // A picked display wins over the run's.
        let (picked, _) = make_offer(KEY, &OfferInputs::default(), Some(1), Some(69_734_208));
        assert_eq!((picked.display, picked.display_id), (Some(1), None));
        let mut answer = RdDocument {
            key: "cd".repeat(32),
            displays: vec![(3024, 1964), (1920, 1080)],
            display_ids: vec![1, 69_734_208],
            current_display: Some(1),
            ..RdDocument::default()
        };
        let parsed = RdDocument::parse(&answer.text()).unwrap();
        assert_eq!(
            (parsed.display_ids.clone(), parsed.current_display),
            (vec![1, 69_734_208], Some(1))
        );
        assert!(!lacks_display(&parsed, 69_734_208) && lacks_display(&parsed, 7));
        answer.display_ids.clear();
        assert!(!answer.text().contains("display-ids"));
        assert!(!lacks_display(&RdDocument::parse(&answer.text()).unwrap(), 69_734_208));
    }

    #[test]
    fn ultra_rides_the_offer_and_balanced_sends_no_line() {
        let inputs = OfferInputs { encode_profile: Some("ultra".into()), ..OfferInputs::default() };
        assert!(
            make_offer(KEY, &inputs, None, None)
                .0
                .text()
                .contains("a=cmux-rd-encode-profile:ultra\r\n")
        );
        assert!(
            !make_offer(KEY, &OfferInputs::default(), None, None)
                .0
                .text()
                .contains("encode-profile")
        );
    }
}
