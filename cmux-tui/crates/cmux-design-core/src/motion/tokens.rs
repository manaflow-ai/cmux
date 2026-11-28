//! The motion tokens of CmuxNextDesignTokens (MotionTokens.swift, MotionFadeTokens.swift,
//! MotionCategory.swift, MotionKinds.swift, MotionScale.generated.swift, MotionTunables.swift
//! defaults): names, declaration order and the code defaults, before any Debug Settings override.

use cmux_motion::SpringParameters;
use serde::{Deserialize, Serialize};

/// `ui.animationSpeed`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum MotionSpeed {
    #[default]
    Fast,
    Normal,
    Off,
}

impl MotionSpeed {
    pub const ALL: [Self; 3] = [Self::Fast, Self::Normal, Self::Off];

    /// Multiplier on every time constant (cmux-motion `MotionSpeed::time_scale`).
    pub fn time_scale(self) -> f64 {
        self.motion().time_scale()
    }

    /// The same speed in cmux-motion.
    pub fn motion(self) -> cmux_motion::MotionSpeed {
        match self {
            Self::Fast => cmux_motion::MotionSpeed::Fast,
            Self::Normal => cmux_motion::MotionSpeed::Normal,
            Self::Off => cmux_motion::MotionSpeed::Off,
        }
    }
}

