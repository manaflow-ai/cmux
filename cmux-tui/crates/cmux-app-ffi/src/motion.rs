//! The C ABI of cmux-motion for the macOS app (`include/cmux_motion_ffi.h`,
//! Swift module `CCmuxMotionFFI`): the closed-form spring step, the token
//! table and the per-kind switches, and the tab strip's tweens and geometry
//! (Chrome's strip motion). The app's
//! `MotionClock` keeps only the display link and the layer updates; the
//! physics and the rules live once, in cmux-motion. Every function is pure
//! (no globals, no allocation) and never panics on any input.

use cmux_motion::{
    AnimationSwitches, MotionFade, MotionKind, MotionPolicy, MotionSpeed, MotionSpring,
    MotionTween, SpringParameters, TabStripGeometry, TweenCurve, TweenValue, advance_spring,
};

/// Bumped on any change to a type or function in the header.
const ABI_VERSION: u32 = 6;

/// `SpringParameters`.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CmuxMotionSpring {
    pub response: f64,
    pub damping_fraction: f64,
}

/// One animated scalar: value, velocity (units per second), target.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CmuxMotionState {
    pub value: f64,
    pub velocity: f64,
    pub target: f64,
}

/// The host's settings for one resolve: `speed` 0 fast, 1 normal, 2 off;
/// the three `ui.animations.*` switches. No field sets a bounce: every
/// spring token is critically damped (Lawrence 2026-11-10).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CmuxMotionPolicy {
    pub speed: u8,
    pub reduce_motion: bool,
    pub pane_animations: bool,
    pub new_tab: bool,
    pub new_workspace: bool,
}

impl From<CmuxMotionSpring> for SpringParameters {
    fn from(s: CmuxMotionSpring) -> Self {
        SpringParameters::new(s.response, s.damping_fraction)
    }
}

impl From<SpringParameters> for CmuxMotionSpring {
    fn from(p: SpringParameters) -> Self {
        Self { response: p.response, damping_fraction: p.damping_fraction }
    }
}

fn policy(p: &CmuxMotionPolicy) -> MotionPolicy {
    let speed = match p.speed {
        1 => MotionSpeed::Normal,
        2 => MotionSpeed::Off,
        _ => MotionSpeed::Fast,
    };
    MotionPolicy::new(speed, p.reduce_motion).with_animations(AnimationSwitches {
        pane_animations: p.pane_animations,
        new_tab: p.new_tab,
        new_workspace: p.new_workspace,
    })
}

/// The ABI version this library implements.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_motion_ffi_abi_version() -> u32 {
    ABI_VERSION
}

/// The spring token `token` (`MotionSpring` order: 0 move, 1 appear, 2
/// disappear, 3 settle, 4 scroll, 5 track, 6 selection, 7 panel, 8 pinDrag,
/// 9 zoom, 10 exit, 11 tabOpen; the macOS `MotionSpring` declares its cases
/// in this order) at speed `fast` from the spec, before the policy. Returns
/// false for an unknown token.
///
/// # Safety
/// `out` is null or points to a writable `CmuxMotionSpring`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_motion_spring_base(token: u8, out: *mut CmuxMotionSpring) -> bool {
    let Some(token) = MotionSpring::ALL.get(usize::from(token)) else { return false };
    if out.is_null() {
        return false;
    }
    // SAFETY: `out` is non-null and writable per the contract above.
    unsafe { out.write(token.base().into()) };
    true
}

/// Resolves `base` (a token's speed-`fast` tuning, possibly a host
/// override) under `policy`: the speed scales the response and the damping
/// fraction stays. The same rule as `MotionPolicy::spring`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_motion_resolve(
    base: CmuxMotionSpring,
    policy: CmuxMotionPolicy,
) -> CmuxMotionSpring {
    let p = self::policy(&policy);
    let s = SpringParameters::from(base);
    if p.speed == MotionSpeed::Off { s.into() } else { s.scaled(p.speed.time_scale()).into() }
}

/// Advances `state` by `dt` seconds on `spring` in closed form (exact at
/// any frame rate, keeps velocity across retargets, dt capped at 0.1 s) and
/// snaps it to its target once within `epsilon` and slow. True while still
/// moving; false (and no change) for a null `state`.
///
/// # Safety
/// `state` is null or points to a valid, writable `CmuxMotionState`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_motion_step(
    state: *mut CmuxMotionState,
    dt: f64,
    spring: CmuxMotionSpring,
    epsilon: f64,
) -> bool {
    if state.is_null() {
        return false;
    }
    // SAFETY: `state` is non-null, valid and writable per the contract above.
    let s = unsafe { &mut *state };
    advance_spring(&mut s.value, &mut s.velocity, s.target, dt, spring.into(), epsilon)
}

/// True when kind `kind` (0 paneAnimations, 1 newTab, 2 newWorkspace) animates
/// under `policy`: movement animates and its switch is on.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_motion_animates(kind: u8, policy: CmuxMotionPolicy) -> bool {
    MotionKind::ALL.get(usize::from(kind)).is_some_and(|k| self::policy(&policy).animates(*k))
}

