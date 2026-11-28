//! The app's `MotionPolicy` (MotionPolicy.swift, MotionTween.swift's `ffi`, MotionPairs.swift):
//! cmux-motion's policy plus the 300 ms cap, the `ui.animations.<category>` switches, the master
//! switch and live resize. Tween seconds are cmux-motion's (`MotionPolicy::tween`).

use super::spring::perceived_duration;
use super::tokens::{
    MotionCategory, MotionFade, MotionKind, MotionLoop, MotionSpeed, MotionSpring, MotionTween,
};
use cmux_motion::{AnimationSwitches, SpringParameters};
use serde::{Deserialize, Serialize};

/// The longest any transition may end visibly (`MotionPolicy.cap`).
pub const CAP: f64 = 0.3;
/// The longest response the speed may stretch a spring to (`capResponse`).
pub const CAP_RESPONSE: f64 = 0.25;

/// `MotionPolicy`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MotionPolicy {
    pub speed: MotionSpeed,
    pub reduce_motion: bool,
    pub enabled_kinds: Vec<MotionKind>,
    pub live_resize: bool,
    pub animations_enabled: bool,
    pub disabled_categories: Vec<MotionCategory>,
    pub category: Option<MotionCategory>,
}

impl Default for MotionPolicy {
    fn default() -> Self {
        Self {
            speed: MotionSpeed::Fast,
            reduce_motion: false,
            enabled_kinds: Vec::new(),
            live_resize: false,
            animations_enabled: true,
            disabled_categories: Vec::new(),
            category: None,
        }
    }
}

impl MotionPolicy {
    pub fn new(speed: MotionSpeed, reduce_motion: bool) -> Self {
        Self { speed, reduce_motion, ..Self::default() }
    }

    /// `for(_:)`: this policy for one category.
    pub fn for_category(&self, category: MotionCategory) -> Self {
        Self { category: Some(category), ..self.clone() }
    }

    /// The master switch and speed allow motion, and this policy's category is on.
    pub fn category_animates(&self) -> bool {
        if !self.animations_enabled || self.speed == MotionSpeed::Off {
            return false;
        }
        self.category.is_none_or(|c| !self.disabled_categories.contains(&c))
    }

    pub fn animates_movement(&self) -> bool {
        self.category_animates() && !self.reduce_motion && !self.live_resize
    }

    pub fn animates(&self, kind: MotionKind) -> bool {
        self.animates_movement() && self.enabled_kinds.contains(&kind)
    }

    pub fn animates_fades(&self) -> bool {
        self.category_animates()
    }

    pub fn animates_loops(&self) -> bool {
        self.category_animates() && !self.reduce_motion
    }

    /// The token's spring at this speed, its response stretched no further than the cap allows.
    pub fn spring(&self, token: MotionSpring) -> SpringParameters {
        let base = token.base();
        if self.speed == MotionSpeed::Off {
            return base;
        }
        let response =
            (base.response * self.speed.time_scale()).min(base.response.max(CAP_RESPONSE));
        SpringParameters::new(response, base.damping_fraction)
    }

    /// Seconds of a fade (0 applies at once).
    pub fn fade_duration(&self, token: MotionFade) -> f64 {
        let hover =
            matches!(token, MotionFade::Hover | MotionFade::HoverReveal | MotionFade::HoverOut);
        if !self.animates_fades() || (self.reduce_motion && hover) {
            return 0.;
        }
        let seconds = if token.is_ambient() {
            token.base_duration() * self.speed.time_scale()
        } else {
            self.scaled(token.base_duration())
        };
        if self.reduce_motion {
            seconds.min(MotionFade::Crossfade.base_duration())
        } else {
            seconds
        }
    }

    /// A timed motion at this speed, stretched no further than the cap.
    pub fn scaled(&self, seconds: f64) -> f64 {
        (seconds * self.speed.time_scale()).min(seconds.max(CAP))
    }

    /// Seconds a spring token ends visibly at (0 when movement does not animate).
    pub fn spring_duration(&self, token: MotionSpring) -> f64 {
        if self.animates_movement() { perceived_duration(self.spring(token)) } else { 0. }
    }

    pub fn period(&self, token: MotionLoop) -> Option<f64> {
        self.animates_loops().then(|| token.period())
    }

    /// The policy as the C ABI takes it (`MotionPolicy.ffi`): a category or master switch off is
    /// speed off, live resize is Reduce Motion, and the pane switch is the zero value.
    pub fn motion(&self) -> cmux_motion::MotionPolicy {
        let speed = if self.category_animates() {
            self.speed.motion()
        } else {
            cmux_motion::MotionSpeed::Off
        };
        cmux_motion::MotionPolicy::new(speed, self.reduce_motion || self.live_resize)
            .with_animations(AnimationSwitches {
                pane_animations: false,
                new_tab: self.enabled_kinds.contains(&MotionKind::NewTab),
                new_workspace: self.enabled_kinds.contains(&MotionKind::NewWorkspace),
            })
    }

    /// Seconds of a tween (`duration(_: MotionTween)`, cmux-motion's).
    pub fn tween_duration(&self, token: MotionTween) -> f64 {
        self.motion().tween(token.motion())
    }

    /// `seconds(_:)` of one side of a pair.
    pub fn seconds(&self, side: Side) -> f64 {
        match side {
            Side::Spring(t) => self.spring_duration(t),
            Side::Fade(t) => self.fade_duration(t),
            Side::Tween(t) => self.tween_duration(t),
        }
    }

    /// `WebTheme.motionValue`'s inputs: what a web page's `data-motion` says (`off`, `reduced`, `full`).
    pub fn web_motion_value(&self) -> &'static str {
        if !self.category_animates() {
            "off"
        } else if self.reduce_motion {
            "reduced"
        } else {
            "full"
        }
    }
}

/// One side of a `MotionPair`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Side {
    Spring(MotionSpring),
    Fade(MotionFade),
    Tween(MotionTween),
}

/// `MotionPair`: an enter and its exit, the exit sooner unless `equal_because` says why not.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MotionPair {
    pub name: &'static str,
    pub enter: Side,
    pub exit: Side,
    pub equal_because: Option<&'static str>,
}

/// `MotionPair.all`, in order: pane, zoom, appear, popup, fade, tab.
pub fn pairs() -> Vec<MotionPair> {
    let pair = |name, enter, exit| MotionPair { name, enter, exit, equal_because: None };
    vec![
        pair(
            "pane split and close",
            Side::Spring(MotionSpring::Split),
            Side::Spring(MotionSpring::PaneClose),
        ),
        pair(
            "pane zoom and unzoom",
            Side::Spring(MotionSpring::Zoom),
            Side::Spring(MotionSpring::Unzoom),
        ),
        pair(
            "appear and disappear",
            Side::Spring(MotionSpring::Appear),
            Side::Spring(MotionSpring::Disappear),
        ),
        pair(
            "popup open and close",
            Side::Spring(MotionSpring::Popover),
            Side::Spring(MotionSpring::PopoverClose),
        ),
        pair("fade in and out", Side::Fade(MotionFade::FadeIn), Side::Fade(MotionFade::FadeOut)),
        MotionPair {
            name: "tab open and close",
            enter: Side::Tween(MotionTween::TabOpen),
            exit: Side::Tween(MotionTween::TabClose),
            equal_because: Some(
                "a strip change is one tween for every tab: the tab that opens or closes and the tabs that make or take room move on one clock, and the open and the close use the same one",
            ),
        },
    ]
}
