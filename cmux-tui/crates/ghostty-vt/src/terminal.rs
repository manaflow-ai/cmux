use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::ffi::c_void;
use std::ptr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use base64::Engine as _;
use ghostty_vt_sys as sys;

use crate::kitty::{
    self, KITTY_INFLIGHT_REPLAY_MAX_BYTES, KittyGraphicsSnapshot, KittyImage, KittyImageAlias,
    KittyInFlightTracker, KittyPlacement, KittyPlacementAnchor, KittyReplaySnapshot,
    MAX_KITTY_IMAGE_BYTES, MAX_KITTY_IMAGES, MAX_KITTY_PLACEMENTS,
};
use crate::mouse::{MouseModeProbe, MouseModeSignature, MouseWireFormat};
use crate::render::{Cell, CellWidth, CursorShape, read_grid_ref_cell, terminal_palette};
use crate::{Error, Result, check};

mod prompt_semantic;
use prompt_semantic::*;

mod vt_boundary;
use vt_boundary::*;

mod color_override;
use color_override::*;

mod cursor_override;
use cursor_override::*;

mod palette_override;
use palette_override::*;

mod mouse_mode_change;
use mouse_mode_change::*;

mod clipboard_read;
pub use clipboard_read::{
    ClipboardLocation, ClipboardReadFn, ClipboardReadRequest, MAX_CLIPBOARD_READ_BYTES,
};

static NEXT_TERMINAL_ID: AtomicU64 = AtomicU64::new(1);
static NEXT_HISTORY_EPOCH: AtomicU64 = AtomicU64::new(1);
const VT_REPLAY_ESTIMATED_BYTES_PER_CELL: u64 = 32;
const DEFAULT_KITTY_IMAGE_STORAGE_LIMIT: u64 = MAX_KITTY_IMAGE_BYTES as u64;
const DEFAULT_KITTY_IMAGE_COUNT_LIMIT: u64 = MAX_KITTY_IMAGES;
const DEFAULT_KITTY_PLACEMENT_COUNT_LIMIT: u64 = MAX_KITTY_PLACEMENTS;
const KITTY_REPLAY_CHUNK: usize = 4096;
/// Largest unfinished escape sequence a snapshot carries as its continuation.
/// Above it the snapshot encoder refuses until the stream reaches ground, and
/// attach falls back to the byte replay. Matches the 1 MiB bound of the
/// surface-side encoder in ghostty-next.
pub const SNAPSHOT_CONTINUATION_MAX_BYTES: usize = 1 << 20;
const KITTY_REPLAY_RAW_CHUNK: usize = KITTY_REPLAY_CHUNK / 4 * 3;
const MAX_COLOR_OSC_BYTES: usize = 16 * 1024;
const MOUSE_DEC_MODES: [u16; 8] = [9, 1000, 1002, 1003, 1005, 1006, 1015, 1016];

#[cfg(test)]
thread_local! {
    static KITTY_REPLAY_IMAGE_ENCODINGS: std::cell::Cell<usize> =
        const { std::cell::Cell::new(0) };
}

#[cfg(test)]
fn reset_kitty_replay_image_encodings() {
    KITTY_REPLAY_IMAGE_ENCODINGS.set(0);
}

#[cfg(test)]
fn kitty_replay_image_encodings() -> usize {
    KITTY_REPLAY_IMAGE_ENCODINGS.get()
}

/// Per-terminal Kitty resource limits that every byte-stream emulator must
/// share to make admission and eviction deterministic.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KittyGraphicsLimits {
    pub image_bytes: u64,
    pub inflight_bytes: u64,
    pub images: u64,
    pub placements: u64,
}

impl KittyGraphicsLimits {
    pub const fn disabled() -> Self {
        Self { image_bytes: 0, inflight_bytes: 0, images: 0, placements: 0 }
    }

    pub fn validate(self) -> Result<Self> {
        if self.image_bytes > MAX_KITTY_IMAGE_BYTES as u64
            || self.inflight_bytes > KITTY_INFLIGHT_REPLAY_MAX_BYTES as u64
            || self.images > MAX_KITTY_IMAGES
            || self.placements > MAX_KITTY_PLACEMENTS
        {
            return Err(Error::InvalidValue);
        }
        Ok(self)
    }
}

impl Default for KittyGraphicsLimits {
    fn default() -> Self {
        Self {
            image_bytes: DEFAULT_KITTY_IMAGE_STORAGE_LIMIT,
            inflight_bytes: KITTY_INFLIGHT_REPLAY_MAX_BYTES as u64,
            images: DEFAULT_KITTY_IMAGE_COUNT_LIMIT,
            placements: DEFAULT_KITTY_PLACEMENT_COUNT_LIMIT,
        }
    }
}

/// Per-screen automatic Kitty image-ID cursors.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KittyImageIdCursors {
    pub primary: u32,
    pub alternate: u32,
}

impl KittyImageIdCursors {
    pub const DEFAULT_NEXT_IMAGE_ID: u32 = 2_147_483_647;

    pub const fn defaults() -> Self {
        Self { primary: Self::DEFAULT_NEXT_IMAGE_ID, alternate: Self::DEFAULT_NEXT_IMAGE_ID }
    }

    fn validate(self) -> Result<Self> {
        if self.primary == 0 || self.alternate == 0 {
            return Err(Error::InvalidValue);
        }
        Ok(self)
    }
}

impl Default for KittyImageIdCursors {
    fn default() -> Self {
        Self::defaults()
    }
}

/// Kitty state that cannot be represented by protocol escape sequences.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KittyReplayState {
    pub limits: KittyGraphicsLimits,
    /// Byte offset where replay must restore `replay_next_image_ids`.
    /// Prefix bytes may contain a synthetic terminal reset; suffix bytes can
    /// contain an in-flight upload that allocates an automatic ID.
    pub replay_cursor_offset: u32,
    /// Per-screen cursors installed at `replay_cursor_offset`. A cursor may
    /// point at an automatic ID already reserved by an in-flight multipart upload.
    pub replay_next_image_ids: KittyImageIdCursors,
    /// Per-screen steady-state cursors restored after replay bytes and aliases.
    pub next_image_ids: KittyImageIdCursors,
}

impl KittyReplayState {
    pub const fn disabled() -> Self {
        Self {
            limits: KittyGraphicsLimits::disabled(),
            replay_cursor_offset: 0,
            replay_next_image_ids: KittyImageIdCursors::defaults(),
            next_image_ids: KittyImageIdCursors::defaults(),
        }
    }

    pub fn validate(self) -> Result<Self> {
        self.limits.validate()?;
        self.replay_next_image_ids.validate()?;
        self.next_image_ids.validate()?;
        Ok(self)
    }

    pub fn validate_for_replay(self, replay_len: usize) -> Result<Self> {
        let state = self.validate()?;
        if state.replay_cursor_offset as usize > replay_len {
            return Err(Error::InvalidValue);
        }
        Ok(state)
    }
}

impl Default for KittyReplayState {
    fn default() -> Self {
        Self::disabled()
    }
}

/// Terminal state replay plus Kitty metadata that cannot share one APC command.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct VtReplay {
    /// Formatted state. Always ends at a parser boundary, so a consumer may
    /// append its own sequences (for example color overrides) after it.
    pub bytes: Vec<u8>,
    pub kitty_image_aliases: Vec<KittyImageAlias>,
    pub kitty_state: KittyReplayState,
    /// The incomplete escape sequence, control string, Kitty command, or
    /// UTF-8 code point the source parser is inside. Write it after `bytes`
    /// and after anything the consumer appends, immediately before the live
    /// stream that completes it.
    pub pending_sequence: Vec<u8>,
}

impl VtReplay {
    /// One byte stream for consumers that append nothing between the replay
    /// and the live stream.
    pub fn into_self_contained_bytes(mut self) -> Vec<u8> {
        self.bytes.append(&mut self.pending_sequence);
        self.bytes
    }

    /// Borrowing form of [`Self::into_self_contained_bytes`].
    pub fn self_contained_bytes(&self) -> Cow<'_, [u8]> {
        if self.pending_sequence.is_empty() {
            Cow::Borrowed(&self.bytes)
        } else {
            Cow::Owned([self.bytes.as_slice(), &self.pending_sequence].concat())
        }
    }
}

/// RGB color triple.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl From<sys::GhosttyColorRgb> for Rgb {
    fn from(c: sys::GhosttyColorRgb) -> Self {
        Rgb { r: c.r, g: c.g, b: c.b }
    }
}

/// Process-host render metadata. Color and palette entries are sparse
/// application-authored overrides, while version 2 cursor metadata is the
/// host-resolved visual pair.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalColorOverrides {
    pub foreground: Option<Rgb>,
    pub background: Option<Rgb>,
    pub cursor: Option<Rgb>,
    /// Host-resolved cursor shape/blink for the active screen. Version 2
    /// process-host snapshots always populate this; `None` represents a
    /// decoded legacy version 1 frame whose raw VT cursor state must be
    /// preserved (the value is unknown, not a reset request).
    pub cursor_visual: Option<(CursorShape, bool)>,
    pub palette: [Option<Rgb>; 256],
}

impl Default for TerminalColorOverrides {
    fn default() -> Self {
        Self {
            foreground: None,
            background: None,
            cursor: None,
            cursor_visual: None,
            palette: [None; 256],
        }
    }
}

/// Parse a color with Ghostty's config semantics.
///
/// This accepts Ghostty's hex, X11 name, `rgb:`, and `rgbi:` forms.
pub fn parse_color(value: &str) -> Option<Rgb> {
    let mut color = sys::GhosttyColorRgb::default();
    check(unsafe { sys::ghostty_color_parse(value.as_ptr().cast(), value.len(), &mut color) })
        .ok()?;
    Some(color.into())
}

/// Parse one Ghostty `palette = N=COLOR` value.
pub fn parse_palette_entry(value: &str) -> Option<(u8, Rgb)> {
    let mut index = 0;
    let mut color = sys::GhosttyColorRgb::default();
    check(unsafe {
        sys::ghostty_color_parse_palette_entry(
            value.as_ptr().cast(),
            value.len(),
            &mut index,
            &mut color,
        )
    })
    .ok()?;
    Some((index, color.into()))
}

/// Which screen buffer is active.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Screen {
    Primary,
    Alternate,
}

/// Immutable terminal state that can change how pointer input is encoded or
/// interpreted. Capture this under the same lock as a rendered frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalPointerSemanticSnapshot {
    pub terminal_instance_id: u64,
    pub mouse_mode_revision: u64,
    pub mouse_tracking: bool,
    /// Last-set-wins active coordinate wire format (xterm semantics), from
    /// Ghostty's own encoder behavior rather than the boolean mode flags.
    pub active_mouse_format: MouseWireFormat,
    pub active_screen: Screen,
    pub cols: u16,
    pub rows: u16,
}

/// Result of a prompt-preserving scrollback clear.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClearHistoryOutcome {
    Cleared(Vec<u8>),
    Blocked,
    Unchanged,
}

/// Scrollbar geometry for the viewport, in rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Scrollbar {
    /// Total scrollable rows (scrollback + screen).
    pub total: u64,
    /// Row offset of the viewport within `total`.
    pub offset: u64,
    /// Viewport height in rows.
    pub len: u64,
}

/// An owned terminal cell anchor that follows its row through scrollback
/// growth, pruning, and reflow. Callers must serialize access with the
/// originating [`Terminal`].
pub struct TrackedScreenPoint {
    raw: sys::GhosttyTrackedGridRef,
    terminal_instance_id: u64,
}

/// One absolute coordinate in the active screen, including retained
/// scrollback rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SelectionPoint {
    pub column: u16,
    pub row: u32,
}

/// A selection range returned by Ghostty's terminal selection rules.
/// Endpoints preserve the direction supplied by the terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SelectionRange {
    pub start: SelectionPoint,
    pub end: SelectionPoint,
}

// The C handle is owned by this value and Ghostty permits freeing it after
// its terminal is gone. All other access requires the originating Terminal,
// whose callers already serialize mutation.
unsafe impl Send for TrackedScreenPoint {}

impl Drop for TrackedScreenPoint {
    fn drop(&mut self) {
        unsafe { sys::ghostty_tracked_grid_ref_free(self.raw) };
    }
}

impl Scrollbar {
    /// Whether the viewport is scrolled away from the live bottom.
    pub fn scrolled_back(&self) -> bool {
        self.offset + self.len < self.total
    }
}

/// Callback invoked with bytes the terminal wants written to the pty.
pub type PtyWriteFn = Box<dyn FnMut(&[u8]) + Send>;
/// Parameterless notification callback (title changed, bell).
pub type NotifyFn = Box<dyn FnMut() + Send>;

/// Host callbacks invoked synchronously during [`Terminal::vt_write`].
///
/// Callbacks must not touch the [`Terminal`] that invoked them (the C API
/// forbids reentrancy); queue work and act on it after `vt_write` returns.
#[derive(Default)]
pub struct Callbacks {
    /// The terminal needs to write bytes back to the pty (query responses,
    /// device status reports, ...).
    pub on_pty_write: Option<PtyWriteFn>,
    /// The terminal title changed (OSC 0/2). Read it with
    /// [`Terminal::title`] after `vt_write` returns.
    pub on_title_changed: Option<NotifyFn>,
    /// BEL received.
    pub on_bell: Option<NotifyFn>,
    /// A program asked to read the clipboard (OSC 52), deferred; see
    /// [`Terminal::set_clipboard_reads_deferred`].
    pub on_clipboard_read: Option<ClipboardReadFn>,
}

/// A terminal instance: VT parser plus full screen/scrollback state.
pub struct Terminal {
    raw: sys::GhosttyTerminal,
    instance_id: u64,
    history_epoch: u64,
    // Detect fixed-size scrollback eviction without scanning retained rows.
    history_anchor: sys::GhosttyTrackedGridRef,
    mouse_mode_revision: u64,
    kitty_inflight: Box<KittyInFlightTracker>,
    // Keep the potentially long-lived replay cache behind one pointer so
    // adding it does not inflate every Surface enum value.
    kitty_replay_pixel_cache: Box<KittyReplayPixelCache>,
    mouse_mode_bits: u8,
    mouse_mode_signature: MouseModeSignature,
    mouse_mode_probe: MouseModeProbe,
    active_mouse_format: MouseWireFormat,
    mouse_mode_change_detector: MouseModeChangeDetector,
    vt_boundary: VtBoundaryTracker,
    prompt_semantic: PromptSemanticTracker,
    // Heap-pinned so the userdata pointer stays valid for the terminal's
    // lifetime.
    callbacks: Box<Callbacks>,
    cursor_override: CursorOverrideTracker,
    palette_override: Box<PaletteOverrideTracker>,
    color_overrides: ColorOverrideTracker,
    c1_normalizer: C1Normalizer,
    /// Stable primary-screen row markers (`terminal.history`).
    history_markers: history::HistoryMarkers,
}

enum PendingSequenceReplay<'a> {
    /// The parser is at a boundary.
    None,
    /// Bytes since the last boundary.
    Bytes(&'a [u8]),
    /// A direct Kitty upload larger than the generic budget, which the
    /// Kitty in-flight prefix reproduces.
    KittyCommand,
}

#[derive(Default)]
struct KittyReplayPixelCache(HashMap<u64, Arc<[u8]>>);

/// Ghostty's protocol integer grammar for OSC color indices (ghostty-next
/// `lib/parse_int.zig`): ASCII decimal digits only, no sign, no digit
/// separators, at most `max`.
fn parse_protocol_decimal(bytes: &[u8], max: u16) -> Option<u16> {
    if bytes.is_empty() {
        return None;
    }
    let mut value = 0_u16;
    for byte in bytes {
        if !byte.is_ascii_digit() {
            return None;
        }
        value = value.checked_mul(10)?.checked_add(u16::from(byte - b'0'))?;
        if value > max {
            return None;
        }
    }
    Some(value)
}

