//! The C ABI of predictive local echo for the macOS app
//! (`include/cmux_terminal_prediction.h`, Swift module
//! `CCmuxTerminalPredictionFFI`), linked into the app through cmux-app-ffi.
//!
//! One handle per terminal. Its calls may come from different threads (input
//! on Ghostty's IO thread, output on the output lane, frames and the overlay on
//! the main thread): the engine sits behind a mutex, held only for the call.
//! Times are microseconds of one monotonic clock the app picks. Every event
//! answers whether the overlay must be drawn again. None unwinds across the
//! boundary.

use crate::config::PredictionConfiguration;
use crate::engine::TerminalPredictionEngine;
use crate::layout::PredictionOverlayLayout;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::time::Duration;

/// Bumped on any change to a type or a function.
pub const CMUX_TERMINAL_PREDICTION_ABI_VERSION: u32 = 1;

/// One terminal's prediction.
pub struct CmuxTerminalPrediction {
    engine: Mutex<TerminalPredictionEngine>,
    /// Enabled and remote: read before the lock, so a terminal that never
    /// predicts costs one relaxed load per output chunk.
    active: AtomicBool,
}

/// One cell to draw. `standing`: 0 speculative (underlined), 1 confirmed (plain,
/// held until its frame), 2 erased (the cell's background only).
#[repr(C)]
pub struct CmuxPredictedGlyph {
    pub character: u8,
    pub standing: u8,
    /// Cells right of the live cursor; negative for a held confirmation.
    pub offset: i32,
}

/// The run on the cursor row: `cell_count` cells from `leading_offset` (cells
/// from the cursor), the caret at `caret_offset` when `has_caret`, and the
/// first `glyph_count` glyphs written to the caller's array.
#[repr(C)]
pub struct CmuxPredictionLayout {
    pub leading_offset: i32,
    pub cell_count: i32,
    pub caret_offset: i32,
    pub has_caret: bool,
    pub glyph_count: usize,
}

impl CmuxTerminalPrediction {
    fn engine(&self) -> MutexGuard<'_, TerminalPredictionEngine> {
        self.engine.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

fn instant(now_us: u64) -> Duration {
    Duration::from_micros(now_us)
}

/// Runs `body` on the handle, or answers `fallback` for a null handle or a panic.
fn with<T>(
    prediction: *const CmuxTerminalPrediction,
    fallback: T,
    body: impl FnOnce(&CmuxTerminalPrediction) -> T,
) -> T {
    if prediction.is_null() {
        return fallback;
    }
    // SAFETY: a non-null handle came from `cmux_terminal_prediction_new` and is
    // not yet freed (the caller's contract).
    let prediction = unsafe { &*prediction };
    catch_unwind(AssertUnwindSafe(|| body(prediction))).unwrap_or(fallback)
}

/// The bytes at `bytes` (`len` of them), or an empty slice for null.
///
/// # Safety
/// `bytes` is null or points to `len` readable bytes for the call.
unsafe fn slice<'a>(bytes: *const u8, len: usize) -> &'a [u8] {
    if bytes.is_null() || len == 0 {
        return &[];
    }
    // SAFETY: the caller's contract.
    unsafe { std::slice::from_raw_parts(bytes, len) }
}

/// `CMUX_TERMINAL_PREDICTION_ABI_VERSION`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_terminal_prediction_abi_version() -> u32 {
    CMUX_TERMINAL_PREDICTION_ABI_VERSION
}

