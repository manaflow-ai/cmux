//! Hover timing: the hover card delays (Chrome's tab hover card timing,
//! tuned by Leo) and the app's one hover-intent policy for tooltips and
//! cards. Durations are signed nanoseconds, as Swift's `Duration` is signed:
//! a target delay of zero or less means "no delay".
//!
//! Chrome's timing (chrome/browser/ui/views/tabs/hovercard/tab_hover_card_controller.cc,
//! read 2026-10-28 at 9220cdeed22f): `GetShowDelay` waits 800 ms plus 500 ms for
//! a tab at standard width (narrower tabs scale down to 300 ms);
//! `ShouldShowImmediately` skips the wait within 300 ms after the card went; an
//! open card moves to the next tab at once. History of the cold delay: 1300 ms
//! (2026-10-14), 250 ms (Lawrence 2026-10-18), Chrome's again (2026-10-28), then
//! 400 ms (Leo 2026-11-01: "i need these hover previews to appear a hell of a
//! lot faster than they do now"): Chrome's floor for a narrow tab plus a beat,
//! so a pointer passing over the sidebar still opens nothing.

/// Nanoseconds in one millisecond.
const NANOS_PER_MS: i64 = 1_000_000;

/// `ms` milliseconds as nanoseconds.
#[must_use]
pub const fn millis(ms: i64) -> i64 {
    ms.saturating_mul(NANOS_PER_MS)
}

/// The cold delay: how long the pointer rests on a sidebar row or a tab
/// before the first card opens. `sidebar.hoverCards.delay` overrides it.
pub const HOVER_CARD_SHOW_DELAY: i64 = millis(400);
/// Warm mode: after a card goes, a hover this soon shows the next one at once
/// (Chrome's `kShowWithoutDelayTimeBuffer`); a gap between rows this short
/// keeps the card.
pub const HOVER_CARD_RESHOW_WINDOW: i64 = millis(300);
/// A sweep: a retarget this soon after the last show or retarget puts the
/// card at its row in that frame, with no slide, crossfade or resize
/// (Lawrence 2026-10-28: "card animation needs to be better, if i move across
/// it very fast").
pub const HOVER_CARD_SWEEP_INTERVAL: i64 = millis(150);
/// How long a pinned card (Show Resource Usage) stays without a dismissal.
pub const HOVER_CARD_PIN_LIFETIME: i64 = millis(10_000);
/// How long a target with no delay waits when it arrives under a still
/// pointer (a scroll, rows reflowing): content passing under a still pointer
/// flashes no card.
pub const HOVER_CARD_STILL_POINTER_DELAY: i64 = millis(300);

/// The app's one hover-intent policy (Leo 2026-10-14: tooltips and hover cards
/// appeared at once everywhere). Tooltips wait before the first one shows,
/// then a neighbor's shows at once while the group is warm; hover cards stay
/// while the pointer heads into them and linger a moment after it leaves.
///
/// Apple's numbers: AppKit's tooltip waits `NSInitialToolTipDelay` (about
/// 1000 ms); cmux waits 450 ms (Leo 2026-10-14: 400-500): a pointer crossing a
/// 24-30 pt button at sweep speed is on it for 30-100 ms, far under the delay,
/// while a deliberate rest gets its answer in under half a second. The warm
/// time (500 ms) is the gap between two buttons a reader moves across. Pages
/// use the same numbers (webviews/src/ui/hoverIntent.ts, `HOVER_INTENT`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct HoverIntentTiming {
    /// Pointer rest before the first tooltip of a group shows.
    pub tooltip_delay: i64,
    /// After the last tooltip hid, how long the next one still shows at once.
    pub tooltip_warm: i64,
    /// How long a card stays after the pointer leaves its target and the card.
    pub card_grace: i64,
    /// How long a pointer heading for a shown card may pause on another target
    /// it crosses before that target's card takes over.
    pub card_aim: i64,
}

impl HoverIntentTiming {
    /// The defaults.
    pub const STANDARD: Self = Self {
        tooltip_delay: millis(450),
        tooltip_warm: millis(500),
        card_grace: millis(200),
        card_aim: millis(300),
    };

    /// The values from tunables in seconds (Debug > Tunables > Hover): each
    /// one at or above zero, rounded to the millisecond.
    #[must_use]
    pub fn from_seconds(
        tooltip_delay: f64,
        tooltip_warm: f64,
        card_grace: f64,
        card_aim: f64,
    ) -> Self {
        Self {
            tooltip_delay: duration_from_seconds(tooltip_delay),
            tooltip_warm: duration_from_seconds(tooltip_warm),
            card_grace: duration_from_seconds(card_grace),
            card_aim: duration_from_seconds(card_aim),
        }
    }
}

impl Default for HoverIntentTiming {
    fn default() -> Self {
        Self::STANDARD
    }
}

/// A tunable's seconds as nanoseconds: at least zero (NaN is zero), rounded
/// half away from zero to the millisecond, and capped at `i64::MAX`
/// milliseconds' worth of nanoseconds.
#[must_use]
pub fn duration_from_seconds(seconds: f64) -> i64 {
    // Swift's `max(0, seconds)` keeps 0 for NaN (`seconds >= 0` is false).
    let seconds = if seconds >= 0. { seconds } else { 0. };
    let ms = (seconds * 1_000.).round();
    #[allow(
        clippy::cast_possible_truncation,
        reason = "a float to integer `as` saturates: outside the i64 range (and +inf) it is i64::MAX, never UB or a panic"
    )]
    let ms = ms as i64;
    millis(ms)
}
