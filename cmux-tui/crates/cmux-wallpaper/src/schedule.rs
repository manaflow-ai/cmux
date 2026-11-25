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
mod tests {
    use super::*;

    fn run(input: &ScheduleInput) -> (u32, f32) {
        match schedule(input) {
            Decision::Run { fps, interval_s, scale } => {
                assert!((interval_s - 1.0 / f64::from(fps)).abs() < 1e-12);
                (fps, scale)
            }
            d => panic!("held: {d:?}"),
        }
    }

    fn held(input: &ScheduleInput) -> (HoldReason, bool) {
        match schedule(input) {
            Decision::Hold { reason, draw_one, .. } => (reason, draw_one),
            d => panic!("ran: {d:?}"),
        }
    }

    #[test]
    fn runs_by_default_at_30() {
        assert_eq!(run(&ScheduleInput::default()), (30, 1.0));
    }

    #[test]
    fn every_hold_condition_holds_alone() {
        type Set = fn(&mut ScheduleInput);
        let cases: [(Set, HoldReason); 10] = [
            (|i| i.visible = false, HoldReason::Occluded),
            (|i| i.coverage_resting = true, HoldReason::Covered),
            (|i| i.minimized = true, HoldReason::Minimized),
            (|i| i.app_hidden = true, HoldReason::AppHidden),
            (|i| i.screens_asleep = true, HoldReason::ScreensAsleep),
            (|i| i.session_inactive = true, HoldReason::SessionInactive),
            (|i| i.low_power = true, HoldReason::LowPower),
            (|i| i.thermal_serious = true, HoldReason::Thermal),
            (|i| i.reduce_motion = true, HoldReason::ReduceMotion),
            (|i| i.animations_off = true, HoldReason::AnimationsOff),
        ];
        for (set, reason) in cases {
            let mut i = ScheduleInput::default();
            set(&mut i);
            assert_eq!(held(&i).0, reason);
            // Pointer motion never overrides a hold.
            i.seconds_since_pointer = 0.0;
            assert_eq!(held(&i).0, reason);
        }
    }

    #[test]
    fn precedence_is_the_listed_order() {
        let all = ScheduleInput {
            visible: false,
            coverage_resting: true,
            minimized: true,
            app_hidden: true,
            screens_asleep: true,
            session_inactive: true,
            low_power: true,
            thermal_serious: true,
            reduce_motion: true,
            animations_off: true,
            seconds_since_activity: 100.0,
            gpu_strikes: 9,
            scale: 0.25,
            ..Default::default()
        };
        assert_eq!(held(&all).0, HoldReason::Occluded);
        let i = ScheduleInput {
            visible: true,
            coverage_resting: false,
            minimized: false,
            app_hidden: false,
            ..all
        };
        assert_eq!(held(&i).0, HoldReason::ScreensAsleep);
        let i = ScheduleInput {
            screens_asleep: false,
            session_inactive: false,
            low_power: false,
            thermal_serious: false,
            reduce_motion: false,
            animations_off: false,
            ..i
        };
        assert_eq!(held(&i).0, HoldReason::TooHeavy);
        let i = ScheduleInput { gpu_strikes: 0, ..i };
        assert_eq!(held(&i).0, HoldReason::Idle);
    }

    #[test]
    fn idles_after_20_seconds_of_nothing() {
        let mut i = ScheduleInput { seconds_since_activity: 19.9, ..Default::default() };
        run(&i);
        i.seconds_since_activity = 20.0;
        assert_eq!(held(&i), (HoldReason::Idle, false));
        // Pointer motion wakes an interactive wallpaper.
        i.seconds_since_pointer = 0.5;
        run(&i);
        // But not one that is not interactive.
        i.interactive = false;
        assert_eq!(held(&i).0, HoldReason::Idle);
        // A key press or theme change wakes either.
        i.seconds_since_activity = 0.0;
        run(&i);
        // A NaN clock is no activity.
        i.seconds_since_activity = f64::NAN;
        assert_eq!(held(&i).0, HoldReason::Idle);
    }

    #[test]
    fn a_manifest_idle_after_holds_sooner() {
        // The dot field: idle_after 2, so it holds 2 s after the last move.
        let mut i = ScheduleInput {
            seconds_since_activity: 60.0,
            seconds_since_pointer: 1.9,
            idle_after_s: 2.0,
            ..Default::default()
        };
        run(&i);
        i.seconds_since_pointer = 2.0;
        assert_eq!(held(&i).0, HoldReason::Idle);
        // A key press wakes it for the same 2 s.
        i.seconds_since_activity = 1.0;
        run(&i);
        i.seconds_since_activity = 2.5;
        assert_eq!(held(&i).0, HoldReason::Idle);
        // 0, a negative or NaN time is the default 20 s; a longer one is cut to 20 s.
        for (idle, quiet, want_held) in [
            (0.0, 19.0, false),
            (-3.0, 19.0, false),
            (f64::NAN, 19.0, false),
            (0.0, 20.0, true),
            (60.0, 20.0, true),
            (f64::INFINITY, 20.0, true),
        ] {
            let i = ScheduleInput {
                seconds_since_activity: quiet,
                idle_after_s: idle,
                ..Default::default()
            };
            assert_eq!(matches!(schedule(&i), Decision::Hold { .. }), want_held, "{idle} {quiet}");
        }
        assert_eq!(idle_after(2.0), 2.0);
        assert_eq!(idle_after(0.0), IDLE_AFTER_S);
    }

