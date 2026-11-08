//! The C ABI of predictive local echo for the macOS app
//! (`include/cmux_terminal_prediction.h`, Swift module
//! `CCmuxTerminalPredictionFFI`), linked into the app through cmux-app-ffi.
//!
//! One handle per terminal surface. The host calls, with its own monotonic
//! clock in nanoseconds (`now_ns`, any fixed origin):
//!
//! - per keystroke: `cmux_terminal_prediction_on_input` with the bytes it is
//!   about to write to the PTY (one printable ASCII byte predicts, DEL or BS
//!   retracts, anything else withdraws), `..._on_line_erase` for Ctrl-U,
//!   Ctrl-W and Option-Backspace, `..._on_nothing_sent` for a key a local
//!   binding consumed, `..._on_untracked_input` for a paste or automation;
//! - per PTY output chunk: `..._on_output`, stamped when the chunk arrived,
//!   and `..._on_missed_output` when the host dropped output;
//! - per presented frame: `..._on_frame`; at `..._next_expiry_ns` when no
//!   event comes: `..._tick`;
//! - to draw: `..._layout` (or `..._glyphs`), offsets in cells from the live
//!   cursor, drawn in an overlay above the grid, never into it.
//!
//! Every function that changes state returns whether the overlay has to be
//! redrawn. A handle is not thread-safe: the host calls it from one thread
//! (the app's main thread, draining PTY output it buffered on the reader
//! thread). None unwinds across the boundary.

use crate::{PredictedGlyph, PredictionConfiguration, PredictionOverlayLayout, Standing, Status, TerminalPredictionEngine};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::time::Duration;

/// Bumped on any change to a type, a constant or a function in the header.
pub const CMUX_TERMINAL_PREDICTION_ABI_VERSION: u32 = 1;

/// `CmuxTerminalPredictionGlyph.standing`: sent, no echo yet (draw underlined).
pub const CMUX_TERMINAL_PREDICTION_STANDING_SPECULATIVE: u8 = 0;
/// Echoed; drawn until the frame carrying the real character is presented.
pub const CMUX_TERMINAL_PREDICTION_STANDING_CONFIRMED: u8 = 1;
/// Deleted before the remote erased it: paint the cell's background only.
pub const CMUX_TERMINAL_PREDICTION_STANDING_ERASED: u8 = 2;

/// `cmux_terminal_prediction_status`.
pub const CMUX_TERMINAL_PREDICTION_STATUS_DISABLED: i32 = 0;
pub const CMUX_TERMINAL_PREDICTION_STATUS_LOCAL_SURFACE: i32 = 1;
pub const CMUX_TERMINAL_PREDICTION_STATUS_LISTENING: i32 = 2;
pub const CMUX_TERMINAL_PREDICTION_STATUS_LINK_IS_FAST_ENOUGH: i32 = 3;
pub const CMUX_TERMINAL_PREDICTION_STATUS_ALTERNATE_SCREEN: i32 = 4;
pub const CMUX_TERMINAL_PREDICTION_STATUS_SUSPENDED: i32 = 5;
pub const CMUX_TERMINAL_PREDICTION_STATUS_PREDICTING: i32 = 6;
/// A null handle.
pub const CMUX_TERMINAL_PREDICTION_STATUS_INVALID: i32 = -1;

/// The tunables (`cmux_terminal_prediction_config_default` fills the defaults).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CmuxTerminalPredictionConfig {
    /// Below this measured echo latency nothing is predicted (25 ms).
    pub engage_above_echo_latency_ns: u64,
    /// A glyph the remote never echoes is withdrawn after this (1.5 s), or
    /// after three measured round trips when that is longer.
    pub speculative_lifetime_ns: u64,
    /// A confirmed glyph's hold when no frame is reported (120 ms).
    pub confirmation_hold_ns: u64,
    /// Visible withdrawals within `misprediction_window_ns` that suspend (4).
    pub mispredictions_before_suspending: u32,
    pub misprediction_window_ns: u64,
    /// How long a suspension lasts (30 s).
    pub suspension_ns: u64,
    /// Keystrokes in flight past which prediction withdraws (40).
    pub maximum_speculative_glyphs: u32,
}

