//! `TitleRoll.swift` (the `MotionGate` roll extension and `TitleRollEnd`), `TitleFade.swift`
//! and `MarqueeLabel.swift`: when a renamed title rolls and how far, the roll's keyframe values,
//! when the roll's end clears the blur; the title fade's mask stops, mask keep and drop choices,
//! the follow path's width and held samples, the marquee start, edge and spring-back choices;
//! the marquee label's intrinsic size and fade geometry inputs.
//!
//! The `TitleFadeGeometry` values (`maskLocations`, `maskFrame`, `isTruncated`, ...) come in as
//! inputs; Core Animation and the layers stay in Swift.

use serde::{Deserialize, Serialize};

/// `MotionGate.rollOutName`: the outgoing copy's layer name.
pub const ROLL_OUT_NAME: &str = "cmux.titleRoll.out";
/// `MotionGate.blurPath`: the blur radius key path.
pub const BLUR_PATH: &str = "filters.blur.inputRadius";
/// The words travel 0.6 em.
pub const ROLL_RISE_EM: f64 = 0.6;
/// The blur radius at the roll's soft end.
pub const ROLL_BLUR_RADIUS: f64 = 2.0;
/// The animation keys `cancelTitleRoll` removes.
pub const ROLL_KEYS: [&str; 3] = ["opacity", "transform.translation.y", BLUR_PATH];

/// `TitleFade.keyPath`: what the marquee moves.
pub const FADE_KEY_PATH: &str = "transform.translation.x";
/// `TitleFade.key`: the marquee's animation key.
pub const FADE_KEY: &str = "marquee";
/// `TitleFade.edgeKey`: the leading fade that follows the marquee.
pub const FADE_EDGE_KEY: &str = "marquee.edge";
/// `TitleFade.followKey`: the prefix of a follow path's keys.
pub const FADE_FOLLOW_KEY: &str = "follow.";
/// The mask colors' alphas (clear, opaque, opaque, clear, clear; gray 0).
pub const FADE_MASK_ALPHAS: [f64; 5] = [0.0, 1.0, 1.0, 0.0, 0.0];
/// The mask's gradient start point.
pub const FADE_MASK_START: (f64, f64) = (0.0, 0.5);
/// The mask's gradient end point.
pub const FADE_MASK_END: (f64, f64) = (1.0, 0.5);
/// The shown translation past which a stopped marquee springs back (`abs(shown) > 0.5`).
pub const SPRING_BACK_THRESHOLD: f64 = 0.5;

/// What `rollTitle` reads before it rolls.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RollInput {
    /// The title has a superlayer.
    pub has_host: bool,
    /// `text.isHidden`.
    pub hidden: bool,
    /// `text.opacity`.
    pub opacity: f64,
    /// The old string.
    pub old: String,
    /// The string the title holds now.
    pub new: String,
    /// `animatesMovement(in:)` of the title's window.
    pub animates_movement: bool,
    /// `canAnimate(in:)` of the view.
    pub can_animate: bool,
    /// `duration(.fadeIn)` (seconds).
    pub fade_in_duration: f64,
}

/// `rollTitle`'s guard: a shown title whose words changed, in a host, where movement animates.
pub fn rolls(input: &RollInput) -> bool {
    input.has_host
        && !input.hidden
        && input.opacity > 0.0
        && !input.old.is_empty()
        && !input.new.is_empty()
        && input.old != input.new
        && input.animates_movement
        && input.can_animate
        && input.fade_in_duration > 0.0
}

/// The rise: 0.6 em rounded, up on screen (negative in a flipped host).
pub fn roll_rise(point_size: f64, flipped: bool) -> f64 {
    (point_size * ROLL_RISE_EM).round() * if flipped { -1.0 } else { 1.0 }
}

/// One value an animation runs from and to.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Span {
    /// The start.
    pub from: f64,
    /// The end (the model value).
    pub to: f64,
}

