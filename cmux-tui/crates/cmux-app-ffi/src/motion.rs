//! The C ABI of cmux-motion for the macOS app (`include/cmux_motion_ffi.h`,
//! Swift module `CCmuxMotionFFI`): the closed-form spring step, the token
//! table and the per-kind switches, and the tab strip's tweens and geometry
//! (Chrome's strip motion). The app's
//! `MotionClock` keeps only the display link and the layer updates; the
//! physics and the rules live once, in cmux-motion. Every function is pure
//! (no globals, no allocation) and never panics on any input.

use cmux_motion::{
    AnimationSwitches, LIGHT_DOMINANT_COUNT, LightField, MotionFade, MotionKind, MotionPolicy,
    MotionSpeed, MotionSpring, MotionTween, SpringParameters, TabStripGeometry, TweenCurve,
    TweenValue, advance_spring, light_field, light_point, light_rim, light_style,
};

/// Bumped on any change to a type or function in the header.
const ABI_VERSION: u32 = 8;

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

/// A wallpaper's light field (cmux-motion `LightField`, `appearance.wallpaperLighting`):
/// colors are straight sRGB 0..=1, positions 0..=1 of the picture from its top
/// left. The first `dominant_count` of `dominant` and `dominant_weight` are set.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxLightField {
    pub ambient: [f64; 3],
    pub ambient_luminance: f64,
    pub key: [f64; 3],
    pub key_x: f64,
    pub key_y: f64,
    pub key_strength: f64,
    pub key_spread: f64,
    pub dominant: [[f64; 3]; 4],
    pub dominant_weight: [f64; 4],
    pub dominant_count: u32,
    pub rim: [f64; 3],
    pub bloom: [f64; 3],
    pub tint: [f64; 3],
}

impl From<LightField> for CmuxLightField {
    fn from(f: LightField) -> Self {
        Self {
            ambient: f.ambient,
            ambient_luminance: f.ambient_luminance,
            key: f.key,
            key_x: f.key_x,
            key_y: f.key_y,
            key_strength: f.key_strength,
            key_spread: f.key_spread,
            dominant: f.dominant,
            dominant_weight: f.dominant_weight,
            dominant_count: f.dominant_count as u32,
            rim: f.rim,
            bloom: f.bloom,
            tint: f.tint,
        }
    }
}

impl From<&CmuxLightField> for LightField {
    fn from(f: &CmuxLightField) -> Self {
        Self {
            ambient: f.ambient,
            ambient_luminance: f.ambient_luminance,
            key: f.key,
            key_x: f.key_x,
            key_y: f.key_y,
            key_strength: f.key_strength,
            key_spread: f.key_spread,
            dominant: f.dominant,
            dominant_weight: f.dominant_weight,
            dominant_count: (f.dominant_count as usize).min(LIGHT_DOMINANT_COUNT),
            rim: f.rim,
            bloom: f.bloom,
            tint: f.tint,
        }
    }
}

/// cmux-motion `LightRim`: a rectangle's radial rim gradient toward the key
/// light, in the rectangle's unit space, and its peak opacity.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxLightRim {
    pub center_x: f64,
    pub center_y: f64,
    pub radius_x: f64,
    pub radius_y: f64,
    pub alpha: f64,
}

/// The light field of a small RGBA8 picture with premultiplied alpha (a
/// `CGContext` with `premultipliedLast`), rows top first, `bytes_per_row`
/// apart, `len` bytes in all. Read once per wallpaper, never per frame. False
/// for a null pointer, an empty, too large (over 128 by 128) or fully
/// transparent picture, or a buffer shorter than its size.
///
/// # Safety
/// `pixels` is null or points to `len` readable bytes; `out` is null or points
/// to a writable `CmuxLightField`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_motion_light_field(
    pixels: *const u8,
    len: usize,
    width: u32,
    height: u32,
    bytes_per_row: u32,
    out: *mut CmuxLightField,
) -> bool {
    if pixels.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: non-null and `len` readable bytes per the contract above.
    let bytes = unsafe { std::slice::from_raw_parts(pixels, len) };
    let Some(field) = light_field(bytes, width as usize, height as usize, bytes_per_row as usize)
    else {
        return false;
    };
    // SAFETY: `out` is non-null and writable per the contract.
    unsafe { out.write(field.into()) };
    true
}