impl From<PredictionConfiguration> for CmuxTerminalPredictionConfig {
    fn from(c: PredictionConfiguration) -> Self {
        let ns = |d: Duration| u64::try_from(d.as_nanos()).unwrap_or(u64::MAX);
        Self {
            engage_above_echo_latency_ns: ns(c.engage_above_echo_latency),
            speculative_lifetime_ns: ns(c.speculative_lifetime),
            confirmation_hold_ns: ns(c.confirmation_hold),
            mispredictions_before_suspending: u32::try_from(c.mispredictions_before_suspending).unwrap_or(u32::MAX),
            misprediction_window_ns: ns(c.misprediction_window),
            suspension_ns: ns(c.suspension),
            maximum_speculative_glyphs: u32::try_from(c.maximum_speculative_glyphs).unwrap_or(u32::MAX),
        }
    }
}

impl From<CmuxTerminalPredictionConfig> for PredictionConfiguration {
    fn from(c: CmuxTerminalPredictionConfig) -> Self {
        Self {
            engage_above_echo_latency: Duration::from_nanos(c.engage_above_echo_latency_ns),
            speculative_lifetime: Duration::from_nanos(c.speculative_lifetime_ns),
            confirmation_hold: Duration::from_nanos(c.confirmation_hold_ns),
            mispredictions_before_suspending: c.mispredictions_before_suspending as usize,
            misprediction_window: Duration::from_nanos(c.misprediction_window_ns),
            suspension: Duration::from_nanos(c.suspension_ns),
            maximum_speculative_glyphs: c.maximum_speculative_glyphs as usize,
        }
    }
}

/// One glyph to draw.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CmuxTerminalPredictionGlyph {
    /// Cells right of the live cursor on its row (negative: a held echo).
    pub offset: i32,
    /// The Unicode scalar to draw (printable ASCII, or a space when erased).
    pub codepoint: u32,
    /// `CMUX_TERMINAL_PREDICTION_STANDING_*`.
    pub standing: u8,
}

impl From<PredictedGlyph> for CmuxTerminalPredictionGlyph {
    fn from(g: PredictedGlyph) -> Self {
        Self {
            offset: g.offset,
            codepoint: u32::from(g.character),
            standing: match g.standing {
                Standing::Speculative => CMUX_TERMINAL_PREDICTION_STANDING_SPECULATIVE,
                Standing::Confirmed => CMUX_TERMINAL_PREDICTION_STANDING_CONFIRMED,
                Standing::Erased => CMUX_TERMINAL_PREDICTION_STANDING_ERASED,
            },
        }
    }
}

/// The overlay's span on the cursor row (`cmux_terminal_prediction_layout`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CmuxTerminalPredictionLayout {
    /// Offset from the cursor of the overlay's first cell.
    pub leading_offset: i32,
    /// Cells from `leading_offset` through the last glyph or the caret.
    pub cell_count: i32,
    /// Whether to draw a caret where typing continues, at `caret_offset`.
    pub has_caret: bool,
    pub caret_offset: i32,
    /// Glyphs on the row; the first `min(glyph_count, capacity)` were written.
    pub glyph_count: usize,
}

/// A surface's prediction engine.
pub struct CmuxTerminalPrediction {
    engine: TerminalPredictionEngine,
    /// Reused for every snapshot, so drawing allocates nothing once warm.
    scratch: Vec<PredictedGlyph>,
}

fn guarded<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(fallback)
}

/// Runs `body` on the handle's state; `fallback` for a null handle or a panic.
///
/// # Safety
///
/// `handle` is null or from `cmux_terminal_prediction_new`, not yet freed,
/// and no other call on it runs at the same time.
unsafe fn with_handle<T>(
    handle: *mut CmuxTerminalPrediction,
    fallback: T,
    body: impl FnOnce(&mut CmuxTerminalPrediction) -> T,
) -> T {
    // SAFETY: the caller's contract above.
    let Some(state) = (unsafe { handle.as_mut() }) else { return fallback };
    catch_unwind(AssertUnwindSafe(|| body(state))).unwrap_or(fallback)
}

fn instant(now_ns: u64) -> Duration {
    Duration::from_nanos(now_ns)
}

/// `CMUX_TERMINAL_PREDICTION_ABI_VERSION`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_terminal_prediction_abi_version() -> u32 {
    CMUX_TERMINAL_PREDICTION_ABI_VERSION
}

/// Writes the default configuration to `out` (ignored when null).
///
/// # Safety
///
/// `out` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_config_default(out: *mut CmuxTerminalPredictionConfig) {
    // SAFETY: the caller's contract above.
    if let Some(out) = unsafe { out.as_mut() } {
        *out = PredictionConfiguration::DEFAULT.into();
    }
}