fn trim_ascii_spaces(mut bytes: &[u8]) -> &[u8] {
    while bytes.first() == Some(&b' ') {
        bytes = &bytes[1..];
    }
    while bytes.last() == Some(&b' ') {
        bytes = &bytes[..bytes.len() - 1];
    }
    bytes
}

// The handle is not thread-safe, but it is movable and we only expose
// mutation through &mut self, so guarding a Terminal with a Mutex is sound.
unsafe impl Send for Terminal {}

unsafe extern "C" fn write_pty_trampoline(
    _terminal: sys::GhosttyTerminal,
    userdata: *mut c_void,
    data: *const u8,
    len: usize,
) {
    let callbacks = unsafe { &mut *(userdata as *mut Callbacks) };
    if let Some(f) = callbacks.on_pty_write.as_mut() {
        let bytes = if len == 0 { &[] } else { unsafe { std::slice::from_raw_parts(data, len) } };
        f(bytes);
    }
}

unsafe extern "C" fn title_changed_trampoline(
    _terminal: sys::GhosttyTerminal,
    userdata: *mut c_void,
) {
    let callbacks = unsafe { &mut *(userdata as *mut Callbacks) };
    if let Some(f) = callbacks.on_title_changed.as_mut() {
        f();
    }
}

unsafe extern "C" fn bell_trampoline(_terminal: sys::GhosttyTerminal, userdata: *mut c_void) {
    let callbacks = unsafe { &mut *(userdata as *mut Callbacks) };
    if let Some(f) = callbacks.on_bell.as_mut() {
        f();
    }
}

impl Terminal {
    pub fn new(cols: u16, rows: u16, max_scrollback: usize, callbacks: Callbacks) -> Result<Self> {
        kitty::install_png_decoder()?;
        let mouse_mode_probe = MouseModeProbe::new()?;
        let mut raw: sys::GhosttyTerminal = ptr::null_mut();
        check(unsafe {
            sys::ghostty_terminal_new(ptr::null(), &mut raw, cols.max(1), rows.max(1))
        })?;
        // The scrollback limit is retained storage in bytes (Ghostty's page
        // budget), not a line count. Snapshots need the continuation of an
        // unfinished escape sequence, so tracking is on from the first byte.
        let configured = check(unsafe {
            sys::ghostty_terminal_set(
                raw,
                sys::GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
                (&max_scrollback as *const usize).cast(),
            )
        })
        .and_then(|()| {
            let limit = SNAPSHOT_CONTINUATION_MAX_BYTES;
            check(unsafe {
                sys::ghostty_terminal_set(
                    raw,
                    sys::GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES,
                    (&limit as *const usize).cast(),
                )
            })
        });
        if let Err(error) = configured {
            unsafe { sys::ghostty_terminal_free(raw) };
            return Err(error);
        }
        if let Err(error) = configure_kitty_graphics(raw) {
            unsafe { sys::ghostty_terminal_free(raw) };
            return Err(error);
        }

        let mut term = Terminal {
            raw,
            instance_id: NEXT_TERMINAL_ID.fetch_add(1, Ordering::Relaxed),
            history_epoch: NEXT_HISTORY_EPOCH.fetch_add(1, Ordering::Relaxed),
            history_anchor: ptr::null_mut(),
            mouse_mode_revision: 0,
            kitty_inflight: Box::new(KittyInFlightTracker::default()),
            kitty_replay_pixel_cache: Box::default(),
            mouse_mode_bits: 0,
            mouse_mode_signature: MouseModeSignature::default(),
            mouse_mode_probe,
            active_mouse_format: MouseWireFormat::default(),
            mouse_mode_change_detector: MouseModeChangeDetector::default(),
            vt_boundary: VtBoundaryTracker::default(),
            prompt_semantic: PromptSemanticTracker::default(),
            callbacks: Box::new(callbacks),
            cursor_override: CursorOverrideTracker::default(),
            palette_override: Box::default(),
            color_overrides: ColorOverrideTracker::default(),
            c1_normalizer: C1Normalizer::default(),
            history_markers: Default::default(),
        };
        let userdata = &mut *term.callbacks as *mut Callbacks as *mut c_void;
        unsafe {
            sys::ghostty_terminal_set(raw, sys::GHOSTTY_TERMINAL_OPT_USERDATA, userdata);
            sys::ghostty_terminal_set(
                raw,
                sys::GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                write_pty_trampoline as *const c_void,
            );
            sys::ghostty_terminal_set(
                raw,
                sys::GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
                title_changed_trampoline as *const c_void,
            );
            sys::ghostty_terminal_set(
                raw,
                sys::GHOSTTY_TERMINAL_OPT_BELL,
                bell_trampoline as *const c_void,
            );
        }
        term.mouse_mode_bits = term.current_mouse_mode_bits();
        term.mouse_mode_signature = term.mouse_mode_probe.signature(term.raw);
        Ok(term)
    }

    pub(crate) fn raw(&self) -> sys::GhosttyTerminal {
        self.raw
    }

    pub(crate) fn mouse_mode_revision(&self) -> u64 {
        self.mouse_mode_revision
    }

    pub(crate) fn instance_id(&self) -> u64 {
        self.instance_id
    }

    /// Monotonic token for retained-history row contents and coordinates.
    /// Frontends must match this with a paged history read before projecting
    /// absolute graphics anchors onto those rows.
    pub fn history_epoch(&self) -> u64 {
        self.history_epoch
    }

    fn bump_history_epoch(&mut self) {
        self.history_epoch = NEXT_HISTORY_EPOCH.fetch_add(1, Ordering::Relaxed);
    }

    fn ensure_history_anchor(&mut self) {
        if !self.history_anchor.is_null() || self.scrollback_rows() == 0 {
            return;
        }
        let point = sys::GhosttyPoint {
            tag: sys::GHOSTTY_POINT_TAG_HISTORY,
            value: sys::GhosttyPointValue {
                coordinate: sys::GhosttyPointCoordinate { x: 0, y: 0 },
            },
        };
        let mut anchor: sys::GhosttyTrackedGridRef = ptr::null_mut();
        if check(unsafe { sys::ghostty_terminal_grid_ref_track(self.raw, point, &mut anchor) })
            .is_ok()
        {
            self.history_anchor = anchor;
        }
    }

    fn reset_history_anchor(&mut self) {
        unsafe { sys::ghostty_tracked_grid_ref_free(self.history_anchor) };
        self.history_anchor = ptr::null_mut();
        self.ensure_history_anchor();
    }

    /// Feed VT-encoded bytes (pty output) into the terminal.
    pub fn vt_write(&mut self, data: &[u8]) {
        let _ = self.vt_write_with_normalized(data);
    }

