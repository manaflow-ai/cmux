//! The C ABI of cmux-motion's gooey tabs for the macOS app
//! (`include/cmux_motion_ffi.h`, the "goo" section; Swift module
//! `CCmuxMotionFFI`; plans/cmux-next/gooey-tabs.md "The C ABI"). The goo
//! lives once, in cmux-motion (`goo`): these functions convert the C structs
//! (total conversions, every value sanitized there) and check pointers. One
//! plan per event, nothing per frame; no allocation. None panics on any input.
//!
//! `CmuxGooLevel` and `CmuxGooEvent` are C enums in the header (written by
//! cbindgen.toml's `after_includes` with the two `CMUX_GOO_*` macros) and
//! plain `u32`s here, so a value outside the enum is not UB: an unknown level
//! is off and an unknown event is select.

use cmux_motion::goo::{
    self, Blob, GOO_KEYFRAMES_MAX, GOO_OUTLINE_LEN, GooEvent, GooLevel, GooSpring, GooTuning,
    Outline, PlanInput, RoundedRect, Track,
};

/// A goo level in C (`CmuxGooLevel`: 0 off, 1 subtle, 2 full).
pub type CmuxGooLevel = u32;
/// A strip event in C (`CmuxGooEvent`: 0 select, 1 open, 2 close, 3 close
/// last, 4 reorder, 5 snap, 6 absorb).
pub type CmuxGooEvent = u32;

/// A goo spring: response (s) and damping fraction (1 is critical; under 1 overshoots).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxGooSpring {
    pub response: f64,
    pub damping_fraction: f64,
}

/// A level's goo: the events' springs, the wobble's, and the goo amounts
/// (`GooTuning::for_level`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxGooTuning {
    pub select: CmuxGooSpring,
    pub open: CmuxGooSpring,
    pub close: CmuxGooSpring,
    pub reorder: CmuxGooSpring,
    pub snap: CmuxGooSpring,
    pub absorb: CmuxGooSpring,
    pub wobble: CmuxGooSpring,
    pub stretch: f64,
    pub lean: f64,
    pub feet_scale: f64,
    pub k: f64,
    pub break_distance: f64,
    pub capture_distance: f64,
    pub wobble_amplitude: f64,
}

/// One edge or scalar in flight: closed-form spring from (x0, v0) toward target, started at `start` (media time).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxGooTrack {
    pub x0: f64,
    pub v0: f64,
    pub target: f64,
    pub start: f64,
    pub spring: CmuxGooSpring,
}

/// The blob's geometry in the strip's layer coordinates (flipped: baseline is the card's top, y grows down).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxGooBlob {
    pub left: f64,
    pub right: f64,
    pub top: f64,
    pub baseline: f64,
    pub corner_radius: f64,
    pub feet_radius: f64,
    pub skips_leading: bool,
}

/// A point of an outline.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxGooPoint {
    pub x: f64,
    pub y: f64,
}

/// 1 + 3*N points (N = CMUX_GOO_OUTLINE_POINTS, 24): a closed path of N cubics (move-to p0, then (c1, c2, p) per
/// segment).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CmuxGooOutline {
    pub p: [CmuxGooPoint; 73],
}

const _: () =
    assert!(GOO_OUTLINE_LEN == 73 && goo::GOO_OUTLINE_POINTS == 24 && GOO_KEYFRAMES_MAX == 120);

impl Default for CmuxGooOutline {
    fn default() -> Self {
        Self { p: [CmuxGooPoint::default(); 73] }
    }
}

impl From<CmuxGooSpring> for GooSpring {
    fn from(s: CmuxGooSpring) -> Self {
        GooSpring::new(s.response, s.damping_fraction)
    }
}

impl From<GooSpring> for CmuxGooSpring {
    fn from(s: GooSpring) -> Self {
        Self { response: s.response, damping_fraction: s.damping_fraction }
    }
}

impl From<&CmuxGooTuning> for GooTuning {
    fn from(t: &CmuxGooTuning) -> Self {
        GooTuning {
            select: t.select.into(),
            open: t.open.into(),
            close: t.close.into(),
            reorder: t.reorder.into(),
            snap: t.snap.into(),
            absorb: t.absorb.into(),
            wobble: t.wobble.into(),
            stretch: t.stretch,
            lean: t.lean,
            feet_scale: t.feet_scale,
            k: t.k,
            break_distance: t.break_distance,
            capture_distance: t.capture_distance,
            wobble_amplitude: t.wobble_amplitude,
        }
    }
}

impl From<GooTuning> for CmuxGooTuning {
    fn from(t: GooTuning) -> Self {
        Self {
            select: t.select.into(),
            open: t.open.into(),
            close: t.close.into(),
            reorder: t.reorder.into(),
            snap: t.snap.into(),
            absorb: t.absorb.into(),
            wobble: t.wobble.into(),
            stretch: t.stretch,
            lean: t.lean,
            feet_scale: t.feet_scale,
            k: t.k,
            break_distance: t.break_distance,
            capture_distance: t.capture_distance,
            wobble_amplitude: t.wobble_amplitude,
        }
    }
}