/// A new engine. `config` null means the defaults. `enabled` is the user
/// setting; `remote` whether the surface's shell runs on another machine (a
/// local surface never predicts). Free with `cmux_terminal_prediction_free`.
///
/// # Safety
///
/// `config` is null or readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_new(
    config: *const CmuxTerminalPredictionConfig,
    enabled: bool,
    remote: bool,
) -> *mut CmuxTerminalPrediction {
    // SAFETY: the caller's contract above.
    let configuration = unsafe { config.as_ref() }.map_or(PredictionConfiguration::DEFAULT, |c| (*c).into());
    guarded(std::ptr::null_mut(), || {
        Box::into_raw(Box::new(CmuxTerminalPrediction {
            engine: TerminalPredictionEngine::new(configuration, enabled, remote),
            scratch: Vec::new(),
        }))
    })
}

/// Frees an engine (null is ignored).
///
/// # Safety
///
/// `handle` is null or from `cmux_terminal_prediction_new` and not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_free(handle: *mut CmuxTerminalPrediction) {
    if !handle.is_null() {
        // SAFETY: the caller's contract above.
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// Applies the user setting. Turning it off drops everything tracked, so
/// nothing stays drawn and no stale echo run survives. Returns whether the
/// overlay has to be redrawn.
///
/// # Safety
///
/// As for every handle function: `handle` is null or live, one call at a time.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_set_enabled(handle: *mut CmuxTerminalPrediction, enabled: bool) -> bool {
    // SAFETY: the caller's contract above.
    unsafe {
        with_handle(handle, false, |s| {
            if enabled == s.engine.is_enabled {
                return false;
            }
            let had_glyphs = !s.engine.glyphs().is_empty();
            if enabled {
                s.engine.is_enabled = true;
            } else {
                s.engine = TerminalPredictionEngine::new(s.engine.configuration, false, s.engine.is_remote_surface);
            }
            had_glyphs
        })
    }
}

/// Classifies the surface: whether its shell runs on another machine. A
/// change starts over from a fresh engine. Returns whether to redraw.
///
/// # Safety
///
/// As for every handle function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_set_remote(handle: *mut CmuxTerminalPrediction, remote: bool) -> bool {
    // SAFETY: the caller's contract above.
    unsafe {
        with_handle(handle, false, |s| {
            if remote == s.engine.is_remote_surface {
                return false;
            }
            let had_glyphs = !s.engine.glyphs().is_empty();
            s.engine = TerminalPredictionEngine::new(s.engine.configuration, s.engine.is_enabled, remote);
            had_glyphs
        })
    }
}

/// Whether a full-screen application already owns the screen, read from the
/// terminal before the first keystroke. Ignored once output switched modes.
///
/// # Safety
///
/// As for every handle function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_seed_alternate_screen(handle: *mut CmuxTerminalPrediction, active: bool) {
    // SAFETY: the caller's contract above.
    unsafe { with_handle(handle, (), |s| s.engine.seed_alternate_screen(active)) }
}

/// Starts over, keeping the configuration, the setting and the
/// classification: for a resize or anything else that moves the grid under
/// the overlay. Returns whether to redraw.
///
/// # Safety
///
/// As for every handle function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_reset(handle: *mut CmuxTerminalPrediction) -> bool {
    // SAFETY: the caller's contract above.
    unsafe {
        with_handle(handle, false, |s| {
            let had_glyphs = !s.engine.glyphs().is_empty();
            let e = &s.engine;
            s.engine = TerminalPredictionEngine::new(e.configuration, e.is_enabled, e.is_remote_surface);
            had_glyphs
        })
    }
}

/// A keystroke: the bytes about to be written to the PTY. One printable
/// ASCII byte predicts it; DEL or BS alone is Backspace; anything else
/// (Return, arrows, chords, non-ASCII text) withdraws. Returns whether to
/// redraw.
///
/// # Safety
///
/// As for every handle function; `bytes` with `len` is readable (or `len` is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_on_input(
    handle: *mut CmuxTerminalPrediction,
    bytes: *const u8,
    len: usize,
    now_ns: u64,
) -> bool {
    // SAFETY: the caller's contract above.
    let input = unsafe { slice(bytes, len) };
    // SAFETY: the caller's contract above.
    unsafe { with_handle(handle, false, |s| s.engine.typed(input, instant(now_ns))) }
}

/// Ctrl-U, Ctrl-W or Option-Backspace: deletes more than one character.
///
/// # Safety
///
/// As for every handle function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_on_line_erase(handle: *mut CmuxTerminalPrediction, now_ns: u64) -> bool {
    // SAFETY: the caller's contract above.
    unsafe { with_handle(handle, false, |s| s.engine.typed_line_erase(instant(now_ns))) }
}