/// Seconds of fade token `fade` (`MotionFade` order) under `policy`; 0
/// applies at once (also for an unknown token).
#[unsafe(no_mangle)]
pub extern "C" fn cmux_motion_fade_seconds(fade: u8, policy: CmuxMotionPolicy) -> f64 {
    MotionFade::ALL.get(usize::from(fade)).map_or(0., |f| self::policy(&policy).fade(*f))
}

/// `TweenParameters`: seconds and curve (0 easeOutQuad).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CmuxMotionTween {
    pub duration: f64,
    pub curve: u8,
}

/// One scalar on a tween (`TweenValue`).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CmuxMotionTweenState {
    pub value: f64,
    pub from: f64,
    pub target: f64,
    pub elapsed: f64,
    pub duration: f64,
}

/// `TabStripGeometry`, the same fields in the same order.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CmuxMotionTabStripGeometry {
    pub max_width: f64,
    pub open_start_width: f64,
    pub close_end_width: f64,
    pub min_active_width: f64,
    pub min_inactive_width: f64,
    pub pinned_width: f64,
    pub reorder_threshold: f64,
    pub closing_mode_below_pad: f64,
    pub closing_mode_trailing_pad: f64,
    pub closing_mode_exit_delay: f64,
}

/// The curve for a C ABI curve number: 0 easeOutQuad, 1 easeOut, 2
/// easeInOut, 3 linear; any other number takes easeOutQuad.
fn curve(c: u8) -> TweenCurve {
    match c {
        1 => TweenCurve::EaseOut,
        2 => TweenCurve::EaseInOut,
        3 => TweenCurve::Linear,
        _ => TweenCurve::EaseOutQuad,
    }
}

impl From<CmuxMotionTweenState> for TweenValue {
    fn from(s: CmuxMotionTweenState) -> Self {
        TweenValue {
            value: s.value,
            from: s.from,
            target: s.target,
            elapsed: s.elapsed,
            duration: s.duration,
        }
    }
}

impl From<TweenValue> for CmuxMotionTweenState {
    fn from(s: TweenValue) -> Self {
        Self {
            value: s.value,
            from: s.from,
            target: s.target,
            elapsed: s.elapsed,
            duration: s.duration,
        }
    }
}

/// The tween token `token` (`MotionTween` order: 0 tabOpen, 1 tabClose, 2
/// tabMove) at speed `fast` from the spec. Returns false for an unknown
/// token or a null `out`.
///
/// # Safety
/// `out` is null or points to a writable `CmuxMotionTween`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_motion_tween_base(token: u8, out: *mut CmuxMotionTween) -> bool {
    let Some(token) = MotionTween::ALL.get(usize::from(token)) else { return false };
    if out.is_null() {
        return false;
    }
    let p = token.base();
    // SAFETY: `out` is non-null and writable per the contract above.
    unsafe { out.write(CmuxMotionTween { duration: p.duration, curve: p.curve as u8 }) };
    true
}

/// Seconds of tween token `token` under `policy`: 0 under speed off,
/// Reduce Motion, or with the token's kind switched off (tabOpen follows
/// newTab); 0 for an unknown token.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_motion_tween_seconds(token: u8, policy: CmuxMotionPolicy) -> f64 {
    MotionTween::ALL.get(usize::from(token)).map_or(0., |t| self::policy(&policy).tween(*t))
}

/// Points `state` at `target`: the same target changes nothing (returns
/// false); a new one restarts `duration` seconds from the current value (no
/// velocity); a duration that is not positive applies it at once. False
/// for a null `state`.
///
/// # Safety
/// `state` is null or points to a valid, writable `CmuxMotionTweenState`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_motion_tween_retarget(
    state: *mut CmuxMotionTweenState,
    target: f64,
    duration: f64,
) -> bool {
    if state.is_null() {
        return false;
    }
    // SAFETY: `state` is non-null, valid and writable per the contract above.
    let s = unsafe { &mut *state };
    let mut t = TweenValue::from(*s);
    let changed = t.retarget(target, duration);
    *s = t.into();
    changed
}

/// Advances `state` by `dt` seconds (capped at 0.1 s) on `curve` (0
/// easeOutQuad). Ends exactly on the target. True while still moving;
/// false (and no change) for a null `state`.
///
/// # Safety
/// `state` is null or points to a valid, writable `CmuxMotionTweenState`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_motion_tween_step(
    state: *mut CmuxMotionTweenState,
    dt: f64,
    curve: u8,
) -> bool {
    if state.is_null() {
        return false;
    }
    // SAFETY: `state` is non-null, valid and writable per the contract above.
    let s = unsafe { &mut *state };
    let mut t = TweenValue::from(*s);
    let moving = t.step(dt, self::curve(curve));
    *s = t.into();
    moving
}

/// Progress of `curve` (0 easeOutQuad, 1 easeOut, 2 easeInOut, 3 linear) at
/// time fraction `t` (clamped to 0..=1).
#[unsafe(no_mangle)]
pub extern "C" fn cmux_motion_ease(curve: u8, t: f64) -> f64 {
    self::curve(curve).progress_f64(t)
}

