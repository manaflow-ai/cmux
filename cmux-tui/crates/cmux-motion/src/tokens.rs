//! Tokens: speed, springs, fades, loops, the bounce setting and the
//! per-kind switches. The numbers come from the spec's design-tokens.json
//! (`motion`), compiled in by build.rs; no timing constant lives here.

use crate::{SpringParameters, TabStripGeometry, TweenCurve, TweenParameters, ease_out};

// SPEED_NORMAL, SPRINGS, STRUCTURAL, SUBTLE_BOUNCE, DEFAULT_BOUNCE,
// DEFAULT_KINDS, SETTLE_*, FADES, TWEENS, TAB_STRIP_*, LOOPS.

include!(concat!(env!("OUT_DIR"), "/tokens.rs"));

// Each table has one entry per variant, so `table[variant as usize]` is in range.
const _: () = assert!(SPRINGS.len() == MotionSpring::ALL.len());
const _: () = assert!(STRUCTURAL.len() == MotionSpring::ALL.len());
const _: () = assert!(TWEENS.len() == MotionTween::ALL.len());
const _: () = assert!(FADES.len() == MotionFade::ALL.len());
const _: () = assert!(LOOPS.len() == MotionLoop::Flash as usize + 1);

// ---------------------------------------------------------------------------
// Tokens

/// `ui.animationSpeed`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum MotionSpeed {
    /// Default: short springs tuned for a pro tool.
    #[default]
    Fast,
    /// About Apple's system pacing: every time constant x1.5.
    Normal,
    /// No animation: every change applies in one frame, no crossfade.
    Off,
}

impl MotionSpeed {
    /// Multiplier on every spring response and fade duration.
    pub fn time_scale(self) -> f64 {
        match self {
            Self::Fast => 1.,
            Self::Normal => SPEED_NORMAL,
            Self::Off => 0.,
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "fast" => Some(Self::Fast),
            "normal" => Some(Self::Normal),
            "off" | "none" | "0" => Some(Self::Off),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Fast => "fast",
            Self::Normal => "normal",
            Self::Off => "off",
        }
    }
}

/// Spring tokens (values at speed `fast`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum MotionSpring {
    /// An existing item moves or resizes: tab reflow and reorder, sidebar
    /// rows, pane and divider frames, pane zoom, sidebar drag gap.
    Move,
    /// Something appears or expands: tab grow-in, group expand, row insert,
    /// palette scale-in.
    Appear,
    /// Something disappears or collapses. Faster than `Appear`.
    Disappear,
    /// Release after direct manipulation; carries pointer velocity and
    /// overshoots slightly (0.8 pt on 200 pt).
    Settle,
    /// Programmatic scroll: tab strip reveal, column reveal, wheel, fling.
    Scroll,
    /// Screen switch slide.
    Screen,
    /// An overlay tracking the pointer between targets: drop zones, ghost.
    Track,
    /// Selection indicator glide (sidebar pill).
    Selection,
    /// Floating panel slide (hover card).
    Panel,
    /// Home list pin drag: the tiles making room, the rows below the grid
    /// and a dropped tile landing (MessagesLab `SidebarPinDragging.spring`:
    /// `CASpringAnimation` mass 1, stiffness 320, damping 30). Overshoots
    /// about 1.6 pt on 200 pt.
    PinDrag,
    /// A pane zooming to fill its screen: it owns the motion, its content
    /// takes the full size once and the spring rect reveals it (Leo
    /// 2026-10-13).
    Zoom,
    /// The panes a zoom leaves fading out, faster than anything arrives
    /// (macOS `Motion.exit(nearness:)` lengthens it up to 25% for the
    /// panes nearer the zoomed one, so the farthest is gone first).
    Exit,
    /// A new tab growing in at its final slot while the tabs right of it
    /// make room, on one spring (`ui.animations.newTab`). Structural.
    TabOpen,
}

impl MotionSpring {
    pub const ALL: [Self; 13] = [
        Self::Move,
        Self::Appear,
        Self::Disappear,
        Self::Settle,
        Self::Scroll,
        Self::Screen,
        Self::Track,
        Self::Selection,
        Self::Panel,
        Self::PinDrag,
        Self::Zoom,
        Self::Exit,
        Self::TabOpen,
    ];

    /// The token's tuning at speed `fast` (design-tokens.json
    /// `motion.springs`). Structural tokens are resolved further by
    /// `MotionPolicy::spring` (the bounce setting).
    #[allow(
        clippy::indexing_slicing,
        reason = "INVARIANT: build.rs emits one entry per variant in declaration order; the table lengths are checked at compile time"
    )]
    pub const fn base(self) -> SpringParameters {
        SPRINGS[self as usize]
    }

    /// Structure: things that take or give up room (`move`, `appear`,
    /// `disappear`; design-tokens.json `motion.structural`). These follow
    /// the bounce setting (`MotionBounce`); release, scroll and overlay
    /// springs keep their own damping.
    #[allow(
        clippy::indexing_slicing,
        reason = "INVARIANT: build.rs emits one entry per variant in declaration order; the table lengths are checked at compile time"
    )]
    pub const fn is_structural(self) -> bool {
        STRUCTURAL[self as usize]
    }
}

