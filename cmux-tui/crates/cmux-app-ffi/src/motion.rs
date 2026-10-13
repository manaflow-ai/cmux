//! The C ABI of cmux-motion for the macOS app (`include/cmux_motion_ffi.h`,
//! Swift module `CCmuxMotionFFI`): the closed-form spring step, the token
//! table, the structural bounce rule and the per-kind switches. The app's
//! `MotionClock` keeps only the display link and the layer updates; the
//! physics and the rules live once, in cmux-motion. Every function is pure
//! (no globals, no allocation) and never panics on any input.

use cmux_motion::{
    AnimationSwitches, MotionBounce, MotionFade, MotionKind, MotionPolicy, MotionSpeed,
    MotionSpring, SpringParameters, advance_spring,
};

/// Bumped on any change to a type or function in the header.
const ABI_VERSION: u32 = 1;

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
/// `bounce` 0 none, 1 subtle; the three `ui.animations.*` switches.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CmuxMotionPolicy {
    pub speed: u8,
    pub reduce_motion: bool,
    pub bounce: u8,
    pub splits: bool,
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
    let bounce = if p.bounce == 1 { MotionBounce::Subtle } else { MotionBounce::None };
    MotionPolicy::new(speed, p.reduce_motion).with_animations(AnimationSwitches {
        splits: p.splits,
        new_tab: p.new_tab,
        new_workspace: p.new_workspace,
        bounce,
    })
}

/// The ABI version this library implements.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_motion_ffi_abi_version() -> u32 {
    ABI_VERSION
}

/// The spring token `token` (`MotionSpring` order: 0 move, 1 appear, 2
/// disappear, 3 settle, 4 scroll, 5 screen, 6 track, 7 selection, 8 panel,
/// 9 pinDrag) at speed `fast` from the spec, before the policy. Returns
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

/// True when spring token `token` is structural (follows the bounce).
#[unsafe(no_mangle)]
pub extern "C" fn cmux_motion_spring_is_structural(token: u8) -> bool {
    MotionSpring::ALL.get(usize::from(token)).is_some_and(|t| t.is_structural())
}

/// Resolves `base` (a token's speed-`fast` tuning, possibly a host
/// override) under `policy`: a structural spring is critically damped with
/// bounce none and takes the subtle bounce with bounce subtle; then the
/// speed scales the response. The same rule as `MotionPolicy::spring`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_motion_resolve(
    base: CmuxMotionSpring,
    structural: bool,
    policy: CmuxMotionPolicy,
) -> CmuxMotionSpring {
    let p = self::policy(&policy);
    let mut s = SpringParameters::from(base);
    if structural {
        s = match p.animations.bounce {
            MotionBounce::None => SpringParameters::new(s.response, s.damping_fraction.max(1.)),
            MotionBounce::Subtle => s.with_bounce(MotionBounce::Subtle.amount()),
        };
    }
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

/// True when kind `kind` (0 splits, 1 newTab, 2 newWorkspace) animates
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