/// CSS `cubic-bezier(x1, y1, x2, y2)` at time fraction `t` (clamped to 0..=1;
/// x1 and x2 clamped to 0..=1).
#[unsafe(no_mangle)]
pub extern "C" fn cmux_motion_cubic_bezier(x1: f64, y1: f64, x2: f64, y2: f64, t: f64) -> f64 {
    cmux_motion::cubic_bezier_progress(t, x1, y1, x2, y2)
}

/// A spring from rest toward 1 at `time` seconds, with no overshoot: held at
/// its running maximum, so it never decreases (0..=1).
#[unsafe(no_mangle)]
pub extern "C" fn cmux_motion_spring_progress_monotone(spring: CmuxMotionSpring, time: f64) -> f64 {
    cmux_motion::spring_progress_monotone(time, spring.into())
}

/// Seconds until a spring from rest first comes within 0.5% of its target (at most 5).
#[unsafe(no_mangle)]
pub extern "C" fn cmux_motion_spring_arrival(spring: CmuxMotionSpring) -> f64 {
    cmux_motion::spring_arrival(spring.into())
}

/// `from` mixed `t` of the way to `to` in `space` (0 OKLab, 1 sRGB; any other
/// number OKLab). Inputs and output are straight (unpremultiplied) sRGB RGBA,
/// 0..=1; the mix runs premultiplied and unpremultiplies the result (alpha 0
/// gives 0, 0, 0, 0). False (and no write) when a pointer is null.
///
/// # Safety
/// `from` and `to` are null or point to 4 readable doubles; `out` is null or
/// points to 4 writable doubles.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_motion_mix_rgba(
    from: *const f64,
    to: *const f64,
    t: f64,
    space: u8,
    out: *mut f64,
) -> bool {
    if from.is_null() || to.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: non-null and sized per the contract above.
    let (a, b) = unsafe { (*(from as *const [f64; 4]), *(to as *const [f64; 4])) };
    let space =
        if space == 1 { cmux_motion::ColorSpace::Srgb } else { cmux_motion::ColorSpace::Oklab };
    let mixed = cmux_motion::mix_rgba(a, b, t, space);
    // SAFETY: `out` is non-null and points to 4 writable doubles per the contract.
    unsafe { *(out as *mut [f64; 4]) = mixed };
    true
}

/// The tab strip geometry for `density` (0 compact, 1 comfortable) from the
/// spec (design-tokens.json `motion.tabStrip`). False for an unknown
/// density or a null `out`.
///
/// # Safety
/// `out` is null or points to a writable `CmuxMotionTabStripGeometry`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_motion_tab_strip_geometry(
    density: u8,
    out: *mut CmuxMotionTabStripGeometry,
) -> bool {
    let g = match density {
        0 => TabStripGeometry::COMPACT,
        1 => TabStripGeometry::COMFORTABLE,
        _ => return false,
    };
    if out.is_null() {
        return false;
    }
    let c = CmuxMotionTabStripGeometry {
        max_width: g.max_width,
        open_start_width: g.open_start_width,
        close_end_width: g.close_end_width,
        min_active_width: g.min_active_width,
        min_inactive_width: g.min_inactive_width,
        pinned_width: g.pinned_width,
        reorder_threshold: g.reorder_threshold,
        closing_mode_below_pad: g.closing_mode_below_pad,
        closing_mode_trailing_pad: g.closing_mode_trailing_pad,
        closing_mode_exit_delay: g.closing_mode_exit_delay,
    };
    // SAFETY: `out` is non-null and writable per the contract above.
    unsafe { out.write(c) };
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base(token: u8) -> Option<CmuxMotionSpring> {
        let mut out = CmuxMotionSpring { response: 0., damping_fraction: 0. };
        // SAFETY: `out` is a valid, writable `CmuxMotionSpring`.
        unsafe { cmux_motion_spring_base(token, &mut out) }.then_some(out)
    }

    /// A change of screen has no animation (Lawrence 2026-11-10): the table has no `screen`
    /// spring. 12 tokens; `track` follows `scroll`.
    #[test]
    fn the_spring_table_has_no_screen_token() {
        assert_eq!(base(4), Some(MotionSpring::Scroll.base().into()));
        assert_eq!(base(5), Some(MotionSpring::Track.base().into()), "token 5 is not track");
        assert_eq!(base(11), Some(MotionSpring::TabOpen.base().into()), "token 11 is not tabOpen");
        assert_eq!(base(12), None, "the table has a 13th spring token");
    }

    /// No bounce in any motion (Lawrence 2026-11-10): no token of the table is under-damped.
    #[test]
    fn no_spring_token_is_under_damped() {
        for token in 0..=u8::MAX {
            if let Some(spring) = base(token) {
                assert!(
                    spring.damping_fraction >= 1.,
                    "spring token {token} has damping fraction {}",
                    spring.damping_fraction
                );
            }
        }
    }
}