impl From<&CmuxGooTrack> for Track {
    fn from(t: &CmuxGooTrack) -> Self {
        Track::new(t.x0, t.v0, t.target, t.start, t.spring.into())
    }
}

impl From<Track> for CmuxGooTrack {
    fn from(t: Track) -> Self {
        Self { x0: t.x0, v0: t.v0, target: t.target, start: t.start, spring: t.spring.into() }
    }
}

impl From<&CmuxGooBlob> for Blob {
    fn from(b: &CmuxGooBlob) -> Self {
        Blob {
            left: b.left,
            right: b.right,
            top: b.top,
            baseline: b.baseline,
            corner_radius: b.corner_radius,
            feet_radius: b.feet_radius,
            skips_leading: b.skips_leading,
        }
    }
}

fn write_outline(out: &mut CmuxGooOutline, o: &Outline) {
    for (slot, p) in out.p.iter_mut().zip(o.p.iter()) {
        *slot = CmuxGooPoint { x: p.x, y: p.y };
    }
}

/// The tuning when `tuning` is null: the level's own.
fn tuning_or(tuning: *const CmuxGooTuning, level: GooLevel) -> GooTuning {
    // SAFETY: `tuning` is null or readable per the callers' contracts.
    match unsafe { tuning.as_ref() } {
        Some(t) => t.into(),
        None => GooTuning::for_level(level),
    }
}

/// The level's tuning (`GooTuning::for_level`); an unknown level is off.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_goo_tuning_for_level(level: CmuxGooLevel) -> CmuxGooTuning {
    GooTuning::for_level(GooLevel::from_raw(level)).into()
}

/// x and velocity of `track` at `t` (media time). Nothing for a null `track`; a null `x` or `v` is skipped.
///
/// # Safety
/// `track` is null or readable; `x` and `v` are each null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_goo_track_state(
    track: *const CmuxGooTrack,
    t: f64,
    x: *mut f64,
    v: *mut f64,
) {
    // SAFETY: null or readable per the contract above.
    let Some(track) = (unsafe { track.as_ref() }) else {
        return;
    };
    let (px, pv) = Track::from(track).state(t);
    // SAFETY: each is null or writable per the contract above.
    if let Some(x) = unsafe { x.as_mut() } {
        *x = px;
    }
    // SAFETY: as above.
    if let Some(v) = unsafe { v.as_mut() } {
        *v = pv;
    }
}

/// The track restarted at `t` from its state there toward `target`, velocity kept (interruption). A null `track`
/// gives a track at rest on `target`.
///
/// # Safety
/// `track` is null or readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_goo_track_retarget(
    track: *const CmuxGooTrack,
    t: f64,
    target: f64,
    spring: CmuxGooSpring,
) -> CmuxGooTrack {
    // SAFETY: null or readable per the contract above.
    match unsafe { track.as_ref() } {
        Some(track) => Track::from(track).retarget(t, target, spring.into()).into(),
        None => Track::at_rest(target, t, spring.into()).sanitized().into(),
    }
}

/// Seconds from start until |x-target| and |v| fall under epsilon. 0 for a null `track`.
///
/// # Safety
/// `track` is null or readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_goo_track_rest_time(track: *const CmuxGooTrack, epsilon: f64) -> f64 {
    // SAFETY: null or readable per the contract above.
    match unsafe { track.as_ref() } {
        Some(track) => Track::from(track).rest_time(epsilon),
        None => 0.,
    }
}

/// The blob's outline at rest (equals TabCell.folderPath's shape to < 0.5 px). Nothing for a null pointer.
///
/// # Safety
/// `blob` is null or readable; `out` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_goo_blob_outline(blob: *const CmuxGooBlob, out: *mut CmuxGooOutline) {
    // SAFETY: null or valid per the contract above.
    let (Some(blob), Some(out)) = (unsafe { blob.as_ref() }, unsafe { out.as_mut() }) else {
        return;
    };
    write_outline(out, &goo::rest_outline(&blob.into()));
}

