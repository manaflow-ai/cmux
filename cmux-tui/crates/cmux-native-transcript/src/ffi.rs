//! The C ABI of the native transcript scene (`include/cmux_native_transcript.h`, Swift module
//! `CCmuxNativeTranscriptFFI`), linked into the app through cmux-app-ffi.
//!
//! One scene per native transcript view, used by one thread at a time (the app's render thread). Null pointers
//! and bad sizes are no-ops (or return 0 / NULL). None unwinds across the boundary.

use crate::{Metrics, Quad, Scene};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type or a function.
pub const CMUX_NATIVE_TRANSCRIPT_ABI_VERSION: u32 = 1;

pub type CmuxNtScene = Scene;
pub type CmuxNtMetrics = Metrics;
pub type CmuxNtQuad = Quad;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CmuxNtRasterRequest {
    pub scalar: u32,
    pub font: u32,
    pub slot_x: u32,
    pub slot_y: u32,
    pub slot_w: u32,
    pub slot_h: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CmuxNtTextureRequest {
    pub texture_id: u32,
    pub row: u32,
    pub w: f32,
    pub h: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CmuxNtFrameInfo {
    pub offset: f64,
    pub content_height: f64,
    pub quads: u32,
    pub quads_needed: u32,
    pub first_row: u32,
    pub last_row: u32,
    pub late_textures: u32,
    pub flinging: bool,
    pub build_us: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CmuxNtStats {
    pub frames: u64,
    pub late_texture_frames: u64,
    pub late_textures: u64,
    pub interval_p50_ms: f64,
    pub interval_p95_ms: f64,
    pub interval_max_ms: f64,
    pub build_p50_us: f64,
    pub build_p95_us: f64,
    pub build_max_us: f64,
    pub intervals_over_8_33: u64,
}

fn guard<T>(fallback: T, f: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(fallback)
}

/// # Safety
/// `metrics` is null or points to a `CmuxNtMetrics`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_nt_scene_new_fixture(
    rows: u32,
    width: f32,
    height: f32,
    metrics: *const CmuxNtMetrics,
) -> *mut CmuxNtScene {
    if metrics.is_null() {
        return std::ptr::null_mut();
    }
    // SAFETY: non-null and points to a metrics struct (the caller's contract).
    let m = unsafe { *metrics };
    guard(std::ptr::null_mut(), || match Scene::fixture(rows, width, height, m) {
        Some(s) => Box::into_raw(Box::new(s)),
        None => std::ptr::null_mut(),
    })
}

/// # Safety
/// `scene` is null or came from `cmux_nt_scene_new_fixture` and is not used after.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_nt_scene_free(scene: *mut CmuxNtScene) {
    if !scene.is_null() {
        // SAFETY: made by Box::into_raw above, freed once (the caller's contract).
        drop(unsafe { Box::from_raw(scene) });
    }
}

/// # Safety
/// `scene` is null or a live scene used by no other thread now.
unsafe fn with<T>(scene: *mut CmuxNtScene, fallback: T, f: impl FnOnce(&mut Scene) -> T) -> T {
    // SAFETY: the caller's contract above.
    match unsafe { scene.as_mut() } {
        Some(s) => guard(fallback, || f(s)),
        None => fallback,
    }
}

/// # Safety
/// `scene` is null or a live scene used by no other thread now.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_nt_set_viewport(scene: *mut CmuxNtScene, width: f32, height: f32) {
    // SAFETY: forwarded contract.
    unsafe { with(scene, (), |s| s.set_viewport(width, height)) }
}

/// # Safety
/// `scene` is null or a live scene used by no other thread now.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_nt_scroll_to(scene: *mut CmuxNtScene, offset: f64) {
    // SAFETY: forwarded contract.
    unsafe { with(scene, (), |s| s.scroll_to(offset)) }
}

/// # Safety
/// `scene` is null or a live scene used by no other thread now.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_nt_scroll_by(scene: *mut CmuxNtScene, delta: f64) {
    // SAFETY: forwarded contract.
    unsafe { with(scene, (), |s| s.scroll_by(delta)) }
}

/// # Safety
/// `scene` is null or a live scene used by no other thread now.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_nt_fling(scene: *mut CmuxNtScene, velocity: f64, now: f64) {
    // SAFETY: forwarded contract.
    unsafe { with(scene, (), |s| s.fling(velocity, now)) }
}