    /// Feed VT-encoded bytes and return the exact byte stream accepted by
    /// Ghostty. Standalone 8-bit control-string/ST controls are returned in
    /// their 7-bit forms, while UTF-8 continuation bytes remain unchanged
    /// across calls.
    ///
    /// Process hosts should publish this returned stream so every frontend
    /// parses the same bytes as the authoritative terminal.
    pub fn vt_write_with_normalized<'a>(&mut self, data: &'a [u8]) -> Cow<'a, [u8]> {
        if data.is_empty() {
            return Cow::Borrowed(data);
        }
        self.ensure_history_anchor();
        let previous_history_rows = self.scrollback_rows();
        let history_anchor_missing = previous_history_rows > 0 && self.history_anchor.is_null();
        let normalized = self.c1_normalizer.normalize(data);
        self.kitty_inflight.write(&normalized);
        self.vt_boundary.feed(&normalized);
        self.prompt_semantic.feed(&normalized);
        self.cursor_override.write(&normalized);
        self.palette_override.write(&normalized);
        self.color_overrides.write(&normalized);
        let mouse_modes_may_have_changed = self.mouse_mode_change_detector.write(&normalized);
        self.history_markers_before_write();
        unsafe { sys::ghostty_terminal_vt_write(self.raw, normalized.as_ptr(), normalized.len()) };
        self.history_markers_after_write();
        let history_rows = self.scrollback_rows();
        let history_anchor_evicted = !self.history_anchor.is_null()
            && !unsafe { sys::ghostty_tracked_grid_ref_has_value(self.history_anchor) };
        if previous_history_rows != history_rows || history_anchor_missing || history_anchor_evicted
        {
            self.bump_history_epoch();
        }
        if history_rows == 0 || history_anchor_evicted {
            self.reset_history_anchor();
        } else if self.history_anchor.is_null() {
            self.ensure_history_anchor();
        }
        if mouse_modes_may_have_changed {
            self.refresh_mouse_mode_revision();
        }
        normalized
    }

    /// Whether the persistent VT stream has no incomplete control sequence or
    /// UTF-8 codepoint. A formatter replay is safe to hand to a fresh parser
    /// only while this is true, serialized with [`Self::vt_write`].
    pub fn vt_stream_is_ground(&self) -> bool {
        self.c1_normalizer.utf8_remaining == 0
            && self.get::<bool>(sys::GHOSTTY_TERMINAL_DATA_VT_GROUND).unwrap_or(false)
    }

    /// Whether a replay built now, followed by the rest of the live stream,
    /// reproduces this terminal in a fresh parser.
    ///
    /// Replays end with the incomplete sequence the parser is inside, so this
    /// holds at every byte except inside a control string larger than the
    /// pending-sequence budget. Callers that cannot resume must fall back to a
    /// fresh attachment at a later boundary.
    pub fn vt_replay_resumes_stream(&self) -> bool {
        self.pending_sequence_replay().is_some()
    }

    /// How the replay reproduces the parser's incomplete sequence, if it can.
    fn pending_sequence_replay(&self) -> Option<PendingSequenceReplay<'_>> {
        if self.vt_stream_is_ground() {
            return Some(PendingSequenceReplay::None);
        }
        if let Some(pending) = self.vt_boundary.pending_replay() {
            return Some(PendingSequenceReplay::Bytes(pending));
        }
        // A direct Kitty upload may exceed the generic budget; its own
        // tracker retains it up to the image limit.
        self.kitty_inflight.has_partial_command().then_some(PendingSequenceReplay::KittyCommand)
    }

    fn refresh_mouse_mode_revision(&mut self) {
        let next_bits = self.current_mouse_mode_bits();
        let bits_changed = next_bits != self.mouse_mode_bits;
        let tracking_bits = next_bits & 0x0f;
        let format_bits = next_bits >> 4;
        // A bit tuple is sufficient when at most one tracking and wire-format
        // mode is active. When modes overlap, query Ghostty's encoder because
        // its parsed last-set precedence is not represented by the bits.
        // Overlapping wire formats stay ambiguous even with tracking off:
        // the active format must be current before tracking is re-enabled
        // or a replay is serialized.
        let behavior_can_be_ambiguous =
            tracking_bits.count_ones() > 1 || format_bits.count_ones() > 1;
        if !bits_changed && !behavior_can_be_ambiguous {
            return;
        }
        let next_signature = self.mouse_mode_probe.signature(self.raw);
        if bits_changed || next_signature != self.mouse_mode_signature {
            self.mouse_mode_revision = self.mouse_mode_revision.wrapping_add(1);
        }
        self.mouse_mode_bits = next_bits;
        self.mouse_mode_signature = next_signature;
        if let Some(format) = self.mouse_mode_probe.classify_wire_format(self.raw) {
            self.active_mouse_format = format;
        }
    }

    /// Last-set-wins active coordinate wire format (xterm semantics).
    ///
    /// This mirrors Ghostty's parsed precedence, which the boolean DEC mode
    /// flags cannot represent when several format modes are flagged at once.
    pub fn active_mouse_format(&self) -> MouseWireFormat {
        self.active_mouse_format
    }

    fn current_mouse_mode_bits(&self) -> u8 {
        MOUSE_DEC_MODES
            .into_iter()
            .enumerate()
            .fold(0, |bits, (index, mode)| bits | (u8::from(self.mode(mode, false)) << index))
    }

    /// Whether the current cursor style/blink came from an active DECSCUSR
    /// override rather than the embedder defaults.
    pub fn cursor_overridden(&self) -> bool {
        self.cursor_override.active
    }

    /// Whether a PTY has an active OSC 4 override for this palette index.
    pub fn palette_overridden(&self, index: u8) -> bool {
        self.palette_override.active[index as usize]
    }

    /// Monotonic revision for PTY-authored palette or special-color changes.
    pub fn color_revision(&self) -> u64 {
        self.palette_override.revision
    }

    /// Monotonic revision for terminal resets that require byte frontends to
    /// reapply the authoritative palette even when its values are unchanged.
    pub fn color_reapply_revision(&self) -> u64 {
        self.palette_override.reapply_revision
    }

    /// Current effective terminal palette without consuming render damage.
    pub fn effective_palette(&self) -> Result<[Rgb; 256]> {
        terminal_palette(self.raw, sys::GHOSTTY_TERMINAL_DATA_COLOR_PALETTE)
    }

    /// Set host-provided default foreground, background, and cursor colors.
    ///
    /// `None` leaves that channel unchanged.
    pub fn set_default_colors(&mut self, fg: Option<Rgb>, bg: Option<Rgb>, cursor: Option<Rgb>) {
        unsafe {
            if let Some(fg) = fg {
                let color = sys::GhosttyColorRgb { r: fg.r, g: fg.g, b: fg.b };
                sys::ghostty_terminal_set(
                    self.raw,
                    sys::GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND,
                    &color as *const sys::GhosttyColorRgb as *const c_void,
                );
            }
            if let Some(bg) = bg {
                let color = sys::GhosttyColorRgb { r: bg.r, g: bg.g, b: bg.b };
                sys::ghostty_terminal_set(
                    self.raw,
                    sys::GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND,
                    &color as *const sys::GhosttyColorRgb as *const c_void,
                );
            }
            if let Some(cursor) = cursor {
                let color = sys::GhosttyColorRgb { r: cursor.r, g: cursor.g, b: cursor.b };
                sys::ghostty_terminal_set(
                    self.raw,
                    sys::GHOSTTY_TERMINAL_OPT_COLOR_CURSOR,
                    &color as *const sys::GhosttyColorRgb as *const c_void,
                );
            }
        }
    }

    /// Replace all host-provided default color channels. Unlike
    /// [`Self::set_default_colors`], `None` clears an earlier embedder value.
    pub fn replace_default_colors(
        &mut self,
        fg: Option<Rgb>,
        bg: Option<Rgb>,
        cursor: Option<Rgb>,
    ) {
        let fg = fg.map(|color| sys::GhosttyColorRgb { r: color.r, g: color.g, b: color.b });
        let bg = bg.map(|color| sys::GhosttyColorRgb { r: color.r, g: color.g, b: color.b });
        let cursor =
            cursor.map(|color| sys::GhosttyColorRgb { r: color.r, g: color.g, b: color.b });
        unsafe {
            for (option, color) in [
                (sys::GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, fg.as_ref()),
                (sys::GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, bg.as_ref()),
                (sys::GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, cursor.as_ref()),
            ] {
                let pointer = color
                    .map(|color| color as *const sys::GhosttyColorRgb as *const c_void)
                    .unwrap_or(ptr::null());
                sys::ghostty_terminal_set(self.raw, option, pointer);
            }
        }
    }

    /// Set selected entries in the host-provided default palette.
    ///
    /// Unspecified entries use Ghostty's built-in palette. Active OSC 4
    /// overrides remain effective; this only replaces their defaults.
    pub fn set_default_palette(&mut self, overrides: &[Option<Rgb>; 256]) {
        let mut palette = [sys::GhosttyColorRgb::default(); 256];
        unsafe { sys::ghostty_color_palette_default(palette.as_mut_ptr()) };
        for (slot, color) in palette.iter_mut().zip(overrides) {
            if let Some(color) = color {
                *slot = sys::GhosttyColorRgb { r: color.r, g: color.g, b: color.b };
            }
        }
        unsafe {
            sys::ghostty_terminal_set(
                self.raw,
                sys::GHOSTTY_TERMINAL_OPT_COLOR_PALETTE,
                palette.as_ptr().cast(),
            );
        }
    }

    /// Set the cursor defaults used until an application overrides them with
    /// DECSCUSR. `None` leaves that default unchanged.
    pub fn set_default_cursor(&mut self, style: Option<CursorShape>, blink: Option<bool>) {
        unsafe {
            if let Some(style) = style {
                let style = match style {
                    CursorShape::Bar => sys::GHOSTTY_TERMINAL_CURSOR_STYLE_BAR,
                    CursorShape::Underline => sys::GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE,
                    CursorShape::Block | CursorShape::BlockHollow => {
                        sys::GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK
                    }
                };
                sys::ghostty_terminal_set(
                    self.raw,
                    sys::GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE,
                    &style as *const sys::GhosttyTerminalCursorStyle as *const c_void,
                );
            }
            if let Some(blink) = blink {
                sys::ghostty_terminal_set(
                    self.raw,
                    sys::GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK,
                    &blink as *const bool as *const c_void,
                );
            }
        }
    }

    /// Replace both embedder cursor defaults. `None` clears an earlier value
    /// and restores Ghostty's built-in default for that channel.
    pub fn replace_default_cursor(&mut self, style: Option<CursorShape>, blink: Option<bool>) {
        let style = style.map(|style| match style {
            CursorShape::Bar => sys::GHOSTTY_TERMINAL_CURSOR_STYLE_BAR,
            CursorShape::Underline => sys::GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE,
            CursorShape::Block | CursorShape::BlockHollow => {
                sys::GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK
            }
        });
        unsafe {
            sys::ghostty_terminal_set(
                self.raw,
                sys::GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE,
                style
                    .as_ref()
                    .map(|style| style as *const sys::GhosttyTerminalCursorStyle as *const c_void)
                    .unwrap_or(ptr::null()),
            );
            sys::ghostty_terminal_set(
                self.raw,
                sys::GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK,
                blink
                    .as_ref()
                    .map(|blink| blink as *const bool as *const c_void)
                    .unwrap_or(ptr::null()),
            );
        }
    }

    /// Effective foreground, background, and cursor colors.
    ///
    /// Each value includes any active OSC 10/11/12 override and is `None`
    /// when neither the embedder nor the terminal application set it.
    pub fn effective_colors(&self) -> (Option<Rgb>, Option<Rgb>, Option<Rgb>) {
        let color = |data| self.get::<sys::GhosttyColorRgb>(data).ok().map(Rgb::from);
        (
            color(sys::GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND),
            color(sys::GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND),
            color(sys::GHOSTTY_TERMINAL_DATA_COLOR_CURSOR),
        )
    }

    /// Effective cursor visual for the active screen, including DECSCUSR,
    /// alternate-screen state, DEC mode 12, and embedder defaults.
    pub fn effective_cursor_visual(&self) -> Result<(CursorShape, bool)> {
        let shape = match self.get::<sys::GhosttyTerminalCursorStyle>(
            sys::GHOSTTY_TERMINAL_DATA_CURSOR_VISUAL_STYLE,
        )? {
            sys::GHOSTTY_TERMINAL_CURSOR_STYLE_BAR => CursorShape::Bar,
            sys::GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE => CursorShape::Underline,
            sys::GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK_HOLLOW => CursorShape::BlockHollow,
            _ => CursorShape::Block,
        };
        let blinking: bool = self.get(sys::GHOSTTY_TERMINAL_DATA_CURSOR_BLINKING)?;
        Ok((shape, blinking))
    }

    /// Opaque semantic cursor activity token. Compare only for inequality;
    /// it advances for DECSCUSR, mode 12, active-screen changes, RIS, and
    /// embedder cursor-default setters even when the resolved pair is equal.
    pub fn cursor_activity(&self) -> Result<u64> {
        self.get(sys::GHOSTTY_TERMINAL_DATA_CURSOR_ACTIVITY)
    }

    /// Dynamic state for process-separated renderers. Application-authored
    /// OSC 4/10/11/12 state remains sparse so the receiving renderer keeps its
    /// own theme. Cursor visual is host-resolved because shape is per-screen,
    /// blink is terminal-global, and DECSCUSR and DEC mode 12 interact.
    pub fn color_overrides(&self) -> TerminalColorOverrides {
        let effective_color = |active: bool, data| {
            active.then(|| self.get::<sys::GhosttyColorRgb>(data).ok().map(Rgb::from)).flatten()
        };
        let palette = self
            .get_palette(sys::GHOSTTY_TERMINAL_DATA_COLOR_PALETTE)
            .map(|effective| {
                std::array::from_fn(|index| {
                    self.color_overrides.palette_authored(index).then(|| effective[index].into())
                })
            })
            .unwrap_or([None; 256]);
        TerminalColorOverrides {
            foreground: effective_color(
                self.color_overrides.foreground,
                sys::GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND,
            ),
            background: effective_color(
                self.color_overrides.background,
                sys::GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND,
            ),
            cursor: effective_color(
                self.color_overrides.cursor,
                sys::GHOSTTY_TERMINAL_DATA_COLOR_CURSOR,
            ),
            cursor_visual: Some(
                self.effective_cursor_visual()
                    .expect("valid terminals expose an effective cursor visual"),
            ),
            palette,
        }
    }

    fn get_palette(&self, data: sys::GhosttyTerminalData) -> Result<[sys::GhosttyColorRgb; 256]> {
        let mut output = [sys::GhosttyColorRgb::default(); 256];
        check(unsafe { sys::ghostty_terminal_get(self.raw, data, output.as_mut_ptr().cast()) })?;
        Ok(output)
    }

    /// Cursor position (column, row), zero-indexed within the active area.
    pub fn cursor_position(&self) -> Option<(u16, u16)> {
        let x = self.get::<u16>(sys::GHOSTTY_TERMINAL_DATA_CURSOR_X).ok()?;
        let y = self.get::<u16>(sys::GHOSTTY_TERMINAL_DATA_CURSOR_Y).ok()?;
        Some((x, y))
    }

    /// Clear retained history and complete rows before the active prompt
    /// without writing bytes to the child process.
    ///
    /// OSC 133 identifies the full prompt when available. Without shell
    /// metadata, only scrollback is cleared because visible rows may contain
    /// hard-newline input whose boundary cannot be inferred. Cursor movement
    /// is skipped when pending-wrap or origin-mode state cannot be restored
    /// exactly. If preserved content begins in scrollback, or the persistent
    /// VT parser is inside a partial sequence or UTF-8 code point, no mutation
    /// is applied.
    pub fn clear_history_preserving_prompt(&mut self) -> ClearHistoryOutcome {
        const CLEAR_SCROLLBACK: &[u8] = b"\x1b[3J";

        if self.active_screen() == Screen::Alternate {
            return ClearHistoryOutcome::Unchanged;
        }
        if !self.vt_boundary.is_safe() {
            return ClearHistoryOutcome::Blocked;
        }

        let mut clear = CLEAR_SCROLLBACK.to_vec();
        let Some((cursor_x, cursor_y)) = self.cursor_position() else {
            return ClearHistoryOutcome::Unchanged;
        };
        let prompt_semantic = self.prompt_semantic.semantic(Screen::Primary);
        let cursor_is_at_prompt = self.cursor_is_at_prompt();
        let prompt_start_y =
            cursor_is_at_prompt.then(|| self.active_prompt_start_row(cursor_y)).flatten();
        let preserve_from_y = if cursor_is_at_prompt {
            prompt_start_y.or_else(|| self.active_logical_line_start_row(cursor_y))
        } else if prompt_semantic == PromptSemantic::Unknown {
            Some(0)
        } else {
            self.active_logical_line_start_row(cursor_y)
        };
        let Some(preserve_from_y) = preserve_from_y else {
            return ClearHistoryOutcome::Unchanged;
        };
        let history_rows = self.history_rows();
        let prompt_may_begin_in_history = cursor_is_at_prompt
            && match prompt_start_y {
                None => true,
                // Some shells mark every hard-newline prompt row. Row zero is
                // only a true boundary when the adjacent history row is not
                // another prompt row.
                Some(0) if history_rows > 0 => self
                    .history_row_prompt_semantic(history_rows - 1)
                    .map(|semantic| semantic != sys::GHOSTTY_ROW_SEMANTIC_NONE)
                    .unwrap_or(true),
                Some(0) => false,
                Some(_) => false,
            };
        if history_rows > 0
            && (prompt_may_begin_in_history
                || (preserve_from_y == 0
                    && !cursor_is_at_prompt
                    && self.active_row_wrap_continuation(0).unwrap_or(true)))
        {
            return ClearHistoryOutcome::Unchanged;
        }
        if self.cursor_pending_wrap() || self.mode(6, false) {
            self.vt_write(&clear);
            return ClearHistoryOutcome::Cleared(clear);
        }
        if preserve_from_y == 0 {
            self.vt_write(&clear);
            return ClearHistoryOutcome::Cleared(clear);
        }

        for row in 0..preserve_from_y {
            clear.extend_from_slice(format!("\x1b[{};1H\x1b[2K", u32::from(row) + 1).as_bytes());
        }
        clear.extend_from_slice(
            format!("\x1b[{};{}H", u32::from(cursor_y) + 1, u32::from(cursor_x) + 1).as_bytes(),
        );
        self.vt_write(&clear);
        ClearHistoryOutcome::Cleared(clear)
    }

    fn cursor_pending_wrap(&self) -> bool {
        self.get::<bool>(sys::GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP).unwrap_or(true)
    }

    fn active_prompt_start_row(&self, cursor_y: u16) -> Option<u16> {
        let mut prompt_y = (0..=cursor_y).rev().find(|&y| {
            self.active_row_prompt_semantic(y) == Some(sys::GHOSTTY_ROW_SEMANTIC_PROMPT)
        })?;
        while prompt_y > 0
            && self.active_row_prompt_semantic(prompt_y - 1)
                == Some(sys::GHOSTTY_ROW_SEMANTIC_PROMPT)
        {
            prompt_y -= 1;
        }
        Some(prompt_y)
    }

    fn active_logical_line_start_row(&self, mut y: u16) -> Option<u16> {
        while y > 0 && self.active_row_wrap_continuation(y)? {
            y -= 1;
        }
        Some(y)
    }

    fn active_row_wrap_continuation(&self, y: u16) -> Option<bool> {
        let grid_ref = self.grid_ref(sys::GHOSTTY_POINT_TAG_ACTIVE, 0, u64::from(y))?;
        let mut row = sys::GhosttyRow::default();
        check(unsafe { sys::ghostty_grid_ref_row(&grid_ref, &mut row) }).ok()?;
        let mut continuation = false;
        check(unsafe {
            sys::ghostty_row_get(
                row,
                sys::GHOSTTY_ROW_DATA_WRAP_CONTINUATION,
                (&mut continuation as *mut bool).cast(),
            )
        })
        .ok()?;
        Some(continuation)
    }

    fn active_row_prompt_semantic(&self, y: u16) -> Option<sys::GhosttyRowSemanticPrompt> {
        self.row_prompt_semantic(sys::GHOSTTY_POINT_TAG_ACTIVE, u64::from(y))
    }

    fn history_row_prompt_semantic(&self, y: u32) -> Option<sys::GhosttyRowSemanticPrompt> {
        self.row_prompt_semantic(sys::GHOSTTY_POINT_TAG_HISTORY, u64::from(y))
    }

    fn row_prompt_semantic(
        &self,
        tag: sys::GhosttyPointTag,
        y: u64,
    ) -> Option<sys::GhosttyRowSemanticPrompt> {
        let grid_ref = self.grid_ref(tag, 0, y)?;
        let mut row = sys::GhosttyRow::default();
        check(unsafe { sys::ghostty_grid_ref_row(&grid_ref, &mut row) }).ok()?;
        let mut semantic = sys::GHOSTTY_ROW_SEMANTIC_NONE;
        check(unsafe {
            sys::ghostty_row_get(
                row,
                sys::GHOSTTY_ROW_DATA_SEMANTIC_PROMPT,
                (&mut semantic as *mut sys::GhosttyRowSemanticPrompt).cast(),
            )
        })
        .ok()?;
        Some(semantic)
    }

    pub fn resize(
        &mut self,
        cols: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    ) -> Result<()> {
        let reflows = (cols.max(1), rows.max(1)) != (self.cols(), self.rows());
        check(unsafe {
            sys::ghostty_terminal_resize(
                self.raw,
                cols.max(1),
                rows.max(1),
                cell_width_px,
                cell_height_px,
            )
        })?;
        self.bump_history_epoch();
        self.reset_history_anchor();
        if reflows {
            self.history_markers_reflowed();
        }
        Ok(())
    }

    /// Copy the active screen's Kitty image storage into owned Rust values.
    pub fn kitty_graphics_snapshot(&self) -> Result<KittyGraphicsSnapshot> {
        kitty::snapshot(self, &mut Default::default(), true)
    }

    /// Restore number aliases after replaying Kitty images by stable ID.
    pub fn restore_kitty_image_aliases(&mut self, aliases: &[KittyImageAlias]) -> Result<()> {
        if aliases.is_empty() {
            return Ok(());
        }

        let mut graphics: sys::GhosttyKittyGraphics = ptr::null_mut();
        check(unsafe {
            sys::ghostty_terminal_get(
                self.raw,
                sys::GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
                (&mut graphics as *mut sys::GhosttyKittyGraphics).cast(),
            )
        })?;
        if graphics.is_null() {
            return Err(Error::NoValue);
        }

        for alias in aliases {
            if unsafe { sys::ghostty_kitty_graphics_image(graphics, alias.image_id) }.is_null() {
                return Err(Error::NoValue);
            }
        }
        for alias in aliases {
            check(unsafe {
                sys::ghostty_kitty_graphics_image_set_number(
                    graphics,
                    alias.image_id,
                    alias.image_number,
                )
            })?;
        }
        Ok(())
    }

    /// Apply one complete replay sidecar and byte stream to this terminal.
    pub fn apply_vt_replay(&mut self, replay: &VtReplay) -> Result<()> {
        self.apply_vt_replay_parts(&replay.bytes, &replay.kitty_image_aliases, replay.kitty_state)?;
        self.vt_write(&replay.pending_sequence);
        Ok(())
    }

    /// Apply replay bytes and their non-VT sidecar through the same ordering
    /// used by owned [`VtReplay`] values. The caller writes the replay's
    /// `pending_sequence` afterwards, after any sequences of its own.
    pub fn apply_vt_replay_parts(
        &mut self,
        bytes: &[u8],
        kitty_image_aliases: &[KittyImageAlias],
        kitty_state: KittyReplayState,
    ) -> Result<()> {
        let kitty_state = kitty_state.validate_for_replay(bytes.len())?;
        self.set_kitty_graphics_limits(kitty_state.limits)?;
        let cursor_offset = kitty_state.replay_cursor_offset as usize;
        self.vt_write(&bytes[..cursor_offset]);
        self.set_kitty_image_id_cursors(kitty_state.replay_next_image_ids)?;
        self.vt_write(&bytes[cursor_offset..]);
        // Protocol-v1/v2 peers cannot carry the replay sidecar. Their safe
        // compatibility state disables graphics, so aliases for discarded
        // replay images must also be discarded.
        if kitty_state.limits != KittyGraphicsLimits::disabled() {
            self.restore_kitty_image_aliases(kitty_image_aliases)?;
        }
        self.set_kitty_image_id_cursors(kitty_state.next_image_ids)
    }

    fn kitty_replay_state(&self, replay_cursor_offset: u32) -> Result<KittyReplayState> {
        let raw: sys::GhosttyTerminalKittyImageIdCursorState =
            self.get(sys::GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_ID_CURSORS)?;
        Ok(KittyReplayState {
            limits: self.kitty_graphics_limits()?,
            replay_cursor_offset,
            replay_next_image_ids: KittyImageIdCursors {
                primary: raw.replay.primary,
                alternate: raw.replay.alternate,
            }
            .validate()?,
            next_image_ids: KittyImageIdCursors {
                primary: raw.next.primary,
                alternate: raw.next.alternate,
            }
            .validate()?,
        })
    }

    fn set_kitty_image_id_cursors(&mut self, cursors: KittyImageIdCursors) -> Result<()> {
        let cursors = cursors.validate()?;
        let raw = sys::GhosttyTerminalKittyImageIdCursors {
            primary: cursors.primary,
            alternate: cursors.alternate,
        };
        check(unsafe {
            sys::ghostty_terminal_set(
                self.raw,
                sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_ID_CURSORS,
                (&raw as *const sys::GhosttyTerminalKittyImageIdCursors).cast(),
            )
        })
    }

    pub fn kitty_graphics_limits(&self) -> Result<KittyGraphicsLimits> {
        Ok(KittyGraphicsLimits {
            image_bytes: self.kitty_image_storage_limit()?,
            inflight_bytes: self.kitty_inflight_storage_limit(),
            images: self.kitty_image_count_limit()?,
            placements: self.kitty_placement_count_limit()?,
        })
    }

    /// Apply all Kitty limits through one shared path. Returns whether native
    /// image or placement content changed.
    pub fn set_kitty_graphics_limits(&mut self, limits: KittyGraphicsLimits) -> Result<bool> {
        let limits = limits.validate()?;
        let generation = self.kitty_graphics_generation()?;
        self.set_kitty_inflight_storage_limit(limits.inflight_bytes);
        self.set_kitty_image_count_limit(limits.images)?;
        if self.set_kitty_placement_count_limit(limits.placements).is_err() {
            // Placement reductions preserve visible state by default. Under
            // pressure, release the old scene before installing the bound.
            self.set_kitty_image_storage_limit(0)?;
            self.set_kitty_placement_count_limit(limits.placements)?;
        }
        // Run after count eviction even when the byte value is unchanged so
        // the replay pixel cache is pruned against native ownership.
        self.set_kitty_image_storage_limit(limits.image_bytes)?;
        Ok(self.kitty_graphics_generation()? != generation)
    }

    /// Set the active terminal's bounded Kitty image storage in bytes.
    pub fn set_kitty_image_storage_limit(&mut self, bytes: u64) -> Result<()> {
        check(unsafe {
            sys::ghostty_terminal_set(
                self.raw,
                sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,
                (&bytes as *const u64).cast(),
            )
        })?;

        // Lowering libghostty's limit evicts native images immediately. Keep
        // the replay-side pixel copy at the same boundary instead of waiting
        // for some later replay to notice those evictions.
        let mut pixel_cache = std::mem::take(&mut self.kitty_replay_pixel_cache.0);
        let snapshot = kitty::snapshot(self, &mut pixel_cache, true);
        if snapshot.is_err() {
            pixel_cache.clear();
        }
        self.kitty_replay_pixel_cache.0 = pixel_cache;
        snapshot.map(|_| ())
    }

    pub fn kitty_image_storage_limit(&self) -> Result<u64> {
        self.get(sys::GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_STORAGE_LIMIT)
    }

    /// Set the total bytes retained while tracking a chunked Kitty upload.
    ///
    /// The completed prefix and current command share this one limit.
    pub fn set_kitty_inflight_storage_limit(&mut self, bytes: u64) {
        let bounded = bytes.min(KITTY_INFLIGHT_REPLAY_MAX_BYTES as u64) as usize;
        self.kitty_inflight.set_max_bytes(bounded);
    }

    pub fn kitty_inflight_storage_limit(&self) -> u64 {
        self.kitty_inflight.max_bytes() as u64
    }

    /// Content generation for the active screen's Kitty image store.
    pub fn kitty_graphics_generation(&self) -> Result<u64> {
        kitty::generation(self)
    }

    /// Set the active terminal's maximum number of stored Kitty images.
    pub fn set_kitty_image_count_limit(&mut self, count: u64) -> Result<()> {
        check(unsafe {
            sys::ghostty_terminal_set(
                self.raw,
                sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_COUNT_LIMIT,
                (&count as *const u64).cast(),
            )
        })
    }

    pub fn kitty_image_count_limit(&self) -> Result<u64> {
        self.get(sys::GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_COUNT_LIMIT)
    }

    /// Set the active terminal's maximum number of Kitty placements.
    pub fn set_kitty_placement_count_limit(&mut self, count: u64) -> Result<()> {
        check(unsafe {
            sys::ghostty_terminal_set(
                self.raw,
                sys::GHOSTTY_TERMINAL_OPT_KITTY_PLACEMENT_COUNT_LIMIT,
                (&count as *const u64).cast(),
            )
        })
    }

    pub fn kitty_placement_count_limit(&self) -> Result<u64> {
        self.get(sys::GHOSTTY_TERMINAL_DATA_KITTY_PLACEMENT_COUNT_LIMIT)
    }

    /// Whether file, temporary-file, or shared-memory image media are enabled.
    ///
    /// cmux enables only direct (`t=d`) payloads, so this is `(false, false,
    /// false)` for terminals created by [`Terminal::new`].
    pub fn kitty_external_image_media_enabled(&self) -> Result<(bool, bool, bool)> {
        // The temporary-file medium reports its allowed directory as a
        // GhosttyString (empty while disabled), never a bool. Reading it into
        // a bool would let Ghostty write 16 bytes into a 1-byte slot.
        let temp_file_directory: sys::GhosttyString =
            self.get(sys::GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_TEMP_FILE)?;
        Ok((
            self.get(sys::GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_FILE)?,
            temp_file_directory.len > 0,
            self.get(sys::GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_SHARED_MEM)?,
        ))
    }

    fn get<T: Default>(&self, data: sys::GhosttyTerminalData) -> Result<T> {
        let mut out = T::default();
        check(unsafe {
            sys::ghostty_terminal_get(self.raw, data, &mut out as *mut T as *mut c_void)
        })?;
        Ok(out)
    }

    pub fn cols(&self) -> u16 {
        self.get::<u16>(sys::GHOSTTY_TERMINAL_DATA_COLS).unwrap_or(0)
    }

    pub fn rows(&self) -> u16 {
        self.get::<u16>(sys::GHOSTTY_TERMINAL_DATA_ROWS).unwrap_or(0)
    }

    pub fn active_screen(&self) -> Screen {
        match self.get::<sys::GhosttyTerminalScreen>(sys::GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN) {
            Ok(sys::GHOSTTY_TERMINAL_SCREEN_ALTERNATE) => Screen::Alternate,
            _ => Screen::Primary,
        }
    }

    /// Whether OSC 133 metadata identifies the cursor as an active shell
    /// prompt. libghostty-vt exposes persisted row/cell semantics but not the
    /// live cursor semantic, so the wrapper also retains OSC 133's current
    /// prompt phase across cursor movement and soft wrapping. Terminals without
    /// shell integration conservatively return false.
    pub fn cursor_is_at_prompt(&self) -> bool {
        if self.active_screen() == Screen::Alternate {
            return false;
        }
        match self.prompt_semantic.semantic(Screen::Primary) {
            PromptSemantic::Prompt
            | PromptSemantic::Input
            | PromptSemantic::InputUntilEndOfLine => return true,
            PromptSemantic::Output => return false,
            PromptSemantic::Unknown => {}
        }
        let Some((x, y)) = self.cursor_position() else {
            return false;
        };
        let Some(grid_ref) = self.grid_ref(sys::GHOSTTY_POINT_TAG_ACTIVE, x, u64::from(y)) else {
            return false;
        };

        let mut row = sys::GhosttyRow::default();
        if check(unsafe { sys::ghostty_grid_ref_row(&grid_ref, &mut row) }).is_err() {
            return false;
        }
        let mut row_semantic = sys::GHOSTTY_ROW_SEMANTIC_NONE;
        if check(unsafe {
            sys::ghostty_row_get(
                row,
                sys::GHOSTTY_ROW_DATA_SEMANTIC_PROMPT,
                (&mut row_semantic as *mut sys::GhosttyRowSemanticPrompt).cast(),
            )
        })
        .is_ok()
            && row_semantic != sys::GHOSTTY_ROW_SEMANTIC_NONE
        {
            return true;
        }

        let mut cell = sys::GhosttyCell::default();
        if check(unsafe { sys::ghostty_grid_ref_cell(&grid_ref, &mut cell) }).is_err() {
            return false;
        }
        let mut cell_semantic = sys::GHOSTTY_CELL_SEMANTIC_OUTPUT;
        check(unsafe {
            sys::ghostty_cell_get(
                cell,
                sys::GHOSTTY_CELL_DATA_SEMANTIC_CONTENT,
                (&mut cell_semantic as *mut sys::GhosttyCellSemanticContent).cast(),
            )
        })
        .is_ok()
            && matches!(
                cell_semantic,
                sys::GHOSTTY_CELL_SEMANTIC_INPUT | sys::GHOSTTY_CELL_SEMANTIC_PROMPT
            )
    }

    /// Plain text of the newest block of shell input on the primary screen:
    /// the cells OSC 133 marks as input (after `B`, until `C`), in the
    /// contiguous rows that hold input nearest above or at the cursor,
    /// scanning at most `max_rows` rows up. Ghostty assigns the semantic as
    /// it parses each byte, so the result does not depend on how output was
    /// chunked (typeahead, redraws) and survives reflow. `None` on the
    /// alternate screen or when no input cell is found.
    pub fn latest_input_text(&mut self, max_rows: u32) -> Option<String> {
        if self.active_screen() == Screen::Alternate {
            return None;
        }
        let scrollbar = self.scrollbar()?;
        let (_, cursor_y) = self.cursor_position()?;
        let active_top = scrollbar.total.checked_sub(u64::from(self.rows()))?;
        let cursor_row = active_top + u64::from(cursor_y);
        let lowest = cursor_row.saturating_sub(u64::from(max_rows));
        let cols = self.cols();
        let mut first: Option<(u16, u64)> = None;
        let mut last: Option<(u16, u64)> = None;
        let mut row = cursor_row;
        loop {
            match (self.input_span(row, cols), last) {
                (Some((start, end)), None) => {
                    first = Some((start, row));
                    last = Some((end, row));
                }
                (Some((start, _)), Some(_)) => first = Some((start, row)),
                (None, Some(_)) => break,
                (None, None) => {}
            }
            if row <= lowest {
                break;
            }
            row -= 1;
        }
        self.selection_text_absolute(first?, last?)
    }

    /// First and last column of the cells OSC 133 marks as input in screen
    /// row `row`.
    fn input_span(&self, row: u64, cols: u16) -> Option<(u16, u16)> {
        let mut first = None;
        let mut last = None;
        for x in 0..cols {
            let grid_ref = self.grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, x, row)?;
            let mut cell = sys::GhosttyCell::default();
            if check(unsafe { sys::ghostty_grid_ref_cell(&grid_ref, &mut cell) }).is_err() {
                continue;
            }
            let mut semantic = sys::GHOSTTY_CELL_SEMANTIC_OUTPUT;
            let read = check(unsafe {
                sys::ghostty_cell_get(
                    cell,
                    sys::GHOSTTY_CELL_DATA_SEMANTIC_CONTENT,
                    (&mut semantic as *mut sys::GhosttyCellSemanticContent).cast(),
                )
            });
            if read.is_ok() && semantic == sys::GHOSTTY_CELL_SEMANTIC_INPUT {
                first.get_or_insert(x);
                last = Some(x);
            }
        }
        Some((first?, last?))
    }

    /// Monotonic revision of recognized OSC 133 prompt-phase markers.
    pub fn prompt_semantic_revision(&self) -> u64 {
        self.prompt_semantic.revision()
    }

    /// Whether any mouse tracking mode is enabled by the application.
    pub fn mouse_tracking(&self) -> bool {
        self.get::<bool>(sys::GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING).unwrap_or(false)
    }

    pub fn pointer_semantic_snapshot(&self) -> TerminalPointerSemanticSnapshot {
        TerminalPointerSemanticSnapshot {
            terminal_instance_id: self.instance_id,
            mouse_mode_revision: self.mouse_mode_revision,
            mouse_tracking: self.mouse_tracking(),
            active_mouse_format: self.active_mouse_format,
            active_screen: self.active_screen(),
            cols: self.cols(),
            rows: self.rows(),
        }
    }

    /// Number of scrollback rows above the viewport.
    pub fn scrollback_rows(&self) -> usize {
        self.get::<usize>(sys::GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS).unwrap_or(0)
    }

    /// Number of retained history rows, saturated to the protocol's `u32`.
    pub fn history_rows(&self) -> u32 {
        u32::try_from(self.scrollback_rows()).unwrap_or(u32::MAX)
    }

    /// Read styled retained rows without moving the viewport or consuming
    /// terminal/render damage.
    ///
    /// `start` is zero-based from the oldest retained row. Reads clamp at the
    /// current history length, so an evicted or past-the-end start returns an
    /// empty page. This uses Ghostty's read-only history-coordinate grid refs;
    /// it never scrolls the shared viewport or updates a render state.
    pub fn styled_history_rows(&self, start: u32, count: u16) -> Result<Vec<Vec<Cell>>> {
        let total = self.history_rows();
        if count == 0 || start >= total {
            return Ok(Vec::new());
        }

        let palette = terminal_palette(self.raw, sys::GHOSTTY_TERMINAL_DATA_COLOR_PALETTE)?;
        let end = start.saturating_add(u32::from(count)).min(total);
        let cols = self.cols();
        let mut rows = Vec::with_capacity((end - start) as usize);
        let mut grapheme_buf = Vec::new();

        for y in start..end {
            let mut row = Vec::with_capacity(cols as usize);
            for x in 0..cols {
                let point = sys::GhosttyPoint {
                    tag: sys::GHOSTTY_POINT_TAG_HISTORY,
                    value: sys::GhosttyPointValue {
                        coordinate: sys::GhosttyPointCoordinate { x, y },
                    },
                };
                let mut grid_ref = sys::GhosttyGridRef {
                    size: size_of::<sys::GhosttyGridRef>(),
                    ..Default::default()
                };
                check(unsafe { sys::ghostty_terminal_grid_ref(self.raw, point, &mut grid_ref) })?;
                row.push(read_grid_ref_cell(&grid_ref, &palette, &mut grapheme_buf)?);
            }
            rows.push(row);
        }
        Ok(rows)
    }

    /// Terminal title as set by OSC 0/2, if any.
    pub fn title(&self) -> Option<String> {
        let s: sys::GhosttyString = self.get(sys::GHOSTTY_TERMINAL_DATA_TITLE).ok()?;
        if s.len == 0 || s.ptr.is_null() {
            return None;
        }
        let bytes = unsafe { std::slice::from_raw_parts(s.ptr, s.len) };
        Some(String::from_utf8_lossy(bytes).into_owned())
    }

    /// Working directory reported via OSC 7, if any.
    pub fn pwd(&self) -> Option<String> {
        let s: sys::GhosttyString = self.get(sys::GHOSTTY_TERMINAL_DATA_PWD).ok()?;
        if s.len == 0 || s.ptr.is_null() {
            return None;
        }
        let bytes = unsafe { std::slice::from_raw_parts(s.ptr, s.len) };
        Some(String::from_utf8_lossy(bytes).into_owned())
    }

    /// Query a terminal mode (DEC private when `ansi` is false).
    pub fn mode(&self, mode: u16, ansi: bool) -> bool {
        let mut config = sys::GhosttyTerminalModeConfig {
            mode: sys::ghostty_mode_new(mode, ansi),
            value: false,
        };
        let result = unsafe {
            sys::ghostty_terminal_get(
                self.raw,
                sys::GHOSTTY_TERMINAL_DATA_MODE,
                (&mut config as *mut sys::GhosttyTerminalModeConfig).cast(),
            )
        };
        result == sys::GHOSTTY_SUCCESS && config.value
    }

    pub fn scroll_delta(&mut self, delta: isize) {
        let behavior = sys::GhosttyTerminalScrollViewport {
            tag: sys::GHOSTTY_SCROLL_VIEWPORT_DELTA,
            value: sys::GhosttyTerminalScrollViewportValue { delta },
        };
        unsafe { sys::ghostty_terminal_scroll_viewport(self.raw, behavior) }
    }

    pub fn scroll_to_bottom(&mut self) {
        let behavior = sys::GhosttyTerminalScrollViewport {
            tag: sys::GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
            value: sys::GhosttyTerminalScrollViewportValue { delta: 0 },
        };
        unsafe { sys::ghostty_terminal_scroll_viewport(self.raw, behavior) }
    }

    /// Scrollbar geometry for the current viewport. The engine notes this
    /// can be expensive for arbitrary scroll positions; call it once per
    /// frame at most.
    pub fn scrollbar(&self) -> Option<Scrollbar> {
        let raw: sys::GhosttyTerminalScrollbar =
            self.get(sys::GHOSTTY_TERMINAL_DATA_SCROLLBAR).ok()?;
        if raw.total == 0 || raw.len == 0 {
            return None;
        }
        Some(Scrollbar { total: raw.total, offset: raw.offset, len: raw.len })
    }

    /// Track one cell in full-screen coordinates. The anchor continues to
    /// identify that cell as history grows or older rows are pruned.
    pub fn track_screen_point(&mut self, x: u16, y: u32) -> Result<TrackedScreenPoint> {
        let point = sys::GhosttyPoint {
            tag: sys::GHOSTTY_POINT_TAG_SCREEN,
            value: sys::GhosttyPointValue { coordinate: sys::GhosttyPointCoordinate { x, y } },
        };
        let mut raw: sys::GhosttyTrackedGridRef = ptr::null_mut();
        check(unsafe { sys::ghostty_terminal_grid_ref_track(self.raw, point, &mut raw) })?;
        if raw.is_null() {
            return Err(Error::NoValue);
        }
        Ok(TrackedScreenPoint { raw, terminal_instance_id: self.instance_id })
    }

    /// Resolve an anchor into the current full-screen coordinate space.
    /// `None` means its row was pruned or belongs to a replaced terminal.
    pub fn tracked_screen_point(&self, point: &TrackedScreenPoint) -> Option<(u16, u32)> {
        if point.terminal_instance_id != self.instance_id || point.raw.is_null() {
            return None;
        }
        let mut coordinate = sys::GhosttyPointCoordinate::default();
        (unsafe {
            sys::ghostty_tracked_grid_ref_point(
                point.raw,
                sys::GHOSTTY_POINT_TAG_SCREEN,
                &mut coordinate,
            )
        } == sys::GHOSTTY_SUCCESS)
            .then_some((coordinate.x, coordinate.y))
    }

    /// Move an existing anchor to a new full-screen coordinate.
    pub fn set_tracked_screen_point(
        &mut self,
        tracked: &mut TrackedScreenPoint,
        x: u16,
        y: u32,
    ) -> Result<()> {
        if tracked.terminal_instance_id != self.instance_id || tracked.raw.is_null() {
            return Err(Error::InvalidValue);
        }
        let point = sys::GhosttyPoint {
            tag: sys::GHOSTTY_POINT_TAG_SCREEN,
            value: sys::GhosttyPointValue { coordinate: sys::GhosttyPointCoordinate { x, y } },
        };
        check(unsafe { sys::ghostty_tracked_grid_ref_set(tracked.raw, self.raw, point) })
    }

    /// Move a screen selection point from a wide grapheme continuation cell
    /// to the grapheme's lead cell. Ghostty represents a wide grapheme that
    /// wraps at the right edge as a spacer head on one row and a wide lead on
    /// the next row. The spacer head has no text of its own, so semantic
    /// selection must address the lead cell.
    pub fn normalize_selection_point_screen(
        &self,
        point: SelectionPoint,
    ) -> Option<SelectionPoint> {
        let width = self.cell_width_screen(point)?;
        match width {
            CellWidth::SpacerTail if point.column > 0 => {
                let leading = SelectionPoint { column: point.column - 1, ..point };
                (self.cell_width_screen(leading) == Some(CellWidth::Wide)).then_some(leading)
            }
            CellWidth::SpacerHead => {
                let leading = SelectionPoint { column: 0, row: point.row.checked_add(1)? };
                (self.cell_width_screen(leading) == Some(CellWidth::Wide)).then_some(leading)
            }
            _ => Some(point),
        }
    }

    fn cell_width_screen(&self, point: SelectionPoint) -> Option<CellWidth> {
        let grid_ref =
            self.grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, point.column, u64::from(point.row))?;
        let mut raw = sys::GhosttyCell::default();
        check(unsafe { sys::ghostty_grid_ref_cell(&grid_ref, &mut raw) }).ok()?;
        Some(crate::render::cell_width(raw))
    }

    /// Select the word containing an absolute screen coordinate using
    /// Ghostty's configured word-boundary rules.
    pub fn select_word_screen(&self, point: SelectionPoint) -> Result<Option<SelectionRange>> {
        let grid_ref = self
            .grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, point.column, u64::from(point.row))
            .ok_or(Error::InvalidValue)?;
        let options = sys::GhosttyTerminalSelectWordOptions {
            size: size_of::<sys::GhosttyTerminalSelectWordOptions>(),
            ref_: grid_ref,
            boundary_codepoints: ptr::null(),
            boundary_codepoints_len: 0,
        };
        let mut selection = sys::GhosttySelection {
            size: size_of::<sys::GhosttySelection>(),
            ..Default::default()
        };
        let result =
            unsafe { sys::ghostty_terminal_select_word(self.raw, &options, &mut selection) };
        if result == sys::GHOSTTY_NO_VALUE {
            return Ok(None);
        }
        check(result)?;
        self.selection_range(&selection).map(Some)
    }

    /// Select the nearest word between two absolute screen coordinates.
    /// This is useful while dragging because it skips whitespace and other
    /// empty cells without inventing boundaries in the UI layer.
    pub fn select_word_between_screen(
        &self,
        start: SelectionPoint,
        end: SelectionPoint,
    ) -> Result<Option<SelectionRange>> {
        let start_ref = self
            .grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, start.column, u64::from(start.row))
            .ok_or(Error::InvalidValue)?;
        let end_ref = self
            .grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, end.column, u64::from(end.row))
            .ok_or(Error::InvalidValue)?;
        let options = sys::GhosttyTerminalSelectWordBetweenOptions {
            size: size_of::<sys::GhosttyTerminalSelectWordBetweenOptions>(),
            start: start_ref,
            end: end_ref,
            boundary_codepoints: ptr::null(),
            boundary_codepoints_len: 0,
        };
        let mut selection = sys::GhosttySelection {
            size: size_of::<sys::GhosttySelection>(),
            ..Default::default()
        };
        let result = unsafe {
            sys::ghostty_terminal_select_word_between(self.raw, &options, &mut selection)
        };
        if result == sys::GHOSTTY_NO_VALUE {
            return Ok(None);
        }
        check(result)?;
        self.selection_range(&selection).map(Some)
    }

    /// Select the logical line containing an absolute screen coordinate.
    pub fn select_line_screen(&self, point: SelectionPoint) -> Result<Option<SelectionRange>> {
        self.select_line_screen_with_whitespace(point, ptr::null(), 0)
    }

    /// Select a logical line without trimming its leading or trailing cells.
    /// This is used only as the blank-line fallback for a triple-click drag.
    pub fn select_line_screen_untrimmed(
        &self,
        point: SelectionPoint,
    ) -> Result<Option<SelectionRange>> {
        // A non-null pointer with a zero length tells Ghostty to use an
        // explicitly empty whitespace set instead of its default trim set.
        const EMPTY_WHITESPACE: u32 = 0;
        let selection = self.select_line_screen_with_whitespace(point, &EMPTY_WHITESPACE, 0)?;
        if selection.is_some() {
            return Ok(selection);
        }

        // Ghostty still returns no value when every cell lacks text. The
        // validated blank row remains a selectable line for a line-wise drag.
        let Some(last_column) = self.cols().checked_sub(1) else { return Ok(None) };
        Ok(Some(SelectionRange {
            start: SelectionPoint { column: 0, row: point.row },
            end: SelectionPoint { column: last_column, row: point.row },
        }))
    }

    fn select_line_screen_with_whitespace(
        &self,
        point: SelectionPoint,
        whitespace: *const u32,
        whitespace_len: usize,
    ) -> Result<Option<SelectionRange>> {
        let grid_ref = self
            .grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, point.column, u64::from(point.row))
            .ok_or(Error::InvalidValue)?;
        let options = sys::GhosttyTerminalSelectLineOptions {
            size: size_of::<sys::GhosttyTerminalSelectLineOptions>(),
            ref_: grid_ref,
            whitespace,
            whitespace_len,
            semantic_prompt_boundary: true,
        };
        let mut selection = sys::GhosttySelection {
            size: size_of::<sys::GhosttySelection>(),
            ..Default::default()
        };
        let result =
            unsafe { sys::ghostty_terminal_select_line(self.raw, &options, &mut selection) };
        if result == sys::GHOSTTY_NO_VALUE {
            return Ok(None);
        }
        check(result)?;
        self.selection_range(&selection).map(Some)
    }

    fn selection_range(&self, selection: &sys::GhosttySelection) -> Result<SelectionRange> {
        Ok(SelectionRange {
            start: self.selection_point(&selection.start)?,
            end: self.selection_point(&selection.end)?,
        })
    }

    fn selection_point(&self, grid_ref: &sys::GhosttyGridRef) -> Result<SelectionPoint> {
        let mut coordinate = sys::GhosttyPointCoordinate::default();
        check(unsafe {
            sys::ghostty_terminal_point_from_grid_ref(
                self.raw,
                grid_ref,
                sys::GHOSTTY_POINT_TAG_SCREEN,
                &mut coordinate,
            )
        })?;
        Ok(SelectionPoint { column: coordinate.x, row: coordinate.y })
    }

    /// Plain text of a selection range given in viewport coordinates
    /// (inclusive). Returns `None` when either endpoint is out of bounds.
    pub fn selection_text(&mut self, start: (u16, u16), end: (u16, u16)) -> Option<String> {
        self.selection_text_with_tag(
            sys::GHOSTTY_POINT_TAG_VIEWPORT,
            (start.0, start.1 as u64),
            (end.0, end.1 as u64),
        )
    }

    /// Plain-text dump of the currently rendered viewport.
    ///
    /// This uses the terminal formatter's read-only selection path rather
    /// than `RenderState::update`, so callers can inspect the viewport
    /// without clearing dirty flags needed by a concurrent renderer.
    pub fn viewport_text(&mut self) -> Result<String> {
        let cols = self.cols();
        let rows = self.rows();
        if cols == 0 || rows == 0 {
            return Ok(String::new());
        }
        self.selection_text_with_tag_options(
            sys::GHOSTTY_POINT_TAG_VIEWPORT,
            (0, 0),
            (cols.saturating_sub(1), rows.saturating_sub(1) as u64),
            false,
            true,
        )
        .ok_or(Error::InvalidValue)
    }

    /// Plain text of a selection range given in absolute screen
    /// coordinates (scrollbar offset + viewport row), inclusive.
    /// Clamps the end row when scrollback has trimmed rows after the
    /// selection was captured.
    pub fn selection_text_absolute(
        &mut self,
        start: (u16, u64),
        end: (u16, u64),
    ) -> Option<String> {
        let sb = self.scrollbar()?;
        let last_row = sb.total.checked_sub(1)?;
        if start.1 > last_row {
            return None;
        }
        let end = (end.0, end.1.min(last_row));
        if (end.1, end.0) < (start.1, start.0) {
            return None;
        }
        self.selection_text_with_tag(sys::GHOSTTY_POINT_TAG_SCREEN, start, end)
    }

    fn selection_text_with_tag(
        &mut self,
        tag: sys::GhosttyPointTag,
        start: (u16, u64),
        end: (u16, u64),
    ) -> Option<String> {
        self.selection_text_with_tag_options(tag, start, end, true, true)
    }

    fn selection_text_with_tag_options(
        &mut self,
        tag: sys::GhosttyPointTag,
        start: (u16, u64),
        end: (u16, u64),
        unwrap_lines: bool,
        trim: bool,
    ) -> Option<String> {
        let selection = sys::GhosttySelection {
            size: size_of::<sys::GhosttySelection>(),
            start: self.grid_ref(tag, start.0, start.1)?,
            end: self.grid_ref(tag, end.0, end.1)?,
            rectangle: false,
        };
        let opts = sys::GhosttyFormatterTerminalOptions {
            size: size_of::<sys::GhosttyFormatterTerminalOptions>(),
            emit: sys::GHOSTTY_FORMATTER_FORMAT_PLAIN,
            unwrap: unwrap_lines,
            trim,
            extra: sys::GhosttyFormatterTerminalExtra {
                size: size_of::<sys::GhosttyFormatterTerminalExtra>(),
                ..Default::default()
            },
            selection: &selection,
        };
        let bytes = self.format(opts).ok()?;
        Some(String::from_utf8_lossy(&bytes).into_owned())
    }

    /// Plain-text dump of the active screen's full page list, INCLUDING
    /// scrollback. For the rendered viewport only, use [`Self::viewport_text`].
    pub fn plain_text(&mut self) -> Result<String> {
        let opts = sys::GhosttyFormatterTerminalOptions {
            size: size_of::<sys::GhosttyFormatterTerminalOptions>(),
            emit: sys::GHOSTTY_FORMATTER_FORMAT_PLAIN,
            unwrap: false,
            trim: true,
            extra: sys::GhosttyFormatterTerminalExtra {
                size: size_of::<sys::GhosttyFormatterTerminalExtra>(),
                ..Default::default()
            },
            selection: ptr::null(),
        };
        Ok(String::from_utf8_lossy(&self.format(opts)?).into_owned())
    }

    /// Replay of the terminal's current state.
    ///
    /// Feeding `bytes` into a fresh terminal of the same size and restoring
    /// `kitty_image_aliases` reproduces
    /// the screen contents, styles, cursor, modes, palette, keyboard
    /// state, charsets, tabstops, and title. This is the attach primitive: a new
    /// frontend replays this, then follows the live pty stream.
    pub fn vt_replay(&mut self) -> Result<VtReplay> {
        self.vt_replay_bounded(usize::MAX)
    }

    /// Byte-only compatibility replay. This discards Kitty number aliases.
    pub fn vt_replay_bytes(&mut self) -> Result<Vec<u8>> {
        Ok(self.vt_replay()?.into_self_contained_bytes())
    }

    /// Reject replay state that cannot fit under `max_bytes` regardless of
    /// text or completed graphics truncation. Callers can use this before a
    /// destructive geometry change, then build the full replay afterward.
    pub fn preflight_vt_replay_bounded(&self, max_bytes: usize) -> Result<()> {
        let (inflight, pending) = self.replay_inflight_and_pending(max_bytes)?;
        let pending = pending.as_slice();
        let suffix_len = self.replay_state_suffix().len();
        if inflight
            .len()
            .checked_add(suffix_len)
            .and_then(|total| total.checked_add(pending.len()))
            .is_none_or(|total| total > max_bytes)
        {
            return Err(Error::OutOfSpace);
        }
        Ok(())
    }

    /// The completed Kitty upload chunks a replay restores, and the
    /// incomplete sequence it hands back separately. The generic pending
    /// bytes already contain any partial Kitty command; a Kitty command past
    /// their budget comes from the Kitty tracker instead.
    fn replay_inflight_and_pending(&self, max_bytes: usize) -> Result<(Vec<u8>, Vec<u8>)> {
        // Always ask the Kitty tracker, so its per-surface upload budget
        // applies whichever tracker supplies the partial command.
        let (inflight, kitty_partial) =
            self.kitty_inflight.replay_prefix_and_partial_checked(max_bytes)?;
        let pending = match self.pending_sequence_replay() {
            Some(PendingSequenceReplay::Bytes(pending)) => pending.to_vec(),
            Some(PendingSequenceReplay::KittyCommand) => kitty_partial,
            Some(PendingSequenceReplay::None) | None => Vec::new(),
        };
        Ok((inflight, pending))
    }

    /// VT replay bounded to `max_bytes`, retaining the newest complete rows.
    ///
    /// Formatting begins with a recent row window derived from the budget. A
    /// fitting window grows geometrically up to the complete history, while an
    /// oversized window shrinks until the active screen fits. This preserves
    /// full history when it fits without first scanning unbounded scrollback.
    /// A pathological screen whose newest row alone exceeds the budget falls
    /// back to a terminal reset so callers can still attach and receive live
    /// output instead of entering a permanent overflow loop.
    pub fn vt_replay_bounded(&mut self, max_bytes: usize) -> Result<VtReplay> {
        self.vt_replay_bounded_with_palette(max_bytes, true)
    }

    /// Theme-portable replay for process-separated renderers.
    ///
    /// This reproduces cells, styles, modes, cursor, history, and Kitty
    /// graphics but omits terminal palette/default-color OSC state. Pair it
    /// with a sparse [`TerminalColorOverrides`] snapshot so the receiving
    /// renderer keeps its own Ghostty theme for every color the application
    /// did not set. This byte-only compatibility API discards Kitty number
    /// aliases.
    pub fn vt_replay_bounded_theme_portable(&mut self, max_bytes: usize) -> Result<Vec<u8>> {
        Ok(self
            .vt_replay_bounded_theme_portable_with_aliases(max_bytes)?
            .into_self_contained_bytes())
    }

    /// Theme-portable replay retaining aliases for the Kitty images admitted
    /// by the bounded replay plan.
    pub fn vt_replay_bounded_theme_portable_with_aliases(
        &mut self,
        max_bytes: usize,
    ) -> Result<VtReplay> {
        self.vt_replay_bounded_with_palette(max_bytes, false)
    }

    /// Bytes appended after the formatted replay for state Ghostty's VT
    /// formatter does not emit.
    fn replay_state_suffix(&self) -> Vec<u8> {
        let mut suffix = self.mouse_format_replay_suffix();
        suffix.extend_from_slice(&self.title_replay_suffix());
        suffix
    }

    /// OSC 2 that restores the title. The formatter emits OSC 7 for the
    /// working directory but never the title, so without this every mirror
    /// rebuilt from a replay (attach, resync, host resize) loses the title an
    /// application set. Control characters cannot appear inside an OSC
    /// payload, so they are replaced with spaces.
    fn title_replay_suffix(&self) -> Vec<u8> {
        let Some(title) = self.title() else {
            return Vec::new();
        };
        let title: String = title.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
        format!("\x1b]2;{title}\x1b\\").into_bytes()
    }

    /// Correction bytes appended to a serialized replay so the replayed
    /// terminal ends with the same ACTIVE extended mouse coordinate format as
    /// this one. The formatter emits mode flags in numeric order (1005, 1006,
    /// 1015, 1016), so whenever more than one format flag is set, or the
    /// flags alone would replay a different format than the last-set-wins
    /// value, the suffix resets the non-active format flags and re-asserts
    /// the active selector last. Replays therefore carry only the active
    /// selector; the inactive flags are deliberately dropped because they
    /// have no encoding semantics.
    fn mouse_format_replay_suffix(&self) -> Vec<u8> {
        const FORMAT_MODES: [(u16, MouseWireFormat); 4] = [
            (1005, MouseWireFormat::Utf8),
            (1006, MouseWireFormat::Sgr),
            (1015, MouseWireFormat::Urxvt),
            (1016, MouseWireFormat::SgrPixels),
        ];
        let active = self.active_mouse_format;
        let set_modes: Vec<(u16, MouseWireFormat)> =
            FORMAT_MODES.into_iter().filter(|(mode, _)| self.mode(*mode, false)).collect();
        // What a numeric-order flag dump would leave active: the highest
        // numbered set format flag.
        let dump_would_activate =
            set_modes.last().map(|(_, format)| *format).unwrap_or(MouseWireFormat::X10);
        if set_modes.len() <= 1 && dump_would_activate == active {
            return Vec::new();
        }
        let mut suffix = Vec::new();
        for (mode, format) in &set_modes {
            if *format != active {
                suffix.extend_from_slice(format!("\x1b[?{mode}l").as_bytes());
            }
        }
        if let Some(mode) = active.dec_mode() {
            suffix.extend_from_slice(format!("\x1b[?{mode}h").as_bytes());
        }
        suffix
    }

    fn vt_replay_bounded_with_palette(
        &mut self,
        max_bytes: usize,
        include_palette: bool,
    ) -> Result<VtReplay> {
        let (inflight, pending) = self.replay_inflight_and_pending(max_bytes)?;
        let state_suffix = self.replay_state_suffix();
        let remaining = max_bytes
            .checked_sub(inflight.len())
            .and_then(|remaining| remaining.checked_sub(state_suffix.len()))
            .and_then(|remaining| remaining.checked_sub(pending.len()))
            .ok_or(Error::OutOfSpace)?;
        let mut pixel_cache = std::mem::take(&mut self.kitty_replay_pixel_cache.0);
        let snapshot = kitty::snapshot_for_replay(self, &mut pixel_cache, true);
        self.kitty_replay_pixel_cache.0 = pixel_cache;
        let snapshot = snapshot?;
        let catalog =
            KittyReplayCatalog::new(&snapshot, self.cell_pixel_size(), self.rows().max(1));

        let active_start = self.scrollbar().map(|scrollbar| {
            let viewport_start = scrollbar.total.saturating_sub(scrollbar.len);
            let visible_start = catalog.visible_anchor_start().unwrap_or(viewport_start);
            viewport_start.min(visible_start)
        });
        let active_text = self.vt_replay_text_layout_bounded(
            remaining,
            catalog.placement_rows(),
            active_start,
            include_palette,
        )?;
        let visible_cost =
            active_text.range.map(|range| catalog.visible_cost(range, remaining)).unwrap_or(0);

        let text_budget = remaining.saturating_sub(visible_cost);
        let text = self.vt_replay_text_layout_bounded(
            text_budget,
            catalog.placement_rows(),
            active_start,
            include_palette,
        )?;
        let graphics_budget = remaining.saturating_sub(text.bytes.len());
        let graphics = catalog.plan(text.range, graphics_budget, false);
        let reset_before_images = text.range.is_none();
        let interleaved = text.interleave(&graphics.placements).ok_or(Error::OutOfSpace)?;

        let total = graphics
            .image_bytes
            .len()
            .checked_add(interleaved.len())
            .and_then(|total| total.checked_add(inflight.len()))
            .and_then(|total| total.checked_add(state_suffix.len()))
            .and_then(|total| total.checked_add(pending.len()))
            .ok_or(Error::OutOfSpace)?;
        if total > max_bytes || graphics.total_len > graphics_budget {
            return Err(Error::OutOfSpace);
        }
        let mut bytes = Vec::with_capacity(total);
        if reset_before_images {
            bytes.extend_from_slice(&interleaved);
            bytes.extend_from_slice(&graphics.image_bytes);
        } else {
            bytes.extend_from_slice(&graphics.image_bytes);
            bytes.extend_from_slice(&interleaved);
        }
        // State the formatter cannot express: the active mouse coordinate
        // format and the OSC 0/2 title.
        bytes.extend_from_slice(&state_suffix);
        let replay_cursor_offset = u32::try_from(bytes.len()).map_err(|_| Error::OutOfSpace)?;
        bytes.extend_from_slice(&inflight);
        Ok(VtReplay {
            bytes,
            kitty_image_aliases: graphics.aliases,
            kitty_state: self.kitty_replay_state(replay_cursor_offset)?,
            pending_sequence: pending,
        })
    }

    /// Bounded byte-only compatibility replay. This discards Kitty aliases.
    pub fn vt_replay_bounded_bytes(&mut self, max_bytes: usize) -> Result<Vec<u8>> {
        Ok(self.vt_replay_bounded(max_bytes)?.into_self_contained_bytes())
    }

    fn vt_replay_text_layout_bounded(
        &mut self,
        max_bytes: usize,
        placement_rows: &KittyReplayRowIndex,
        minimum_start: Option<u64>,
        include_palette: bool,
    ) -> Result<ReplayText> {
        let Some(scrollbar) = self.scrollbar() else {
            return Ok(ReplayText::minimal(max_bytes));
        };
        if scrollbar.total == 0 {
            return Ok(ReplayText::minimal(max_bytes));
        }

        let screen_rows = scrollbar.len.min(scrollbar.total).max(1);
        let minimum_start = minimum_start
            .unwrap_or_else(|| scrollbar.total.saturating_sub(screen_rows))
            .min(scrollbar.total - 1);
        let minimum_rows = scrollbar.total.saturating_sub(minimum_start).max(screen_rows);
        let mut tail_rows =
            vt_replay_row_window(scrollbar.total, screen_rows, self.cols(), max_bytes)
                .max(minimum_rows)
                .min(scrollbar.total);
        let mut best = None;
        let mut failed_start = None;

        loop {
            let range = ReplayRowRange {
                start: scrollbar.total.saturating_sub(tail_rows),
                end: scrollbar.total - 1,
            };
            if let Some(replay) = self.vt_replay_text_range_bounded(
                range,
                placement_rows,
                max_bytes,
                include_palette,
            )? {
                if tail_rows == scrollbar.total {
                    return Ok(replay);
                }
                if let Some(failed_start) = failed_start {
                    return self.vt_replay_text_at_oldest_fitting_anchor(
                        replay,
                        failed_start,
                        placement_rows,
                        max_bytes,
                        include_palette,
                    );
                }
                best = Some(replay);
                let next = tail_rows.saturating_mul(2).min(scrollbar.total);
                if next == tail_rows {
                    break;
                }
                tail_rows = next;
                continue;
            }
            failed_start = Some(range.start);
            if let Some(replay) = best {
                return self.vt_replay_text_at_oldest_fitting_anchor(
                    replay,
                    range.start,
                    placement_rows,
                    max_bytes,
                    include_palette,
                );
            }
            if tail_rows <= minimum_rows {
                break;
            }
            let next = minimum_rows.max(tail_rows / 2);
            if next == tail_rows {
                break;
            }
            tail_rows = next;
        }

        Ok(ReplayText::minimal(max_bytes))
    }

    fn vt_replay_text_at_oldest_fitting_anchor(
        &mut self,
        mut best: ReplayText,
        failed_start: u64,
        placement_rows: &KittyReplayRowIndex,
        max_bytes: usize,
        include_palette: bool,
    ) -> Result<ReplayText> {
        let Some(best_range) = best.range else {
            return Ok(best);
        };
        let candidates = placement_rows
            .anchors
            .range(failed_start..best_range.start)
            .copied()
            .collect::<Vec<_>>();
        let mut low = 0;
        let mut high = candidates.len();
        while low < high {
            let middle = low + (high - low) / 2;
            let range = ReplayRowRange { start: candidates[middle], end: best_range.end };
            if let Some(replay) = self.vt_replay_text_range_bounded(
                range,
                placement_rows,
                max_bytes,
                include_palette,
            )? {
                best = replay;
                high = middle;
            } else {
                low = middle + 1;
            }
        }
        Ok(best)
    }

    fn vt_replay_text_range_bounded(
        &mut self,
        range: ReplayRowRange,
        placement_rows: &KittyReplayRowIndex,
        max_bytes: usize,
        include_palette: bool,
    ) -> Result<Option<ReplayText>> {
        let cols = self.cols();
        if cols == 0 || range.start > range.end {
            return Err(Error::InvalidValue);
        }
        let suffix = self.cursor_position_escape()?;
        let suffix_len = suffix.as_ref().map_or(0, Vec::len);
        let Some(format_max_bytes) = max_bytes.checked_sub(suffix_len) else {
            return Ok(None);
        };
        let insert_at_start = placement_rows.overlaps(range.start);
        let has_placement_anchor =
            placement_rows.anchors.range(range.start..=range.end).next().is_some();
        let mut segment_ends =
            placement_rows.anchors.range(range.start..=range.end).copied().collect::<BTreeSet<_>>();
        if insert_at_start {
            segment_ends.insert(range.start);
        }
        segment_ends.insert(range.end);
        let mut bytes = Vec::new();
        let mut insertion_offsets = BTreeMap::new();
        let mut segment_start = range.start;
        let replay_rows = range.end - range.start + 1;
        let screen_rows = u64::from(self.rows().max(1));
        // A replay with retained scrollback can contain exactly one viewport
        // of rows while still carrying a sparse history prefix in Ghostty's
        // screen coordinate space. Keep every row boundary in that case so
        // the target cannot retain stale history above the active TUI.
        let history_bearing = self.history_rows() > 0 || replay_rows > screen_rows;
        // A replay without image placement anchors can let the target terminal
        // recreate soft wraps naturally. Placement commands and history-bearing
        // ranges depend on physical row cursor positions, so retain the
        // row-delimited form for those cases.
        let preserve_soft_wrap = !history_bearing && !insert_at_start && !has_placement_anchor;
        let mut emitted_breaks = 0usize;
        for segment_end in segment_ends {
            if segment_end < segment_start {
                continue;
            }
            let selection = self.screen_selection(segment_start, segment_end)?;
            let first = segment_start == range.start;
            let last = segment_end == range.end;
            let remaining = format_max_bytes.saturating_sub(bytes.len());
            let Some(chunk) = self.format_bounded(
                Self::vt_replay_segment_options(
                    &selection,
                    first,
                    last,
                    include_palette,
                    preserve_soft_wrap,
                ),
                remaining,
            )?
            else {
                return Ok(None);
            };
            if !preserve_soft_wrap {
                emitted_breaks = emitted_breaks
                    .saturating_add(chunk.windows(2).filter(|bytes| *bytes == b"\r\n").count());
            }
            bytes.extend_from_slice(&chunk);
            if !preserve_soft_wrap && history_bearing {
                let expected_breaks =
                    usize::try_from(segment_end - range.start).unwrap_or(usize::MAX);
                while emitted_breaks < expected_breaks {
                    if bytes.len().saturating_add(2) > format_max_bytes {
                        return Ok(None);
                    }
                    bytes.extend_from_slice(b"\r\n");
                    emitted_breaks = emitted_breaks.saturating_add(1);
                }
            }
            if placement_rows.anchors.contains(&segment_end)
                || (insert_at_start && segment_end == range.start)
            {
                insertion_offsets.insert(segment_end, bytes.len());
            }
            if !last {
                if !preserve_soft_wrap {
                    if bytes.len().saturating_add(2) > format_max_bytes {
                        return Ok(None);
                    }
                    bytes.extend_from_slice(b"\r\n");
                    emitted_breaks = emitted_breaks.saturating_add(1);
                }
                segment_start = segment_end.saturating_add(1);
            }
        }
        if !preserve_soft_wrap && history_bearing {
            let expected_breaks = usize::try_from(replay_rows - 1).unwrap_or(usize::MAX);
            for _ in emitted_breaks..expected_breaks {
                if bytes.len().saturating_add(2) > format_max_bytes {
                    return Ok(None);
                }
                bytes.extend_from_slice(b"\r\n");
            }
        }
        if let Some(suffix) = suffix {
            bytes.extend_from_slice(&suffix);
        }
        Ok(Some(ReplayText { bytes, range: Some(range), insertion_offsets }))
    }

    fn screen_selection(&self, start_row: u64, end_row: u64) -> Result<sys::GhosttySelection> {
        let cols = self.cols();
        if cols == 0 || start_row > end_row {
            return Err(Error::InvalidValue);
        }
        Ok(sys::GhosttySelection {
            size: size_of::<sys::GhosttySelection>(),
            start: self
                .grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, 0, start_row)
                .ok_or(Error::InvalidValue)?,
            end: self
                .grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, cols.saturating_sub(1), end_row)
                .ok_or(Error::InvalidValue)?,
            rectangle: false,
        })
    }

    fn cursor_position_escape(&mut self) -> Result<Option<Vec<u8>>> {
        let Some((x, y)) = self.cursor_position() else { return Ok(None) };
        // With DECOM on, the ghostty-next formatter already emits the cursor,
        // including a pending wrap. An appended CUP would reinterpret
        // active-area coordinates relative to the scrolling region, and a
        // reprint of the cursor cell would land before the cursor moved.
        if self.mode(6, false) {
            return Ok(None);
        }
        if !self.get::<bool>(sys::GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP).unwrap_or(false) {
            return Ok(Some(
                format!("\x1b[{};{}H", u32::from(y) + 1, u32::from(x) + 1).into_bytes(),
            ));
        }

        // No standard cursor-positioning sequence can restore pending wrap:
        // CUP clears it. Reprint the authoritative cursor cell last instead.
        // The one-cell formatter includes a wide cell's lead grapheme, then
        // restores active cursor state without moving the cursor again.
        let cursor_ref = self
            .grid_ref(sys::GHOSTTY_POINT_TAG_ACTIVE, x, u64::from(y))
            .ok_or(Error::InvalidValue)?;
        let palette = terminal_palette(self.raw, sys::GHOSTTY_TERMINAL_DATA_COLOR_PALETTE)?;
        let mut grapheme = Vec::new();
        let cursor_cell = read_grid_ref_cell(&cursor_ref, &palette, &mut grapheme)?;
        let start_x = if cursor_cell.width == CellWidth::SpacerTail {
            x.checked_sub(1).ok_or(Error::InvalidValue)?
        } else {
            x
        };
        let selection = sys::GhosttySelection {
            size: size_of::<sys::GhosttySelection>(),
            start: self
                .grid_ref(sys::GHOSTTY_POINT_TAG_ACTIVE, start_x, u64::from(y))
                .ok_or(Error::InvalidValue)?,
            end: cursor_ref,
            rectangle: false,
        };
        let opts = sys::GhosttyFormatterTerminalOptions {
            size: size_of::<sys::GhosttyFormatterTerminalOptions>(),
            emit: sys::GHOSTTY_FORMATTER_FORMAT_VT,
            unwrap: false,
            trim: false,
            extra: sys::GhosttyFormatterTerminalExtra {
                size: size_of::<sys::GhosttyFormatterTerminalExtra>(),
                palette: false,
                modes: false,
                scrolling_region: false,
                tabstops: false,
                pwd: false,
                keyboard: false,
                screen: sys::GhosttyFormatterScreenExtra {
                    size: size_of::<sys::GhosttyFormatterScreenExtra>(),
                    cursor: false,
                    style: true,
                    hyperlink: true,
                    protection: true,
                    kitty_keyboard: true,
                    charsets: true,
                },
            },
            selection: &selection,
        };
        let mut suffix =
            format!("\x1b[{};{}H", u32::from(y) + 1, u32::from(start_x) + 1).into_bytes();
        suffix.extend_from_slice(&self.format(opts)?);
        Ok(Some(suffix))
    }

    fn vt_replay_segment_options(
        selection: &sys::GhosttySelection,
        first: bool,
        last: bool,
        include_palette: bool,
        unwrap_soft_wrap: bool,
    ) -> sys::GhosttyFormatterTerminalOptions {
        let mut options =
            Self::vt_replay_options(Some(selection), include_palette, unwrap_soft_wrap);
        options.extra.palette = include_palette && first;
        options.extra.modes = first;
        options.extra.scrolling_region = last;
        options.extra.tabstops = last;
        options.extra.pwd = last;
        options.extra.keyboard = last;
        options.extra.screen.cursor = last;
        options.extra.screen.style = last;
        options.extra.screen.hyperlink = last;
        options.extra.screen.protection = last;
        options.extra.screen.kitty_keyboard = last;
        options.extra.screen.charsets = last;
        options
    }

    fn vt_replay_options(
        selection: Option<&sys::GhosttySelection>,
        include_palette: bool,
        unwrap_soft_wrap: bool,
    ) -> sys::GhosttyFormatterTerminalOptions {
        sys::GhosttyFormatterTerminalOptions {
            size: size_of::<sys::GhosttyFormatterTerminalOptions>(),
            emit: sys::GHOSTTY_FORMATTER_FORMAT_VT,
            unwrap: unwrap_soft_wrap,
            trim: false,
            extra: sys::GhosttyFormatterTerminalExtra {
                size: size_of::<sys::GhosttyFormatterTerminalExtra>(),
                palette: include_palette,
                modes: true,
                scrolling_region: true,
                tabstops: true,
                pwd: true,
                keyboard: true,
                screen: sys::GhosttyFormatterScreenExtra {
                    size: size_of::<sys::GhosttyFormatterScreenExtra>(),
                    cursor: true,
                    style: true,
                    hyperlink: true,
                    protection: true,
                    kitty_keyboard: true,
                    charsets: true,
                },
            },
            selection: selection.map_or(ptr::null(), |value| value),
        }
    }

    fn cell_pixel_size(&self) -> (u32, u32) {
        let cols = u32::from(self.cols().max(1));
        let rows = u32::from(self.rows().max(1));
        let width = self.get::<u32>(sys::GHOSTTY_TERMINAL_DATA_WIDTH_PX).unwrap_or(cols);
        let height = self.get::<u32>(sys::GHOSTTY_TERMINAL_DATA_HEIGHT_PX).unwrap_or(rows);
        ((width / cols).max(1), (height / rows).max(1))
    }

    fn grid_ref(&self, tag: sys::GhosttyPointTag, x: u16, y: u64) -> Option<sys::GhosttyGridRef> {
        let y = u32::try_from(y).ok()?;
        let point = sys::GhosttyPoint {
            tag,
            value: sys::GhosttyPointValue { coordinate: sys::GhosttyPointCoordinate { x, y } },
        };
        let mut out =
            sys::GhosttyGridRef { size: size_of::<sys::GhosttyGridRef>(), ..Default::default() };
        let result = unsafe { sys::ghostty_terminal_grid_ref(self.raw, point, &mut out) };
        (result == sys::GHOSTTY_SUCCESS).then_some(out)
    }

    fn format(&mut self, opts: sys::GhosttyFormatterTerminalOptions) -> Result<Vec<u8>> {
        let mut formatter: sys::GhosttyFormatter = ptr::null_mut();
        check(unsafe {
            sys::ghostty_formatter_terminal_new(ptr::null(), &mut formatter, self.raw, opts)
        })?;
        let result = (|| {
            let mut needed: usize = 0;
            let query = unsafe {
                sys::ghostty_formatter_format_buf(formatter, ptr::null_mut(), 0, &mut needed)
            };
            if query != sys::GHOSTTY_OUT_OF_SPACE && query != sys::GHOSTTY_SUCCESS {
                check(query)?;
            }
            let mut buf = vec![0u8; needed.max(1)];
            let mut written: usize = 0;
            check(unsafe {
                sys::ghostty_formatter_format_buf(
                    formatter,
                    buf.as_mut_ptr(),
                    buf.len(),
                    &mut written,
                )
            })?;
            buf.truncate(written);
            Ok(buf)
        })();
        unsafe { sys::ghostty_formatter_free(formatter) };
        result
    }

    fn format_bounded(
        &mut self,
        opts: sys::GhosttyFormatterTerminalOptions,
        max_bytes: usize,
    ) -> Result<Option<Vec<u8>>> {
        let mut formatter: sys::GhosttyFormatter = ptr::null_mut();
        check(unsafe {
            sys::ghostty_formatter_terminal_new(ptr::null(), &mut formatter, self.raw, opts)
        })?;
        let result = (|| {
            let mut needed: usize = 0;
            let query = unsafe {
                sys::ghostty_formatter_format_buf(formatter, ptr::null_mut(), 0, &mut needed)
            };
            if query != sys::GHOSTTY_OUT_OF_SPACE && query != sys::GHOSTTY_SUCCESS {
                check(query)?;
            }
            if needed > max_bytes {
                return Ok(None);
            }
            let mut buf = vec![0u8; needed.max(1)];
            let mut written: usize = 0;
            check(unsafe {
                sys::ghostty_formatter_format_buf(
                    formatter,
                    buf.as_mut_ptr(),
                    buf.len(),
                    &mut written,
                )
            })?;
            buf.truncate(written);
            Ok(Some(buf))
        })();
        unsafe { sys::ghostty_formatter_free(formatter) };
        result
    }
}