/// A new terminal's prediction: predicts only while `enabled` (the setting)
/// and `remote` (the terminal's shell runs on another machine). Free it with
/// `cmux_terminal_prediction_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_terminal_prediction_new(
    enabled: bool,
    remote: bool,
) -> *mut CmuxTerminalPrediction {
    catch_unwind(|| {
        Box::into_raw(Box::new(CmuxTerminalPrediction {
            engine: Mutex::new(TerminalPredictionEngine::new(
                PredictionConfiguration::default(),
                enabled,
                remote,
            )),
            active: AtomicBool::new(enabled && remote),
        }))
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Frees a handle (null is ignored).
///
/// # Safety
/// `prediction` came from `cmux_terminal_prediction_new`, is freed once, and no
/// other call on it runs or follows.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_free(prediction: *mut CmuxTerminalPrediction) {
    if !prediction.is_null() {
        // SAFETY: the pointer came from Box::into_raw and is freed once.
        drop(unsafe { Box::from_raw(prediction) });
    }
}

/// Sets whether the setting is on and whether the shell runs on another
/// machine. A change starts over from a fresh engine (nothing drawn, no echo
/// run). Answers whether anything drawn went.
///
/// # Safety
/// `prediction` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_set(
    prediction: *const CmuxTerminalPrediction,
    enabled: bool,
    remote: bool,
) -> bool {
    with(prediction, false, |prediction| {
        let mut engine = prediction.engine();
        if engine.is_enabled == enabled && engine.is_remote_surface == remote {
            return false;
        }
        let drew = !engine.glyphs().is_empty();
        *engine = TerminalPredictionEngine::new(engine.configuration, enabled, remote);
        prediction.active.store(enabled && remote, Ordering::Relaxed);
        drew
    })
}

/// Whether the terminal predicts at all (enabled and remote).
///
/// # Safety
/// `prediction` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_active(
    prediction: *const CmuxTerminalPrediction,
) -> bool {
    with(prediction, false, |prediction| prediction.active.load(Ordering::Relaxed))
}

/// Seeds whether a full-screen program already owns the screen, read from the
/// terminal before the first keystroke.
///
/// # Safety
/// `prediction` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_seed_alternate_screen(
    prediction: *const CmuxTerminalPrediction,
    active: bool,
) {
    with(prediction, (), |prediction| prediction.engine().seed_alternate_screen(active));
}

/// One write of encoded input about to go to the remote (one key press, a
/// paste, a mouse report): `len` bytes at `bytes`.
///
/// # Safety
/// `prediction` is null or a live handle; `bytes` is null or `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_sent(
    prediction: *const CmuxTerminalPrediction,
    bytes: *const u8,
    len: usize,
    now_us: u64,
) -> bool {
    // SAFETY: the caller's contract.
    let bytes = unsafe { slice(bytes, len) };
    with(prediction, false, |prediction| {
        prediction.active.load(Ordering::Relaxed)
            && prediction.engine().sent(bytes, instant(now_us))
    })
}

/// Output from the remote, just before the terminal parses it.
///
/// # Safety
/// `prediction` is null or a live handle; `bytes` is null or `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_output(
    prediction: *const CmuxTerminalPrediction,
    bytes: *const u8,
    len: usize,
    now_us: u64,
) -> bool {
    // SAFETY: the caller's contract.
    let bytes = unsafe { slice(bytes, len) };
    with(prediction, false, |prediction| {
        prediction.active.load(Ordering::Relaxed)
            && prediction.engine().observed_output(bytes, instant(now_us))
    })
}

/// Output was lost or replaced before the terminal parsed it (a snapshot
/// restore, a reconnect): everything starts over.
///
/// # Safety
/// `prediction` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_missed_output(
    prediction: *const CmuxTerminalPrediction,
    now_us: u64,
) -> bool {
    with(prediction, false, |prediction| prediction.engine().missed_output(instant(now_us)))
}

/// The grid or the font changed under the glyphs with no output lost (a
/// resize): what is drawn goes, and what the engine knows of the screen stays.
///
/// # Safety
/// `prediction` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_layout_changed(
    prediction: *const CmuxTerminalPrediction,
    now_us: u64,
) -> bool {
    with(prediction, false, |prediction| prediction.engine().layout_changed(instant(now_us)))
}

/// A rendered frame reached the screen: held confirmations retire.
///
/// # Safety
/// `prediction` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_presented_frame(
    prediction: *const CmuxTerminalPrediction,
    now_us: u64,
) -> bool {
    with(prediction, false, |prediction| {
        prediction.active.load(Ordering::Relaxed)
            && prediction.engine().presented_frame(instant(now_us))
    })
}