/// Where `field`'s key light falls on a `width` by `height` container that a
/// picture of `picture_aspect` (width over height) fills, aspect fill and
/// centered, in points from the container's top left (`out_xy[0]`, `[1]`).
/// False for a null pointer.
///
/// # Safety
/// `field` is null or points to a readable `CmuxLightField`; `out_xy` is null
/// or points to 2 writable doubles.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_motion_light_point(
    field: *const CmuxLightField,
    picture_aspect: f64,
    width: f64,
    height: f64,
    out_xy: *mut f64,
) -> bool {
    if field.is_null() || out_xy.is_null() {
        return false;
    }
    // SAFETY: non-null and readable per the contract.
    let field: LightField = unsafe { &*field }.into();
    let (x, y) = light_point(&field, picture_aspect, width, height);
    // SAFETY: `out_xy` is non-null and points to 2 writable doubles.
    unsafe { *(out_xy as *mut [f64; 2]) = [x, y] };
    true
}

/// The rim light of `rect` (x, y, width, height) in a container `diagonal`
/// points across whose key light sits at `light_x, light_y` (from
/// `cmux_motion_light_point`). False for a null pointer or a degenerate
/// rectangle.
///
/// # Safety
/// `field` is null or points to a readable `CmuxLightField`; `rect` is null or
/// points to 4 readable doubles; `out` is null or points to a writable
/// `CmuxLightRim`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_motion_light_rim(
    field: *const CmuxLightField,
    light_x: f64,
    light_y: f64,
    rect: *const f64,
    diagonal: f64,
    out: *mut CmuxLightRim,
) -> bool {
    if field.is_null() || rect.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: non-null and sized per the contract.
    let (field, r): (LightField, [f64; 4]) =
        unsafe { ((&*field).into(), *(rect as *const [f64; 4])) };
    let Some(rim) = light_rim(&field, light_x, light_y, r[0], r[1], r[2], r[3], diagonal) else {
        return false;
    };
    let c = CmuxLightRim {
        center_x: rim.center_x,
        center_y: rim.center_y,
        radius_x: rim.radius_x,
        radius_y: rim.radius_y,
        alpha: rim.alpha,
    };
    // SAFETY: `out` is non-null and writable per the contract.
    unsafe { out.write(c) };
    true
}

/// cmux-motion `LightStyle`: what a page's glass draws from the light.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxLightStyle {
    pub dx: f64,
    pub dy: f64,
    pub rim_alpha: f64,
    pub bloom_alpha: f64,
    pub tint_share: f64,
}

/// The light style of `rect` (x, y, width, height; a window) with the same
/// inputs as `cmux_motion_light_rim`. False for a null pointer or a
/// degenerate rectangle.
///
/// # Safety
/// `field` is null or points to a readable `CmuxLightField`; `rect` is null or
/// points to 4 readable doubles; `out` is null or points to a writable
/// `CmuxLightStyle`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_motion_light_style(
    field: *const CmuxLightField,
    light_x: f64,
    light_y: f64,
    rect: *const f64,
    diagonal: f64,
    out: *mut CmuxLightStyle,
) -> bool {
    if field.is_null() || rect.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: non-null and sized per the contract.
    let (field, r): (LightField, [f64; 4]) =
        unsafe { ((&*field).into(), *(rect as *const [f64; 4])) };
    let Some(s) = light_style(&field, light_x, light_y, r[0], r[1], r[2], r[3], diagonal) else {
        return false;
    };
    let c = CmuxLightStyle {
        dx: s.dx,
        dy: s.dy,
        rim_alpha: s.rim_alpha,
        bloom_alpha: s.bloom_alpha,
        tint_share: s.tint_share,
    };
    // SAFETY: `out` is non-null and writable per the contract.
    unsafe { out.write(c) };
    true
}

#[cfg(test)]
#[path = "motion_tests.rs"]
mod tests;