fn configure_kitty_graphics(raw: sys::GhosttyTerminal) -> Result<()> {
    for (option, limit) in [
        (sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &DEFAULT_KITTY_IMAGE_STORAGE_LIMIT),
        (sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_COUNT_LIMIT, &DEFAULT_KITTY_IMAGE_COUNT_LIMIT),
        (
            sys::GHOSTTY_TERMINAL_OPT_KITTY_PLACEMENT_COUNT_LIMIT,
            &DEFAULT_KITTY_PLACEMENT_COUNT_LIMIT,
        ),
    ] {
        check(unsafe { sys::ghostty_terminal_set(raw, option, (limit as *const u64).cast()) })?;
    }
    let disabled = false;
    for option in [
        sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE,
        sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM,
    ] {
        check(unsafe {
            sys::ghostty_terminal_set(raw, option, (&disabled as *const bool).cast())
        })?;
    }
    // The temporary-file medium takes a GhosttyString directory; NULL disables
    // it. A pointer to a bool would be read as a 16-byte string.
    check(unsafe {
        sys::ghostty_terminal_set(
            raw,
            sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE,
            ptr::null(),
        )
    })?;
    Ok(())
}

fn minimal_vt_replay(max_bytes: usize) -> Vec<u8> {
    const RESET: &[u8] = b"\x1bc";
    if max_bytes >= RESET.len() { RESET.to_vec() } else { Vec::new() }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ReplayRowRange {
    start: u64,
    end: u64,
}

#[derive(Default)]
struct KittyReplayRowIndex {
    anchors: BTreeSet<u64>,
    // Merged inclusive spans avoid expanding attacker-controlled `grid_rows`
    // into one entry per occupied cell.
    occupied_spans: Vec<ReplayRowRange>,
}

impl KittyReplayRowIndex {
    fn insert(&mut self, row: u64, grid_rows: u32) {
        self.anchors.insert(row);
        self.occupied_spans.push(ReplayRowRange {
            start: row,
            end: row.saturating_add(u64::from(grid_rows.max(1)) - 1),
        });
    }

    fn finish(mut self) -> Self {
        self.occupied_spans.sort_by_key(|span| (span.start, span.end));
        let mut merged = Vec::<ReplayRowRange>::with_capacity(self.occupied_spans.len());
        for span in self.occupied_spans.drain(..) {
            if let Some(previous) = merged.last_mut()
                && span.start <= previous.end.saturating_add(1)
            {
                previous.end = previous.end.max(span.end);
            } else {
                merged.push(span);
            }
        }
        self.occupied_spans = merged;
        self
    }

    fn overlaps(&self, row: u64) -> bool {
        let insertion = self.occupied_spans.partition_point(|span| span.start <= row);
        insertion > 0 && self.occupied_spans[insertion - 1].end >= row
    }
}

#[cfg(test)]
impl FromIterator<u64> for KittyReplayRowIndex {
    fn from_iter<T: IntoIterator<Item = u64>>(rows: T) -> Self {
        let mut index = Self::default();
        for row in rows {
            index.insert(row, 1);
        }
        index.finish()
    }
}

struct ReplayText {
    bytes: Vec<u8>,
    range: Option<ReplayRowRange>,
    insertion_offsets: BTreeMap<u64, usize>,
}

impl ReplayText {
    fn minimal(max_bytes: usize) -> Self {
        Self {
            bytes: minimal_vt_replay(max_bytes),
            range: None,
            insertion_offsets: BTreeMap::new(),
        }
    }

    fn interleave(self, placements: &BTreeMap<u64, Vec<Vec<u8>>>) -> Option<Vec<u8>> {
        let placement_bytes = placements
            .values()
            .flatten()
            .try_fold(0usize, |total, command| total.checked_add(command.len()))?;
        let mut bytes = Vec::with_capacity(self.bytes.len().checked_add(placement_bytes)?);
        let mut copied = 0;
        for (row, offset) in self.insertion_offsets {
            if offset < copied || offset > self.bytes.len() {
                return None;
            }
            bytes.extend_from_slice(&self.bytes[copied..offset]);
            if let Some(commands) = placements.get(&row) {
                for command in commands {
                    bytes.extend_from_slice(command);
                }
            }
            copied = offset;
        }
        bytes.extend_from_slice(&self.bytes[copied..]);
        Some(bytes)
    }
}

struct KittyReplayPlacement<'a> {
    placement: &'a KittyPlacement,
    anchor: KittyPlacementAnchor,
}

