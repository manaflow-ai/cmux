//! The C ABI of cmux-wallpaper for the macOS app (`include/cmux_wallpaper_ffi.h`):
//! live wallpapers (plans/cmux-next/live-wallpapers.md). The first-party set
//! with its Metal translated at build time (the library links no shader
//! compiler), the manifest check, the
//! draw scheduler, the `Frame` uniform packer and the pointer's smoothing.
//! The app's `BackdropLiveView` keeps only the Metal layer, the display link
//! and the events; every rule and every number lives once, in cmux-wallpaper.
//! Motion scenes (plans/cmux-next/motion-scenes.md) add a scene player handle
//! (`cmux_wallpaper_scene_*`): it packs the 2048-byte Scene block each frame
//! and says when the scene is at rest, for the scheduler.
//!
//! No function panics across the boundary: the ones that allocate or run a
//! scene run under `catch_unwind`, and the rest are panic-free arithmetic. A
//! null pointer is answered with a defined value, never read.

use cmux_wallpaper::frame::{ActivityState, FrameInput, PointerState};
use cmux_wallpaper::schedule::{Decision, ScheduleInput};
use cmux_wallpaper::{FRAME_FLOATS, Manifest, Player, SCENE_FLOATS};
use std::ffi::{CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type or function in the header. 4: motion
/// scenes (`cmux_wallpaper_scene_*`), the scheduler's `at_rest` input and hold
/// reason 13.
const ABI_VERSION: u32 = 4;

/// The result of `cmux_wallpaper_validate_manifest`; free it with
/// `cmux_wallpaper_manifest_result_free`. On success `json` is the manifest
/// with every optional key filled in (params' titles, variants' themes); on
/// failure `error` says why and `pointer` (a JSON pointer, "" for the whole
/// document) says where.
#[repr(C)]
#[derive(Debug)]
pub struct CmuxWallpaperManifestResult {
    pub ok: bool,
    pub json: *mut c_char,
    pub error: *mut c_char,
    pub pointer: *mut c_char,
}

/// What the host knows when it asks the scheduler (`ScheduleInput`).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CmuxWallpaperScheduleInput {
    /// Seconds since the last key press in the window, size or theme change.
    pub seconds_since_activity: f64,
    /// Seconds since the pointer last moved over the window.
    pub seconds_since_pointer: f64,
    /// Seconds since an agent in the window last wrote output or changed state
    /// (`cmux_wallpaper_activity_since_event`).
    pub seconds_since_agent_event: f64,
    /// `appearance.liveWallpaperFrameRate` (15, 30, 60); 0 means 30.
    pub settings_fps_cap: u32,
    /// The manifest's `fps`.
    pub manifest_fps: u32,
    /// GPU frames over 4 ms in a row (`cmux_wallpaper_gpu_strikes`).
    pub gpu_strikes: u32,
    /// The backing scale the view draws at now (starts at the manifest's `scale`).
    pub scale: f32,
    /// The window is on screen (not occluded).
    pub visible: bool,
    /// `BackdropCoverage`: nearly all covered, and resting.
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
    /// The manifest's `interactive`.
    pub interactive: bool,
    /// The manifest's `agents`.
    pub agents: bool,
    /// The view has drawn at least one frame.
    pub has_frame: bool,
    /// A motion scene at rest (`cmux_wallpaper_scene_at_rest`); false for a
    /// program wallpaper.
    pub at_rest: bool,
}

/// The scheduler's answer. `run` false: hold (stop the display link, no
/// timer), for `hold_reason`: 1 occluded, 2 covered, 3 minimized, 4 app
/// hidden, 5 screens asleep, 6 session inactive, 7 Low Power Mode, 8 thermal,
/// 9 Reduce Motion, 10 animations off, 11 too heavy (mark it in the picker),
/// 12 idle, 13 a motion scene at rest (ask again after a pointer move or a
/// press has gone through `cmux_wallpaper_scene_evaluate`); with `draw_one`,
/// draw one frame at `scale` first (the view has
/// none yet). `run` true: draw every `interval_s` seconds (`fps`, the display
/// link's preferred rate) at backing scale `scale`; `hold_reason` is 0. When
/// `scale` differs from the input's, set the strikes to 0.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CmuxWallpaperDecision {
    pub interval_s: f64,
    pub scale: f32,
    pub fps: u32,
    pub run: bool,
    pub draw_one: bool,
    pub hold_reason: u8,
}

/// One frame's values by name (`FrameInput`); `cmux_wallpaper_frame_pack`
/// writes the 40 floats of the 160-byte Frame uniform. Colors are linear
/// RGB (`cmux_wallpaper_srgb_to_linear`). NaN or infinite values become 0.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxWallpaperFrameInput {
    /// Seconds since shown (continues across holds).
    pub time: f32,
    /// Seconds since the last frame.
    pub delta: f32,
    pub frame_number: f32,
    /// Backdrop size in rendered pixels.
    pub width: f32,
    pub height: f32,
    pub backing_scale: f32,
    /// 0..1, per window.
    pub seed: f32,
    /// Backing pixels, top left origin (`CmuxWallpaperPointer.x`, `.y`).
    pub pointer_x: f32,
    pub pointer_y: f32,
    /// Backing pixels per second, smoothed (`CmuxWallpaperPointer.vx`, `.vy`).
    pub velocity_x: f32,
    pub velocity_y: f32,
    /// 0..1, eased (`CmuxWallpaperPointer.presence`).
    pub presence: f32,
    /// `cmux_wallpaper_pointer_since_moved`.
    pub since_moved: f32,
    /// 0..1, eased (`CmuxWallpaperActivity.level`).
    pub activity: f32,
    /// `cmux_wallpaper_activity_since_event`.
    pub since_agent_event: f32,
    /// `CmuxWallpaperActivity.count`.
    pub agent_events: f32,
    pub ink: [f32; 3],
    pub paper: [f32; 3],
    pub accent: [f32; 3],
    /// The manifest's params in order, then 0.
    pub params: [f32; 8],
    /// A still (thumbnail, light field, cover), not a live frame.
    pub still: bool,
    pub button_down: bool,
    /// Dark appearance.
    pub dark: bool,
}