    #[test]
    fn agent_output_wakes_only_a_wallpaper_that_reads_it() {
        let mut i = ScheduleInput {
            seconds_since_activity: 60.0,
            seconds_since_agent_event: 1.0,
            ..Default::default()
        };
        // A wallpaper without `agents` stays idle while agents write.
        assert_eq!(held(&i).0, HoldReason::Idle);
        i.agents = true;
        run(&i);
        i.seconds_since_agent_event = 20.0;
        assert_eq!(held(&i).0, HoldReason::Idle);
        // Agent output never overrides a hold such as occlusion.
        i.seconds_since_agent_event = 0.0;
        i.visible = false;
        assert_eq!(held(&i).0, HoldReason::Occluded);
    }

    #[test]
    fn the_cap_is_the_lower_of_manifest_and_settings() {
        for (manifest, settings, want) in [
            (30, 30, 30),
            (60, 30, 30),
            (24, 60, 24),
            (60, 60, 60),
            (60, 15, 15),
            (12, 0, 12),
            (60, 0, 30),
            (0, 30, 1),
            (90, 120, 60),
        ] {
            let i = ScheduleInput {
                manifest_fps: manifest,
                settings_fps_cap: settings,
                ..Default::default()
            };
            assert_eq!(run(&i).0, want, "{manifest} {settings}");
        }
    }

    #[test]
    fn the_cap_applies_while_the_pointer_moves() {
        let i = ScheduleInput {
            manifest_fps: 60,
            settings_fps_cap: 15,
            seconds_since_pointer: 0.0,
            ..Default::default()
        };
        assert_eq!(run(&i).0, 15);
    }

    #[test]
    fn strikes_count_frames_over_4ms_in_a_row() {
        assert_eq!(gpu_strikes(0, 4.1), 1);
        assert_eq!(gpu_strikes(2, 9.0), 3);
        assert_eq!(gpu_strikes(2, 4.0), 0);
        assert_eq!(gpu_strikes(2, 1.0), 0);
        assert_eq!(gpu_strikes(2, f32::NAN), 2);
        assert_eq!(gpu_strikes(2, -1.0), 2);
        assert_eq!(gpu_strikes(u32::MAX, 9.0), u32::MAX);
    }

    #[test]
    fn three_strikes_halve_the_scale_down_to_a_quarter_then_too_heavy() {
        let mut i = ScheduleInput { scale: 1.0, gpu_strikes: 2, ..Default::default() };
        assert_eq!(run(&i).1, 1.0);
        i.gpu_strikes = 3;
        assert_eq!(run(&i).1, 0.5);
        i.scale = 0.5;
        assert_eq!(run(&i).1, 0.25);
        i.scale = 0.4;
        assert_eq!(run(&i).1, 0.25);
        i.scale = 0.25;
        assert_eq!(held(&i), (HoldReason::TooHeavy, false));
        if let Decision::Hold { scale, .. } = schedule(&i) {
            assert_eq!(scale, 0.25);
        }
        i.gpu_strikes = 0;
        assert_eq!(run(&i).1, 0.25);
    }

    #[test]
    fn scale_is_clamped() {
        assert_eq!(run(&ScheduleInput { scale: 4.0, ..Default::default() }).1, 1.0);
        assert_eq!(run(&ScheduleInput { scale: 0.0, ..Default::default() }).1, 0.25);
        assert_eq!(run(&ScheduleInput { scale: f32::NAN, ..Default::default() }).1, 1.0);
    }

    #[test]
    fn a_window_opening_while_held_draws_one_frame() {
        let i = ScheduleInput { low_power: true, has_frame: false, ..Default::default() };
        assert_eq!(held(&i), (HoldReason::LowPower, true));
        let i =
            ScheduleInput { seconds_since_activity: 30.0, has_frame: false, ..Default::default() };
        assert_eq!(held(&i), (HoldReason::Idle, true));
        // Nothing to draw for while it cannot be seen.
        let i = ScheduleInput { minimized: true, has_frame: false, ..Default::default() };
        assert_eq!(held(&i), (HoldReason::Minimized, false));
        let i = ScheduleInput { low_power: true, has_frame: true, ..Default::default() };
        assert_eq!(held(&i), (HoldReason::LowPower, false));
    }

    #[test]
    fn reason_names_are_unique() {
        let all = [
            HoldReason::Occluded,
            HoldReason::Covered,
            HoldReason::Minimized,
            HoldReason::AppHidden,
            HoldReason::ScreensAsleep,
            HoldReason::SessionInactive,
            HoldReason::LowPower,
            HoldReason::Thermal,
            HoldReason::ReduceMotion,
            HoldReason::AnimationsOff,
            HoldReason::TooHeavy,
            HoldReason::Idle,
        ];
        let names: std::collections::HashSet<_> = all.iter().map(|r| r.name()).collect();
        assert_eq!(names.len(), all.len());
        for (n, r) in all.iter().enumerate() {
            assert_eq!(*r as usize, n + 1);
        }
    }
}