struct KittyReplayImage<'a> {
    image: &'a KittyImage,
    transmission_len: usize,
    placements: Vec<KittyReplayPlacement<'a>>,
}

struct KittyReplayCatalog<'a> {
    images: Vec<KittyReplayImage<'a>>,
    placement_rows: KittyReplayRowIndex,
    cell_pixels: (u32, u32),
    terminal_rows: u16,
    #[cfg(test)]
    placement_grouping_visits: usize,
}

struct KittyReplayCandidate {
    image_index: usize,
    visible: bool,
    cost: usize,
    placements: Vec<(u64, Vec<u8>)>,
}

struct KittyReplayPlan {
    image_bytes: Vec<u8>,
    placements: BTreeMap<u64, Vec<Vec<u8>>>,
    aliases: Vec<KittyImageAlias>,
    total_len: usize,
}

impl<'a> KittyReplayCatalog<'a> {
    fn new(snapshot: &'a KittyReplaySnapshot, cell_pixels: (u32, u32), terminal_rows: u16) -> Self {
        let mut placements_by_image = HashMap::<u32, Vec<KittyReplayPlacement<'a>>>::new();
        let mut placement_rows = KittyReplayRowIndex::default();
        #[cfg(test)]
        let mut placement_grouping_visits = 0;
        for placement in &snapshot.graphics.placements {
            #[cfg(test)]
            {
                placement_grouping_visits += 1;
            }
            let Some(anchor) = snapshot.anchors.get(&placement.key).copied() else {
                continue;
            };
            placement_rows.insert(u64::from(anchor.row), placement.grid_rows);
            placements_by_image
                .entry(placement.image_id)
                .or_default()
                .push(KittyReplayPlacement { placement, anchor });
        }

        let mut images = snapshot.graphics.images.iter().collect::<Vec<_>>();
        images.sort_by_key(|image| (image.generation, image.id));
        let images = images
            .into_iter()
            .filter_map(|image| {
                Some(KittyReplayImage {
                    image,
                    transmission_len: kitty_replay_image_len(image)?,
                    placements: placements_by_image.remove(&image.id).unwrap_or_default(),
                })
            })
            .collect();
        Self {
            images,
            placement_rows: placement_rows.finish(),
            cell_pixels,
            terminal_rows,
            #[cfg(test)]
            placement_grouping_visits,
        }
    }

