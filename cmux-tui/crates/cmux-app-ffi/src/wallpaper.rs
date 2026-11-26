//! The C ABI of cmux-wallpaper for the macOS app (`include/cmux_wallpaper_ffi.h`):
//! live wallpapers (plans/cmux-next/live-wallpapers.md). The first-party set
//! with its Metal translated at build time (the library links no shader
//! compiler), the manifest check, the
//! draw scheduler, the `Frame` uniform packer, the pointer's smoothing and
//! its trail.
//! The app's `BackdropLiveView` keeps only the Metal layer, the display link
//! and the events; every rule and every number lives once, in cmux-wallpaper.
//!
//! No function panics across the boundary: the ones that allocate run under
//! `catch_unwind`, and the rest are panic-free arithmetic. A null pointer is
//! answered with a defined value, never read.

use cmux_wallpaper::frame::{ActivityState, FrameInput, PointerState};
use cmux_wallpaper::schedule::{Decision, ScheduleInput};
use cmux_wallpaper::{Manifest, TrailPoint, TrailState};
use std::ffi::{CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type or function in the header.
const ABI_VERSION: u32 = 5;

/// Floats in the Frame uniform (`cmux_wallpaper_frame_pack` writes this
/// many; 4 bytes each). Size the uniform buffer from this, never a literal.
pub const CMUX_WALLPAPER_FRAME_FLOATS: usize = 108;
/// Points in a `CmuxWallpaperTrail`, and rows in `Frame.trail`.
pub const CMUX_WALLPAPER_TRAIL_POINTS: usize = 16;
/// Floats `cmux_wallpaper_trail_rows` writes: 4 per point (x, y, age, valid).
pub const CMUX_WALLPAPER_TRAIL_FLOATS: usize = 64;

// The header's numbers are cmux-wallpaper's: a mismatch does not compile.
const _: () = assert!(CMUX_WALLPAPER_FRAME_FLOATS == cmux_wallpaper::FRAME_FLOATS);
const _: () = assert!(CMUX_WALLPAPER_TRAIL_POINTS == cmux_wallpaper::TRAIL_POINTS);
const _: () = assert!(CMUX_WALLPAPER_TRAIL_FLOATS == CMUX_WALLPAPER_TRAIL_POINTS * 4);

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
    /// The manifest's `idle_after` in seconds; 0 means the default (20).
    pub idle_after_s: f64,
}

/// The scheduler's answer. `run` false: hold (stop the display link, no
/// timer), for `hold_reason`: 1 occluded, 2 covered, 3 minimized, 4 app
/// hidden, 5 screens asleep, 6 session inactive, 7 Low Power Mode, 8 thermal,
/// 9 Reduce Motion, 10 animations off, 11 too heavy (mark it in the picker),
/// 12 idle; with `draw_one`, draw one frame at `scale` first (the view has
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
/// writes the `CMUX_WALLPAPER_FRAME_FLOATS` floats of the Frame uniform. Colors are linear
/// RGB (`cmux_wallpaper_srgb_to_linear`). NaN or infinite values become 0.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
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
    /// The tritone grade over the program's colors, 0 (off) ..1 (`appearance.liveWallpaperGrade`):
    /// lightness mapped from the darker of paper and ink, through accent, to the lighter.
    pub grade: f32,
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
    /// The pointer's trail, `CMUX_WALLPAPER_TRAIL_POINTS` rows of (x, y, age,
    /// valid), newest first: `cmux_wallpaper_trail_rows` fills it. Zeros: no trail.
    pub trail: [f32; CMUX_WALLPAPER_TRAIL_FLOATS],
}

impl Default for CmuxWallpaperFrameInput {
    fn default() -> Self {
        Self {
            time: 0.0,
            delta: 0.0,
            frame_number: 0.0,
            width: 0.0,
            height: 0.0,
            backing_scale: 0.0,
            seed: 0.0,
            pointer_x: 0.0,
            pointer_y: 0.0,
            velocity_x: 0.0,
            velocity_y: 0.0,
            presence: 0.0,
            since_moved: 0.0,
            activity: 0.0,
            since_agent_event: 0.0,
            agent_events: 0.0,
            grade: 0.0,
            ink: [0.0; 3],
            paper: [0.0; 3],
            accent: [0.0; 3],
            params: [0.0; 8],
            still: false,
            button_down: false,
            dark: false,
            trail: [0.0; CMUX_WALLPAPER_TRAIL_FLOATS],
        }
    }
}

/// The pointer's recent path (`TrailState`): a ring of points, newest first,
/// `len` of them set. Zero it (or call `cmux_wallpaper_trail_reset`) once;
/// then `update` on each pointer move, with the same position and time as
/// `cmux_wallpaper_pointer_update`, and `rows` once per drawn frame into
/// `CmuxWallpaperFrameInput.trail`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxWallpaperTrail {
    /// Seconds, the host's monotonic clock.
    pub t: [f64; CMUX_WALLPAPER_TRAIL_POINTS],
    pub x: [f32; CMUX_WALLPAPER_TRAIL_POINTS],
    pub y: [f32; CMUX_WALLPAPER_TRAIL_POINTS],
    /// Points set, 0..=`CMUX_WALLPAPER_TRAIL_POINTS`.
    pub len: u32,
}

impl From<&CmuxWallpaperTrail> for TrailState {
    fn from(c: &CmuxWallpaperTrail) -> Self {
        let mut s = Self {
            len: usize::try_from(c.len).unwrap_or(usize::MAX).min(CMUX_WALLPAPER_TRAIL_POINTS),
            ..Self::default()
        };
        for (i, p) in s.points.iter_mut().enumerate() {
            let (Some(&t), Some(&x), Some(&y)) = (c.t.get(i), c.x.get(i), c.y.get(i)) else {
                continue;
            };
            *p = TrailPoint { x, y, t };
        }
        s
    }
}