/// The pointer's smoothing state (`PointerState`). Zero it (or call
/// `cmux_wallpaper_pointer_reset`) once; then `update` on each pointer
/// move, `leave` when it leaves the window, and `advance` once per drawn
/// frame. Times are the host's monotonic clock in seconds
/// (`CACurrentMediaTime`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxWallpaperPointer {
    pub last_sample: f64,
    pub last_advance: f64,
    pub x: f32,
    pub y: f32,
    pub vx: f32,
    pub vy: f32,
    pub presence: f32,
    pub inside: bool,
    pub has_sample: bool,
}

impl From<CmuxWallpaperPointer> for PointerState {
    fn from(p: CmuxWallpaperPointer) -> Self {
        Self {
            x: p.x,
            y: p.y,
            vx: p.vx,
            vy: p.vy,
            presence: p.presence,
            inside: p.inside,
            last_sample: p.last_sample,
            last_advance: p.last_advance,
            has_sample: p.has_sample,
        }
    }
}

impl From<PointerState> for CmuxWallpaperPointer {
    fn from(p: PointerState) -> Self {
        Self {
            last_sample: p.last_sample,
            last_advance: p.last_advance,
            x: p.x,
            y: p.y,
            vx: p.vx,
            vy: p.vy,
            presence: p.presence,
            inside: p.inside,
            has_sample: p.has_sample,
        }
    }
}

impl From<&CmuxWallpaperFrameInput> for FrameInput {
    fn from(i: &CmuxWallpaperFrameInput) -> Self {
        Self {
            time: i.time,
            delta: i.delta,
            frame_number: i.frame_number,
            still: i.still,
            width: i.width,
            height: i.height,
            backing_scale: i.backing_scale,
            seed: i.seed,
            pointer_x: i.pointer_x,
            pointer_y: i.pointer_y,
            velocity_x: i.velocity_x,
            velocity_y: i.velocity_y,
            presence: i.presence,
            since_moved: i.since_moved,
            activity: i.activity,
            since_agent_event: i.since_agent_event,
            agent_events: i.agent_events,
            button_down: i.button_down,
            dark: i.dark,
            ink: i.ink,
            paper: i.paper,
            accent: i.accent,
            params: i.params,
        }
    }
}

impl From<&CmuxWallpaperScheduleInput> for ScheduleInput {
    fn from(i: &CmuxWallpaperScheduleInput) -> Self {
        Self {
            visible: i.visible,
            coverage_resting: i.coverage_resting,
            minimized: i.minimized,
            app_hidden: i.app_hidden,
            screens_asleep: i.screens_asleep,
            session_inactive: i.session_inactive,
            low_power: i.low_power,
            thermal_serious: i.thermal_serious,
            reduce_motion: i.reduce_motion,
            animations_off: i.animations_off,
            seconds_since_activity: i.seconds_since_activity,
            seconds_since_pointer: i.seconds_since_pointer,
            seconds_since_agent_event: i.seconds_since_agent_event,
            interactive: i.interactive,
            agents: i.agents,
            settings_fps_cap: i.settings_fps_cap,
            manifest_fps: i.manifest_fps,
            gpu_strikes: i.gpu_strikes,
            scale: i.scale,
            has_frame: i.has_frame,
            at_rest: i.at_rest,
        }
    }
}

fn owned(s: &str) -> *mut c_char {
    let bytes: Vec<u8> = s.bytes().filter(|b| *b != 0).collect();
    CString::new(bytes).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

fn release(p: *mut c_char) {
    if !p.is_null() {
        // SAFETY: every non-null string in a result came from `owned` (CString::into_raw)
        // and is released once, by the result's free function.
        drop(unsafe { CString::from_raw(p) });
    }
}

/// The bytes at `ptr..ptr+len`; empty for a null pointer.
///
/// # Safety
/// `ptr` is null or points to `len` readable bytes.
unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        // SAFETY: non-null and `len` readable bytes per the caller's contract.
        unsafe { std::slice::from_raw_parts(ptr, len) }
    }
}

/// The ABI version this library implements.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_wallpaper_abi_version() -> u32 {
    ABI_VERSION
}

/// How many first-party wallpapers the binary carries (the shipped set,
/// sorted by id; the `smoke` test sample is not among them).
#[unsafe(no_mangle)]
pub extern "C" fn cmux_wallpaper_first_party_count() -> usize {
    cmux_wallpaper::first_party().len()
}

fn static_text(text: Option<&'static str>, len: *mut usize) -> *const u8 {
    let text = text.unwrap_or("");
    if !len.is_null() {
        // SAFETY: `len` is non-null and writable per the callers' contracts.
        unsafe { len.write(text.len()) };
    }
    if text.is_empty() { std::ptr::null() } else { text.as_ptr() }
}

/// First-party wallpaper `index`'s `wallpaper.json`: static UTF-8 bytes (not
/// NUL-terminated, never freed), their count in `*len`. Null and 0 for an
/// index past the count.
///
/// # Safety
/// `len` is null or points to a writable `size_t`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_first_party_manifest_json(
    index: usize,
    len: *mut usize,
) -> *const u8 {
    static_text(cmux_wallpaper::first_party_at(index).map(|w| w.manifest_json), len)
}

/// First-party wallpaper `index`'s program (`wallpaper.wgsl`): static UTF-8
/// bytes as above.
///
/// # Safety
/// `len` is null or points to a writable `size_t`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_first_party_source(
    index: usize,
    len: *mut usize,
) -> *const u8 {
    static_text(cmux_wallpaper::first_party_at(index).map(|w| w.source), len)
}

/// First-party wallpaper `index`'s program in Metal Shading Language 2.1,
/// translated when the library was built (the library has no shader
/// compiler): `vertex vs_main` (a full-screen triangle, 3 vertices) and
/// `fragment fs_main`, the 160-byte Frame uniform at buffer index 0 in both.
/// Static UTF-8 bytes as above.
///
/// # Safety
/// `len` is null or points to a writable `size_t`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_first_party_msl(
    index: usize,
    len: *mut usize,
) -> *const u8 {
    static_text(cmux_wallpaper::first_party_at(index).map(|w| w.msl), len)
}

fn manifest_result(json: &[u8]) -> CmuxWallpaperManifestResult {
    match Manifest::parse(json) {
        Ok(m) => CmuxWallpaperManifestResult {
            ok: true,
            json: owned(&m.to_json().to_string()),
            error: std::ptr::null_mut(),
            pointer: std::ptr::null_mut(),
        },
        Err(e) => CmuxWallpaperManifestResult {
            ok: false,
            json: std::ptr::null_mut(),
            error: owned(&e.message),
            pointer: owned(&e.pointer),
        },
    }
}