    fn visible_anchor_start(&self) -> Option<u64> {
        self.images
            .iter()
            .flat_map(|image| &image.placements)
            .filter(|placement| placement.placement.viewport_visible)
            .map(|placement| u64::from(placement.anchor.row))
            .min()
    }

    fn placement_rows(&self) -> &KittyReplayRowIndex {
        &self.placement_rows
    }

    fn visible_cost(&self, range: ReplayRowRange, max_bytes: usize) -> usize {
        self.plan_internal(Some(range), max_bytes, true, false).total_len
    }

    fn plan(
        &self,
        range: Option<ReplayRowRange>,
        max_bytes: usize,
        visible_only: bool,
    ) -> KittyReplayPlan {
        self.plan_internal(range, max_bytes, visible_only, true)
    }

    fn plan_internal(
        &self,
        range: Option<ReplayRowRange>,
        max_bytes: usize,
        visible_only: bool,
        encode_images: bool,
    ) -> KittyReplayPlan {
        let mut candidates = Vec::with_capacity(self.images.len());
        for (image_index, image) in self.images.iter().enumerate() {
            let mut visible = false;
            let mut placements = Vec::new();
            if let Some(range) = range {
                for replay_placement in &image.placements {
                    let row = u64::from(replay_placement.anchor.row);
                    let end = row
                        .saturating_add(u64::from(replay_placement.placement.grid_rows.max(1)) - 1);
                    if end < range.start || row > range.end {
                        continue;
                    }
                    let Some(command) = kitty_replay_placement_at(
                        replay_placement.placement,
                        replay_placement.anchor,
                        range.start,
                        self.terminal_rows,
                        self.cell_pixels,
                    ) else {
                        continue;
                    };
                    visible |= replay_placement.placement.viewport_visible;
                    placements.push((row.max(range.start), command));
                }
            }
            let Some(cost) =
                placements.iter().try_fold(image.transmission_len, |total, (_, command)| {
                    total.checked_add(command.len())
                })
            else {
                continue;
            };
            candidates.push(KittyReplayCandidate { image_index, visible, cost, placements });
        }

        let mut admitted = vec![false; candidates.len()];
        let mut total_len = 0usize;
        for require_visible in [true, false] {
            if visible_only && !require_visible {
                break;
            }
            for (index, candidate) in candidates.iter().enumerate() {
                if candidate.visible != require_visible {
                    continue;
                }
                let Some(next) = total_len.checked_add(candidate.cost) else {
                    continue;
                };
                if next > max_bytes {
                    continue;
                }
                admitted[index] = true;
                total_len = next;
            }
        }

        let mut numbered_history_counts = HashMap::<u32, (usize, usize)>::new();
        for image in &self.images {
            if image.image.number != 0 {
                numbered_history_counts.entry(image.image.number).or_default().0 += 1;
            }
        }
        for (candidate, is_admitted) in candidates.iter().zip(&admitted) {
            let image = &self.images[candidate.image_index];
            if *is_admitted && image.image.number != 0 {
                numbered_history_counts.entry(image.image.number).or_default().1 += 1;
            }
        }

        let mut image_bytes = Vec::new();
        let mut placements = BTreeMap::<u64, Vec<Vec<u8>>>::new();
        let mut aliases = Vec::new();
        for (candidate, admitted) in candidates.into_iter().zip(admitted) {
            if !admitted {
                continue;
            }
            let image = &self.images[candidate.image_index];
            if encode_images {
                append_kitty_replay_image(&mut image_bytes, image.image);
            }
            for (row, command) in candidate.placements {
                placements.entry(row).or_default().push(command);
            }
            if image.image.number != 0
                && numbered_history_counts
                    .get(&image.image.number)
                    .is_some_and(|(total, admitted)| total == admitted)
            {
                aliases.push(KittyImageAlias {
                    image_id: image.image.id,
                    image_number: image.image.number,
                });
            }
        }
        KittyReplayPlan { image_bytes, placements, aliases, total_len }
    }
}