impl From<&TrailState> for CmuxWallpaperTrail {
    fn from(s: &TrailState) -> Self {
        Self {
            t: s.points.map(|p| p.t),
            x: s.points.map(|p| p.x),
            y: s.points.map(|p| p.y),
            len: u32::try_from(s.len.min(CMUX_WALLPAPER_TRAIL_POINTS)).unwrap_or(0),
        }
    }
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
            grade: i.grade,
            button_down: i.button_down,
            dark: i.dark,
            ink: i.ink,
            paper: i.paper,
            accent: i.accent,
            params: i.params,
            trail: std::array::from_fn(|r| {
                let at = |c: usize| i.trail.get(r * 4 + c).copied().unwrap_or(0.0);
                [at(0), at(1), at(2), at(3)]
            }),
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
            idle_after_s: i.idle_after_s,
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
/// `fragment fs_main`, the Frame uniform (`CMUX_WALLPAPER_FRAME_FLOATS`
/// floats) at buffer index 0 in both.
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
/// many, `CMUX_WALLPAPER_FRAME_FLOATS`): the host sizes its buffer from this,
/// never from a number of its own, so a Frame that grows cannot overrun it.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_wallpaper_frame_floats() -> usize {
    CMUX_WALLPAPER_FRAME_FLOATS
}

/// Writes the `CMUX_WALLPAPER_FRAME_FLOATS` floats (4 bytes each) of the
/// Frame uniform for `input` to `out`. False, and nothing written, when
/// either is null.
///
/// # Safety
/// `input` is null or points to a valid `CmuxWallpaperFrameInput`; `out` is
/// null or points to `CMUX_WALLPAPER_FRAME_FLOATS` writable floats.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_frame_pack(
    input: *const CmuxWallpaperFrameInput,
    out: *mut f32,
) -> bool {
    if input.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: non-null and valid per this function's contract.
    let floats: [f32; CMUX_WALLPAPER_FRAME_FLOATS] =
        cmux_wallpaper::pack_frame(&FrameInput::from(unsafe { &*input }));
    // SAFETY: `out` has room for CMUX_WALLPAPER_FRAME_FLOATS floats per this function's contract.
    unsafe { std::ptr::copy_nonoverlapping(floats.as_ptr(), out, CMUX_WALLPAPER_FRAME_FLOATS) };
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
    if state.is_null() {
        return;
    }
    // A write, never a read: the storage may be uninitialized (this call stands in for zeroing
    // the struct), and reading it first would read uninitialized `bool`s.
    // SAFETY: `state` is non-null and points to writable `CmuxWallpaperPointer` storage (contract above).
    unsafe { state.write(PointerState::default().into()) };
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

/// Sets `state` to its start (no points).
///
/// # Safety
/// `state` is null or points to a writable `CmuxWallpaperTrail`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_trail_reset(state: *mut CmuxWallpaperTrail) {
    if state.is_null() {
        return;
    }
    // SAFETY: non-null and writable per this function's contract.
    unsafe { state.write(CmuxWallpaperTrail::default()) };
}

/// A pointer move to (`x`, `y`) at time `t` seconds (the values given to
/// `cmux_wallpaper_pointer_update`): the head follows the pointer, and a move
/// 50 ms or more after the newest committed point commits a new one. NaN or
/// infinite values are ignored.
///
/// # Safety
/// `state` is null or points to a valid, writable `CmuxWallpaperTrail`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_trail_update(
    state: *mut CmuxWallpaperTrail,
    x: f32,
    y: f32,
    t: f64,
) {
    if state.is_null() {
        return;
    }
    // SAFETY: non-null, valid and writable per this function's contract.
    let s = unsafe { &mut *state };
    let mut trail = TrailState::from(&*s);
    trail.moved(x, y, t);
    *s = CmuxWallpaperTrail::from(&trail);
}

/// Writes `Frame.trail` at time `now` to `out`: `CMUX_WALLPAPER_TRAIL_POINTS`
/// rows of (x, y, age seconds, valid 0/1), newest first, x and y times
/// `scale` (the update's units to the Frame's rendered pixels; 1 when they
/// already are). A point older than 1 s or not set is all zeros. False, and
/// nothing written, when either pointer is null.
///
/// # Safety
/// `state` is null or points to a valid `CmuxWallpaperTrail`; `out` is null or
/// points to `CMUX_WALLPAPER_TRAIL_FLOATS` writable floats
/// (`CmuxWallpaperFrameInput.trail`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_trail_rows(
    state: *const CmuxWallpaperTrail,
    now: f64,
    scale: f32,
    out: *mut f32,
) -> bool {
    if state.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: non-null and valid per this function's contract.
    let rows = TrailState::from(unsafe { &*state }).rows(now, scale);
    let mut flat = [0.0f32; CMUX_WALLPAPER_TRAIL_FLOATS];
    for (slot, v) in flat.iter_mut().zip(rows.iter().flatten()) {
        *slot = *v;
    }
    // SAFETY: `out` has room for CMUX_WALLPAPER_TRAIL_FLOATS floats per this function's contract.
    unsafe { std::ptr::copy_nonoverlapping(flat.as_ptr(), out, CMUX_WALLPAPER_TRAIL_FLOATS) };
    true
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

#[cfg(test)]
mod tests;