/// Tween tokens (duration and curve at speed `fast`; design-tokens.json
/// `motion.tweens`): Chrome's tab strip motion, a 200 ms ease-out that
/// restarts from the value on screen when the target changes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum MotionTween {
    /// A new tab opening at its slot from the previous tab's right edge,
    /// and its neighbours and the + button making room
    /// (`ui.animations.newTab`).
    TabOpen,
    /// A closing tab shrinking with its left edge pinned, its neighbours
    /// closing the gap, and the resize when mouse closing mode ends
    /// (`ui.animations.newTab`).
    TabClose,
    /// Tabs moving in a reorder or crowding change and a dragged tab
    /// settling on release. A gesture: not under a kind switch.
    TabMove,
}

impl MotionTween {
    pub const ALL: [Self; 3] = [Self::TabOpen, Self::TabClose, Self::TabMove];

    /// Duration and curve at speed `fast` (design-tokens.json `motion.tweens`).
    #[allow(
        clippy::indexing_slicing,
        reason = "INVARIANT: build.rs emits one entry per variant in declaration order; the table lengths are checked at compile time"
    )]
    pub const fn base(self) -> TweenParameters {
        TWEENS[self as usize]
    }

    /// The `ui.animations.*` switch that turns this tween on (an off kind
    /// applies the change at once), or none for a gesture.
    pub const fn kind(self) -> Option<MotionKind> {
        match self {
            Self::TabOpen | Self::TabClose => Some(MotionKind::NewTab),
            Self::TabMove => None,
        }
    }
}

/// Timed opacity and color changes (ease-out), seconds at speed `fast`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum MotionFade {
    /// Hover fills and hover-revealed buttons.
    Hover,
    /// Focus ring and inactive-pane dim.
    Focus,
    /// A view or panel fades in.
    FadeIn,
    /// A view or panel fades out. Faster than `FadeIn`.
    FadeOut,
    /// Content swap in place; also the Reduce Motion ceiling.
    Crossfade,
    /// Drag lift shadow.
    Lift,
    /// Theme switch recoloring in place.
    Theme,
    /// A highlighted row fading out after a jump to it (cmux-next: the
    /// Settings row after a search jump or deep link).
    Highlight,
    /// The launch mark resolving on a window still connecting (cmux-next
    /// `LaunchMarkView`, `Motion.revealLaunchMark`).
    Launch,
    /// Home list pin drag: the tile lifting to `SidebarPinDragState.lift`
    /// (MessagesLab `beginPinDrag`, `transform.scale` over 0.15 s).
    PinLift,
    /// Home list pin drag: a dropped tile scaling back from the lift
    /// (`landPinDrag`, `transform.scale` over 0.25 s).
    PinSettle,
    /// Home list pin drag: a ghost that is not a tile now shrinking onto
    /// its row's avatar and fading out (`landPinDrag`, a 0.22 s transaction).
    PinShrink,
}

impl MotionFade {
    pub const ALL: [Self; 12] = [
        Self::Hover,
        Self::Focus,
        Self::FadeIn,
        Self::FadeOut,
        Self::Crossfade,
        Self::Lift,
        Self::Theme,
        Self::Highlight,
        Self::Launch,
        Self::PinLift,
        Self::PinSettle,
        Self::PinShrink,
    ];

    /// Seconds at speed `fast` (design-tokens.json `motion.fades`).
    #[allow(
        clippy::indexing_slicing,
        reason = "INVARIANT: build.rs emits one entry per variant in declaration order; the table lengths are checked at compile time"
    )]
    pub const fn base(self) -> f64 {
        FADES[self as usize]
    }
}

impl MotionFade {
    /// The token's timing curve. Every fade eases out (cmux-next
    /// `Motion.fadeCurve`) but MessagesLab's pin drag scales, which run
    /// linear: `beginPinDrag`'s lift and `landPinDrag`'s settle are
    /// `CABasicAnimation`s with no timing function (Core Animation paces
    /// those linearly). `pinShrink` keeps ease-out: it is an implicit
    /// animation in a `CATransaction` with no timing function set.
    pub const fn curve(self) -> MotionCurve {
        match self {
            Self::PinLift | Self::PinSettle => MotionCurve::Linear,
            _ => MotionCurve::EaseOut,
        }
    }
}

/// A timed fade's curve (`MotionFade::curve`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum MotionCurve {
    /// Core Animation's `easeOut` (`ease_out`).
    EaseOut,
    /// Core Animation's `linear` (a `CABasicAnimation` without a timing function).
    Linear,
}

