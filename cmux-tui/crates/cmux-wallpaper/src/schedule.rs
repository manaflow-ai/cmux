//! When a live wallpaper draws (plans/cmux-next/live-wallpapers.md, "When it
//! draws (cost)"). The host asks after every event that could change the
//! answer and on each frame; [`schedule`] answers [`Decision::Hold`] (stop
//! the display link, run no timer) or [`Decision::Run`] at an interval and a
//! scale.
//!
//! The GPU budget: the host counts frames over [`GPU_BUDGET_MS`] in a row
//! with [`gpu_strikes`]. At [`STRIKES_TO_HALVE`] strikes the answer runs at
//! half the scale; the host resets the count to 0 when the scale it draws at
//! changes. At [`MIN_SCALE`] the answer is `Hold(TooHeavy)`, for as long as
//! the host keeps the count.
//!
//! A motion scene (plans/cmux-next/motion-scenes.md) with no keyframes whose
//! physics sleeps is at rest (`Player::at_rest`): the host passes that as
//! [`ScheduleInput::at_rest`] and the answer is `Hold(AtRest)`, after every
//! unseen and power reason and the GPU budget, and before `Idle`. Input still
//! wakes it: the host asks again after a pointer move or a press, the frame it
//! draws for that input wakes the scene's physics, and the next ask runs.

/// Nothing for this long (no pointer motion over the window, no key press in
/// it, no size or theme change, and for a wallpaper with `agents` no agent
/// event) and the wallpaper holds on its frame. A manifest's `idle_after`
/// shortens it ([`ScheduleInput::idle_after_s`]).
pub const IDLE_AFTER_S: f64 = 20.0;
/// The Settings cap when the host passes none.
pub const DEFAULT_FPS_CAP: u32 = 30;
/// A frame's GPU time above this is a strike.
pub const GPU_BUDGET_MS: f32 = 4.0;
/// Strikes in a row that halve the scale.
pub const STRIKES_TO_HALVE: u32 = 3;
/// The lowest scale; strikes here hold the wallpaper as too heavy.
pub const MIN_SCALE: f32 = 0.25;
/// The highest scale.
pub const MAX_SCALE: f32 = 1.0;

/// Why a wallpaper holds. Ordered by precedence: the first that applies wins.
/// The numbers are the C ABI's.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum HoldReason {
    /// The window is not on screen (occluded).
    Occluded = 1,
    /// The window is nearly all covered (`BackdropCoverage` resting).
    Covered = 2,
    Minimized = 3,
    /// Hidden with the app.
    AppHidden = 4,
    ScreensAsleep = 5,
    /// The login session is not the active one.
    SessionInactive = 6,
    LowPower = 7,
    /// Serious or critical thermal state.
    Thermal = 8,
    ReduceMotion = 9,
    /// Settings turned animations off.
    AnimationsOff = 10,
    /// The GPU budget failed at the lowest scale.
    TooHeavy = 11,
    /// Nothing happened for the idle time ([`ScheduleInput::idle_after_s`]).
    Idle = 12,
    /// A motion scene with nothing moving: no keyframes, and its physics, if
    /// any, asleep. Its frame does not change until input wakes it.
    AtRest = 13,
}

impl HoldReason {
    /// A stable lowercase name (logs, the picker's mark).
    pub fn name(self) -> &'static str {
        match self {
            Self::Occluded => "occluded",
            Self::Covered => "covered",
            Self::Minimized => "minimized",
            Self::AppHidden => "app_hidden",
            Self::ScreensAsleep => "screens_asleep",
            Self::SessionInactive => "session_inactive",
            Self::LowPower => "low_power",
            Self::Thermal => "thermal",
            Self::ReduceMotion => "reduce_motion",
            Self::AnimationsOff => "animations_off",
            Self::TooHeavy => "too_heavy",
            Self::Idle => "idle",
            Self::AtRest => "at_rest",
        }
    }

    /// True when nothing of the window can be seen: a held frame is not
    /// needed now (it is drawn when the window shows again).
    pub fn unseen(self) -> bool {
        matches!(
            self,
            Self::Occluded
                | Self::Covered
                | Self::Minimized
                | Self::AppHidden
                | Self::ScreensAsleep
                | Self::SessionInactive
        )
    }
}

/// What the host knows when it asks.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScheduleInput {
    /// The window is on screen (not occluded).
    pub visible: bool,
    /// `BackdropCoverage` says the backdrop is nearly all covered, and resting.
    pub coverage_resting: bool,
    pub minimized: bool,
    pub app_hidden: bool,
    pub screens_asleep: bool,
    pub session_inactive: bool,
    pub low_power: bool,
    /// Thermal state serious or critical.
    pub thermal_serious: bool,
    pub reduce_motion: bool,
    pub animations_off: bool,
    /// Seconds since the last key press in the window, size change or theme change.
    pub seconds_since_activity: f64,
    /// Seconds since the pointer last moved over the window (counts only when `interactive`).
    pub seconds_since_pointer: f64,
    /// Seconds since an agent in the window last wrote output or changed state
    /// (counts only when `agents`).
    pub seconds_since_agent_event: f64,
    /// The manifest's `interactive`.
    pub interactive: bool,
    /// The manifest's `agents`.
    pub agents: bool,
    /// The manifest's `idle_after` in seconds; 0 (or anything not above 0)
    /// means [`IDLE_AFTER_S`], and a longer time is cut to it.
    pub idle_after_s: f64,
    /// `appearance.liveWallpaperFrameRate`; 0 means the default (30).
    pub settings_fps_cap: u32,
    /// The manifest's `fps`.
    pub manifest_fps: u32,
    /// GPU frames over budget in a row ([`gpu_strikes`]).
    pub gpu_strikes: u32,
    /// The scale the host draws at now (starts at the manifest's `scale`).
    pub scale: f32,
    /// The view has drawn at least one frame.
    pub has_frame: bool,
    /// A motion scene at rest (`Player::at_rest`); false for a program wallpaper.
    pub at_rest: bool,
}