/// The roll's animations, each on the `fadeIn` fade.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RollPlan {
    /// The rise used.
    pub rise: f64,
    /// The outgoing copy's opacity (1 to 0).
    pub out_opacity: Span,
    /// The outgoing copy's y translation (0 to the rise).
    pub out_translation_y: Span,
    /// The outgoing copy's blur (0 to 2; animation only).
    pub out_blur: Span,
    /// The title's opacity (0 to its model opacity).
    pub text_opacity: Span,
    /// The title's y translation (rest less the rise to rest).
    pub text_translation_y: Span,
    /// The title's blur (2 to 0; animation only).
    pub text_blur: Span,
}

/// The roll's values for a title in `point_size` at `opacity` whose transform's y translation
/// (`m42`) is `rest`.
pub fn roll_plan(point_size: f64, flipped: bool, opacity: f64, rest: f64) -> RollPlan {
    let rise = roll_rise(point_size, flipped);
    RollPlan {
        rise,
        out_opacity: Span { from: 1.0, to: 0.0 },
        out_translation_y: Span { from: 0.0, to: rise },
        out_blur: Span { from: 0.0, to: ROLL_BLUR_RADIUS },
        text_opacity: Span { from: 0.0, to: opacity },
        text_translation_y: Span { from: rest - rise, to: rest },
        text_blur: Span { from: ROLL_BLUR_RADIUS, to: 0.0 },
    }
}

/// `TitleRollEnd`: once its outgoing words go, the roll clears the title's blur unless a newer
/// roll's copy is still in the host or the title left the host.
pub fn roll_end_clears_blur(host_has_roll_out: bool, text_in_host: bool) -> bool {
    !host_has_roll_out && text_in_host
}

/// `[0, leadingPadding / max(1, width), 1, 1, 1]`: the stops of an open (unclipped) mask.
pub fn open_locations(leading_padding: f64, width: f64) -> [f64; 5] {
    [0.0, leading_padding / width.max(1.0), 1.0, 1.0, 1.0]
}

/// `apply`, unclipped: keep the mask (to ease it open) only when the layout animates or the
/// title still slides home under it, and the mask is on.
pub fn unclipped_keeps_mask(animated: bool, returning: bool, masked: bool) -> bool {
    (animated || returning) && masked
}

/// `apply`, unclipped and not animated: where the stops ease open from, given the stops shown
/// now (presentation or model; None when unset).
pub fn unclipped_from(shown: Option<&[f64]>, open: [f64; 5]) -> [f64; 5] {
    match shown {
        Some(s) if s.len() == open.len() => {
            [s.first().copied().unwrap_or(0.0), s.get(1).copied().unwrap_or(0.0), 1.0, 1.0, 1.0]
        }
        _ => open,
    }
}

/// `apply`, unclipped and not animated: nothing to do when the stops are open already.
pub fn unclipped_settled(current: Option<&[f64]>, open: [f64; 5]) -> bool {
    current == Some(&open[..])
}

/// What `apply` does with the stops of a clipped title.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum ClippedStops {
    /// Fade to the stops (Motion `hover`), from these (None: from the shown stops).
    Fade {
        /// The start stops (a title that was not clipped starts fully visible).
        from: Option<[f64; 5]>,
    },
    /// Set them at once (no animation).
    Set,
}

/// `apply`, clipped: fade when animated and the stops change, else set.
pub fn clipped_stops(
    animated: bool,
    current: Option<&[f64]>,
    locations: [f64; 5],
    was_masked: bool,
) -> ClippedStops {
    if animated && current.unwrap_or(&[]) != &locations[..] {
        ClippedStops::Fade { from: (!was_masked).then_some([0.0, locations[1], 1.0, 1.0, 1.0]) }
    } else {
        ClippedStops::Set
    }
}

/// `apply`, clipped: a running marquee whose travel changed starts over from rest.
pub fn restarts_marquee(marquee_active: bool, previous_travel: Option<f64>, travel: f64) -> bool {
    marquee_active && previous_travel != Some(travel)
}

/// `follow`'s stops for one sample: the clipped stops, else open over the leading padding and
/// span.
pub fn follow_locations(
    truncated: bool,
    mask_locations: [f64; 5],
    leading_padding: f64,
    span: f64,
) -> [f64; 5] {
    if truncated { mask_locations } else { open_locations(leading_padding, leading_padding + span) }
}