/// Checks `len` bytes of `wallpaper.json`. Never null; free the result with
/// `cmux_wallpaper_manifest_result_free`.
///
/// # Safety
/// `json` is null or points to `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_validate_manifest(
    json: *const u8,
    len: usize,
) -> *mut CmuxWallpaperManifestResult {
    // SAFETY: per this function's contract.
    let json = unsafe { bytes(json, len) };
    let result = catch_unwind(AssertUnwindSafe(|| manifest_result(json))).unwrap_or_else(|_| {
        CmuxWallpaperManifestResult {
            ok: false,
            json: std::ptr::null_mut(),
            error: owned("the manifest check failed"),
            pointer: owned(""),
        }
    });
    Box::into_raw(Box::new(result))
}

/// Frees a `cmux_wallpaper_validate_manifest` result. Null is a no-op.
///
/// # Safety
/// `result` is null or a pointer `cmux_wallpaper_validate_manifest` returned, not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_manifest_result_free(
    result: *mut CmuxWallpaperManifestResult,
) {
    if result.is_null() {
        return;
    }
    // SAFETY: `result` came from Box::into_raw in cmux_wallpaper_validate_manifest and is freed once.
    let r = unsafe { Box::from_raw(result) };
    release(r.json);
    release(r.error);
    release(r.pointer);
}

/// Whether the wallpaper draws now, and how (the spec's "When it draws").
/// Ask after every event that could change the answer and on each frame. A
/// null `input` holds as occluded.
///
/// # Safety
/// `input` is null or points to a valid `CmuxWallpaperScheduleInput`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_schedule(
    input: *const CmuxWallpaperScheduleInput,
) -> CmuxWallpaperDecision {
    let held = |reason: u8, draw_one: bool, scale: f32| CmuxWallpaperDecision {
        interval_s: 0.0,
        scale,
        fps: 0,
        run: false,
        draw_one,
        hold_reason: reason,
    };
    if input.is_null() {
        return held(1, false, 1.0);
    }
    // SAFETY: non-null and valid per this function's contract.
    let input = ScheduleInput::from(unsafe { &*input });
    match cmux_wallpaper::schedule(&input) {
        Decision::Hold { reason, draw_one, scale } => held(reason as u8, draw_one, scale),
        Decision::Run { fps, interval_s, scale } => CmuxWallpaperDecision {
            interval_s,
            scale,
            fps,
            run: true,
            draw_one: false,
            hold_reason: 0,
        },
    }
}

/// The GPU strike count after a frame that took `gpu_ms` on the GPU: one
/// more when it passed 4 ms, else 0 (NaN or negative: unchanged).
#[unsafe(no_mangle)]
pub extern "C" fn cmux_wallpaper_gpu_strikes(strikes: u32, gpu_ms: f32) -> u32 {
    cmux_wallpaper::gpu_strikes(strikes, gpu_ms)
}

/// The floats in the Frame uniform (`cmux_wallpaper_frame_pack` writes this
/// many): the host sizes its buffer from this, never from a number of its
/// own, so a Frame that grows cannot overrun it.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_wallpaper_frame_floats() -> usize {
    FRAME_FLOATS
}

/// Writes the 40 floats (160 bytes) of the Frame uniform for `input` to
/// `out`. False, and nothing written, when either is null.
///
/// # Safety
/// `input` is null or points to a valid `CmuxWallpaperFrameInput`; `out` is
/// null or points to `cmux_wallpaper_frame_floats()` writable floats.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_frame_pack(
    input: *const CmuxWallpaperFrameInput,
    out: *mut f32,
) -> bool {
    if input.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: non-null and valid per this function's contract.
    let floats = cmux_wallpaper::pack_frame(&FrameInput::from(unsafe { &*input }));
    // SAFETY: `out` has room for FRAME_FLOATS floats per this function's contract.
    unsafe { std::ptr::copy_nonoverlapping(floats.as_ptr(), out, FRAME_FLOATS) };
    true
}

/// One sRGB channel (0..1) in linear light, for the theme colors.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_wallpaper_srgb_to_linear(c: f32) -> f32 {
    cmux_wallpaper::srgb_to_linear(c)
}

fn with_pointer(state: *mut CmuxWallpaperPointer, f: impl FnOnce(&mut PointerState)) {
    if state.is_null() {
        return;
    }
    // SAFETY: callers pass `state` from their own contract: null (handled) or valid and writable.
    let s = unsafe { &mut *state };
    let mut p = PointerState::from(*s);
    f(&mut p);
    *s = p.into();
}

/// Sets `state` to its start (no sample, outside, still).
///
/// # Safety
/// `state` is null or points to a writable `CmuxWallpaperPointer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_pointer_reset(state: *mut CmuxWallpaperPointer) {
    with_pointer(state, |p| *p = PointerState::default());
}

/// A pointer move to (`x`, `y`) rendered pixels (top left origin) at time `t`
/// seconds: the smoothed velocity takes the sample in and presence heads to 1.
///
/// # Safety
/// `state` is null or points to a valid, writable `CmuxWallpaperPointer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_pointer_update(
    state: *mut CmuxWallpaperPointer,
    x: f32,
    y: f32,
    t: f64,
) {
    with_pointer(state, |p| p.moved(x, y, t));
}

/// The pointer left the window: presence heads to 0.
///
/// # Safety
/// `state` is null or points to a valid, writable `CmuxWallpaperPointer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_pointer_leave(state: *mut CmuxWallpaperPointer) {
    with_pointer(state, PointerState::left);
}

/// Steps presence and velocity easing to time `t` (once per drawn frame).
///
/// # Safety
/// `state` is null or points to a valid, writable `CmuxWallpaperPointer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_pointer_advance(state: *mut CmuxWallpaperPointer, t: f64) {
    with_pointer(state, |p| p.advance(t));
}

/// Seconds since the pointer last moved at time `t`, capped at 10000 (the
/// cap when it never moved, or for a null `state`): `Frame.presence.y`.
///
/// # Safety
/// `state` is null or points to a valid `CmuxWallpaperPointer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_pointer_since_moved(
    state: *const CmuxWallpaperPointer,
    t: f64,
) -> f32 {
    if state.is_null() {
        return cmux_wallpaper::frame::MAX_SINCE_MOVED;
    }
    // SAFETY: non-null and valid per this function's contract.
    PointerState::from(unsafe { *state }).since_moved(t)
}