/// A key a local binding consumed without writing to the PTY.
///
/// # Safety
///
/// As for every handle function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_on_nothing_sent(handle: *mut CmuxTerminalPrediction, now_ns: u64) -> bool {
    // SAFETY: the caller's contract above.
    unsafe { with_handle(handle, false, |s| s.engine.typed_nothing(instant(now_ns))) }
}

/// Input that reached the PTY without a keystroke: a paste, dropped text,
/// automation or a paired device.
///
/// # Safety
///
/// As for every handle function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_on_untracked_input(handle: *mut CmuxTerminalPrediction, now_ns: u64) -> bool {
    // SAFETY: the caller's contract above.
    unsafe { with_handle(handle, false, |s| s.engine.sent_untracked_input(instant(now_ns))) }
}

/// A chunk of PTY output, `now_ns` when it arrived (not when it is drained).
/// Returns whether to re-anchor the overlay; when
/// `cmux_terminal_prediction_holds_layout_until_frame` is then true, keep it
/// where it is until the next presented frame.
///
/// # Safety
///
/// As for every handle function; `bytes` with `len` is readable (or `len` is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_on_output(
    handle: *mut CmuxTerminalPrediction,
    bytes: *const u8,
    len: usize,
    now_ns: u64,
) -> bool {
    // SAFETY: the caller's contract above.
    let output = unsafe { slice(bytes, len) };
    // SAFETY: the caller's contract above.
    unsafe { with_handle(handle, false, |s| s.engine.observed_output(output, instant(now_ns))) }
}

/// The host dropped output before this point (its buffer overflowed).
///
/// # Safety
///
/// As for every handle function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_on_missed_output(handle: *mut CmuxTerminalPrediction, now_ns: u64) -> bool {
    // SAFETY: the caller's contract above.
    unsafe { with_handle(handle, false, |s| s.engine.missed_output(instant(now_ns))) }
}

/// A rendered frame reached the screen: held confirmations retire.
///
/// # Safety
///
/// As for every handle function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_on_frame(handle: *mut CmuxTerminalPrediction, now_ns: u64) -> bool {
    // SAFETY: the caller's contract above.
    unsafe { with_handle(handle, false, |s| s.engine.presented_frame(instant(now_ns))) }
}

/// Time passed with no other event: withdraws what aged out.
///
/// # Safety
///
/// As for every handle function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_tick(handle: *mut CmuxTerminalPrediction, now_ns: u64) -> bool {
    // SAFETY: the caller's contract above.
    unsafe { with_handle(handle, false, |s| s.engine.tick(instant(now_ns))) }
}

/// `CMUX_TERMINAL_PREDICTION_STATUS_*` at `now_ns`.
///
/// # Safety
///
/// As for every handle function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_status(handle: *mut CmuxTerminalPrediction, now_ns: u64) -> i32 {
    // SAFETY: the caller's contract above.
    unsafe {
        with_handle(handle, CMUX_TERMINAL_PREDICTION_STATUS_INVALID, |s| match s.engine.status(instant(now_ns)) {
            Status::Disabled => CMUX_TERMINAL_PREDICTION_STATUS_DISABLED,
            Status::LocalSurface => CMUX_TERMINAL_PREDICTION_STATUS_LOCAL_SURFACE,
            Status::Listening => CMUX_TERMINAL_PREDICTION_STATUS_LISTENING,
            Status::LinkIsFastEnough => CMUX_TERMINAL_PREDICTION_STATUS_LINK_IS_FAST_ENOUGH,
            Status::AlternateScreen => CMUX_TERMINAL_PREDICTION_STATUS_ALTERNATE_SCREEN,
            Status::Suspended => CMUX_TERMINAL_PREDICTION_STATUS_SUSPENDED,
            Status::Predicting => CMUX_TERMINAL_PREDICTION_STATUS_PREDICTING,
        })
    }
}

/// The smoothed keystroke-to-echo latency into `out`; false (and `out`
/// untouched) before the first echo.
///
/// # Safety
///
/// As for every handle function; `out` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_echo_latency_ns(handle: *mut CmuxTerminalPrediction, out: *mut u64) -> bool {
    // SAFETY: the caller's contract above.
    let latency = unsafe { with_handle(handle, None, |s| s.engine.observed_echo_latency()) };
    // SAFETY: the caller's contract above.
    unsafe { write_ns(latency, out) }
}