impl Default for ScheduleInput {
    fn default() -> Self {
        Self {
            visible: true,
            coverage_resting: false,
            minimized: false,
            app_hidden: false,
            screens_asleep: false,
            session_inactive: false,
            low_power: false,
            thermal_serious: false,
            reduce_motion: false,
            animations_off: false,
            seconds_since_activity: 0.0,
            seconds_since_pointer: f64::INFINITY,
            seconds_since_agent_event: f64::INFINITY,
            interactive: true,
            agents: false,
            idle_after_s: 0.0,
            settings_fps_cap: DEFAULT_FPS_CAP,
            manifest_fps: DEFAULT_FPS_CAP,
            gpu_strikes: 0,
            scale: MAX_SCALE,
            has_frame: true,
            at_rest: false,
        }
    }
}

/// The answer.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Decision {
    /// Stop the display link; no timer. `draw_one`: the view has no frame
    /// yet and can be seen, so it draws one frame at `scale` first and then
    /// holds (a window that opens while held).
    Hold { reason: HoldReason, draw_one: bool, scale: f32 },
    /// Draw every `interval_s` (`1 / fps`) at backing scale `scale`.
    Run { fps: u32, interval_s: f64, scale: f32 },
}

/// The frame cap: the lower of the manifest's and Settings', 1..=60.
pub fn fps_cap(manifest_fps: u32, settings_fps_cap: u32) -> u32 {
    let settings = if settings_fps_cap == 0 { DEFAULT_FPS_CAP } else { settings_fps_cap };
    manifest_fps.min(settings).clamp(1, 60)
}

/// The strike count after a frame whose GPU time was `gpu_ms`: one more
/// when it passed [`GPU_BUDGET_MS`], else 0. A NaN or negative time is no
/// measurement and keeps the count.
pub fn gpu_strikes(strikes: u32, gpu_ms: f32) -> u32 {
    if !gpu_ms.is_finite() || gpu_ms < 0.0 {
        strikes
    } else if gpu_ms > GPU_BUDGET_MS {
        strikes.saturating_add(1)
    } else {
        0
    }
}

/// The idle time for `idle_after_s` ([`ScheduleInput::idle_after_s`]).
pub fn idle_after(idle_after_s: f64) -> f64 {
    if idle_after_s > 0.0 { idle_after_s.min(IDLE_AFTER_S) } else { IDLE_AFTER_S }
}

/// Decides whether the wallpaper draws now, and how.
pub fn schedule(input: &ScheduleInput) -> Decision {
    let scale =
        if input.scale.is_finite() { input.scale.clamp(MIN_SCALE, MAX_SCALE) } else { MAX_SCALE };
    let hold = |reason: HoldReason, scale: f32| Decision::Hold {
        reason,
        draw_one: !input.has_frame && !reason.unseen(),
        scale,
    };
    let reasons = [
        (!input.visible, HoldReason::Occluded),
        (input.coverage_resting, HoldReason::Covered),
        (input.minimized, HoldReason::Minimized),
        (input.app_hidden, HoldReason::AppHidden),
        (input.screens_asleep, HoldReason::ScreensAsleep),
        (input.session_inactive, HoldReason::SessionInactive),
        (input.low_power, HoldReason::LowPower),
        (input.thermal_serious, HoldReason::Thermal),
        (input.reduce_motion, HoldReason::ReduceMotion),
        (input.animations_off, HoldReason::AnimationsOff),
    ];
    if let Some((_, reason)) = reasons.iter().find(|(on, _)| *on) {
        return hold(*reason, scale);
    }

    let mut scale = scale;
    if input.gpu_strikes >= STRIKES_TO_HALVE {
        if scale <= MIN_SCALE {
            return hold(HoldReason::TooHeavy, MIN_SCALE);
        }
        scale = (scale / 2.0).max(MIN_SCALE);
    }

    // Nothing on screen would change: holding costs nothing, and `draw_one`
    // still gives a view with no frame its picture.
    if input.at_rest {
        return hold(HoldReason::AtRest, scale);
    }

    let idle = idle_after(input.idle_after_s);
    let quiet = |s: f64| s.is_nan() || s >= idle;
    let pointer_quiet = !input.interactive || quiet(input.seconds_since_pointer);
    let agents_quiet = !input.agents || quiet(input.seconds_since_agent_event);
    if quiet(input.seconds_since_activity) && pointer_quiet && agents_quiet {
        return hold(HoldReason::Idle, scale);
    }

    let fps = fps_cap(input.manifest_fps, input.settings_fps_cap);
    Decision::Run { fps, interval_s: 1.0 / f64::from(fps), scale }
}

#[cfg(test)]
#[path = "schedule_tests.rs"]
mod tests;