/// True when nothing in `state` is easing (presence at its target, velocity
/// 0): the pointer needs no frames of its own. True for a null `state`.
///
/// # Safety
/// `state` is null or points to a valid `CmuxWallpaperPointer`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_pointer_settled(
    state: *const CmuxWallpaperPointer,
) -> bool {
    if state.is_null() {
        return true;
    }
    // SAFETY: non-null and valid per this function's contract.
    PointerState::from(unsafe { *state }).settled()
}

/// The agents' activity in a window (`ActivityState`). Zero it (or call
/// `cmux_wallpaper_activity_reset`) once; then `event` when an agent in the
/// window writes output or changes state, and `advance` once per drawn frame.
/// Times are the host's monotonic clock in seconds (`CACurrentMediaTime`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxWallpaperActivity {
    pub last_event: f64,
    pub last_advance: f64,
    /// 0..1, eased: `Frame.activity.x`.
    pub level: f32,
    /// Counted events, mod 1024: `Frame.activity.z`.
    pub count: u16,
    pub has_event: bool,
}

impl From<CmuxWallpaperActivity> for ActivityState {
    fn from(a: CmuxWallpaperActivity) -> Self {
        Self {
            level: a.level,
            count: a.count,
            last_event: a.last_event,
            last_advance: a.last_advance,
            has_event: a.has_event,
        }
    }
}

impl From<ActivityState> for CmuxWallpaperActivity {
    fn from(a: ActivityState) -> Self {
        Self {
            last_event: a.last_event,
            last_advance: a.last_advance,
            level: a.level,
            count: a.count,
            has_event: a.has_event,
        }
    }
}

fn with_activity(state: *mut CmuxWallpaperActivity, f: impl FnOnce(&mut ActivityState)) {
    if state.is_null() {
        return;
    }
    // SAFETY: callers pass `state` from their own contract: null (handled) or valid and writable.
    let s = unsafe { &mut *state };
    let mut a = ActivityState::from(*s);
    f(&mut a);
    *s = a.into();
}

/// Sets `state` to its start (no event, level 0).
///
/// # Safety
/// `state` is null or points to a writable `CmuxWallpaperActivity`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_activity_reset(state: *mut CmuxWallpaperActivity) {
    with_activity(state, |a| *a = ActivityState::default());
}

/// An agent event at time `t`: the level rises, and an event more than 0.4 s
/// after the last counted one is counted (a burst of output counts once).
///
/// # Safety
/// `state` is null or points to a valid, writable `CmuxWallpaperActivity`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_activity_event(state: *mut CmuxWallpaperActivity, t: f64) {
    with_activity(state, |a| a.event(t));
}

/// Steps the level's decay to time `t` (once per drawn frame).
///
/// # Safety
/// `state` is null or points to a valid, writable `CmuxWallpaperActivity`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_activity_advance(
    state: *mut CmuxWallpaperActivity,
    t: f64,
) {
    with_activity(state, |a| a.advance(t));
}

/// Seconds since the newest counted agent event at time `t`, capped at 10000
/// (the cap when there was none, or for a null `state`): `Frame.activity.y`
/// and the scheduler's `seconds_since_agent_event`.
///
/// # Safety
/// `state` is null or points to a valid `CmuxWallpaperActivity`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_activity_since_event(
    state: *const CmuxWallpaperActivity,
    t: f64,
) -> f32 {
    if state.is_null() {
        return cmux_wallpaper::frame::MAX_SINCE_MOVED;
    }
    // SAFETY: non-null and valid per this function's contract.
    ActivityState::from(unsafe { *state }).since_event(t)
}

/// True when the activity needs no frames of its own at time `t` (the level
/// rests at 0 and the newest event's 4 s flash is over). True for a null `state`.
///
/// # Safety
/// `state` is null or points to a valid `CmuxWallpaperActivity`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_activity_settled(
    state: *const CmuxWallpaperActivity,
    t: f64,
) -> bool {
    if state.is_null() {
        return true;
    }
    // SAFETY: non-null and valid per this function's contract.
    ActivityState::from(unsafe { *state }).settled(t)
}

// MARK: Motion scenes (plans/cmux-next/motion-scenes.md)

/// A motion scene running in one backdrop: its keyframes and its physics
/// world. Made by `cmux_wallpaper_scene_new` or
/// `cmux_wallpaper_scene_new_first_party`, freed by `cmux_wallpaper_scene_free`.
/// Not thread-safe: use one handle from one thread at a time (the view's main
/// thread).
#[derive(Debug)]
pub struct CmuxWallpaperScene {
    player: Player,
}

fn scene_from(manifest_json: &[u8], scene: &[u8]) -> Result<CmuxWallpaperScene, String> {
    let manifest = Manifest::parse(manifest_json).map_err(|e| pointed(&e.pointer, &e.message))?;
    if manifest.scene.is_none() && manifest.lottie.is_none() {
        return Err("the wallpaper names no scene or lottie file".to_string());
    }
    let scene = cmux_wallpaper::scene::load(&manifest, scene)
        .map_err(|e| pointed(&e.pointer, &format!("scene: {}", e.message)))?;
    Ok(CmuxWallpaperScene { player: Player::new(scene) })
}

fn pointed(pointer: &str, message: &str) -> String {
    if pointer.is_empty() { message.to_string() } else { format!("{pointer}: {message}") }
}

fn set_error(error: *mut *mut c_char, text: &str) {
    if !error.is_null() {
        // SAFETY: `error` is non-null and writable per the callers' contracts.
        unsafe { error.write(owned(text)) };
    }
}

/// A scene player for a wallpaper's `wallpaper.json` (which names `scene` or
/// `lottie`) and that file's bytes. Null when either is refused; then, when
/// `error` is not null, `*error` is the reason (a JSON pointer, a colon and
/// the message), freed with `cmux_wallpaper_string_free`. On success `*error`
/// is set to null. Free the handle with `cmux_wallpaper_scene_free`.
///
/// # Safety
/// `manifest_json` and `scene` are null or point to their lengths' readable
/// bytes; `error` is null or points to a writable `char *`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_scene_new(
    manifest_json: *const u8,
    manifest_len: usize,
    scene: *const u8,
    scene_len: usize,
    error: *mut *mut c_char,
) -> *mut CmuxWallpaperScene {
    // SAFETY: per this function's contract.
    let (manifest_json, scene) =
        unsafe { (bytes(manifest_json, manifest_len), bytes(scene, scene_len)) };
    if !error.is_null() {
        // SAFETY: `error` is non-null and writable per this function's contract.
        unsafe { error.write(std::ptr::null_mut()) };
    }
    match catch_unwind(AssertUnwindSafe(|| scene_from(manifest_json, scene))) {
        Ok(Ok(s)) => Box::into_raw(Box::new(s)),
        Ok(Err(why)) => {
            set_error(error, &why);
            std::ptr::null_mut()
        }
        Err(_) => {
            set_error(error, "the scene check failed");
            std::ptr::null_mut()
        }
    }
}