/// Time passed with no other event: withdraws what aged out.
///
/// # Safety
/// `prediction` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_tick(
    prediction: *const CmuxTerminalPrediction,
    now_us: u64,
) -> bool {
    with(prediction, false, |prediction| prediction.engine().tick(instant(now_us)))
}

/// When the next change to what is drawn falls due (written to `out_us`), or
/// false when nothing is drawn: the app's one timer for a terminal gone quiet.
///
/// # Safety
/// `prediction` is null or a live handle; `out_us` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_next_expiry(
    prediction: *const CmuxTerminalPrediction,
    out_us: *mut u64,
) -> bool {
    let Some(at) = with(prediction, None, |prediction| prediction.engine().next_expiry()) else {
        return false;
    };
    if !out_us.is_null() {
        // SAFETY: the caller's contract.
        unsafe { *out_us = u64::try_from(at.as_micros()).unwrap_or(u64::MAX) };
    }
    true
}

/// Whether the overlay stays where it is until the next presented frame
/// (output took blanks away that the frame on screen still shows).
///
/// # Safety
/// `prediction` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_holds_layout(
    prediction: *const CmuxTerminalPrediction,
) -> bool {
    with(prediction, false, |prediction| prediction.engine().holds_layout_until_frame())
}

/// Why it is or is not drawing: 0 disabled, 1 local surface, 2 listening, 3 link
/// fast enough, 4 alternate screen, 5 suspended, 6 predicting.
///
/// # Safety
/// `prediction` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_status(
    prediction: *const CmuxTerminalPrediction,
    now_us: u64,
) -> u8 {
    with(prediction, 0, |prediction| prediction.engine().status(instant(now_us)) as u8)
}

/// The smoothed round trip from keystroke to echo (written to `out_us`), or
/// false before the first echo.
///
/// # Safety
/// `prediction` is null or a live handle; `out_us` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_echo_latency(
    prediction: *const CmuxTerminalPrediction,
    out_us: *mut u64,
) -> bool {
    let Some(latency) =
        with(prediction, None, |prediction| prediction.engine().observed_echo_latency())
    else {
        return false;
    };
    if !out_us.is_null() {
        // SAFETY: the caller's contract.
        unsafe { *out_us = u64::try_from(latency.as_micros()).unwrap_or(u64::MAX) };
    }
    true
}

/// What to draw now, on a row of `columns` cells with the live cursor at
/// `cursor_column`: withdraws what aged out first, writes the run to
/// `out_layout` and up to `capacity` glyphs to `out_glyphs`. False when nothing
/// is drawn (the overlay hides).
///
/// # Safety
/// `prediction` is null or a live handle; `out_layout` is null or writable;
/// `out_glyphs` is null or `capacity` writable glyphs.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_layout(
    prediction: *const CmuxTerminalPrediction,
    now_us: u64,
    cursor_column: i32,
    columns: i32,
    out_layout: *mut CmuxPredictionLayout,
    out_glyphs: *mut CmuxPredictedGlyph,
    capacity: usize,
) -> bool {
    let layout = with(prediction, None, |prediction| {
        let mut engine = prediction.engine();
        engine.tick(instant(now_us));
        PredictionOverlayLayout::new(&engine.glyphs(), cursor_column, columns)
    });
    let Some(layout) = layout else { return false };
    if out_layout.is_null() {
        return true;
    }
    let count = if out_glyphs.is_null() { 0 } else { layout.glyphs.len().min(capacity) };
    for (index, glyph) in layout.glyphs.iter().take(count).enumerate() {
        // SAFETY: `index < capacity`, the caller's array length.
        unsafe {
            out_glyphs.add(index).write(CmuxPredictedGlyph {
                character: glyph.character,
                standing: glyph.standing as u8,
                offset: glyph.offset,
            });
        }
    }
    // SAFETY: the caller's contract.
    unsafe {
        out_layout.write(CmuxPredictionLayout {
            leading_offset: layout.leading_offset,
            cell_count: layout.cell_count,
            caret_offset: layout.caret_offset.unwrap_or(0),
            has_caret: layout.caret_offset.is_some(),
            glyph_count: count,
        });
    }
    true
}