fn kitty_replay_image_len(image: &KittyImage) -> Option<usize> {
    if image.data.is_empty() {
        return Some(0);
    }
    let encoded_len = image.data.len().checked_add(2)?.checked_div(3)?.checked_mul(4)?;
    let chunks = image.data.len().div_ceil(KITTY_REPLAY_RAW_CHUNK);
    let first_header = format!(
        "\x1b_Ga=t,t=d,f={},i={},s={},v={},q=2,m=0;",
        image.format.kitty_protocol_value(),
        image.id,
        image.width,
        image.height
    )
    .len();
    let continuation_header = b"\x1b_Gq=2,m=0;".len();
    encoded_len
        .checked_add(first_header)?
        .checked_add(2)?
        .checked_add((chunks - 1).checked_mul(continuation_header.checked_add(2)?)?)
}

fn append_kitty_replay_image(bytes: &mut Vec<u8>, image: &KittyImage) {
    if image.data.is_empty() {
        return;
    }
    #[cfg(test)]
    KITTY_REPLAY_IMAGE_ENCODINGS.set(KITTY_REPLAY_IMAGE_ENCODINGS.get() + 1);
    let mut payload = [0_u8; KITTY_REPLAY_CHUNK];
    for (index, chunk) in image.data.chunks(KITTY_REPLAY_RAW_CHUNK).enumerate() {
        let more = usize::from((index + 1) * KITTY_REPLAY_RAW_CHUNK < image.data.len());
        if index == 0 {
            bytes.extend_from_slice(
                format!(
                    "\x1b_Ga=t,t=d,f={},i={},s={},v={},q=2,m={more};",
                    image.format.kitty_protocol_value(),
                    image.id,
                    image.width,
                    image.height
                )
                .as_bytes(),
            );
        } else {
            bytes.extend_from_slice(format!("\x1b_Gq=2,m={more};").as_bytes());
        }
        let encoded = base64::engine::general_purpose::STANDARD
            .encode_slice(chunk, &mut payload)
            .expect("a 3:4-sized replay buffer must fit base64 output");
        bytes.extend_from_slice(&payload[..encoded]);
        bytes.extend_from_slice(b"\x1b\\");
    }
}