/// A scene player for first-party wallpaper `index` (`cmux_wallpaper_first_party_*`
/// order) from the scene bytes embedded in the library. Null when that
/// wallpaper is not a scene or the index is past the count. Free it with
/// `cmux_wallpaper_scene_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_wallpaper_scene_new_first_party(index: usize) -> *mut CmuxWallpaperScene {
    let Some(w) = cmux_wallpaper::first_party_at(index) else { return std::ptr::null_mut() };
    let Some(scene) = w.scene_json else { return std::ptr::null_mut() };
    match catch_unwind(AssertUnwindSafe(|| {
        scene_from(w.manifest_json.as_bytes(), scene.as_bytes())
    })) {
        Ok(Ok(s)) => Box::into_raw(Box::new(s)),
        _ => std::ptr::null_mut(),
    }
}

/// Frees a scene player. Null is a no-op.
///
/// # Safety
/// `scene` is null or a handle `cmux_wallpaper_scene_new*` returned, not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_scene_free(scene: *mut CmuxWallpaperScene) {
    if !scene.is_null() {
        // SAFETY: `scene` came from Box::into_raw in cmux_wallpaper_scene_new* and is freed once.
        drop(unsafe { Box::from_raw(scene) });
    }
}

/// Frees a string this library returned through an out-parameter
/// (`cmux_wallpaper_scene_new`'s `error`). Null is a no-op.
///
/// # Safety
/// `text` is null or such a string, not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_string_free(text: *mut c_char) {
    release(text);
}

/// The floats in the Scene block (`cmux_wallpaper_scene_evaluate` writes this
/// many: 512, 2048 bytes, fragment buffer 1). Size the buffer from this.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_wallpaper_scene_floats() -> u32 {
    u32::try_from(SCENE_FLOATS).unwrap_or(0)
}

/// Steps the scene's physics to `now` (the host's monotonic clock in
/// seconds, `CACurrentMediaTime`, the pointer's clock: a double, so the fixed
/// step stays exact after hours), with the pointer and button in `input`,
/// and writes the Scene block for `input` (its keyframes at `input->time`)
/// to `out`. Call it once per drawn frame, with the same `input` as
/// `cmux_wallpaper_frame_pack`; while the view holds at rest, call it on each
/// press, release and pointer move (no draw): a press on a draggable body
/// wakes the physics, and the button's edges are seen only through these
/// calls. Then ask `cmux_wallpaper_scene_at_rest` and the scheduler again.
/// False, and nothing written, when a pointer is null or `out_len` is below
/// `cmux_wallpaper_scene_floats()`.
///
/// # Safety
/// `scene` is null or a live handle not used on another thread meanwhile;
/// `input` is null or points to a valid `CmuxWallpaperFrameInput`; `out` is
/// null or points to `out_len` writable floats.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_scene_evaluate(
    scene: *mut CmuxWallpaperScene,
    input: *const CmuxWallpaperFrameInput,
    now: f64,
    out: *mut f32,
    out_len: usize,
) -> bool {
    if scene.is_null() || input.is_null() || out.is_null() || out_len < SCENE_FLOATS {
        return false;
    }
    // SAFETY: non-null and valid per this function's contract; no other reference to them lives.
    let (scene, input) = unsafe { (&mut *scene, FrameInput::from(&*input)) };
    let mut block = [0.0_f32; SCENE_FLOATS];
    let ok = catch_unwind(AssertUnwindSafe(|| scene.player.evaluate_at(&input, now, &mut block)))
        .is_ok();
    if ok {
        // SAFETY: `out` has room for `out_len` >= SCENE_FLOATS floats per this function's contract.
        unsafe { std::ptr::copy_nonoverlapping(block.as_ptr(), out, SCENE_FLOATS) };
    }
    ok
}

/// True when nothing on screen changes without input: no keyframes, and the
/// physics, if any, asleep. The scheduler's `at_rest`. True for null.
///
/// # Safety
/// `scene` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_scene_at_rest(scene: *const CmuxWallpaperScene) -> bool {
    if scene.is_null() {
        return true;
    }
    // SAFETY: non-null and live per this function's contract.
    unsafe { &*scene }.player.at_rest()
}

/// True when the scene shows the image slot (`badge`: the person's avatar and
/// name): bind that image at fragment texture 0. False for null.
///
/// # Safety
/// `scene` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_scene_has_image(scene: *const CmuxWallpaperScene) -> bool {
    if scene.is_null() {
        return false;
    }
    // SAFETY: non-null and live per this function's contract.
    unsafe { &*scene }.player.scene().image().is_some()
}

