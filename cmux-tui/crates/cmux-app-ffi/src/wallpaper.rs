//! The C ABI of cmux-wallpaper for the macOS app (`include/cmux_wallpaper_ffi.h`):
//! live wallpapers (plans/cmux-next/live-wallpapers.md). The first-party set,
//! the program check and its translation to Metal, the manifest check, the
//! draw scheduler, the `Frame` uniform packer and the pointer's smoothing.
//! The app's `BackdropLiveView` keeps only the Metal layer, the display link
//! and the events; every rule and every number lives once, in cmux-wallpaper.
//!
//! No function panics across the boundary: the ones that allocate run under
//! `catch_unwind`, and the rest are panic-free arithmetic. A null pointer is
//! answered with a defined value, never read.

use cmux_wallpaper::frame::{FrameInput, PointerState};
use cmux_wallpaper::schedule::{Decision, ScheduleInput};
use cmux_wallpaper::{FRAME_FLOATS, Manifest, ProgramErrorKind};
use std::ffi::{CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type or function in the header.
const ABI_VERSION: u32 = 1;

/// The result of `cmux_wallpaper_compile`; free it with
/// `cmux_wallpaper_compiled_free`. Strings are UTF-8, NUL-terminated, owned
/// by the result, and null when absent.
///
/// `error_kind`: 0 none, 1 too large, 2 parse, 3 binding, 4 entry point,
/// 5 var<workgroup>, 6 var<private>, 7 texture, 8 sampler, 9 storage,
/// 10 other global, 11 override, 12 reserved name, 13 no `fn wallpaper`,
/// 14 wrong `wallpaper` signature, 15 validation, 16 translation, 17 internal.
/// `error_line`/`error_column` are 1-based in the program's source, 0 when
/// the error has no place there.
#[repr(C)]
#[derive(Debug)]
pub struct CmuxWallpaperCompiled {
    pub ok: bool,
    /// Metal Shading Language 2.1: `vertex vs_main`, `fragment fs_main`,
    /// the Frame uniform at buffer index 0 in both.
    pub msl: *mut c_char,
    /// GLSL ES 3.00 fragment shader (`fs_main` as `main`).
    pub glsl: *mut c_char,
    /// `line:column: message`, or the message alone.
    pub error: *mut c_char,
    pub error_kind: u32,
    pub error_line: u32,
    pub error_column: u32,
}

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
    /// The view has drawn at least one frame.
    pub has_frame: bool,
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
/// writes the 36 floats of the 144-byte Frame uniform. Colors are linear
/// RGB (`cmux_wallpaper_srgb_to_linear`). NaN or infinite values become 0.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxWallpaperFrameInput {
    /// Seconds since shown (continues across holds).
    pub time: f32,
    /// Seconds since the last frame.
    pub delta: f32,
    pub frame_number: f32,
    /// Backdrop size in backing pixels.
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
            interactive: i.interactive,
            settings_fps_cap: i.settings_fps_cap,
            manifest_fps: i.manifest_fps,
            gpu_strikes: i.gpu_strikes,
            scale: i.scale,
            has_frame: i.has_frame,
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

fn kind_code(kind: ProgramErrorKind) -> u32 {
    match kind {
        ProgramErrorKind::TooLarge => 1,
        ProgramErrorKind::Parse => 2,
        ProgramErrorKind::Binding => 3,
        ProgramErrorKind::EntryPoint => 4,
        ProgramErrorKind::Workgroup => 5,
        ProgramErrorKind::Private => 6,
        ProgramErrorKind::Texture => 7,
        ProgramErrorKind::Sampler => 8,
        ProgramErrorKind::Storage => 9,
        ProgramErrorKind::OtherGlobal => 10,
        ProgramErrorKind::Override => 11,
        ProgramErrorKind::ReservedName => 12,
        ProgramErrorKind::MissingWallpaper => 13,
        ProgramErrorKind::WallpaperSignature => 14,
        ProgramErrorKind::Validation => 15,
        ProgramErrorKind::Translation => 16,
        ProgramErrorKind::Internal => 17,
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

/// First-party wallpaper `index`'s program (`wallpaper.wgsl`), for
/// `cmux_wallpaper_compile`: static UTF-8 bytes as above.
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

fn compiled(source: &[u8]) -> CmuxWallpaperCompiled {
    match cmux_wallpaper::compile_bytes(source) {
        Ok(c) => CmuxWallpaperCompiled {
            ok: true,
            msl: owned(&c.msl),
            glsl: owned(&c.glsl),
            error: std::ptr::null_mut(),
            error_kind: 0,
            error_line: 0,
            error_column: 0,
        },
        Err(e) => {
            let (line, column) = e.location.unwrap_or((0, 0));
            CmuxWallpaperCompiled {
                ok: false,
                msl: std::ptr::null_mut(),
                glsl: std::ptr::null_mut(),
                error: owned(&e.to_string()),
                error_kind: kind_code(e.kind),
                error_line: line,
                error_column: column,
            }
        }
    }
}

/// Checks a wallpaper program (`len` bytes of UTF-8 WGSL, at most 64 KiB)
/// against the sandbox and translates it. Never null; free the result with
/// `cmux_wallpaper_compiled_free`. The app never loads a program whose
/// result is not `ok`.
///
/// # Safety
/// `source` is null or points to `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_compile(
    source: *const u8,
    len: usize,
) -> *mut CmuxWallpaperCompiled {
    // SAFETY: per this function's contract.
    let source = unsafe { bytes(source, len) };
    let result = catch_unwind(AssertUnwindSafe(|| compiled(source))).unwrap_or_else(|_| {
        CmuxWallpaperCompiled {
            ok: false,
            msl: std::ptr::null_mut(),
            glsl: std::ptr::null_mut(),
            error: owned("the WGSL translator failed on this program"),
            error_kind: kind_code(ProgramErrorKind::Internal),
            error_line: 0,
            error_column: 0,
        }
    });
    Box::into_raw(Box::new(result))
}

/// Frees a `cmux_wallpaper_compile` result and its strings. Null is a no-op.
///
/// # Safety
/// `result` is null or a pointer `cmux_wallpaper_compile` returned, not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_wallpaper_compiled_free(result: *mut CmuxWallpaperCompiled) {
    if result.is_null() {
        return;
    }
    // SAFETY: `result` came from Box::into_raw in cmux_wallpaper_compile and is freed once.
    let r = unsafe { Box::from_raw(result) };
    release(r.msl);
    release(r.glsl);
    release(r.error);
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

/// Writes the 36 floats (144 bytes) of the Frame uniform for `input` to
/// `out`. False, and nothing written, when either is null.
///
/// # Safety
/// `input` is null or points to a valid `CmuxWallpaperFrameInput`; `out` is
/// null or points to 36 writable floats.
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

/// A pointer move to (`x`, `y`) backing pixels (top left origin) at time `t`
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
    fn abi_version_is_one() {
        assert_eq!(cmux_wallpaper_abi_version(), 1);
    }

    #[test]
    fn compile_round_trips_the_smoke_sample_and_a_refusal() {
        let smoke = cmux_wallpaper::smoke().unwrap().source;
        // SAFETY: valid bytes; the result is freed once.
        unsafe {
            let r = cmux_wallpaper_compile(smoke.as_ptr(), smoke.len());
            assert!((*r).ok);
            assert!(text((*r).msl).unwrap().contains("fs_main"));
            assert!(text((*r).glsl).unwrap().starts_with("#version 300 es"));
            assert!((*r).error.is_null());
            cmux_wallpaper_compiled_free(r);

            let bad = "var<private> n: f32;\nfn wallpaper(px: vec2<f32>) -> vec4<f32> { return frame.paper; }";
            let r = cmux_wallpaper_compile(bad.as_ptr(), bad.len());
            assert!(!(*r).ok);
            assert!((*r).msl.is_null());
            assert_eq!((*r).error_kind, 6);
            assert_eq!((*r).error_line, 1);
            assert!(text((*r).error).unwrap().contains("var<private>"));
            cmux_wallpaper_compiled_free(r);

            let r = cmux_wallpaper_compile(std::ptr::null(), 0);
            assert!(!(*r).ok);
            assert_eq!((*r).error_kind, 13);
            cmux_wallpaper_compiled_free(r);
            cmux_wallpaper_compiled_free(std::ptr::null_mut());
        }
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
        }
        assert_eq!(static_bytes(cmux_wallpaper_first_party_manifest_json, n), None);
    }

    #[test]
    fn schedule_round_trips() {
        let mut input = CmuxWallpaperScheduleInput {
            seconds_since_activity: 0.0,
            seconds_since_pointer: f64::INFINITY,
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
            has_frame: true,
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
        // SAFETY: `p` is valid and writable; `out` has 36 floats.
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
            let mut out = [7.0f32; 36];
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
}