fn kitty_replay_placement_at(
    placement: &KittyPlacement,
    anchor: KittyPlacementAnchor,
    replay_start_row: u64,
    terminal_rows: u16,
    cell_pixels: (u32, u32),
) -> Option<Vec<u8>> {
    // The interleaved row break or final replay suffix positions the cursor
    // after this command. DECSC/DECRC would overwrite the application's one
    // saved-cursor slot while providing no additional replay state.
    let anchor_row = u64::from(anchor.row);
    if anchor_row >= replay_start_row {
        if placement.pixel_width == 0
            || placement.pixel_height == 0
            || placement.source_width == 0
            || placement.source_height == 0
        {
            return None;
        }
        let row = (anchor_row - replay_start_row)
            .min(u64::from(terminal_rows.saturating_sub(1)))
            .saturating_add(1);
        let col = u32::from(anchor.col).saturating_add(1);
        let placement_id = if placement.is_internal { 0 } else { placement.placement_id };
        let mut command = format!(
            "\x1b[{row};{col}H\x1b_Ga=p,i={},p={},x={},y={},w={},h={},X={},Y={}",
            placement.image_id,
            placement_id,
            placement.source_x,
            placement.source_y,
            placement.source_width,
            placement.source_height,
            placement.x_offset,
            placement.y_offset,
        );
        if placement.columns > 0 {
            command.push_str(&format!(",c={}", placement.columns));
        }
        if placement.rows > 0 {
            command.push_str(&format!(",r={}", placement.rows));
        }
        command.push_str(&format!(",z={},C=1,q=2;\x1b\\", placement.z));
        return Some(command.into_bytes());
    }
    let relative_row = i64::try_from(replay_start_row - anchor_row).ok()?.checked_neg()?;
    kitty_replay_placement_from_origin(placement, i64::from(anchor.col), relative_row, cell_pixels)
}

#[cfg(test)]
fn kitty_replay_placement(placement: &KittyPlacement, cell_pixels: (u32, u32)) -> Option<Vec<u8>> {
    kitty_replay_placement_from_origin(
        placement,
        i64::from(placement.viewport_col),
        i64::from(placement.viewport_row),
        cell_pixels,
    )
}

fn kitty_replay_placement_from_origin(
    placement: &KittyPlacement,
    viewport_col: i64,
    viewport_row: i64,
    cell_pixels: (u32, u32),
) -> Option<Vec<u8>> {
    if placement.pixel_width == 0
        || placement.pixel_height == 0
        || placement.source_width == 0
        || placement.source_height == 0
    {
        return None;
    }

    let cell_width = cell_pixels.0.max(1);
    let cell_height = cell_pixels.1.max(1);
    let image_left = viewport_col
        .saturating_mul(i64::from(cell_width))
        .saturating_add(i64::from(placement.x_offset));
    let image_top = viewport_row
        .saturating_mul(i64::from(cell_height))
        .saturating_add(i64::from(placement.y_offset));
    let image_right = image_left.saturating_add(i64::from(placement.pixel_width));
    let image_bottom = image_top.saturating_add(i64::from(placement.pixel_height));
    let visible_left = image_left.max(0);
    let visible_top = image_top.max(0);
    let mut visible_width = image_right.saturating_sub(visible_left);
    let mut visible_height = image_bottom.saturating_sub(visible_top);
    if visible_width <= 0 || visible_height <= 0 {
        return None;
    }
    if placement.columns > 0 {
        visible_width -= visible_width % i64::from(cell_width);
    }
    if placement.rows > 0 {
        visible_height -= visible_height % i64::from(cell_height);
    }
    if visible_width <= 0 || visible_height <= 0 {
        return None;
    }

    let source_left = replay_proportional_boundary(
        placement.source_width,
        u32::try_from(visible_left.saturating_sub(image_left)).ok()?,
        placement.pixel_width,
    );
    let source_right = replay_proportional_boundary(
        placement.source_width,
        u32::try_from(visible_left.saturating_add(visible_width).saturating_sub(image_left))
            .ok()?,
        placement.pixel_width,
    );
    let source_top = replay_proportional_boundary(
        placement.source_height,
        u32::try_from(visible_top.saturating_sub(image_top)).ok()?,
        placement.pixel_height,
    );
    let source_bottom = replay_proportional_boundary(
        placement.source_height,
        u32::try_from(visible_top.saturating_add(visible_height).saturating_sub(image_top)).ok()?,
        placement.pixel_height,
    );
    let source_x = placement.source_x.saturating_add(source_left);
    let source_y = placement.source_y.saturating_add(source_top);
    let mut source_width = source_right.saturating_sub(source_left);
    let mut source_height = source_bottom.saturating_sub(source_top);
    if source_width == 0 || source_height == 0 {
        return None;
    }

    let columns = if placement.columns > 0 {
        Some(u32::try_from(visible_width).ok()?.checked_div(cell_width)?)
    } else {
        None
    };
    let rows = if placement.rows > 0 {
        Some(u32::try_from(visible_height).ok()?.checked_div(cell_height)?)
    } else {
        None
    };
    if columns.is_some_and(|columns| columns == 0) || rows.is_some_and(|rows| rows == 0) {
        return None;
    }
    if columns.is_some() && rows.is_none() {
        source_height = replay_fit_inferred_source_dimension(
            columns?.saturating_mul(cell_width),
            source_width,
            source_height,
            u32::try_from(visible_height).ok()?,
        );
    } else if columns.is_none() && rows.is_some() {
        source_width = replay_fit_inferred_source_dimension(
            rows?.saturating_mul(cell_height),
            source_height,
            source_width,
            u32::try_from(visible_width).ok()?,
        );
    } else if columns.is_none() && rows.is_none() {
        source_width = source_width.min(u32::try_from(visible_width).ok()?);
        source_height = source_height.min(u32::try_from(visible_height).ok()?);
    }
    if source_width == 0 || source_height == 0 {
        return None;
    }

    let col = u32::try_from(visible_left).ok()?.checked_div(cell_width)?.saturating_add(1);
    let row = u32::try_from(visible_top).ok()?.checked_div(cell_height)?.saturating_add(1);
    let x_offset = u32::try_from(visible_left).ok()? % cell_width;
    let y_offset = u32::try_from(visible_top).ok()? % cell_height;
    let placement_id = if placement.is_internal { 0 } else { placement.placement_id };
    let mut command = format!(
        "\x1b[{row};{col}H\x1b_Ga=p,i={},p={},x={source_x},y={source_y},w={source_width},h={source_height},X={x_offset},Y={y_offset}",
        placement.image_id, placement_id
    );
    if let Some(columns) = columns {
        command.push_str(&format!(",c={columns}"));
    }
    if let Some(rows) = rows {
        command.push_str(&format!(",r={rows}"));
    }
    command.push_str(&format!(",z={},C=1,q=2;\x1b\\", placement.z));
    Some(command.into_bytes())
}

fn replay_proportional_boundary(
    source_pixels: u32,
    output_pixels: u32,
    rendered_pixels: u32,
) -> u32 {
    if rendered_pixels == 0 {
        return 0;
    }
    u32::try_from(
        u128::from(source_pixels) * u128::from(output_pixels) / u128::from(rendered_pixels),
    )
    .unwrap_or(source_pixels)
    .min(source_pixels)
}

fn replay_rounded_ratio(value: u32, numerator: u32, denominator: u32) -> Option<u32> {
    if denominator == 0 {
        return None;
    }
    u32::try_from(
        (u128::from(value) * u128::from(numerator) + u128::from(denominator) / 2)
            / u128::from(denominator),
    )
    .ok()
}

fn replay_fit_inferred_source_dimension(
    explicit_pixels: u32,
    fixed_source: u32,
    inferred_source: u32,
    maximum_pixels: u32,
) -> u32 {
    let mut low = 0;
    let mut high = inferred_source;
    while low < high {
        let candidate = low + (high - low).div_ceil(2);
        if replay_rounded_ratio(explicit_pixels, candidate, fixed_source)
            .is_some_and(|pixels| pixels <= maximum_pixels)
        {
            low = candidate;
        } else {
            high = candidate - 1;
        }
    }
    low
}

fn vt_replay_row_window(total_rows: u64, screen_rows: u64, cols: u16, max_bytes: usize) -> u64 {
    let estimated_row_bytes = u64::from(cols.max(1)) * VT_REPLAY_ESTIMATED_BYTES_PER_CELL;
    let budget_rows = u64::try_from(max_bytes).unwrap_or(u64::MAX) / estimated_row_bytes;
    budget_rows.max(screen_rows).min(total_rows)
}

impl Drop for Terminal {
    fn drop(&mut self) {
        unsafe {
            sys::ghostty_tracked_grid_ref_free(self.history_anchor);
            self.history_anchor = ptr::null_mut();
            self.history_markers.release();
            // Clear callbacks first so a hypothetical late invocation can't
            // touch the freed Box.
            sys::ghostty_terminal_set(self.raw, sys::GHOSTTY_TERMINAL_OPT_WRITE_PTY, ptr::null());
            sys::ghostty_terminal_set(
                self.raw,
                sys::GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
                ptr::null(),
            );
            sys::ghostty_terminal_set(self.raw, sys::GHOSTTY_TERMINAL_OPT_BELL, ptr::null());
            sys::ghostty_terminal_free(self.raw);
        }
    }
}

#[path = "terminal_history.rs"]
mod history;
pub use history::{HistoryPage, HistoryPages, HistorySnapshot, MarkerError};

#[cfg(test)]
#[path = "terminal_tests.rs"]
mod tests;