/// `follow`'s text width: the target's text width rounded up, widened to every shown sample's
/// span.
pub fn follow_width(target_text_width: f64, shown_spans: &[f64]) -> f64 {
    shown_spans.iter().fold(target_text_width.ceil(), |w, s| w.max(*s))
}

/// `follow`'s samples where the title hides: each holds the last shown one before it (the first
/// shown one before any). Returns the index each sample takes; None when no sample shows.
pub fn follow_filled(shown: &[bool]) -> Option<Vec<usize>> {
    let first = shown.iter().position(|s| *s)?;
    let mut last = first;
    Some(
        shown
            .iter()
            .enumerate()
            .map(|(i, s)| {
                if *s {
                    last = i;
                }
                last
            })
            .collect(),
    )
}

/// `follow`'s rule for adding a keyframe path: the values differ somewhere.
pub fn follow_changes<T: PartialEq>(values: &[T]) -> bool {
    values.windows(2).any(|w| w.first() != w.get(1))
}

/// What `startMarquee` reads.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MarqueeStart {
    /// A marquee is already active.
    pub active: bool,
    /// There is a geometry.
    pub has_geometry: bool,
    /// The geometry is truncated.
    pub truncated: bool,
    /// The mask is on the title.
    pub masked: bool,
    /// The gate gave both animations (movement animates and travel is not 0).
    pub animations: bool,
}

/// `startMarquee`'s guard.
pub fn starts_marquee(input: &MarqueeStart) -> bool {
    !input.active && input.has_geometry && input.truncated && input.masked && input.animations
}

/// `startMarquee`'s edge fade: added when the scrolled stops differ from rest; its reach.
pub fn marquee_edge(
    rest: [f64; 5],
    scrolled: [f64; 5],
    fade_width: f64,
    leading_padding: f64,
) -> Option<f64> {
    (scrolled != rest).then_some(fade_width.max(leading_padding))
}

/// `stopMarquee`: a title caught mid-scroll springs back (else it snaps home).
pub fn springs_back(animated: bool, shown: f64, animates_movement: bool) -> bool {
    animated && shown.abs() > SPRING_BACK_THRESHOLD && animates_movement
}

/// `stopMarquee`: the leading fade eases back with the text when it was running and differs
/// from rest.
pub fn eases_edge_back(shown_stops: Option<&[f64]>, rest: Option<&[f64]>) -> bool {
    matches!((shown_stops, rest), (Some(s), Some(r)) if s != r)
}

/// `dropOpenMask`: an unclipped title's mask goes once nothing moves under it.
pub fn drops_open_mask(
    truncated: Option<bool>,
    masked: bool,
    sliding: bool,
    stops_animating: bool,
) -> bool {
    truncated == Some(false) && masked && !sliding && !stops_animating
}

/// `MarqueeLabel.intrinsicContentSize`: the text width and the font's line height, rounded up.
pub fn marquee_intrinsic_size(
    text_width: f64,
    ascender: f64,
    descender: f64,
    leading: f64,
) -> (f64, f64) {
    (text_width.ceil(), (ascender - descender + leading).ceil())
}

/// The `TitleFadeGeometry` inputs `MarqueeLabel.layout` passes.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MarqueeGeometryInput {
    /// `textWidth`.
    pub text_width: f64,
    /// `span`: the bounds width.
    pub span: f64,
    /// `visibleWidth`: the bounds less the trailing occlusion, at least 0.
    pub visible_width: f64,
    /// `leadingPadding`.
    pub leading_padding: f64,
    /// `trailingPadding` (always 0).
    pub trailing_padding: f64,
    /// `fadeWidth`.
    pub fade_width: f64,
}

/// `MarqueeLabel.layout`'s geometry inputs.
pub fn marquee_geometry_input(
    text_width: f64,
    bounds_width: f64,
    trailing_occlusion: f64,
    leading_padding: f64,
    fade_width: f64,
) -> MarqueeGeometryInput {
    MarqueeGeometryInput {
        text_width,
        span: bounds_width,
        visible_width: (bounds_width - trailing_occlusion).max(0.0),
        leading_padding,
        trailing_padding: 0.0,
        fade_width,
    }
}