macro_rules! named_enum {
    ($(#[$m:meta])* $name:ident { $($case:ident = $raw:literal),+ $(,)? }) => {
        $(#[$m])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
        pub enum $name { $(#[serde(rename = $raw)] $case),+ }

        impl $name {
            /// Every case, in the Swift declaration order (`allCases`).
            pub const ALL: &'static [Self] = &[$(Self::$case),+];

            /// The Swift raw value.
            pub fn as_str(self) -> &'static str {
                match self { $(Self::$case => $raw),+ }
            }

            /// The case with Swift raw value `raw`.
            pub fn parse(raw: &str) -> Option<Self> {
                match raw { $($raw => Some(Self::$case),)+ _ => None }
            }
        }
    };
}

named_enum!(
    /// Spring tokens (`MotionSpring`).
    MotionSpring {
        Move = "move", Appear = "appear", Disappear = "disappear", Settle = "settle",
        Scroll = "scroll", Track = "track", Selection = "selection", Panel = "panel",
        PinDrag = "pinDrag", Zoom = "zoom", Exit = "exit", TabOpen = "tabOpen", Split = "split",
        Popover = "popover", PopoverClose = "popoverClose", PaneClose = "paneClose", Unzoom = "unzoom",
    }
);

named_enum!(
    /// Fade tokens (`MotionFade`).
    MotionFade {
        Hover = "hover", HoverReveal = "hoverReveal", HoverOut = "hoverOut", Focus = "focus",
        PaneDim = "paneDim", FocusFlash = "focusFlash", FadeIn = "fadeIn", FadeOut = "fadeOut",
        Crossfade = "crossfade", Scrim = "scrim", Wallpaper = "wallpaper", Lift = "lift",
        Theme = "theme", Highlight = "highlight", Launch = "launch", ClickPulse = "clickPulse",
        CursorHide = "cursorHide", HibernateIcon = "hibernateIcon", HibernateRing = "hibernateRing",
        Settle = "settle", OmniboxPopup = "omniboxPopup",
    }
);

named_enum!(
    /// Loop tokens (`MotionLoop`).
    MotionLoop {
        Spinner = "spinner", Pulse = "pulse", Flash = "flash", Sweep = "sweep",
        Breath = "breath", Wiggle = "wiggle", Nudge = "nudge",
    }
);

named_enum!(
    /// `ui.animations.<category>` switches (`MotionCategory`; its config key is its raw value).
    MotionCategory {
        Sidebar = "sidebar", Tabs = "tabs", Panes = "panes", Overlays = "overlays",
        HoverCards = "hoverCards", Home = "home", Cursor = "cursor", Indicators = "indicators",
        Feedback = "feedback", Web = "web",
    }
);

named_enum!(
    /// The per-kind switches (`MotionKind`).
    MotionKind { NewTab = "newTab", NewWorkspace = "newWorkspace" }
);

named_enum!(
    /// Tween tokens (`MotionTween`, raw values 0, 1, 2 in Swift); their seconds are cmux-motion's.
    MotionTween { TabOpen = "tabOpen", TabClose = "tabClose", TabMove = "tabMove" }
);

/// `MotionScale` (design-tokens.json `motion.scale`).
pub mod scale {
    pub const QUICK: f64 = 0.08;
    pub const MICRO: f64 = 0.12;
    pub const STANDARD: f64 = 0.18;
    pub const LARGE: f64 = 0.24;
    /// The longest transition step.
    pub const CEILING: f64 = LARGE;
    pub const STEPS: [f64; 4] = [QUICK, MICRO, STANDARD, LARGE];
    /// `MotionScale.easeOut` control points.
    pub const EASE_OUT: [f64; 4] = [0., 0., 0.58, 1.];
    pub const SPINNER_PERIOD: f64 = 2.;
}

/// `MotionTunables.fallbackSpring`.
pub const FALLBACK_SPRING: SpringParameters = SpringParameters::new(0.2, 1.);

impl MotionSpring {
    /// `MotionTunables.springDefaults[token]`.
    pub const fn base(self) -> SpringParameters {
        let response = match self {
            Self::Move => 0.15,
            Self::Appear => 0.135,
            Self::Disappear => 0.11,
            Self::Settle => 0.22,
            Self::Scroll => 0.2,
            Self::Track => 0.12,
            Self::Selection => 0.15,
            Self::Panel => 0.165,
            Self::PinDrag => 0.215,
            Self::Zoom => 0.2,
            Self::Exit => 0.2,
            Self::TabOpen => 0.1,
            Self::Split => 0.085,
            Self::Popover => 0.24,
            Self::PopoverClose => 0.15,
            Self::PaneClose => 0.064,
            Self::Unzoom => 0.15,
        };
        SpringParameters::new(response, 1.)
    }
}

impl MotionFade {
    /// `MotionTunables.fadeDefaults[token]` (`baseDuration`).
    pub const fn base_duration(self) -> f64 {
        match self {
            Self::Hover => 0.08,
            Self::HoverReveal => 0.12,
            Self::HoverOut => 0.,
            Self::Focus => 0.08,
            Self::PaneDim => 0.12,
            Self::FocusFlash => 0.5,
            Self::FadeIn => 0.12,
            Self::FadeOut => 0.08,
            Self::Crossfade => 0.08,
            Self::Scrim => 0.18,
            Self::Wallpaper => 0.6,
            Self::Lift => 0.12,
            Self::Theme => 0.12,
            Self::Highlight => 1.2,
            Self::Launch => 0.24,
            Self::ClickPulse => 0.24,
            Self::CursorHide => 0.24,
            Self::HibernateIcon => 0.24,
            Self::HibernateRing => 1.,
            Self::Settle => 0.18,
            Self::OmniboxPopup => 0.08,
        }
    }

    /// An ambient fade nothing waits on: the speed scales it, the cap does not cut it.
    pub const fn is_ambient(self) -> bool {
        matches!(self, Self::FocusFlash | Self::Wallpaper | Self::Highlight | Self::HibernateRing)
    }
}

impl MotionLoop {
    /// `MotionLoop.shortestFlashCycle`: no flashing faster than twice a second.
    pub const SHORTEST_FLASH_CYCLE: f64 = 0.5;

    /// `MotionTunables` loop default.
    pub const fn base_period(self) -> f64 {
        match self {
            Self::Spinner => 2.,
            Self::Pulse => 1.8,
            Self::Flash => 1.,
            Self::Sweep => 1.3,
            Self::Breath => 2.4,
            Self::Wiggle => 0.3,
            Self::Nudge => 1.,
        }
    }

    /// The shortest period a tuned value may take.
    pub const fn minimum_period(self) -> f64 {
        match self {
            Self::Spinner | Self::Wiggle => 0.1,
            Self::Pulse | Self::Sweep | Self::Nudge => Self::SHORTEST_FLASH_CYCLE,
            Self::Flash | Self::Breath => 1.,
        }
    }

    /// `period`: the base, never under the minimum.
    pub fn period(self) -> f64 {
        self.base_period().max(self.minimum_period())
    }
}

impl MotionTween {
    /// The same token in cmux-motion.
    pub fn motion(self) -> cmux_motion::MotionTween {
        match self {
            Self::TabOpen => cmux_motion::MotionTween::TabOpen,
            Self::TabClose => cmux_motion::MotionTween::TabClose,
            Self::TabMove => cmux_motion::MotionTween::TabMove,
        }
    }
}

/// The scalar `MotionTunables` defaults (seconds, points, points per second, scale factors).
pub const OTHER_TUNABLES: [(&str, f64); 18] = [
    ("marqueeDelay", 0.6),
    ("marqueeSpeed", 40.),
    ("marqueeMinimumScroll", 0.4),
    ("marqueeHold", 1.2),
    ("marqueeMinimumTravel", 2.),
    ("tooltipDelay", 0.45),
    ("tooltipWarm", 0.5),
    ("hoverCardGrace", 0.2),
    ("hoverCardAim", 0.3),
    ("panelOpenScale", 0.97),
    ("panelCloseScale", 0.98),
    ("popupOpenScale", 0.95),
    ("popupCloseScale", 0.97),
    ("agentCursorGlideScale", 0.5),
    ("agentCursorGlideMax", 0.24),
    ("launchMarkDelay", 0.15),
    ("launchTextDelay", 1.2),
    ("colorTransitionDefaultDuration", 0.2),
];

/// Every token default (`motion.tokens`): springs, fades, loops, tweens and the scalars.
pub fn table() -> serde_json::Value {
    use serde_json::{Map, Value, json};
    let springs: Map<String, Value> = MotionSpring::ALL
        .iter()
        .map(|t| {
            let p = t.base();
            (
                t.as_str().into(),
                json!({ "response": p.response, "dampingFraction": p.damping_fraction }),
            )
        })
        .collect();
    let fades: Map<String, Value> = MotionFade::ALL
        .iter()
        .map(|t| {
            (t.as_str().into(), json!({ "duration": t.base_duration(), "ambient": t.is_ambient() }))
        })
        .collect();
    let loops: Map<String, Value> = MotionLoop::ALL
        .iter()
        .map(|t| {
            (
                t.as_str().into(),
                json!({ "period": t.period(), "minimumPeriod": t.minimum_period() }),
            )
        })
        .collect();
    let other: Map<String, Value> =
        OTHER_TUNABLES.iter().map(|(k, v)| ((*k).into(), json!(v))).collect();
    json!({
        "springs": springs,
        "fades": fades,
        "loops": loops,
        "tweens": MotionTween::ALL.iter().map(|t| t.as_str()).collect::<Vec<_>>(),
        "categories": MotionCategory::ALL.iter().map(|t| t.as_str()).collect::<Vec<_>>(),
        "other": other,
    })
}