/// # Safety
/// `scene` is null or a live scene used by no other thread now; `out` is null or has `cap` quads; `info` is null or
/// writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_nt_frame(
    scene: *mut CmuxNtScene,
    now: f64,
    out: *mut CmuxNtQuad,
    cap: u32,
    info: *mut CmuxNtFrameInfo,
) -> u32 {
    let buf: &mut [Quad] = if out.is_null() || cap == 0 {
        &mut []
    } else {
        // SAFETY: `out` has `cap` quads (the caller's contract).
        unsafe { std::slice::from_raw_parts_mut(out, cap as usize) }
    };
    // SAFETY: forwarded contract.
    let fi = unsafe { with(scene, None, |s| Some(s.frame(now, buf))) };
    let Some(fi) = fi else { return 0 };
    // SAFETY: null or writable (the caller's contract).
    if let Some(info) = unsafe { info.as_mut() } {
        *info = CmuxNtFrameInfo {
            offset: fi.offset,
            content_height: fi.content_height,
            quads: fi.quads,
            quads_needed: fi.quads_needed,
            first_row: fi.first_row,
            last_row: fi.last_row,
            late_textures: fi.late_textures,
            flinging: fi.flinging,
            build_us: fi.build_us,
        };
    }
    fi.quads
}

/// # Safety
/// `scene` is null or a live scene used by no other thread now; `out` is null or has `cap` requests.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_nt_take_raster_requests(
    scene: *mut CmuxNtScene,
    out: *mut CmuxNtRasterRequest,
    cap: u32,
) -> u32 {
    if out.is_null() || cap == 0 {
        return 0;
    }
    // SAFETY: forwarded contract.
    let taken = unsafe { with(scene, Vec::new(), |s| s.atlas().take(cap as usize)) };
    for (i, (key, slot)) in taken.iter().enumerate() {
        // SAFETY: i < cap (take returns at most cap) and `out` has cap entries.
        unsafe {
            *out.add(i) = CmuxNtRasterRequest {
                scalar: key.scalar,
                font: key.font,
                slot_x: slot.x,
                slot_y: slot.y,
                slot_w: slot.w,
                slot_h: slot.h,
            };
        }
    }
    taken.len() as u32
}

/// # Safety
/// `scene` is null or a live scene used by no other thread now.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_nt_glyphs_ready(scene: *mut CmuxNtScene) {
    // SAFETY: forwarded contract.
    unsafe { with(scene, (), |s| s.atlas().ready()) }
}

/// # Safety
/// `scene` is null or a live scene used by no other thread now; `out` is null or has `cap` requests.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_nt_take_texture_requests(
    scene: *mut CmuxNtScene,
    prefetch_rows: u32,
    out: *mut CmuxNtTextureRequest,
    cap: u32,
) -> u32 {
    if out.is_null() || cap == 0 {
        return 0;
    }
    // SAFETY: forwarded contract.
    let reqs = unsafe {
        with(scene, Vec::new(), |s| s.take_texture_requests(prefetch_rows, cap as usize))
    };
    for (i, (texture_id, row, w, h)) in reqs.iter().enumerate() {
        // SAFETY: i < cap and `out` has cap entries.
        unsafe {
            *out.add(i) = CmuxNtTextureRequest { texture_id: *texture_id, row: *row, w: *w, h: *h }
        };
    }
    reqs.len() as u32
}

/// # Safety
/// `scene` is null or a live scene used by no other thread now.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_nt_texture_ready(
    scene: *mut CmuxNtScene,
    texture_id: u32,
    ready: bool,
) {
    // SAFETY: forwarded contract.
    unsafe { with(scene, (), |s| s.texture_ready(texture_id, ready)) }
}

/// # Safety
/// `scene` is null or a live scene; `out` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_nt_stats(scene: *const CmuxNtScene, out: *mut CmuxNtStats) {
    // SAFETY: the caller's contract.
    let (Some(s), Some(out)) = (unsafe { scene.as_ref() }, unsafe { out.as_mut() }) else { return };
    let r = &s.record;
    let iv = r.intervals();
    let b = r.build();
    *out = CmuxNtStats {
        frames: r.frames,
        late_texture_frames: r.late_texture_frames,
        late_textures: r.late_textures,
        interval_p50_ms: iv.p50,
        interval_p95_ms: iv.p95,
        interval_max_ms: iv.max,
        build_p50_us: b.p50,
        build_p95_us: b.p95,
        build_max_us: b.max,
        intervals_over_8_33: r.intervals_missed,
    };
}

/// # Safety
/// `scene` is null or a live scene used by no other thread now.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_nt_stats_reset(scene: *mut CmuxNtScene) {
    // SAFETY: forwarded contract.
    unsafe { with(scene, (), |s| s.record = Default::default()) }
}