impl MotionCurve {
    /// The progress at time fraction `t` (0..=1).
    pub fn progress(self, t: f32) -> f32 {
        match self {
            Self::EaseOut => ease_out(t),
            Self::Linear => t.clamp(0., 1.),
        }
    }
}

/// Repeating indicators. Speed does not scale them; `off` and Reduce Motion
/// stop them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum MotionLoop {
    Spinner,
    Pulse,
    Flash,
}

impl MotionLoop {
    /// Seconds per cycle (design-tokens.json `motion.loops`).
    #[allow(
        clippy::indexing_slicing,
        reason = "INVARIANT: build.rs emits one entry per variant in declaration order; the table lengths are checked at compile time"
    )]
    pub const fn period(self) -> f64 {
        LOOPS[self as usize]
    }
}

/// `ui.animations.bounce`: how springy structural motion is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum MotionBounce {
    /// Critically damped: a tab, row or pane never passes its target. The
    /// default (design-tokens.json `motion.bounce.default`).
    #[default]
    None,
    /// SwiftUI bounce `motion.bounce.subtle` (0.15): about 1% overshoot.
    Subtle,
}

impl MotionBounce {
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "none" => Some(Self::None),
            "subtle" => Some(Self::Subtle),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Subtle => "subtle",
        }
    }

    /// SwiftUI bounce of a structural spring under this setting.
    pub const fn amount(self) -> f64 {
        match self {
            Self::None => 0.,
            Self::Subtle => SUBTLE_BOUNCE,
        }
    }
}

/// The structural changes a user turns animation on for one by one, under
/// `ui.animationSpeed`, one per cmux.json key (`MotionKind::config_path`):
/// `ui.paneAnimations`, `ui.animations.newTab`, `ui.animations.newWorkspace`.
/// newTab on by default, the others off (design-tokens.json `motion.kinds`);
/// an off kind applies the change in one frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum MotionKind {
    /// `ui.paneAnimations`: pane layout (split grow-in, close, move, swap,
    /// zoom and unzoom, column reveal, screen switch, a divider released).
    PaneAnimations,
    /// A new tab growing into its slot (every entry point).
    NewTab,
    /// A new workspace row opening in the sidebar.
    NewWorkspace,
}

impl MotionKind {
    pub const ALL: [Self; 3] = [Self::PaneAnimations, Self::NewTab, Self::NewWorkspace];

    /// The setting's last key (`paneAnimations`, `newTab`, `newWorkspace`).
    pub fn as_str(self) -> &'static str {
        match self {
            Self::PaneAnimations => "paneAnimations",
            Self::NewTab => "newTab",
            Self::NewWorkspace => "newWorkspace",
        }
    }

    /// The full cmux.json path of the kind's switch.
    pub fn config_path(self) -> &'static str {
        match self {
            Self::PaneAnimations => "ui.paneAnimations",
            Self::NewTab => "ui.animations.newTab",
            Self::NewWorkspace => "ui.animations.newWorkspace",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.as_str() == s.trim())
    }
}

/// The motion settings: one switch per `MotionKind` (`ui.paneAnimations`,
/// `ui.animations.newTab`, `ui.animations.newWorkspace`) and the bounce
/// (`ui.animations.bounce`).
/// The host reads its settings file and passes these in
/// (`set_animation_switches`, or `MotionPolicy::with_animations`); this
/// crate never reads a settings file.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(C)]
pub struct AnimationSwitches {
    pub pane_animations: bool,
    pub new_tab: bool,
    pub new_workspace: bool,
    pub bounce: MotionBounce,
}

impl AnimationSwitches {
    /// The spec defaults (design-tokens.json `motion.kinds`, `motion.bounce`).
    pub const DEFAULT: Self = Self {
        pane_animations: DEFAULT_KINDS[0],
        new_tab: DEFAULT_KINDS[1],
        new_workspace: DEFAULT_KINDS[2],
        bounce: DEFAULT_BOUNCE,
    };

    /// `kind`'s switch is on.
    pub const fn enabled(&self, kind: MotionKind) -> bool {
        match kind {
            MotionKind::PaneAnimations => self.pane_animations,
            MotionKind::NewTab => self.new_tab,
            MotionKind::NewWorkspace => self.new_workspace,
        }
    }

    /// The same switches with `kind` set to `on`.
    pub fn with(mut self, kind: MotionKind, on: bool) -> Self {
        match kind {
            MotionKind::PaneAnimations => self.pane_animations = on,
            MotionKind::NewTab => self.new_tab = on,
            MotionKind::NewWorkspace => self.new_workspace = on,
        }
        self
    }
}

impl Default for AnimationSwitches {
    fn default() -> Self {
        Self::DEFAULT
    }
}