/// When the next change to what is drawn falls due, into `out`: the host
/// calls `cmux_terminal_prediction_tick` then, since a quiet terminal renders
/// no frames. False when nothing is drawn.
///
/// # Safety
///
/// As for every handle function; `out` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_next_expiry_ns(handle: *mut CmuxTerminalPrediction, out: *mut u64) -> bool {
    // SAFETY: the caller's contract above.
    let expiry = unsafe { with_handle(handle, None, |s| s.engine.next_expiry()) };
    // SAFETY: the caller's contract above.
    unsafe { write_ns(expiry, out) }
}

/// Output took blanks away that the frame on screen still shows: keep the
/// overlay as it is until the next presented frame.
///
/// # Safety
///
/// As for every handle function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_holds_layout_until_frame(handle: *mut CmuxTerminalPrediction) -> bool {
    // SAFETY: the caller's contract above.
    unsafe { with_handle(handle, false, |s| s.engine.holds_layout_until_frame()) }
}

/// Every glyph to draw, left to right, offsets from the live cursor. Writes
/// the first `min(total, capacity)` to `out` and returns the total, so a
/// caller with too small a buffer can retry.
///
/// # Safety
///
/// As for every handle function; `out` is writable for `capacity` glyphs (or
/// `capacity` is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_glyphs(
    handle: *mut CmuxTerminalPrediction,
    out: *mut CmuxTerminalPredictionGlyph,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's contract above.
    unsafe {
        with_handle(handle, 0, |s| {
            let mut scratch = std::mem::take(&mut s.scratch);
            s.engine.glyphs_into(&mut scratch);
            let total = scratch.len();
            write_glyphs(&scratch, out, capacity);
            s.scratch = scratch;
            total
        })
    }
}

/// Which glyphs fit on the cursor row (`cursor_column` zero-based, `columns`
/// the grid's width) and the span to cover. False when nothing is drawn
/// (`out_layout` untouched). Writes the row's glyphs as
/// `cmux_terminal_prediction_glyphs` does.
///
/// # Safety
///
/// As for every handle function; `out_layout` is null or writable; `out` is
/// writable for `capacity` glyphs (or `capacity` is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_terminal_prediction_layout(
    handle: *mut CmuxTerminalPrediction,
    cursor_column: i32,
    columns: i32,
    out_layout: *mut CmuxTerminalPredictionLayout,
    out: *mut CmuxTerminalPredictionGlyph,
    capacity: usize,
) -> bool {
    // SAFETY: the caller's contract above.
    unsafe {
        with_handle(handle, false, |s| {
            let mut scratch = std::mem::take(&mut s.scratch);
            s.engine.glyphs_into(&mut scratch);
            let layout = PredictionOverlayLayout::new(&scratch, cursor_column, columns);
            s.scratch = scratch;
            let Some(layout) = layout else { return false };
            write_glyphs(&layout.glyphs, out, capacity);
            if let Some(out_layout) = out_layout.as_mut() {
                *out_layout = CmuxTerminalPredictionLayout {
                    leading_offset: layout.leading_offset,
                    cell_count: layout.cell_count,
                    has_caret: layout.caret_offset.is_some(),
                    caret_offset: layout.caret_offset.unwrap_or(0),
                    glyph_count: layout.glyphs.len(),
                };
            }
            true
        })
    }
}

/// # Safety
///
/// `bytes` with `len` is readable, or `len` is 0.
unsafe fn slice<'a>(bytes: *const u8, len: usize) -> &'a [u8] {
    if bytes.is_null() || len == 0 {
        return &[];
    }
    // SAFETY: the caller's contract above.
    unsafe { std::slice::from_raw_parts(bytes, len) }
}

/// # Safety
///
/// `out` is null or writable.
unsafe fn write_ns(value: Option<Duration>, out: *mut u64) -> bool {
    let Some(value) = value else { return false };
    // SAFETY: the caller's contract above.
    if let Some(out) = unsafe { out.as_mut() } {
        *out = u64::try_from(value.as_nanos()).unwrap_or(u64::MAX);
    }
    true
}

/// # Safety
///
/// `out` is writable for `capacity` glyphs, or `capacity` is 0.
unsafe fn write_glyphs(glyphs: &[PredictedGlyph], out: *mut CmuxTerminalPredictionGlyph, capacity: usize) {
    if out.is_null() {
        return;
    }
    for (index, glyph) in glyphs.iter().take(capacity).enumerate() {
        // SAFETY: index < capacity, within the caller's buffer.
        unsafe { out.add(index).write((*glyph).into()) };
    }
}