/// The scene engine program in Metal Shading Language 2.1, translated when the
/// library was built: one program draws every scene. `vertex vs_main`,
/// `fragment fs_main`, the Frame uniform at buffer 0 in both, the Scene block
/// at fragment buffer 1, the image at fragment texture 0 and its sampler at
/// fragment sampler 0. Static UTF-8 bytes (not NUL-terminated, never freed),
/// their count in `*len`; null and 0 when this library carries no engine.
///
/// # Safety
/// `len` is null or points to a writable `size_t`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_scene_engine_msl(len: *mut usize) -> *const u8 {
    static_text(Some(cmux_wallpaper::first_party::SCENE_ENGINE_MSL), len)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    fn text(p: *const c_char) -> Option<String> {
        // SAFETY: test pointers come from `owned` and are still alive.
        (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
    }

    fn static_bytes(
        f: unsafe extern "C" fn(usize, *mut usize) -> *const u8,
        i: usize,
    ) -> Option<String> {
        let mut len = 99;
        // SAFETY: `len` is writable.
        let p = unsafe { f(i, &mut len) };
        if p.is_null() {
            assert_eq!(len, 0);
            return None;
        }
        // SAFETY: the library returned `len` bytes at `p`.
        Some(String::from_utf8(unsafe { std::slice::from_raw_parts(p, len) }.to_vec()).unwrap())
    }

    #[test]
    fn abi_version_is_four() {
        assert_eq!(cmux_wallpaper_abi_version(), 4);
    }

    const SCENE_MANIFEST: &str = r#"{"id": "scene-test", "name": "Scene test",
        "description": "A test scene.", "scene": "scene.json", "fps": 30, "scale": 1,
        "interactive": true, "params": [], "still": {"time": 0, "pointer": [0.5, 0.5]},
        "variants": [{"name": "Plain"}]}"#;

    /// Makes a scene from `manifest` and `scene`, or the error text.
    fn new_scene(manifest: &str, scene: &str) -> Result<*mut CmuxWallpaperScene, String> {
        let mut error: *mut c_char = std::ptr::dangling_mut();
        // SAFETY: valid bytes; `error` is writable.
        let s = unsafe {
            cmux_wallpaper_scene_new(
                manifest.as_ptr(),
                manifest.len(),
                scene.as_ptr(),
                scene.len(),
                &mut error,
            )
        };
        if s.is_null() {
            let why = text(error).expect("an error with a null scene");
            // SAFETY: `error` came from this library and is freed once.
            unsafe { cmux_wallpaper_string_free(error) };
            Err(why)
        } else {
            assert!(error.is_null());
            Ok(s)
        }
    }

    #[test]
    fn a_scene_packs_its_block_and_rests() {
        assert_eq!(cmux_wallpaper_scene_floats(), 512);
        let still = r##"{"field": {"points": [
            {"at": [0, 0], "color": "#FF0000"}, {"at": [1, 0], "color": "paper"},
            {"at": [1, 1], "color": "accent"}, {"at": [0, 1], "color": "ink"}]},
            "shapes": [{"kind": "circle", "size": [0.4, 0.4]}],
            "image": {"slot": "badge"}}"##;
        let moving = r#"{"shapes": [{"kind": "ring",
            "at": {"keys": [[0, [0.2, 0.5]], [2, [0.8, 0.5]]]}, "size": [0.3, 0.3]}]}"#;
        let input = CmuxWallpaperFrameInput {
            time: 1.0,
            width: 800.0,
            height: 400.0,
            backing_scale: 2.0,
            presence: 1.0,
            ..Default::default()
        };
        let s = new_scene(SCENE_MANIFEST, still).unwrap();
        let m = new_scene(SCENE_MANIFEST, moving).unwrap();
        // SAFETY: live handles; `out` has 512 floats; null is allowed.
        unsafe {
            let mut out = [7.0_f32; 512];
            assert!(cmux_wallpaper_scene_evaluate(s, &input, 1.0, out.as_mut_ptr(), out.len()));
            // Header: one shape, no guides, no ropes.
            assert_eq!(&out[0..4], &[1.0, 0.0, 0.0, 0.0]);
            // Grain row: image shown.
            assert_eq!(out[7], 1.0);
            // Shape 0 (row 12): a circle at the center, in rendered pixels.
            assert_eq!(&out[48..51], &[1.0, 400.0, 200.0]);
            assert!(cmux_wallpaper_scene_at_rest(s));
            assert!(cmux_wallpaper_scene_has_image(s));

            assert!(cmux_wallpaper_scene_evaluate(m, &input, 1.0, out.as_mut_ptr(), out.len()));
            assert_eq!(out[48], 8.0);
            assert!(!cmux_wallpaper_scene_at_rest(m));
            assert!(!cmux_wallpaper_scene_has_image(m));

            // Too short a buffer or a null: false, nothing written.
            let mut short = [7.0_f32; 511];
            assert!(!cmux_wallpaper_scene_evaluate(
                s,
                &input,
                1.0,
                short.as_mut_ptr(),
                short.len()
            ));
            assert!(short.iter().all(|x| *x == 7.0));
            assert!(!cmux_wallpaper_scene_evaluate(
                std::ptr::null_mut(),
                &input,
                1.0,
                out.as_mut_ptr(),
                512
            ));
            assert!(!cmux_wallpaper_scene_evaluate(
                s,
                std::ptr::null(),
                1.0,
                out.as_mut_ptr(),
                512
            ));
            assert!(!cmux_wallpaper_scene_evaluate(s, &input, 1.0, std::ptr::null_mut(), 512));
            assert!(cmux_wallpaper_scene_at_rest(std::ptr::null()));
            assert!(!cmux_wallpaper_scene_has_image(std::ptr::null()));

            cmux_wallpaper_scene_free(s);
            cmux_wallpaper_scene_free(m);
            cmux_wallpaper_scene_free(std::ptr::null_mut());
            cmux_wallpaper_string_free(std::ptr::null_mut());
        }
    }

    /// The hold end to end: a hanging card settles and the scene is at rest
    /// (the scheduler holds it, reason 13); a pointer move alone keeps it at
    /// rest; a press on the card wakes it, and the scheduler runs it.
    #[test]
    fn a_press_on_the_card_wakes_a_resting_scene() {
        let lanyard = r#"{
            "physics": {
                "bodies": [{"id": "card", "at": [0.5, 0.6], "size": [0.2, 0.28], "draggable": true, "damping": 0.6}],
                "ropes": [{"id": "strap", "anchor": [0.5, -0.02], "to": "card", "toAt": [0, -0.5],
                           "length": 0.45, "segments": 6, "width": 0.012, "color": "accent"}]
            },
            "shapes": [{"kind": "roundRect", "size": [0.2, 0.28], "body": "card"}],
            "image": {"slot": "badge", "body": "card", "inset": 0.02}
        }"#;
        let s = new_scene(SCENE_MANIFEST, lanyard).unwrap();
        let mut input = CmuxWallpaperFrameInput {
            width: 800.0,
            height: 400.0,
            backing_scale: 1.0,
            pointer_x: 10.0,
            pointer_y: 390.0,
            ..Default::default()
        };
        let mut out = [0.0_f32; 512];
        let mut schedule = CmuxWallpaperScheduleInput {
            seconds_since_activity: 0.0,
            seconds_since_pointer: 0.0,
            seconds_since_agent_event: f64::INFINITY,
            settings_fps_cap: 30,
            manifest_fps: 30,
            gpu_strikes: 0,
            scale: 1.0,
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
            interactive: true,
            agents: false,
            has_frame: true,
            at_rest: false,
        };
        // SAFETY: a live handle; `out` has 512 floats; `schedule` is valid.
        unsafe {
            let mut now = 1000.0_f64;
            let mut frames = 0;
            while !cmux_wallpaper_scene_at_rest(s) {
                assert!(frames < 60 * 60, "the card never settled");
                now += 1.0 / 60.0;
                frames += 1;
                assert!(cmux_wallpaper_scene_evaluate(s, &input, now, out.as_mut_ptr(), out.len()));
            }
            schedule.at_rest = cmux_wallpaper_scene_at_rest(s);
            assert_eq!(cmux_wallpaper_schedule(&schedule).hold_reason, 13);
            // The card's center, from the image row (126).
            let (cx, cy) = (out[126 * 4], out[126 * 4 + 1]);
            assert!(cx > 0.0 && cy > 0.0, "no card pose: {cx} {cy}");

            // A move over the card, no button: still at rest.
            (input.pointer_x, input.pointer_y) = (cx, cy);
            now += 1.0 / 60.0;
            assert!(cmux_wallpaper_scene_evaluate(s, &input, now, out.as_mut_ptr(), out.len()));
            assert!(cmux_wallpaper_scene_at_rest(s));

            // A press away from the card: still at rest.
            (input.pointer_x, input.pointer_y, input.button_down) = (10.0, 390.0, true);
            assert!(cmux_wallpaper_scene_evaluate(s, &input, now, out.as_mut_ptr(), out.len()));
            assert!(cmux_wallpaper_scene_at_rest(s));
            input.button_down = false;
            assert!(cmux_wallpaper_scene_evaluate(s, &input, now, out.as_mut_ptr(), out.len()));

            // A press on the card wakes it, and the scheduler runs.
            (input.pointer_x, input.pointer_y, input.button_down) = (cx, cy, true);
            assert!(cmux_wallpaper_scene_evaluate(s, &input, now, out.as_mut_ptr(), out.len()));
            assert!(!cmux_wallpaper_scene_at_rest(s));
            schedule.at_rest = cmux_wallpaper_scene_at_rest(s);
            assert!(cmux_wallpaper_schedule(&schedule).run);
            cmux_wallpaper_scene_free(s);
        }
    }

    #[test]
    fn a_refused_scene_says_where() {
        // A program wallpaper is not a scene.
        let smoke = cmux_wallpaper::smoke().unwrap().manifest_json;
        assert!(new_scene(smoke, "{}").unwrap_err().contains("no scene"));
        // A bad manifest names its pointer.
        assert!(new_scene(r#"{"id": "Bad"}"#, "{}").unwrap_err().starts_with("/id: "));
        // A bad scene names its pointer.
        let why = new_scene(SCENE_MANIFEST, r#"{"shapes": [{"kind": "star", "size": [1, 1]}]}"#)
            .unwrap_err();
        assert!(why.starts_with("/shapes/0/kind: scene: "), "{why}");
        assert!(new_scene(SCENE_MANIFEST, "not json").is_err());
        // A null error pointer is allowed.
        // SAFETY: valid bytes; a null `error` is allowed.
        let s = unsafe {
            cmux_wallpaper_scene_new(
                SCENE_MANIFEST.as_ptr(),
                SCENE_MANIFEST.len(),
                b"{".as_ptr(),
                1,
                std::ptr::null_mut(),
            )
        };
        assert!(s.is_null());
    }

    #[test]
    fn first_party_scenes_load_and_programs_are_not_scenes() {
        let mut engine_len = 99;
        // SAFETY: `engine_len` is writable.
        let engine = unsafe { cmux_wallpaper_scene_engine_msl(&mut engine_len) };
        assert!(!engine.is_null() && engine_len > 0);
        // SAFETY: the library returned `engine_len` bytes at `engine`.
        let msl =
            std::str::from_utf8(unsafe { std::slice::from_raw_parts(engine, engine_len) }).unwrap();
        // The engine's entry points and the Frame uniform at buffer 0, as every program's.
        assert!(
            msl.contains("vs_main") && msl.contains("fs_main") && msl.contains("[[buffer(0)]]")
        );
        // The host binds the Scene block at fragment buffer 1, the image at texture 0, its sampler at 0.
        assert!(msl.contains("[[buffer(1)]]"), "the Scene block is not at buffer 1");
        assert!(msl.contains("[[texture(0)]]"), "the image is not at texture 0");
        assert!(msl.contains("[[sampler(0)]]"), "the sampler is not at sampler 0");
        for (i, w) in cmux_wallpaper::first_party().iter().enumerate() {
            let m = Manifest::parse(w.manifest_json.as_bytes()).unwrap();
            let s = cmux_wallpaper_scene_new_first_party(i);
            if m.scene.is_some() || m.lottie.is_some() {
                assert!(!s.is_null(), "{} does not load", w.folder);
                // Its program is the engine's.
                assert_eq!(static_bytes(cmux_wallpaper_first_party_msl, i).as_deref(), Some(msl));
            } else {
                assert!(s.is_null(), "{} is a program, not a scene", w.folder);
            }
            // SAFETY: null or a live handle, freed once.
            unsafe { cmux_wallpaper_scene_free(s) };
        }
        assert!(cmux_wallpaper_scene_new_first_party(usize::MAX).is_null());
    }

    #[test]
    fn manifest_round_trips() {
        let smoke = cmux_wallpaper::smoke().unwrap().manifest_json;
        // SAFETY: valid bytes; the result is freed once.
        unsafe {
            let r = cmux_wallpaper_validate_manifest(smoke.as_ptr(), smoke.len());
            assert!((*r).ok);
            let json: serde_json::Value = serde_json::from_str(&text((*r).json).unwrap()).unwrap();
            assert_eq!(json["id"], "smoke");
            assert_eq!(json["variants"][0]["themes"], serde_json::json!(["dark", "light"]));
            cmux_wallpaper_manifest_result_free(r);

            let bad = br#"{"id": "Bad"}"#;
            let r = cmux_wallpaper_validate_manifest(bad.as_ptr(), bad.len());
            assert!(!(*r).ok);
            assert_eq!(text((*r).pointer).as_deref(), Some("/id"));
            assert!((*r).json.is_null());
            cmux_wallpaper_manifest_result_free(r);
            cmux_wallpaper_manifest_result_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn first_party_lists_every_shipped_wallpaper() {
        let n = cmux_wallpaper_first_party_count();
        for i in 0..n {
            let json = static_bytes(cmux_wallpaper_first_party_manifest_json, i).unwrap();
            assert!(!json.contains("\"smoke\""));
            assert!(static_bytes(cmux_wallpaper_first_party_source, i).is_some());
            let msl = static_bytes(cmux_wallpaper_first_party_msl, i).unwrap();
            assert!(
                msl.contains("vs_main") && msl.contains("fs_main") && msl.contains("[[buffer(0)]]")
            );
        }
        assert_eq!(static_bytes(cmux_wallpaper_first_party_manifest_json, n), None);
        assert_eq!(static_bytes(cmux_wallpaper_first_party_msl, n), None);
    }

    #[test]
    fn schedule_round_trips() {
        let mut input = CmuxWallpaperScheduleInput {
            seconds_since_activity: 0.0,
            seconds_since_pointer: f64::INFINITY,
            seconds_since_agent_event: f64::INFINITY,
            settings_fps_cap: 30,
            manifest_fps: 60,
            gpu_strikes: 0,
            scale: 0.5,
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
            interactive: true,
            agents: false,
            has_frame: true,
            at_rest: false,
        };
        // SAFETY: `input` is valid.
        let d = unsafe { cmux_wallpaper_schedule(&input) };
        assert!(d.run);
        assert_eq!((d.fps, d.scale, d.hold_reason), (30, 0.5, 0));
        input.low_power = true;
        input.has_frame = false;
        // SAFETY: `input` is valid.
        let d = unsafe { cmux_wallpaper_schedule(&input) };
        assert_eq!((d.run, d.hold_reason, d.draw_one), (false, 7, true));
        input.low_power = false;
        input.at_rest = true;
        // SAFETY: `input` is valid.
        let d = unsafe { cmux_wallpaper_schedule(&input) };
        assert_eq!((d.run, d.hold_reason, d.draw_one), (false, 13, true));
        input.at_rest = false;
        input.gpu_strikes = cmux_wallpaper_gpu_strikes(
            cmux_wallpaper_gpu_strikes(cmux_wallpaper_gpu_strikes(0, 5.0), 5.0),
            5.0,
        );
        input.scale = 0.25;
        // SAFETY: `input` is valid.
        let d = unsafe { cmux_wallpaper_schedule(&input) };
        assert_eq!((d.run, d.hold_reason), (false, 11));
        // SAFETY: null is allowed.
        assert_eq!(unsafe { cmux_wallpaper_schedule(std::ptr::null()) }.hold_reason, 1);
    }

    #[test]
    fn frame_and_pointer_round_trip() {
        let mut p = CmuxWallpaperPointer::default();
        // SAFETY: `p` is valid and writable; `out` has 40 floats.
        unsafe {
            cmux_wallpaper_pointer_reset(&mut p);
            cmux_wallpaper_pointer_update(&mut p, 10.0, 20.0, 1.0);
            cmux_wallpaper_pointer_update(&mut p, 20.0, 20.0, 1.0 + 1.0 / 60.0);
            cmux_wallpaper_pointer_advance(&mut p, 1.0 + 1.0 / 60.0);
            assert!(p.vx > 0.0 && p.inside && p.presence > 0.0);
            assert!(!cmux_wallpaper_pointer_settled(&p));
            assert!((cmux_wallpaper_pointer_since_moved(&p, 2.0 + 1.0 / 60.0) - 1.0).abs() < 1e-4);
            cmux_wallpaper_pointer_leave(&mut p);
            assert!(!p.inside);

            let input = CmuxWallpaperFrameInput {
                time: 3.0,
                pointer_x: p.x,
                presence: p.presence,
                accent: [0.1, 0.2, 0.3],
                params: [1.0, 2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                dark: true,
                ..Default::default()
            };
            let mut out = [7.0f32; 40];
            assert!(cmux_wallpaper_frame_pack(&input, out.as_mut_ptr()));
            assert_eq!(out[0], 3.0);
            assert_eq!(out[8], 20.0);
            assert_eq!(out[15], 1.0);
            assert_eq!(&out[24..28], &[0.1, 0.2, 0.3, 1.0]);
            assert_eq!(&out[28..30], &[1.0, 2.0]);
            assert!(!cmux_wallpaper_frame_pack(std::ptr::null(), out.as_mut_ptr()));
            assert!(!cmux_wallpaper_frame_pack(&input, std::ptr::null_mut()));
        }
        assert!((cmux_wallpaper_srgb_to_linear(1.0) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn activity_round_trips_into_the_frame_and_the_schedule() {
        let mut a = CmuxWallpaperActivity::default();
        // SAFETY: `a` is valid and writable; `out` has 40 floats; null is allowed.
        unsafe {
            cmux_wallpaper_activity_reset(&mut a);
            assert!(cmux_wallpaper_activity_settled(&a, 0.0));
            cmux_wallpaper_activity_event(&mut a, 5.0);
            cmux_wallpaper_activity_event(&mut a, 5.1);
            cmux_wallpaper_activity_advance(&mut a, 5.5);
            assert_eq!(a.count, 1);
            assert!(a.level > 0.0);
            assert!(!cmux_wallpaper_activity_settled(&a, 6.0));
            let since = cmux_wallpaper_activity_since_event(&a, 6.0);
            assert!((since - 1.0).abs() < 1e-6);
            assert_eq!(cmux_wallpaper_activity_since_event(std::ptr::null(), 6.0), 1.0e4);

            let input = CmuxWallpaperFrameInput {
                activity: a.level,
                since_agent_event: since,
                agent_events: f32::from(a.count),
                ..Default::default()
            };
            let mut out = [7.0f32; 40];
            assert!(cmux_wallpaper_frame_pack(&input, out.as_mut_ptr()));
            assert_eq!(&out[36..40], &[a.level, 1.0, 1.0, 0.0]);

            let mut s = CmuxWallpaperScheduleInput {
                seconds_since_activity: 100.0,
                seconds_since_pointer: f64::INFINITY,
                seconds_since_agent_event: f64::from(since),
                settings_fps_cap: 30,
                manifest_fps: 30,
                gpu_strikes: 0,
                scale: 1.0,
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
                interactive: true,
                agents: true,
                has_frame: true,
                at_rest: false,
            };
            assert!(cmux_wallpaper_schedule(&s).run);
            s.agents = false;
            assert_eq!(cmux_wallpaper_schedule(&s).hold_reason, 12);
        }
    }
}