/// An event's keyframes: the blob's edges from `left`/`right` tracks (plus lean and wobble from `tuning`), sampled
/// at `hz` from max(left.start, right.start); writes at most `capacity` (and at most CMUX_GOO_KEYFRAMES_MAX)
/// outlines and their key times (0...1), and returns the count and the duration in seconds (`duration` may be
/// null). reduce_motion: 1 keyframe (the end) and duration 0. The last keyframe is exactly `rest_to` at rest.
/// 0 for a null blob, track, `outlines` or `key_times`; a null `tuning` is full's.
///
/// # Safety
/// The blob and track pointers are null or readable; `tuning` is null or readable; `outlines` and `key_times`
/// are null or point to `capacity` writable elements each; `duration` is null or writable.
#[allow(clippy::too_many_arguments)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_goo_plan(
    event: CmuxGooEvent,
    rest_from: *const CmuxGooBlob,
    rest_to: *const CmuxGooBlob,
    left: *const CmuxGooTrack,
    right: *const CmuxGooTrack,
    tuning: *const CmuxGooTuning,
    hz: f64,
    reduce_motion: bool,
    outlines: *mut CmuxGooOutline,
    key_times: *mut f64,
    capacity: usize,
    duration: *mut f64,
) -> usize {
    // SAFETY: `duration` is null or writable per the contract above.
    let duration = unsafe { duration.as_mut() };
    let mut seconds = 0.;
    let count = 'plan: {
        // SAFETY: each is null or readable per the contract above.
        let ptrs = unsafe { (rest_from.as_ref(), rest_to.as_ref(), left.as_ref(), right.as_ref()) };
        let (Some(rest_from), Some(rest_to), Some(left), Some(right)) = ptrs else {
            break 'plan 0;
        };
        let capacity = capacity.min(GOO_KEYFRAMES_MAX);
        if outlines.is_null() || key_times.is_null() || capacity == 0 {
            break 'plan 0;
        }
        // SAFETY: non-null with at least `capacity` writable elements per the contract above.
        let outlines = unsafe { std::slice::from_raw_parts_mut(outlines, capacity) };
        // SAFETY: as above.
        let key_times = unsafe { std::slice::from_raw_parts_mut(key_times, capacity) };
        let input = PlanInput {
            event: GooEvent::from_raw(event),
            rest_from: rest_from.into(),
            rest_to: rest_to.into(),
            left: left.into(),
            right: right.into(),
            tuning: tuning_or(tuning, GooLevel::Full),
            hz,
            reduce_motion,
        };
        let mut slots = outlines.iter_mut().zip(key_times.iter_mut());
        let (count, d) = goo::plan(&input, capacity, |o, k| {
            if let Some((out, key)) = slots.next() {
                write_outline(out, o);
                *key = k;
            }
        });
        seconds = d;
        count
    };
    if let Some(duration) = duration {
        *duration = seconds;
    }
    count
}

/// The drag neck: `slot` is the dragged tab's blob in the strip, `tab_*` the lifted tab's rect (same coordinates).
/// attached = whether the neck holds; outline = the slot's blob merged with the neck (or the slot alone, detached).
/// `was_attached` gives the hysteresis (break_distance out, capture_distance back). Nothing for a null `slot` or
/// `out`; a null `tuning` is full's; `attached` may be null.
///
/// # Safety
/// `slot` and `tuning` are null or readable; `out` and `attached` are null or writable.
#[allow(clippy::too_many_arguments)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_goo_drag_neck(
    slot: *const CmuxGooBlob,
    tab_x: f64,
    tab_y: f64,
    tab_w: f64,
    tab_h: f64,
    was_attached: bool,
    tuning: *const CmuxGooTuning,
    out: *mut CmuxGooOutline,
    attached: *mut bool,
) {
    // SAFETY: null or valid per the contract above.
    let (Some(slot), Some(out)) = (unsafe { slot.as_ref() }, unsafe { out.as_mut() }) else {
        return;
    };
    let slot = Blob::from(slot);
    let tab = RoundedRect::new(tab_x, tab_y, tab_w, tab_h, slot.corner_radius);
    let neck = goo::drag_neck(&slot, &tab, was_attached, &tuning_or(tuning, GooLevel::Full));
    write_outline(out, &neck.outline);
    // SAFETY: null or writable per the contract above.
    if let Some(attached) = unsafe { attached.as_mut() } {
        *attached = neck.attached;
    }
}

/// A neighbour's smooth union with the blob (full only): the blob merged with a rounded rect within k. Nothing
/// for a null `blob` or `out`; a null `tuning` is full's.
///
/// # Safety
/// `blob` and `tuning` are null or readable; `out` is null or writable.
#[allow(clippy::too_many_arguments)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_goo_neck(
    blob: *const CmuxGooBlob,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    radius: f64,
    tuning: *const CmuxGooTuning,
    out: *mut CmuxGooOutline,
) {
    // SAFETY: null or valid per the contract above.
    let (Some(blob), Some(out)) = (unsafe { blob.as_ref() }, unsafe { out.as_mut() }) else {
        return;
    };
    let k = tuning_or(tuning, GooLevel::Full).sanitized().k;
    write_outline(out, &goo::neck(&blob.into(), &RoundedRect::new(x, y, w, h, radius), k));
}

#[cfg(test)]
#[path = "goo_tests.rs"]
mod tests;
