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

static NEXT_TERMINAL_ID: AtomicU64 = AtomicU64::new(1);
static NEXT_HISTORY_EPOCH: AtomicU64 = AtomicU64::new(1);
const VT_REPLAY_ESTIMATED_BYTES_PER_CELL: u64 = 32;
const DEFAULT_KITTY_IMAGE_STORAGE_LIMIT: u64 = MAX_KITTY_IMAGE_BYTES as u64;
const DEFAULT_KITTY_IMAGE_COUNT_LIMIT: u64 = MAX_KITTY_IMAGES;
const DEFAULT_KITTY_PLACEMENT_COUNT_LIMIT: u64 = MAX_KITTY_PLACEMENTS;
const KITTY_REPLAY_CHUNK: usize = 4096;
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
    pub bytes: Vec<u8>,
    pub kitty_image_aliases: Vec<KittyImageAlias>,
    pub kitty_state: KittyReplayState,
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
}

/// Conservatively recognizes control sequences that can change Ghostty's
/// authoritative mouse modes. False positives only trigger a state query;
/// C0 controls and DEL remain inside CSI so valid split sequences cannot be
/// missed by this hot-path filter.
#[derive(Default)]
struct MouseModeChangeDetector {
    state: MouseModeChangeState,
    utf8_remaining: u8,
    csi_private: bool,
    csi_parameter: u16,
    csi_has_digits: bool,
    csi_has_mouse_mode: bool,
    csi_intermediate: Option<u8>,
    csi_invalid: bool,
}

#[derive(Default)]
enum MouseModeChangeState {
    #[default]
    Ground,
    Escape,
    Csi,
}

impl MouseModeChangeDetector {
    fn write(&mut self, data: &[u8]) -> bool {
        use MouseModeChangeState as State;

        let mut may_have_changed = false;
        for &byte in data {
            if matches!(self.state, State::Ground) {
                if self.consume_utf8_continuation(byte) {
                    continue;
                }
                self.note_utf8_lead(byte);
            }
            let state = std::mem::take(&mut self.state);
            self.state = match state {
                State::Ground => match byte {
                    0x1b => State::Escape,
                    0x9b => {
                        self.start_csi();
                        State::Csi
                    }
                    _ => State::Ground,
                },
                State::Escape => match byte {
                    b'[' => {
                        self.start_csi();
                        State::Csi
                    }
                    b'c' => {
                        may_have_changed = true;
                        State::Ground
                    }
                    0x1b => State::Escape,
                    0x00..=0x1f | 0x7f => State::Escape,
                    _ => State::Ground,
                },
                State::Csi => match byte {
                    0x1b => {
                        self.start_csi();
                        State::Escape
                    }
                    0x00..=0x1f | 0x7f => State::Csi,
                    b'?' if !self.csi_has_digits
                        && !self.csi_private
                        && self.csi_intermediate.is_none() =>
                    {
                        self.csi_private = true;
                        State::Csi
                    }
                    b'0'..=b'9' if self.csi_intermediate.is_none() => {
                        self.csi_has_digits = true;
                        self.csi_parameter = self
                            .csi_parameter
                            .saturating_mul(10)
                            .saturating_add(u16::from(byte - b'0'));
                        State::Csi
                    }
                    b';' if self.csi_intermediate.is_none() => {
                        self.finish_csi_parameter();
                        State::Csi
                    }
                    0x20..=0x2f if self.csi_intermediate.is_none() => {
                        self.finish_csi_parameter();
                        self.csi_intermediate = Some(byte);
                        State::Csi
                    }
                    0x40..=0x7e => {
                        self.finish_csi_parameter();
                        may_have_changed |= self.csi_changes_mouse_mode(byte);
                        self.start_csi();
                        State::Ground
                    }
                    _ => {
                        self.csi_invalid = true;
                        State::Csi
                    }
                },
            };
        }
        may_have_changed
    }

    fn start_csi(&mut self) {
        self.csi_private = false;
        self.csi_parameter = 0;
        self.csi_has_digits = false;
        self.csi_has_mouse_mode = false;
        self.csi_intermediate = None;
        self.csi_invalid = false;
    }

    fn finish_csi_parameter(&mut self) {
        if self.csi_has_digits && MOUSE_DEC_MODES.contains(&self.csi_parameter) {
            self.csi_has_mouse_mode = true;
        }
        self.csi_parameter = 0;
        self.csi_has_digits = false;
    }

    fn csi_changes_mouse_mode(&self, final_byte: u8) -> bool {
        if self.csi_invalid {
            return false;
        }
        let private_mouse_change = self.csi_private
            && self.csi_intermediate.is_none()
            && self.csi_has_mouse_mode
            && matches!(final_byte, b'h' | b'l' | b'r');
        let soft_reset =
            !self.csi_private && self.csi_intermediate == Some(b'!') && final_byte == b'p';
        private_mouse_change || soft_reset
    }

    fn consume_utf8_continuation(&mut self, byte: u8) -> bool {
        if self.utf8_remaining == 0 {
            return false;
        }
        if matches!(byte, 0x80..=0xbf) {
            self.utf8_remaining -= 1;
            true
        } else {
            self.utf8_remaining = 0;
            false
        }
    }

    fn note_utf8_lead(&mut self, byte: u8) {
        self.utf8_remaining = match byte {
            0xc2..=0xdf => 1,
            0xe0..=0xef => 2,
            0xf0..=0xf4 => 3,
            _ => 0,
        };
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
enum PromptSemantic {
    #[default]
    Unknown,
    Prompt,
    Input,
    InputUntilEndOfLine,
    Output,
}

#[derive(Default)]
struct PromptSemanticTracker {
    state: PromptTrackState,
    primary: PromptSemantic,
    alternate: PromptSemantic,
    alternate_active: bool,
    screen_modes: [bool; 3],
    saved_screen_modes: [bool; 3],
    revision: u64,
}

#[derive(Debug, Clone, Copy, Default)]
struct ScreenModeSelection {
    indices: [u8; 3],
    len: u8,
}

impl ScreenModeSelection {
    fn push(&mut self, mode: u16) {
        let Some(index) = PromptSemanticTracker::screen_mode_index(mode) else {
            return;
        };
        let index = index as u8;
        let len = usize::from(self.len);
        if let Some(position) = self.indices[..len].iter().position(|candidate| *candidate == index)
        {
            self.indices.copy_within(position + 1..len, position);
            self.len -= 1;
        }
        self.indices[usize::from(self.len)] = index;
        self.len += 1;
    }

    fn indices(&self) -> impl Iterator<Item = usize> + '_ {
        self.indices[..usize::from(self.len)].iter().map(|index| usize::from(*index))
    }

    fn is_empty(&self) -> bool {
        self.len == 0
    }
}

#[derive(Default)]
enum PromptTrackState {
    #[default]
    Ground,
    Escape,
    Osc(PromptOsc),
    OscEscape(PromptOsc),
    String,
    Csi {
        private: bool,
        at_start: bool,
        parameter: u16,
        has_parameter: bool,
        screen_modes: ScreenModeSelection,
    },
}

#[derive(Default)]
struct PromptOsc {
    prefix_len: u8,
    action: Option<u8>,
    options_started: bool,
    invalid: bool,
}

impl PromptOsc {
    fn feed(&mut self, byte: u8) {
        const PREFIX: &[u8] = b"133;";
        if self.invalid {
            return;
        }
        if usize::from(self.prefix_len) < PREFIX.len() {
            if byte == PREFIX[usize::from(self.prefix_len)] {
                self.prefix_len += 1;
            } else {
                self.invalid = true;
            }
            return;
        }
        if self.action.is_none() {
            self.action = Some(byte);
        } else if !self.options_started {
            if byte == b';' {
                self.options_started = true;
            } else {
                self.invalid = true;
            }
        }
    }

    fn valid_action(&self) -> Option<u8> {
        if self.invalid { None } else { self.action }
    }
}

impl PromptSemanticTracker {
    fn feed(&mut self, data: &[u8]) {
        for &byte in data {
            let state = std::mem::take(&mut self.state);
            self.state = match state {
                // The PTY stream is UTF-8. Accept only 7-bit ESC forms so
                // continuation bytes cannot masquerade as 8-bit C1 controls.
                PromptTrackState::Ground => match byte {
                    0x1b => PromptTrackState::Escape,
                    b'\n' | 0x0b | 0x0c => {
                        self.end_line();
                        PromptTrackState::Ground
                    }
                    _ => PromptTrackState::Ground,
                },
                PromptTrackState::Escape => match byte {
                    b']' => PromptTrackState::Osc(PromptOsc::default()),
                    b'[' => Self::csi(),
                    b'P' | b'X' | b'^' | b'_' => PromptTrackState::String,
                    b'D' | b'E' => {
                        self.end_line();
                        PromptTrackState::Ground
                    }
                    b'c' => {
                        self.primary = PromptSemantic::Unknown;
                        self.alternate = PromptSemantic::Unknown;
                        self.alternate_active = false;
                        self.screen_modes = [false; 3];
                        self.saved_screen_modes = [false; 3];
                        PromptTrackState::Ground
                    }
                    0x1b => PromptTrackState::Escape,
                    _ => PromptTrackState::Ground,
                },
                PromptTrackState::Osc(mut osc) => match byte {
                    0x07 => {
                        self.finish_osc(osc.valid_action());
                        PromptTrackState::Ground
                    }
                    0x18 | 0x1a => PromptTrackState::Ground,
                    0x1b => PromptTrackState::OscEscape(osc),
                    _ => {
                        osc.feed(byte);
                        PromptTrackState::Osc(osc)
                    }
                },
                PromptTrackState::OscEscape(osc) => {
                    if byte == b'\\' {
                        self.finish_osc(osc.valid_action());
                        PromptTrackState::Ground
                    } else if byte == 0x1b {
                        PromptTrackState::OscEscape(osc)
                    } else {
                        PromptTrackState::Ground
                    }
                }
                PromptTrackState::String => match byte {
                    0x18 | 0x1a => PromptTrackState::Ground,
                    0x1b => PromptTrackState::Escape,
                    _ => PromptTrackState::String,
                },
                PromptTrackState::Csi {
                    mut private,
                    mut at_start,
                    mut parameter,
                    mut has_parameter,
                    mut screen_modes,
                } => match byte {
                    b'?' if at_start => {
                        private = true;
                        at_start = false;
                        PromptTrackState::Csi {
                            private,
                            at_start,
                            parameter,
                            has_parameter,
                            screen_modes,
                        }
                    }
                    b'0'..=b'9' => {
                        at_start = false;
                        has_parameter = true;
                        parameter =
                            parameter.saturating_mul(10).saturating_add(u16::from(byte - b'0'));
                        PromptTrackState::Csi {
                            private,
                            at_start,
                            parameter,
                            has_parameter,
                            screen_modes,
                        }
                    }
                    b';' => {
                        if private && has_parameter {
                            screen_modes.push(parameter);
                        }
                        at_start = false;
                        parameter = 0;
                        has_parameter = false;
                        PromptTrackState::Csi {
                            private,
                            at_start,
                            parameter,
                            has_parameter,
                            screen_modes,
                        }
                    }
                    0x40..=0x7e => {
                        if private && has_parameter {
                            screen_modes.push(parameter);
                        }
                        self.apply_screen_modes(byte, screen_modes);
                        PromptTrackState::Ground
                    }
                    0x1b => PromptTrackState::Escape,
                    _ => PromptTrackState::Ground,
                },
            };
        }
    }

    fn csi() -> PromptTrackState {
        PromptTrackState::Csi {
            private: false,
            at_start: true,
            parameter: 0,
            has_parameter: false,
            screen_modes: ScreenModeSelection::default(),
        }
    }

    fn screen_mode_index(mode: u16) -> Option<usize> {
        match mode {
            47 => Some(0),
            1047 => Some(1),
            1049 => Some(2),
            _ => None,
        }
    }

    fn apply_screen_modes(&mut self, action: u8, screen_modes: ScreenModeSelection) {
        match action {
            b'h' | b'l' if !screen_modes.is_empty() => {
                let enabled = action == b'h';
                for index in screen_modes.indices() {
                    self.screen_modes[index] = enabled;
                    self.alternate_active = enabled;
                }
            }
            b's' => {
                for index in screen_modes.indices() {
                    self.saved_screen_modes[index] = self.screen_modes[index];
                }
            }
            b'r' => {
                for index in screen_modes.indices() {
                    let enabled = self.saved_screen_modes[index];
                    self.screen_modes[index] = enabled;
                    self.alternate_active = enabled;
                }
            }
            _ => {}
        }
    }

    fn semantic(&self, screen: Screen) -> PromptSemantic {
        match screen {
            Screen::Primary => self.primary,
            Screen::Alternate => self.alternate,
        }
    }

    fn revision(&self) -> u64 {
        self.revision
    }

    fn current_mut(&mut self) -> &mut PromptSemantic {
        if self.alternate_active { &mut self.alternate } else { &mut self.primary }
    }

    fn end_line(&mut self) {
        if *self.current_mut() == PromptSemantic::InputUntilEndOfLine {
            *self.current_mut() = PromptSemantic::Output;
        }
    }

    fn finish_osc(&mut self, action: Option<u8>) {
        let Some(action) = action else { return };
        let semantic = match action {
            b'A' | b'N' | b'P' => PromptSemantic::Prompt,
            b'B' => PromptSemantic::Input,
            b'I' => PromptSemantic::InputUntilEndOfLine,
            b'C' | b'D' => PromptSemantic::Output,
            _ => return,
        };
        *self.current_mut() = semantic;
        self.revision = self.revision.wrapping_add(1);
    }
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
}

#[derive(Default)]
struct KittyReplayPixelCache(HashMap<u64, Arc<[u8]>>);

/// Tracks whether Ghostty's persistent VT stream is between complete
/// sequences and UTF-8 code points.
///
/// Emulator-owned VT bytes may only be inserted at that boundary. The state
/// transitions mirror Ghostty's DEC ANSI parser, while ground-state bytes use
/// its UTF-8 stream behavior. Invalid UTF-8 may keep this tracker unsafe
/// slightly longer than Ghostty, but can never make an incomplete stream look
/// safe.
#[derive(Default)]
struct VtBoundaryTracker {
    state: VtBoundaryState,
    utf8_remaining: u8,
}

#[derive(Clone, Copy, Default, PartialEq, Eq)]
enum VtBoundaryState {
    #[default]
    Ground,
    Escape,
    EscapeIntermediate,
    CsiEntry,
    CsiIntermediate,
    CsiParam,
    CsiIgnore,
    DcsEntry,
    DcsParam,
    DcsIntermediate,
    DcsPassthrough,
    DcsIgnore,
    OscString,
    SosPmApcString,
}

impl VtBoundaryTracker {
    fn feed(&mut self, data: &[u8]) {
        for &byte in data {
            self.feed_byte(byte);
        }
    }

    fn is_safe(&self) -> bool {
        self.state == VtBoundaryState::Ground && self.utf8_remaining == 0
    }

    fn feed_byte(&mut self, byte: u8) {
        if self.consume_utf8_byte(byte) {
            return;
        }

        if self.state == VtBoundaryState::Ground {
            if byte == 0x1b {
                self.state = VtBoundaryState::Escape;
            }
            return;
        }

        self.state = match byte {
            0x18 | 0x1a | 0x80..=0x8f | 0x91..=0x97 | 0x99 | 0x9a | 0x9c => VtBoundaryState::Ground,
            0x1b => VtBoundaryState::Escape,
            0x98 | 0x9e | 0x9f => VtBoundaryState::SosPmApcString,
            0x9b => VtBoundaryState::CsiEntry,
            0x90 => VtBoundaryState::DcsEntry,
            0x9d => VtBoundaryState::OscString,
            _ => self.state.transition(byte),
        };
    }

    fn consume_utf8_byte(&mut self, byte: u8) -> bool {
        if self.utf8_remaining != 0 {
            if matches!(byte, 0x80..=0xbf) {
                self.utf8_remaining -= 1;
                return true;
            }
            // Ghostty replaces the incomplete code point and retries this byte
            // from the UTF-8 accept state.
            self.utf8_remaining = 0;
        }

        self.utf8_remaining = match byte {
            0xc2..=0xdf => 1,
            0xe0..=0xef => 2,
            0xf0..=0xf4 => 3,
            _ => 0,
        };
        self.utf8_remaining != 0
    }
}

impl VtBoundaryState {
    fn transition(self, byte: u8) -> Self {
        match self {
            Self::Ground => Self::Ground,
            Self::Escape => match byte {
                0x20..=0x2f => Self::EscapeIntermediate,
                0x30..=0x4f | 0x51..=0x57 | 0x59..=0x5a | 0x5c | 0x60..=0x7e => Self::Ground,
                0x50 => Self::DcsEntry,
                0x58 | 0x5e | 0x5f => Self::SosPmApcString,
                0x5b => Self::CsiEntry,
                0x5d => Self::OscString,
                _ => Self::Escape,
            },
            Self::EscapeIntermediate => {
                if matches!(byte, 0x30..=0x7e) {
                    Self::Ground
                } else {
                    self
                }
            }
            Self::CsiEntry => match byte {
                0x40..=0x7e => Self::Ground,
                0x3a => Self::CsiIgnore,
                0x20..=0x2f => Self::CsiIntermediate,
                0x30..=0x39 | 0x3b..=0x3f => Self::CsiParam,
                _ => self,
            },
            Self::CsiParam => match byte {
                0x40..=0x7e => Self::Ground,
                0x3c..=0x3f => Self::CsiIgnore,
                0x20..=0x2f => Self::CsiIntermediate,
                _ => self,
            },
            Self::CsiIntermediate => match byte {
                0x40..=0x7e => Self::Ground,
                0x30..=0x3f => Self::CsiIgnore,
                _ => self,
            },
            Self::CsiIgnore => {
                if matches!(byte, 0x40..=0x7e) {
                    Self::Ground
                } else {
                    self
                }
            }
            Self::DcsEntry => match byte {
                0x20..=0x2f => Self::DcsIntermediate,
                0x3a => Self::DcsIgnore,
                0x30..=0x39 | 0x3b..=0x3f => Self::DcsParam,
                0x40..=0x7e => Self::DcsPassthrough,
                _ => self,
            },
            Self::DcsParam => match byte {
                0x3a | 0x3c..=0x3f => Self::DcsIgnore,
                0x20..=0x2f => Self::DcsIntermediate,
                0x40..=0x7e => Self::DcsPassthrough,
                _ => self,
            },
            Self::DcsIntermediate => match byte {
                0x30..=0x3f => Self::DcsIgnore,
                0x40..=0x7e => Self::DcsPassthrough,
                _ => self,
            },
            Self::DcsPassthrough | Self::DcsIgnore | Self::SosPmApcString | Self::OscString => {
                if self == Self::OscString && byte == 0x07 {
                    Self::Ground
                } else {
                    self
                }
            }
        }
    }
}

/// Ghostty's parser intentionally treats bytes >= 0x80 as UTF-8 in ground
/// state, while PTYs can still emit 8-bit C1 control-string forms. Normalize
/// only standalone C1 control bytes; continuation bytes inside UTF-8 text
/// remain byte-for-byte unchanged.
#[derive(Default)]
struct C1Normalizer {
    utf8_remaining: u8,
}

impl C1Normalizer {
    fn normalize<'a>(&mut self, data: &'a [u8]) -> Cow<'a, [u8]> {
        let mut output: Option<Vec<u8>> = None;
        for (index, &byte) in data.iter().enumerate() {
            let continuation = if self.utf8_remaining != 0 && matches!(byte, 0x80..=0xbf) {
                self.utf8_remaining -= 1;
                true
            } else {
                self.utf8_remaining = 0;
                false
            };
            let replacement = (!continuation).then_some(byte).and_then(|byte| match byte {
                0x90 => Some(b'P'),
                0x98 => Some(b'X'),
                0x9d => Some(b']'),
                0x9e => Some(b'^'),
                0x9f => Some(b'_'),
                0x9c => Some(b'\\'),
                _ => None,
            });
            if let Some(replacement) = replacement {
                let output = output.get_or_insert_with(|| {
                    let mut output = Vec::with_capacity(data.len() + 1);
                    output.extend_from_slice(&data[..index]);
                    output
                });
                output.extend_from_slice(&[0x1b, replacement]);
            } else if let Some(output) = output.as_mut() {
                output.push(byte);
            }
            if !continuation {
                self.utf8_remaining = match byte {
                    0xc2..=0xdf => 1,
                    0xe0..=0xef => 2,
                    0xf0..=0xf4 => 3,
                    _ => 0,
                };
            }
        }
        output.map(Cow::Owned).unwrap_or(Cow::Borrowed(data))
    }
}

#[derive(Default)]
struct ColorOverrideTracker {
    state: ColorTrackState,
    utf8_remaining: u8,
    foreground: bool,
    background: bool,
    cursor: bool,
    palette: [u64; 4],
}

#[derive(Default)]
enum ColorTrackState {
    #[default]
    Ground,
    Escape,
    EscapeIntermediate,
    Osc {
        payload: Vec<u8>,
        overflowed: bool,
    },
    OscEscape {
        payload: Vec<u8>,
        overflowed: bool,
    },
    String,
    StringEscape,
}

impl ColorOverrideTracker {
    fn write(&mut self, data: &[u8]) {
        for &byte in data {
            let state = std::mem::take(&mut self.state);
            self.state = match state {
                ColorTrackState::Ground => self.ground(byte),
                ColorTrackState::Escape => self.escape(byte),
                ColorTrackState::EscapeIntermediate => match byte {
                    0x1b => ColorTrackState::Escape,
                    0x20..=0x2f => ColorTrackState::EscapeIntermediate,
                    _ => ColorTrackState::Ground,
                },
                ColorTrackState::Osc { mut payload, mut overflowed } => {
                    if self.consume_utf8_continuation(byte) {
                        Self::push_osc_byte(&mut payload, &mut overflowed, byte);
                        ColorTrackState::Osc { payload, overflowed }
                    } else {
                        match byte {
                            0x07 | 0x9c => {
                                self.finish_osc(&payload, overflowed);
                                ColorTrackState::Ground
                            }
                            0x1b => ColorTrackState::OscEscape { payload, overflowed },
                            _ => {
                                self.note_utf8_lead(byte);
                                Self::push_osc_byte(&mut payload, &mut overflowed, byte);
                                ColorTrackState::Osc { payload, overflowed }
                            }
                        }
                    }
                }
                ColorTrackState::OscEscape { mut payload, mut overflowed } => match byte {
                    b'\\' | 0x9c => {
                        self.utf8_remaining = 0;
                        self.finish_osc(&payload, overflowed);
                        ColorTrackState::Ground
                    }
                    0x1b => ColorTrackState::OscEscape { payload, overflowed },
                    _ => {
                        self.utf8_remaining = 0;
                        Self::push_osc_byte(&mut payload, &mut overflowed, 0x1b);
                        Self::push_osc_byte(&mut payload, &mut overflowed, byte);
                        self.note_utf8_lead(byte);
                        ColorTrackState::Osc { payload, overflowed }
                    }
                },
                ColorTrackState::String => {
                    if self.consume_utf8_continuation(byte) {
                        ColorTrackState::String
                    } else {
                        match byte {
                            0x9c => ColorTrackState::Ground,
                            0x1b => ColorTrackState::StringEscape,
                            _ => {
                                self.note_utf8_lead(byte);
                                ColorTrackState::String
                            }
                        }
                    }
                }
                ColorTrackState::StringEscape => match byte {
                    b'\\' | 0x9c => {
                        self.utf8_remaining = 0;
                        ColorTrackState::Ground
                    }
                    0x1b => ColorTrackState::StringEscape,
                    _ => {
                        self.note_utf8_lead(byte);
                        ColorTrackState::String
                    }
                },
            };
        }
    }

    fn ground(&mut self, byte: u8) -> ColorTrackState {
        if self.consume_utf8_continuation(byte) {
            return ColorTrackState::Ground;
        }
        match byte {
            0x1b => ColorTrackState::Escape,
            // A standalone 8-bit OSC is a control. A 0x9d occurring inside
            // UTF-8 text was consumed above and cannot open an OSC.
            0x9d => self.osc(),
            _ => {
                self.note_utf8_lead(byte);
                ColorTrackState::Ground
            }
        }
    }

    fn escape(&mut self, byte: u8) -> ColorTrackState {
        self.utf8_remaining = 0;
        match byte {
            b']' | 0x9d => self.osc(),
            b'P' | b'X' | b'^' | b'_' => ColorTrackState::String,
            b'c' => {
                self.reset_all();
                ColorTrackState::Ground
            }
            0x1b => ColorTrackState::Escape,
            0x20..=0x2f => ColorTrackState::EscapeIntermediate,
            _ => ColorTrackState::Ground,
        }
    }

    fn osc(&mut self) -> ColorTrackState {
        self.utf8_remaining = 0;
        ColorTrackState::Osc { payload: Vec::new(), overflowed: false }
    }

    fn push_osc_byte(payload: &mut Vec<u8>, overflowed: &mut bool, byte: u8) {
        if *overflowed {
            return;
        }
        if payload.len() == MAX_COLOR_OSC_BYTES {
            payload.clear();
            *overflowed = true;
        } else {
            payload.push(byte);
        }
    }

    fn consume_utf8_continuation(&mut self, byte: u8) -> bool {
        if self.utf8_remaining == 0 {
            return false;
        }
        if matches!(byte, 0x80..=0xbf) {
            self.utf8_remaining -= 1;
            true
        } else {
            self.utf8_remaining = 0;
            false
        }
    }

    fn note_utf8_lead(&mut self, byte: u8) {
        self.utf8_remaining = match byte {
            0xc2..=0xdf => 1,
            0xe0..=0xef => 2,
            0xf0..=0xf4 => 3,
            _ => 0,
        };
    }

    fn finish_osc(&mut self, payload: &[u8], overflowed: bool) {
        self.utf8_remaining = 0;
        if overflowed {
            return;
        }
        let Ok(payload) = std::str::from_utf8(payload) else { return };
        let mut parts = payload.split(';');
        let Some(command) = parts.next().and_then(|value| value.parse::<u16>().ok()) else {
            return;
        };
        match command {
            4 => {
                while let (Some(index), Some(value)) = (parts.next(), parts.next()) {
                    let Some(index) = index.parse::<u8>().ok() else { continue };
                    if value != "?" && parse_color(value).is_some() {
                        self.set_palette_authored(index as usize, true);
                    }
                }
            }
            104 => {
                let mut had_parameter = false;
                for value in parts {
                    had_parameter = true;
                    let Some(index) = value.parse::<u8>().ok() else {
                        continue;
                    };
                    self.set_palette_authored(index as usize, false);
                }
                if !had_parameter {
                    self.palette.fill(0);
                }
            }
            10..=12 => {
                for (offset, value) in parts.enumerate() {
                    let code = command.saturating_add(offset as u16);
                    if code > 12 {
                        break;
                    }
                    if value == "?" || parse_color(value).is_none() {
                        continue;
                    }
                    match code {
                        10 => self.foreground = true,
                        11 => self.background = true,
                        12 => self.cursor = true,
                        _ => unreachable!(),
                    }
                }
            }
            110 => self.foreground = false,
            111 => self.background = false,
            112 => self.cursor = false,
            _ => {}
        }
    }

    fn reset_all(&mut self) {
        self.foreground = false;
        self.background = false;
        self.cursor = false;
        self.palette.fill(0);
    }

    fn set_palette_authored(&mut self, index: usize, authored: bool) {
        let (word, bit) = (index / 64, index % 64);
        if authored {
            self.palette[word] |= 1u64 << bit;
        } else {
            self.palette[word] &= !(1u64 << bit);
        }
    }

    fn palette_authored(&self, index: usize) -> bool {
        self.palette[index / 64] & (1u64 << (index % 64)) != 0
    }
}

#[derive(Default)]
struct CursorOverrideTracker {
    state: CursorTrackState,
    active: bool,
}

#[derive(Default)]
enum CursorTrackState {
    #[default]
    Ground,
    Escape,
    EscapeIntermediate,
    Csi(CursorCsi),
    String {
        bell_terminated: bool,
    },
}

#[derive(Default)]
struct CursorCsi {
    value: u16,
    digits: bool,
    space: bool,
    invalid: bool,
}

impl CursorOverrideTracker {
    fn write(&mut self, data: &[u8]) {
        for &byte in data {
            let state = std::mem::take(&mut self.state);
            self.state = match state {
                CursorTrackState::Ground => self.ground(byte),
                CursorTrackState::Escape => self.escape(byte),
                CursorTrackState::EscapeIntermediate => match byte {
                    0x1b => CursorTrackState::Escape,
                    0x20..=0x2f => CursorTrackState::EscapeIntermediate,
                    _ => CursorTrackState::Ground,
                },
                CursorTrackState::Csi(mut csi) => self.csi(byte, &mut csi),
                CursorTrackState::String { bell_terminated } => match byte {
                    0x07 if bell_terminated => CursorTrackState::Ground,
                    0x9c => CursorTrackState::Ground,
                    0x18 | 0x1a => CursorTrackState::Ground,
                    0x1b => CursorTrackState::Escape,
                    _ => CursorTrackState::String { bell_terminated },
                },
            };
        }
    }

    fn ground(&mut self, byte: u8) -> CursorTrackState {
        // Ghostty's stream UTF-8-decodes in ground state, so 0x80..=0xff here
        // are text (UTF-8 lead/continuation bytes), never C1 controls — an
        // emoji like U+1F44D contains 0x9f and must not open a control
        // string. C1 openers are only honored inside escape-initiated states,
        // mirroring ghostty's ground handling.
        match byte {
            0x1b => CursorTrackState::Escape,
            _ => CursorTrackState::Ground,
        }
    }

    fn escape(&mut self, byte: u8) -> CursorTrackState {
        match byte {
            b'[' => CursorTrackState::Csi(CursorCsi::default()),
            b']' => CursorTrackState::String { bell_terminated: true },
            b'P' | b'X' | b'^' | b'_' => CursorTrackState::String { bell_terminated: false },
            b'c' => {
                self.active = false;
                CursorTrackState::Ground
            }
            0x1b => CursorTrackState::Escape,
            0x20..=0x2f => CursorTrackState::EscapeIntermediate,
            _ => CursorTrackState::Ground,
        }
    }

    fn csi(&mut self, byte: u8, csi: &mut CursorCsi) -> CursorTrackState {
        match byte {
            b'0'..=b'9' if !csi.space => {
                csi.digits = true;
                csi.value = csi.value.saturating_mul(10).saturating_add((byte - b'0') as u16);
                CursorTrackState::Csi(std::mem::take(csi))
            }
            0x30..=0x3f => {
                csi.invalid = true;
                CursorTrackState::Csi(std::mem::take(csi))
            }
            b' ' if !csi.space => {
                csi.space = true;
                CursorTrackState::Csi(std::mem::take(csi))
            }
            0x20..=0x2f => {
                csi.invalid = true;
                CursorTrackState::Csi(std::mem::take(csi))
            }
            b'q' => {
                if csi.space && !csi.invalid {
                    match (csi.digits, csi.value) {
                        (false, _) | (true, 0) => {
                            self.active = false;
                        }
                        (true, 1..=6) => self.active = true,
                        _ => {}
                    }
                }
                CursorTrackState::Ground
            }
            0x40..=0x7e => CursorTrackState::Ground,
            0x18 | 0x1a => CursorTrackState::Ground,
            0x1b => CursorTrackState::Escape,
            _ => CursorTrackState::Csi(std::mem::take(csi)),
        }
    }
}

struct PaletteOverrideTracker {
    state: PaletteTrackState,
    active: [bool; 256],
    revision: u64,
    reapply_revision: u64,
}

impl Default for PaletteOverrideTracker {
    fn default() -> Self {
        Self {
            state: PaletteTrackState::Ground,
            active: [false; 256],
            revision: 0,
            reapply_revision: 0,
        }
    }
}

#[derive(Default)]
enum PaletteTrackState {
    #[default]
    Ground,
    Escape,
    EscapeIntermediate,
    Osc(PaletteOsc),
    String {
        bell_terminated: bool,
    },
    Csi,
}

enum PaletteOsc {
    Operation { bytes: [u8; 3], len: u8, invalid: bool },
    Palette(Box<PaletteCommand>),
    Ignore,
}

impl Default for PaletteOsc {
    fn default() -> Self {
        Self::Operation { bytes: [0; 3], len: 0, invalid: false }
    }
}

struct PaletteCommand {
    mode: PaletteOscMode,
    token: [u8; Self::MAX_CAPTURE_BYTES],
    token_len: usize,
    captured: usize,
    pending: [u8; 256],
    request_count: usize,
    kitty_request_count: usize,
    stopped: bool,
    overflowed: bool,
    color_changed: bool,
}

impl PaletteCommand {
    const MAX_CAPTURE_BYTES: usize = 2048;

    fn new(mode: PaletteOscMode) -> Self {
        Self {
            mode,
            token: [0; Self::MAX_CAPTURE_BYTES],
            token_len: 0,
            captured: 0,
            pending: [0; 256],
            request_count: 0,
            kitty_request_count: 0,
            stopped: false,
            overflowed: false,
            color_changed: false,
        }
    }
}

#[derive(Default)]
enum PaletteOscMode {
    #[default]
    Ignore,
    SetIndex,
    SetColor(PaletteTarget),
    Reset,
    Kitty,
}

#[derive(Clone, Copy)]
enum PaletteTarget {
    Palette(u8),
    Special,
    Invalid,
}

impl PaletteOverrideTracker {
    fn write(&mut self, data: &[u8]) {
        for &byte in data {
            let state = std::mem::take(&mut self.state);
            self.state = match state {
                PaletteTrackState::Ground => match byte {
                    0x1b => PaletteTrackState::Escape,
                    _ => PaletteTrackState::Ground,
                },
                PaletteTrackState::Escape => match palette_c1_transition(byte) {
                    Some(state) => state,
                    None => match byte {
                        b']' => PaletteTrackState::Osc(PaletteOsc::default()),
                        b'P' | b'X' | b'^' | b'_' => {
                            PaletteTrackState::String { bell_terminated: false }
                        }
                        b'c' => {
                            // Ghostty preserves palette overrides across RIS, but
                            // attached byte frontends reset their mirror palette.
                            // Re-emit the authoritative sparse snapshot afterward.
                            self.revision = self.revision.wrapping_add(1);
                            self.reapply_revision = self.reapply_revision.wrapping_add(1);
                            PaletteTrackState::Ground
                        }
                        0x18 | 0x1a => PaletteTrackState::Ground,
                        0x1b => PaletteTrackState::Escape,
                        0x00..=0x17 | 0x19 | 0x1c..=0x1f | 0x7f => PaletteTrackState::Escape,
                        0x20..=0x2f => PaletteTrackState::EscapeIntermediate,
                        _ => PaletteTrackState::Ground,
                    },
                },
                PaletteTrackState::EscapeIntermediate => match palette_c1_transition(byte) {
                    Some(state) => state,
                    None => match byte {
                        0x18 | 0x1a => PaletteTrackState::Ground,
                        0x1b => PaletteTrackState::Escape,
                        0x00..=0x17 | 0x19 | 0x1c..=0x1f | 0x7f => {
                            PaletteTrackState::EscapeIntermediate
                        }
                        0x20..=0x2f => PaletteTrackState::EscapeIntermediate,
                        _ => PaletteTrackState::Ground,
                    },
                },
                PaletteTrackState::Osc(mut osc) => match byte {
                    0x07 | 0x18 | 0x1a => {
                        self.commit_osc(osc);
                        PaletteTrackState::Ground
                    }
                    0..=0x06 | 0x08..=0x17 | 0x19 | 0x1c..=0x1f => PaletteTrackState::Osc(osc),
                    0x1b => {
                        // Ghostty dispatches OSC on the ESC byte that begins
                        // ST, before the trailing `\\` arrives.
                        self.commit_osc(osc);
                        PaletteTrackState::Escape
                    }
                    _ => {
                        // Ghostty's OSC-specific 0x20...0xff parse-table row
                        // overrides the generic C1 transitions. Raw C1 bytes
                        // are OSC payload here, unlike in DCS/APC/CSI states.
                        osc.feed(byte);
                        PaletteTrackState::Osc(osc)
                    }
                },
                PaletteTrackState::String { bell_terminated } => {
                    match palette_c1_transition(byte) {
                        Some(state) => state,
                        None => match byte {
                            0x07 if bell_terminated => PaletteTrackState::Ground,
                            0x18 | 0x1a => PaletteTrackState::Ground,
                            0x1b => PaletteTrackState::Escape,
                            _ => PaletteTrackState::String { bell_terminated },
                        },
                    }
                }
                PaletteTrackState::Csi => match palette_c1_transition(byte) {
                    Some(state) => state,
                    None => match byte {
                        0x18 | 0x1a => PaletteTrackState::Ground,
                        0x1b => PaletteTrackState::Escape,
                        0x40..=0x7e => PaletteTrackState::Ground,
                        _ => PaletteTrackState::Csi,
                    },
                },
            };
        }
    }

    fn commit_osc(&mut self, osc: PaletteOsc) {
        if osc.commit(&mut self.active) {
            self.revision = self.revision.wrapping_add(1);
        }
    }
}

/// Ghostty's generic C1 transitions for parser states whose state-specific
/// table does not override them. Raw C1 bytes only reach this tracker after an
/// escape-initiated state; ground-state bytes pass through the UTF-8 decoder.
fn palette_c1_transition(byte: u8) -> Option<PaletteTrackState> {
    match byte {
        0x80..=0x8f | 0x91..=0x97 | 0x99 | 0x9a | 0x9c => Some(PaletteTrackState::Ground),
        0x90 | 0x98 | 0x9e | 0x9f => Some(PaletteTrackState::String { bell_terminated: false }),
        0x9b => Some(PaletteTrackState::Csi),
        0x9d => Some(PaletteTrackState::Osc(PaletteOsc::default())),
        _ => None,
    }
}

impl PaletteOsc {
    fn feed(&mut self, byte: u8) {
        match self {
            Self::Operation { bytes, len, invalid } => {
                if byte == b';' {
                    let mode = if *invalid {
                        None
                    } else {
                        match &bytes[..usize::from(*len)] {
                            b"4" => Some(PaletteOscMode::SetIndex),
                            b"104" => Some(PaletteOscMode::Reset),
                            b"21" => Some(PaletteOscMode::Kitty),
                            _ => None,
                        }
                    };
                    *self = mode
                        .map(|mode| Self::Palette(Box::new(PaletteCommand::new(mode))))
                        .unwrap_or(Self::Ignore);
                } else if usize::from(*len) < bytes.len() {
                    bytes[usize::from(*len)] = byte;
                    *len += 1;
                } else {
                    *invalid = true;
                }
            }
            Self::Palette(command) => command.feed(byte),
            Self::Ignore => {}
        }
    }

    fn commit(self, active: &mut [bool; 256]) -> bool {
        match self {
            Self::Operation { bytes, len, invalid: false }
                if &bytes[..usize::from(len)] == b"104" =>
            {
                active.fill(false);
                true
            }
            Self::Palette(command) => command.commit(active),
            Self::Operation { .. } | Self::Ignore => false,
        }
    }
}

impl PaletteCommand {
    fn feed(&mut self, byte: u8) {
        if self.stopped {
            return;
        }
        if self.captured == Self::MAX_CAPTURE_BYTES {
            self.stopped = true;
            self.overflowed = true;
            self.token_len = 0;
            return;
        }
        self.captured += 1;
        if byte == b';' {
            self.finish_token();
        } else {
            self.token[self.token_len] = byte;
            self.token_len += 1;
        }
    }

    fn finish_token(&mut self) {
        if self.stopped {
            self.token_len = 0;
            return;
        }
        let token = &self.token[..self.token_len];
        if matches!(self.mode, PaletteOscMode::Kitty) && self.kitty_request_count >= 526 {
            self.stopped = true;
            self.overflowed = true;
            self.token_len = 0;
            return;
        }
        // Ghostty tokenizes OSC color arguments with `tokenizeScalar`, which
        // skips empty parameters without advancing the index/color pairing.
        if token.is_empty() {
            return;
        }
        self.mode = match std::mem::take(&mut self.mode) {
            PaletteOscMode::SetIndex => {
                let target = Self::parse_target(token);
                if matches!(target, PaletteTarget::Invalid) {
                    self.stopped = true;
                }
                PaletteOscMode::SetColor(target)
            }
            PaletteOscMode::SetColor(target) => {
                if token != b"?" {
                    let valid = std::str::from_utf8(token).ok().and_then(parse_color).is_some();
                    if valid {
                        self.color_changed = true;
                        if let PaletteTarget::Palette(index) = target {
                            self.pending[index as usize] = 1;
                        }
                    } else {
                        self.stopped = true;
                    }
                }
                PaletteOscMode::SetIndex
            }
            PaletteOscMode::Reset => {
                if !token.is_empty() {
                    match Self::parse_target(token) {
                        PaletteTarget::Palette(index) => {
                            self.color_changed = true;
                            self.pending[index as usize] = 2;
                            self.request_count += 1;
                        }
                        PaletteTarget::Special => {
                            self.color_changed = true;
                            self.request_count += 1;
                        }
                        PaletteTarget::Invalid => {}
                    }
                }
                PaletteOscMode::Reset
            }
            PaletteOscMode::Kitty => {
                let separator = token.iter().position(|byte| *byte == b'=').unwrap_or(token.len());
                let key = &token[..separator];
                let value = token.get(separator + 1..).unwrap_or_default();
                let key = std::str::from_utf8(key).unwrap_or_default();
                let index = parse_zig_decimal(key.as_bytes(), u8::MAX.into(), false)
                    .map(|value| value as u8);
                let recognized = index.is_some()
                    || matches!(
                        key,
                        "foreground"
                            | "background"
                            | "selection_foreground"
                            | "selection_background"
                            | "cursor"
                            | "cursor_text"
                            | "visual_bell"
                            | "second_transparent_background"
                    );
                let value = std::str::from_utf8(trim_ascii_spaces(value)).ok();
                let accepted = recognized
                    && value.is_some_and(|value| {
                        value.is_empty() || value == "?" || parse_color(value).is_some()
                    });
                if accepted {
                    let value = value.expect("accepted Kitty color value must be valid UTF-8");
                    self.kitty_request_count += 1;
                    self.color_changed |= value != "?";
                    if value.is_empty()
                        && let Some(index) = index
                    {
                        self.pending[index as usize] = 2;
                    } else if value != "?"
                        && let Some(index) = index
                    {
                        self.pending[index as usize] = 1;
                    }
                }
                PaletteOscMode::Kitty
            }
            PaletteOscMode::Ignore => PaletteOscMode::Ignore,
        };
        self.token_len = 0;
    }

    fn parse_target(token: &[u8]) -> PaletteTarget {
        // Ghostty parses OSC 4/104 indices with Zig's `parseInt(u9, ..., 10)`,
        // including its sign and underscore grammar.
        let Some(value) = parse_zig_decimal(token, 0x1ff, true) else {
            return PaletteTarget::Invalid;
        };
        match value {
            0..=255 => PaletteTarget::Palette(value as u8),
            256..=260 => PaletteTarget::Special,
            _ => PaletteTarget::Invalid,
        }
    }

    fn commit(mut self: Box<Self>, active: &mut [bool; 256]) -> bool {
        if self.overflowed {
            return false;
        }
        self.finish_token();
        if self.overflowed {
            return false;
        }
        if matches!(self.mode, PaletteOscMode::Reset) && self.request_count == 0 {
            active.fill(false);
            return true;
        }
        for (active, pending) in active.iter_mut().zip(self.pending) {
            match pending {
                1 => *active = true,
                2 => *active = false,
                _ => {}
            }
        }
        self.color_changed
    }
}

/// Match Zig's decimal `parseInt`/`parseUnsigned` grammar used by Ghostty's
/// OSC color parsers without allocating a normalized copy of the token.
fn parse_zig_decimal(bytes: &[u8], max: u16, allow_sign: bool) -> Option<u16> {
    let (negative, digits) = match bytes.first().copied() {
        Some(b'+') if allow_sign => (false, &bytes[1..]),
        Some(b'-') if allow_sign => (true, &bytes[1..]),
        Some(_) => (false, bytes),
        None => return None,
    };
    if digits.is_empty() || digits.first() == Some(&b'_') || digits.last() == Some(&b'_') {
        return None;
    }

    let mut value = 0_u16;
    for byte in digits {
        if *byte == b'_' {
            continue;
        }
        let digit = u16::from(byte.checked_sub(b'0')?);
        if digit > 9 {
            return None;
        }
        value = value.checked_mul(10)?.checked_add(digit)?;
        if value > max {
            return None;
        }
    }
    if negative && value != 0 {
        return None;
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
        let opts =
            sys::GhosttyTerminalOptions { cols: cols.max(1), rows: rows.max(1), max_scrollback };
        check(unsafe { sys::ghostty_terminal_new(ptr::null(), &mut raw, opts) })?;
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
        unsafe { sys::ghostty_terminal_vt_write(self.raw, normalized.as_ptr(), normalized.len()) };
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
            && unsafe { sys::ghostty_terminal_vt_stream_is_ground(self.raw) }
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
        self.apply_vt_replay_parts(&replay.bytes, &replay.kitty_image_aliases, replay.kitty_state)
    }

    /// Apply replay bytes and their non-VT sidecar through the same ordering
    /// used by owned [`VtReplay`] values.
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
        Ok((
            self.get(sys::GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_FILE)?,
            self.get(sys::GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_TEMP_FILE)?,
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
        let mut out = false;
        let result = unsafe {
            sys::ghostty_terminal_mode_get(self.raw, sys::ghostty_mode_new(mode, ansi), &mut out)
        };
        result == sys::GHOSTTY_SUCCESS && out
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
    /// state, charsets, and tabstops. This is the attach primitive: a new
    /// frontend replays this, then follows the live pty stream.
    pub fn vt_replay(&mut self) -> Result<VtReplay> {
        self.vt_replay_bounded(usize::MAX)
    }

    /// Byte-only compatibility replay. This discards Kitty number aliases.
    pub fn vt_replay_bytes(&mut self) -> Result<Vec<u8>> {
        Ok(self.vt_replay()?.bytes)
    }

    /// Reject replay state that cannot fit under `max_bytes` regardless of
    /// text or completed graphics truncation. Callers can use this before a
    /// destructive geometry change, then build the full replay afterward.
    pub fn preflight_vt_replay_bounded(&self, max_bytes: usize) -> Result<()> {
        self.kitty_inflight.replay_prefix_fits(max_bytes)?;
        let suffix_len = self.mouse_format_replay_suffix().len();
        let prefix_len = self.kitty_inflight.replay_prefix_checked(max_bytes)?.len();
        if prefix_len.checked_add(suffix_len).is_none_or(|total| total > max_bytes) {
            return Err(Error::OutOfSpace);
        }
        Ok(())
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
        Ok(self.vt_replay_bounded_theme_portable_with_aliases(max_bytes)?.bytes)
    }

    /// Theme-portable replay retaining aliases for the Kitty images admitted
    /// by the bounded replay plan.
    pub fn vt_replay_bounded_theme_portable_with_aliases(
        &mut self,
        max_bytes: usize,
    ) -> Result<VtReplay> {
        self.vt_replay_bounded_with_palette(max_bytes, false)
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
        let inflight = self.kitty_inflight.replay_prefix_checked(max_bytes)?;
        let mouse_format_suffix = self.mouse_format_replay_suffix();
        let remaining = max_bytes
            .checked_sub(inflight.len())
            .and_then(|remaining| remaining.checked_sub(mouse_format_suffix.len()))
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
            .and_then(|total| total.checked_add(mouse_format_suffix.len()))
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
        // The formatter dumps DEC modes in numeric order, which destroys the
        // last-set-wins semantics of the extended mouse coordinate formats.
        // Reduce the flag dump to the single active selector so replay
        // reproduces the semantic, not the numeric flag order.
        bytes.extend_from_slice(&mouse_format_suffix);
        let replay_cursor_offset = u32::try_from(bytes.len()).map_err(|_| Error::OutOfSpace)?;
        bytes.extend_from_slice(&inflight);
        Ok(VtReplay {
            bytes,
            kitty_image_aliases: graphics.aliases,
            kitty_state: self.kitty_replay_state(replay_cursor_offset)?,
        })
    }

    /// Bounded byte-only compatibility replay. This discards Kitty aliases.
    pub fn vt_replay_bounded_bytes(&mut self, max_bytes: usize) -> Result<Vec<u8>> {
        Ok(self.vt_replay_bounded(max_bytes)?.bytes)
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
        let history_bearing = replay_rows > screen_rows;
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
                Self::vt_replay_segment_options(&selection, first, last, include_palette),
                remaining,
            )?
            else {
                return Ok(None);
            };
            emitted_breaks = emitted_breaks
                .saturating_add(chunk.windows(2).filter(|bytes| *bytes == b"\r\n").count());
            bytes.extend_from_slice(&chunk);
            if history_bearing {
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
                if bytes.len().saturating_add(2) > format_max_bytes {
                    return Ok(None);
                }
                bytes.extend_from_slice(b"\r\n");
                emitted_breaks = emitted_breaks.saturating_add(1);
                segment_start = segment_end.saturating_add(1);
            }
        }
        if history_bearing {
            // A history-bearing selection must advance once per row so the
            // reconstructed scrollback keeps Kitty anchors aligned. A
            // viewport-only selection may use direct cursor positioning for
            // sparse rows; padding that case would scroll visible text away.
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
        let origin_mode = self.mode(6, false);
        if !self.get::<bool>(sys::GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP).unwrap_or(false) {
            // The formatter already emits the cursor. An appended CUP would
            // reinterpret active-area coordinates relative to the scrolling
            // region while DECOM is enabled.
            if origin_mode {
                return Ok(None);
            }
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
        let mut suffix = if origin_mode {
            // The main formatter leaves the cursor at the authoritative cell.
            // Move only to a wide glyph's lead cell, using a relative motion
            // whose meaning is independent of the scrolling-region origin.
            let columns_left = x.saturating_sub(start_x);
            if columns_left == 0 {
                Vec::new()
            } else {
                format!("\x1b[{}D", u32::from(columns_left)).into_bytes()
            }
        } else {
            format!("\x1b[{};{}H", u32::from(y) + 1, u32::from(start_x) + 1).into_bytes()
        };
        suffix.extend_from_slice(&self.format(opts)?);
        Ok(Some(suffix))
    }

    fn vt_replay_segment_options(
        selection: &sys::GhosttySelection,
        first: bool,
        last: bool,
        include_palette: bool,
    ) -> sys::GhosttyFormatterTerminalOptions {
        let mut options = Self::vt_replay_options(Some(selection), include_palette);
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
    ) -> sys::GhosttyFormatterTerminalOptions {
        sys::GhosttyFormatterTerminalOptions {
            size: size_of::<sys::GhosttyFormatterTerminalOptions>(),
            emit: sys::GHOSTTY_FORMATTER_FORMAT_VT,
            unwrap: false,
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
        sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE,
        sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM,
    ] {
        check(unsafe {
            sys::ghostty_terminal_set(raw, option, (&disabled as *const bool).cast())
        })?;
    }
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

#[cfg(test)]
mod tests {
    use crate::kitty::{
        KittyGraphicsSnapshot, KittyImage, KittyImageAlias, KittyImageFormat, KittyPlacement,
        KittyPlacementAnchor, KittyPlacementKey, KittyReplaySnapshot,
    };

    use super::{
        C1Normalizer, Callbacks, ClearHistoryOutcome, KittyReplayCatalog, MouseModeChangeDetector,
        PaletteOsc, PromptSemantic, PromptSemanticTracker, PromptTrackState, Screen, Terminal,
        kitty_replay_image_encodings, kitty_replay_image_len, kitty_replay_placement,
        reset_kitty_replay_image_encodings, vt_replay_row_window,
    };

    fn replay_placement_fixture(
        source: (u32, u32),
        grid: (u32, u32),
        pixels: (u32, u32),
        sizing: (u32, u32),
        viewport: (i32, i32),
        offset: (u32, u32),
    ) -> KittyPlacement {
        KittyPlacement {
            key: KittyPlacementKey { image_id: 1, placement_id: 2, ordinal: 0 },
            image_id: 1,
            placement_id: 2,
            is_internal: false,
            x_offset: offset.0,
            y_offset: offset.1,
            source_x: 0,
            source_y: 0,
            source_width: source.0,
            source_height: source.1,
            columns: sizing.0,
            rows: sizing.1,
            grid_cols: grid.0,
            grid_rows: grid.1,
            pixel_width: pixels.0,
            pixel_height: pixels.1,
            viewport_col: viewport.0,
            viewport_row: viewport.1,
            viewport_visible: true,
            anchor: None,
            z: 3,
        }
    }

    fn replay_placement_command(placement: &KittyPlacement) -> String {
        String::from_utf8(kitty_replay_placement(placement, (10, 20)).unwrap()).unwrap()
    }

    #[test]
    fn unrelated_osc_tracking_keeps_palette_state_out_of_line() {
        assert!(size_of::<PaletteOsc>() <= 16);
    }

    #[test]
    fn prompt_semantic_tracking_does_not_buffer_unrelated_osc_payloads() {
        let mut tracker = PromptSemanticTracker::default();

        tracker.feed(b"\x1b]0;");
        tracker.feed(&vec![b'x'; 4 * 1024]);

        assert!(size_of::<PromptTrackState>() <= 16);
        assert!(matches!(tracker.state, PromptTrackState::Osc(_)));
    }

    #[test]
    fn terminal_instances_have_lifetime_stable_ids() {
        let first = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        let second = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();

        assert_ne!(first.instance_id(), second.instance_id());
    }

    #[test]
    fn history_epoch_ignores_output_that_only_mutates_the_active_screen() {
        let mut terminal = Terminal::new(8, 2, 1_000, Callbacks::default()).unwrap();
        let initial = terminal.history_epoch();

        terminal.vt_write(b"visible");
        terminal.vt_write(b"\x1b[H\x1b[2K\x1b]2;title\x07");

        assert_eq!(terminal.history_rows(), 0);
        assert_eq!(terminal.history_epoch(), initial);

        terminal.vt_write(b"first\r\nsecond\r\nthird");
        assert!(terminal.history_rows() > 0);
        assert!(terminal.history_epoch() > initial);
    }

    #[test]
    fn history_epoch_ignores_kitty_content_updates_that_do_not_move_history() {
        let mut terminal = Terminal::new(8, 2, 1_000, Callbacks::default()).unwrap();
        terminal.vt_write(b"first\r\nsecond\r\nthird");
        assert!(terminal.history_rows() > 0);
        let history_epoch = terminal.history_epoch();

        terminal.vt_write(b"\x1b_Ga=T,t=d,f=24,i=8,p=1,s=1,v=1,c=1,r=1,C=1,q=2;/wAA\x1b\\");
        terminal.vt_write(b"\x1b_Ga=T,t=d,f=24,i=8,p=1,s=1,v=1,c=1,r=1,C=1,q=2;AP8A\x1b\\");

        assert_eq!(terminal.history_epoch(), history_epoch);
    }

    #[test]
    fn history_epochs_change_across_mutations_and_terminal_instances() {
        let mut first = Terminal::new(8, 2, 1_000, Callbacks::default()).unwrap();
        let initial = first.history_epoch();
        first.vt_write(b"first\r\nsecond\r\nthird");
        let after_output = first.history_epoch();
        first.resize(40, 12, 8, 16).unwrap();
        let after_resize = first.history_epoch();
        let second = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();

        assert!(after_output > initial);
        assert!(after_resize > after_output);
        assert_ne!(second.history_epoch(), after_resize);
    }

    #[test]
    fn ordinary_output_does_not_probe_unchanged_ambiguous_mouse_modes() {
        let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?1015h");
        let probes_after_modes = terminal.mouse_mode_probe.signature_calls();

        for _ in 0..128 {
            terminal.vt_write(b"ordinary application output\r\n");
        }

        assert_eq!(
            terminal.mouse_mode_probe.signature_calls(),
            probes_after_modes,
            "ordinary PTY output must not run synthetic mouse encodes"
        );
    }

    #[test]
    fn unrelated_dec_modes_do_not_probe_ambiguous_mouse_modes() {
        let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?1015h");
        let probes_after_modes = terminal.mouse_mode_probe.signature_calls();

        for _ in 0..128 {
            terminal.vt_write(b"\x1b[?2026hpaint\x1b[?2026l");
        }

        assert_eq!(
            terminal.mouse_mode_probe.signature_calls(),
            probes_after_modes,
            "synchronized-output framing must not run synthetic mouse encodes"
        );
    }

    /// Encode a left press, its release, and a wheel-up through encoders
    /// synced from `terminal`, exactly like a scoped attach client forwarding
    /// host clicks to the inner PTY.
    fn synced_mouse_bytes(terminal: &Terminal) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
        use crate::key::Mods;
        use crate::mouse::{MouseAction, MouseButton, MouseEncoders, MouseInput};

        let input = |action, button, any_button_pressed| MouseInput {
            action,
            button,
            mods: Mods::default(),
            position: (36.5, 20.5),
            screen_size: (80, 24),
            cell_size: (1, 1),
            any_button_pressed,
        };
        let mut encoders = MouseEncoders::new().unwrap();
        encoders.sync_from_terminal(terminal);
        let (mut press, mut release, mut wheel) = (Vec::new(), Vec::new(), Vec::new());
        encoders
            .encode_press_pair(
                input(MouseAction::Press, Some(MouseButton::Left), true),
                input(MouseAction::Release, Some(MouseButton::Left), false),
                &mut press,
                &mut release,
            )
            .unwrap();
        encoders
            .encode(input(MouseAction::Press, Some(MouseButton::WheelUp), false), &mut wheel)
            .unwrap();
        (press, release, wheel)
    }

    fn replayed_mirror(inner_mode_bytes: &[u8]) -> Terminal {
        let mut host = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        host.vt_write(inner_mode_bytes);
        let replay = host.vt_replay().unwrap();
        let mut mirror = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        mirror.apply_vt_replay(&replay).unwrap();
        mirror
    }

    /// btop enables 1002h, 1015h, 1006h in that order: SGR is set last, so
    /// last-set-wins makes SGR the active extended-coordinate encoding.
    /// Replay must reproduce that semantic, not a numeric flag dump that
    /// re-enables urxvt (1015) after SGR (1006) and flips the active encoding.
    #[test]
    fn replay_preserves_sgr_mouse_encoding_when_sgr_is_set_last() {
        let mirror = replayed_mirror(b"\x1b[?1002h\x1b[?1015h\x1b[?1006h");
        let (press, release, wheel) = synced_mouse_bytes(&mirror);
        assert_eq!(press, b"\x1b[<0;37;21M", "press must stay SGR after replay");
        assert_eq!(release, b"\x1b[<0;37;21m", "release must stay SGR after replay");
        assert_eq!(wheel, b"\x1b[<64;37;21M", "wheel must stay SGR after replay");
    }

    /// The mirror case: an application that deliberately sets urxvt last must
    /// keep urxvt across replay.
    #[test]
    fn replay_preserves_urxvt_mouse_encoding_when_urxvt_is_set_last() {
        let mirror = replayed_mirror(b"\x1b[?1002h\x1b[?1006h\x1b[?1015h");
        let (press, release, wheel) = synced_mouse_bytes(&mirror);
        assert_eq!(press, b"\x1b[32;37;21M", "press must stay urxvt after replay");
        assert_eq!(release, b"\x1b[35;37;21M", "release must stay urxvt after replay");
        assert_eq!(wheel, b"\x1b[96;37;21M", "wheel must stay urxvt after replay");
    }

    /// The active wire format is a single last-set-wins selector; resetting
    /// the active selector falls back to X10 even while other format flags
    /// stay set (xterm semantics, mirrored by Ghostty's stream handler).
    #[test]
    fn active_mouse_format_tracks_last_set_wins() {
        use crate::mouse::MouseWireFormat;

        let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        assert_eq!(terminal.active_mouse_format(), MouseWireFormat::X10);
        terminal.vt_write(b"\x1b[?1005h");
        assert_eq!(terminal.active_mouse_format(), MouseWireFormat::Utf8);
        terminal.vt_write(b"\x1b[?1015h");
        assert_eq!(terminal.active_mouse_format(), MouseWireFormat::Urxvt);
        terminal.vt_write(b"\x1b[?1006h");
        assert_eq!(terminal.active_mouse_format(), MouseWireFormat::Sgr);
        assert_eq!(terminal.pointer_semantic_snapshot().active_mouse_format, MouseWireFormat::Sgr);
        terminal.vt_write(b"\x1b[?1016h");
        assert_eq!(terminal.active_mouse_format(), MouseWireFormat::SgrPixels);
        terminal.vt_write(b"\x1b[?1016l");
        assert_eq!(terminal.active_mouse_format(), MouseWireFormat::X10);
    }

    /// A single-format application must not grow a correction suffix: its
    /// numeric flag dump already replays the right active encoding.
    #[test]
    fn single_format_replay_carries_no_mouse_format_suffix() {
        let mut host = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        host.vt_write(b"\x1b[?1002h\x1b[?1006h");
        assert!(host.mouse_format_replay_suffix().is_empty());
        let replay = host.vt_replay_bytes().unwrap();
        let text = String::from_utf8_lossy(&replay);
        assert!(!text.contains("[?1006l"), "suffix must not reset the only format");
        assert_eq!(text.matches("[?1006h").count(), 1, "active selector emitted once");
    }

    #[test]
    fn replay_preflight_reserves_mouse_suffix_at_exact_boundary() {
        let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b[?1006h\x1b[?1015h\x1b[?1006h");
        let suffix_len = terminal.mouse_format_replay_suffix().len();
        assert!(suffix_len > 0);
        assert!(terminal.preflight_vt_replay_bounded(suffix_len).is_ok());
        assert!(terminal.preflight_vt_replay_bounded(suffix_len - 1).is_err());
    }

    #[test]
    fn mouse_mode_detector_keeps_controls_inside_escape_and_csi() {
        let mut detector = MouseModeChangeDetector::default();

        assert!(!detector.write(b"\x1b\x07[?100"));
        assert!(detector.write(b"6\x7fh"));
        assert!(!detector.write(&[0xc4]));
        assert!(!detector.write(&[0x9b, b'h']), "UTF-8 continuation must not open CSI");
        assert!(detector.write(b"\x1b\x07c"), "C0 controls must not hide a hard reset");
    }

    #[test]
    fn cursor_prompt_detection_requires_primary_screen_semantic_metadata() {
        let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"ordinary output");
        assert!(!terminal.cursor_is_at_prompt());

        terminal.vt_write(b"\r\n\x1b]133;A\x07prompt> \x1b]133;B\x07pending");
        assert!(terminal.cursor_is_at_prompt());

        terminal.vt_write(b"\x1b[?1049h");
        assert_eq!(terminal.active_screen(), Screen::Alternate);
        assert!(!terminal.cursor_is_at_prompt());
    }

    #[test]
    fn cursor_prompt_detection_follows_live_semantics_after_input_wraps() {
        let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07123456789\x1b[B");

        assert!(terminal.cursor_is_at_prompt());

        terminal.vt_write(b"\x1b]133;C\x07\x1b[B");
        assert!(!terminal.cursor_is_at_prompt());
    }

    #[test]
    fn cursor_prompt_detection_keeps_primary_semantics_out_of_alternate_screen() {
        let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07pending");
        assert!(terminal.cursor_is_at_prompt());

        terminal.vt_write(b"\x1b[?1049h\x1b]133;C\x07");
        assert!(!terminal.cursor_is_at_prompt());

        terminal.vt_write(b"\x1b[?1049l");
        assert!(terminal.cursor_is_at_prompt());
    }

    #[test]
    fn cursor_prompt_detection_follows_saved_private_screen_mode() {
        let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07pending");
        assert!(terminal.cursor_is_at_prompt());

        terminal.vt_write(b"\x1b[?1049s\x1b[?1049h\x1b]133;C\x07\x1b[?1049r");

        assert_eq!(terminal.active_screen(), Screen::Primary);
        assert!(terminal.cursor_is_at_prompt());

        terminal.vt_write(b"\x1b]133;C\x07");
        assert!(!terminal.cursor_is_at_prompt());
    }

    #[test]
    fn cursor_prompt_detection_saves_private_screen_modes_independently() {
        let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07pending");
        assert!(terminal.cursor_is_at_prompt());

        terminal.vt_write(b"\x1b[?47h\x1b[?1049s\x1b[?1049r");

        assert_eq!(terminal.active_screen(), Screen::Primary);
        assert!(terminal.cursor_is_at_prompt());
        terminal.vt_write(b"\x1b]133;C\x07");
        assert!(!terminal.cursor_is_at_prompt());
    }

    #[test]
    fn cursor_prompt_detection_restores_private_screen_modes_in_wire_order() {
        let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07pending");
        terminal.vt_write(b"\x1b[?47h\x1b]133;C\x07\x1b[?47s\x1b[?47l\x1b[?1049s");

        terminal.vt_write(b"\x1b[?47;1049r");
        assert_eq!(terminal.active_screen(), Screen::Primary);
        assert!(terminal.cursor_is_at_prompt());

        terminal.vt_write(b"\x1b[?1049;47r");
        assert_eq!(terminal.active_screen(), Screen::Alternate);
        terminal.vt_write(b"\x1b]133;C\x07\x1b[?47l");
        assert_eq!(terminal.active_screen(), Screen::Primary);
        assert!(terminal.cursor_is_at_prompt());
    }

    #[test]
    fn clear_history_preserves_the_active_prompt_and_cursor() {
        let mut terminal = Terminal::new(20, 4, 1_000, Callbacks::default()).unwrap();
        for line in 0..10 {
            terminal.vt_write(format!("history-{line}\r\n").as_bytes());
        }
        terminal.vt_write(b"\x1b]133;A\x07prompt> \x1b]133;B\x07pending");
        let cursor_before = terminal.cursor_position();

        let ClearHistoryOutcome::Cleared(clear) = terminal.clear_history_preserving_prompt() else {
            panic!("active prompt was wholly inside the viewport");
        };

        assert_eq!(terminal.history_rows(), 0);
        assert_eq!(terminal.cursor_position(), cursor_before);
        let viewport = terminal.viewport_text().unwrap();
        assert!(viewport.contains("prompt> pending"));
        assert!(!viewport.contains("history-"));
        assert!(!clear.contains(&b'\x0c'));
    }

    #[test]
    fn clear_history_fails_closed_when_pending_wrap_cannot_be_restored() {
        let mut terminal = Terminal::new(10, 3, 1_000, Callbacks::default()).unwrap();
        for line in 0..5 {
            terminal.vt_write(format!("old-{line}\r\n").as_bytes());
        }
        terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x0712345678");
        assert!(terminal.cursor_pending_wrap());
        let viewport_before = terminal.viewport_text().unwrap();

        let ClearHistoryOutcome::Cleared(clear) = terminal.clear_history_preserving_prompt() else {
            panic!("pending-wrap prompt was wholly inside the viewport");
        };

        assert_eq!(clear, b"\x1b[3J");
        assert_eq!(terminal.history_rows(), 0);
        assert_eq!(terminal.viewport_text().unwrap(), viewport_before);
        assert!(terminal.cursor_pending_wrap());
    }

    #[test]
    fn clear_history_leaves_viewport_spanning_active_input_intact() {
        let mut terminal = Terminal::new(8, 3, 1_000, Callbacks::default()).unwrap();
        for line in 0..5 {
            terminal.vt_write(format!("old-{line}\r\n").as_bytes());
        }
        terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07123456789012345678901234567");
        let history_before = terminal.history_rows();
        let contents_before = terminal.plain_text().unwrap();

        let outcome = terminal.clear_history_preserving_prompt();

        assert_eq!(outcome, ClearHistoryOutcome::Unchanged);
        assert!(history_before > 0);
        assert_eq!(terminal.history_rows(), history_before);
        assert_eq!(terminal.plain_text().unwrap(), contents_before);
    }

    #[test]
    fn clear_history_rejects_prompt_continuations_whose_prompt_row_is_in_history() {
        let mut terminal = Terminal::new(16, 4, 1_000, Callbacks::default()).unwrap();
        for line in 0..6 {
            terminal.vt_write(format!("old-{line}\r\n").as_bytes());
        }
        terminal.vt_write(
            b"\x1b]133;A\x07$ \x1b]133;B\x07active-one\r\nactive-two\r\nactive-three\r\nactive-four\r\nactive-five",
        );
        let history_before = terminal.history_rows();
        let contents_before = terminal.plain_text().unwrap();
        let cursor_y = terminal.cursor_position().unwrap().1;
        assert!(terminal.cursor_is_at_prompt());
        assert_eq!(terminal.active_prompt_start_row(cursor_y), None);

        let outcome = terminal.clear_history_preserving_prompt();

        assert_eq!(outcome, ClearHistoryOutcome::Unchanged);
        assert!(history_before > 0);
        assert_eq!(terminal.history_rows(), history_before);
        assert_eq!(terminal.plain_text().unwrap(), contents_before);
    }

    #[test]
    fn clear_history_rejects_repeated_prompt_markers_that_begin_in_history() {
        let mut terminal = Terminal::new(16, 4, 1_000, Callbacks::default()).unwrap();
        for line in 0..6 {
            terminal.vt_write(format!("old-{line}\r\n").as_bytes());
        }
        terminal.vt_write(
            b"\x1b]133;A\x07prompt-one\r\n\
              \x1b]133;A\x07prompt-two\r\n\
              \x1b]133;A\x07prompt-three\r\n\
              \x1b]133;A\x07prompt-four\r\n\
              \x1b]133;A\x07prompt-five\x1b]133;B\x07pending",
        );
        let history_before = terminal.history_rows();
        let contents_before = terminal.plain_text().unwrap();
        let cursor_y = terminal.cursor_position().unwrap().1;
        assert!(terminal.cursor_is_at_prompt());
        assert_eq!(terminal.active_prompt_start_row(cursor_y), Some(0));

        let outcome = terminal.clear_history_preserving_prompt();

        assert_eq!(outcome, ClearHistoryOutcome::Unchanged);
        assert!(history_before > 0);
        assert_eq!(terminal.history_rows(), history_before);
        assert_eq!(terminal.plain_text().unwrap(), contents_before);
    }

    #[test]
    fn clear_history_accepts_row_zero_prompt_after_output_history() {
        let mut terminal = Terminal::new(32, 4, 1_000, Callbacks::default()).unwrap();
        for line in 0..6 {
            terminal.vt_write(format!("old-{line}\r\n").as_bytes());
        }
        terminal.vt_write(
            b"\x1b]133;A\x07prompt-one\r\n\
              \x1b]133;A\x07prompt-two\r\n\
              \x1b]133;A\x07prompt-three\r\n\
              \x1b]133;A\x07prompt-four\x1b]133;B\x07pending",
        );
        let history_before = terminal.history_rows();
        let viewport_before = terminal.viewport_text().unwrap();
        let cursor_before = terminal.cursor_position();
        let cursor_y = cursor_before.unwrap().1;
        assert!(terminal.cursor_is_at_prompt());
        assert_eq!(terminal.active_prompt_start_row(cursor_y), Some(0));

        let outcome = terminal.clear_history_preserving_prompt();

        assert_eq!(outcome, ClearHistoryOutcome::Cleared(b"\x1b[3J".to_vec()));
        assert!(history_before > 0);
        assert_eq!(terminal.history_rows(), 0);
        assert_eq!(terminal.viewport_text().unwrap(), viewport_before);
        assert_eq!(terminal.cursor_position(), cursor_before);
    }

    #[test]
    fn clear_history_without_prompt_metadata_clears_scrollback_only() {
        let mut terminal = Terminal::new(16, 4, 1_000, Callbacks::default()).unwrap();
        for line in 0..6 {
            terminal.vt_write(format!("old-{line}\r\n").as_bytes());
        }
        terminal.vt_write(b"first-active\r\nsecond-active");
        let history_before = terminal.history_rows();
        let viewport_before = terminal.viewport_text().unwrap();
        let cursor_before = terminal.cursor_position();

        let outcome = terminal.clear_history_preserving_prompt();

        assert_eq!(outcome, ClearHistoryOutcome::Cleared(b"\x1b[3J".to_vec()));
        assert!(history_before > 0);
        assert_eq!(terminal.history_rows(), 0);
        assert_eq!(terminal.viewport_text().unwrap(), viewport_before);
        assert_eq!(terminal.cursor_position(), cursor_before);
    }

    #[test]
    fn clear_history_without_prompt_metadata_preserves_visible_hard_newline_rows() {
        let mut terminal = Terminal::new(16, 4, 1_000, Callbacks::default()).unwrap();
        for line in 0..6 {
            terminal.vt_write(format!("old-{line}\r\n").as_bytes());
        }
        terminal.vt_write(b"active-one\r\nactive-two\r\nactive-three\r\nactive-four");
        let history_before = terminal.history_rows();
        let viewport_before = terminal.viewport_text().unwrap();

        let outcome = terminal.clear_history_preserving_prompt();

        assert_eq!(outcome, ClearHistoryOutcome::Cleared(b"\x1b[3J".to_vec()));
        assert!(history_before > 0);
        assert_eq!(terminal.history_rows(), 0);
        assert_eq!(terminal.viewport_text().unwrap(), viewport_before);
    }

    #[test]
    fn clear_history_fails_closed_at_every_partial_vt_boundary() {
        let sequences: &[(&str, &[u8])] = &[
            ("escape-intermediate", b"\x1b(B"),
            ("csi", b"\x1b[31m"),
            ("osc-bel", b"\x1b]2;title\x07"),
            ("osc-st", b"\x1b]2;title\x1b\\"),
            ("osc-utf8-st-byte", "\x1b]2;Ütitle\x07".as_bytes()),
            ("c1-osc", b"\x9d2;title\x9c"),
            ("dcs", b"\x1bP1;2qpayload\x1b\\"),
            ("apc", b"\x1b_payload\x1b\\"),
            ("utf8", "🙂".as_bytes()),
        ];

        for &(name, sequence) in sequences {
            for split in 1..sequence.len() {
                let mut terminal = Terminal::new(20, 4, 1_000, Callbacks::default()).unwrap();
                for line in 0..10 {
                    terminal.vt_write(format!("history-{line}\r\n").as_bytes());
                }
                terminal.vt_write(b"\x1b]133;A\x07prompt> \x1b]133;B\x07pending");
                terminal.vt_write(&sequence[..split]);
                let history_before = terminal.history_rows();
                let contents_before = terminal.plain_text().unwrap();

                assert_eq!(
                    terminal.clear_history_preserving_prompt(),
                    ClearHistoryOutcome::Blocked,
                    "{name} split at byte {split}"
                );
                assert_eq!(terminal.history_rows(), history_before, "{name} split at byte {split}");
                assert_eq!(
                    terminal.plain_text().unwrap(),
                    contents_before,
                    "{name} split at byte {split}"
                );

                terminal.vt_write(&sequence[split..]);
                terminal.vt_write(b"Z");
                assert!(
                    terminal.viewport_text().unwrap().contains('Z'),
                    "{name} split at byte {split}"
                );
                assert!(
                    matches!(
                        terminal.clear_history_preserving_prompt(),
                        ClearHistoryOutcome::Cleared(_)
                    ),
                    "{name} remained unsafe after completing split at byte {split}"
                );
            }
        }
    }

    #[test]
    fn prompt_semantic_tracking_ignores_utf8_continuation_bytes_that_resemble_c1() {
        let mut tracker = PromptSemanticTracker::default();
        tracker.feed(b"\x1b]133;A\x07\x1b]133;B\x07");
        assert_eq!(tracker.semantic(Screen::Primary), PromptSemantic::Input);

        tracker.feed("\u{45d}".as_bytes());
        tracker.feed(b"\x1b]133;C\x07");

        assert_eq!(tracker.semantic(Screen::Primary), PromptSemantic::Output);
    }

    #[test]
    fn prompt_semantic_tracking_ignores_control_string_payload_newlines() {
        for introducer in *b"PX^_" {
            let mut tracker = PromptSemanticTracker::default();
            tracker.feed(b"\x1b]133;I\x07");
            assert_eq!(tracker.semantic(Screen::Primary), PromptSemantic::InputUntilEndOfLine);

            tracker.feed(&[0x1b, introducer, b'q', b'\n', 0x1b, b'\\']);
            assert_eq!(
                tracker.semantic(Screen::Primary),
                PromptSemantic::InputUntilEndOfLine,
                "control-string introducer {introducer:#x} leaked its payload"
            );

            tracker.feed(b"\n");
            assert_eq!(tracker.semantic(Screen::Primary), PromptSemantic::Output);
        }
    }

    #[test]
    fn prompt_semantic_tracking_rejects_suffixes_without_an_option_separator() {
        let mut tracker = PromptSemanticTracker::default();
        tracker.feed(b"\x1b]133;C\x07");
        let revision = tracker.revision();
        assert_eq!(tracker.semantic(Screen::Primary), PromptSemantic::Output);

        tracker.feed(b"\x1b]133;Agarbage\x1b\\");

        assert_eq!(tracker.semantic(Screen::Primary), PromptSemantic::Output);
        assert_eq!(tracker.revision(), revision);

        tracker.feed(b"\x1b]133;A;redraw=1\x1b\\");
        assert_eq!(tracker.semantic(Screen::Primary), PromptSemantic::Prompt);
        assert_eq!(tracker.revision(), revision.wrapping_add(1));
    }

    #[test]
    fn live_output_phase_overrides_persisted_prompt_rows() {
        let mut terminal = Terminal::new(20, 4, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07command");
        assert!(terminal.cursor_is_at_prompt());

        terminal.vt_write(b"\r\n\x1b]133;C\x07output\x1b[A\r");

        assert!(!terminal.cursor_is_at_prompt());
    }

    #[test]
    fn bounded_vt_replay_keeps_the_latest_screen_after_large_history() {
        let mut source = Terminal::new(80, 24, 2 * 1024 * 1024, Callbacks::default()).unwrap();
        let wide_line = "x".repeat(2048);
        for index in 0..500 {
            source.vt_write(format!("history-{index:04}-{wide_line}\r\n").as_bytes());
        }
        source.vt_write(b"LATEST-VISIBLE-CONTENT");

        let full = source.vt_replay_bytes().unwrap();
        assert!(full.len() > 32 * 1024);

        let bounded = source.vt_replay_bounded_bytes(32 * 1024).unwrap();
        assert!(bounded.len() <= 32 * 1024);

        let mut restored = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        restored.vt_write(&bounded);
        assert!(restored.viewport_text().unwrap().contains("LATEST-VISIBLE-CONTENT"));
    }

    #[test]
    fn bounded_vt_replay_preserves_complete_history_when_it_fits() {
        let mut source = Terminal::new(80, 24, 4 * 1024 * 1024, Callbacks::default()).unwrap();
        for index in 0..10_000 {
            source.vt_write(format!("plain-history-{index:05}\r\n").as_bytes());
        }
        source.vt_write(b"LATEST-VISIBLE-CONTENT");

        let full = source.vt_replay_bytes().unwrap();
        assert!(full.len() < 8 * 1024 * 1024);
        assert_eq!(source.vt_replay_bounded_bytes(8 * 1024 * 1024).unwrap(), full);
    }

    #[test]
    fn vt_replay_preserves_sparse_viewport_rows_without_scrolling_them_into_history() {
        let mut source = Terminal::new(80, 24, 100, Callbacks::default()).unwrap();
        source.vt_write(b"READY\r\n");
        let expected = source.viewport_text().unwrap();
        assert!(expected.contains("READY"));

        let replay = source.vt_replay_bytes().unwrap();
        let mut target = Terminal::new(80, 24, 100, Callbacks::default()).unwrap();
        target.vt_write(&replay);

        assert_eq!(target.viewport_text().unwrap(), expected);
    }

    #[test]
    fn theme_portable_replay_retains_aliases_for_admitted_kitty_images() {
        let mut source = Terminal::new(20, 4, 100, Callbacks::default()).unwrap();
        source.vt_write(b"\x1b_Ga=T,t=d,f=24,I=77,p=0,s=1,v=1,c=1,r=1,q=2;/wAA\x1b\\");
        let image_id = source.kitty_graphics_snapshot().unwrap().images[0].id;

        let replay = source.vt_replay_bounded_theme_portable_with_aliases(1024 * 1024).unwrap();
        assert_eq!(
            replay.kitty_image_aliases,
            vec![KittyImageAlias { image_id, image_number: 77 }]
        );

        let mut target = Terminal::new(20, 4, 100, Callbacks::default()).unwrap();
        target.vt_write(&replay.bytes);
        target.restore_kitty_image_aliases(&replay.kitty_image_aliases).unwrap();
        target.vt_write(b"\x1b_Ga=p,I=77,p=5,c=1,r=1,q=2;\x1b\\");
        assert_eq!(target.kitty_graphics_snapshot().unwrap().placements[0].image_id, image_id);
    }

    #[test]
    fn kitty_replay_placement_does_not_replace_the_saved_cursor_slot() {
        let mut source = Terminal::new(20, 8, 100, Callbacks::default()).unwrap();
        source.resize(20, 8, 10, 20).unwrap();
        source.vt_write(b"before");
        source.vt_write(b"\x1b_Ga=T,t=d,f=32,i=77,p=1,s=1,v=1,c=2,r=2,q=2;/wAAfw==\x1b\\");
        source.vt_write(b"\x1b[8;10Htail");
        let source_graphics = source.kitty_graphics_snapshot().unwrap();
        assert_eq!(source_graphics.placements.len(), 1);
        assert!(
            source_graphics.placements[0].pixel_width > 0,
            "fixture placement: {:?}",
            source_graphics.placements[0]
        );

        let replay = source.vt_replay_bounded_theme_portable_with_aliases(1024 * 1024).unwrap();
        let mut target = Terminal::new(20, 8, 100, Callbacks::default()).unwrap();
        target.resize(20, 8, 10, 20).unwrap();
        target.vt_write(&replay.bytes);
        assert_eq!(target.kitty_graphics_snapshot().unwrap().placements.len(), 1);
        target.restore_kitty_image_aliases(&replay.kitty_image_aliases).unwrap();
        target.vt_write(b"\x1b[8;20H\x1b8");

        assert_eq!(
            target.cursor_position(),
            Some((0, 0)),
            "a placement replay must leave the no-save DECRC fallback unchanged"
        );
    }

    #[test]
    fn minimal_bounded_replay_resets_before_numbered_kitty_images() {
        let mut source = Terminal::new(256, 1, 0, Callbacks::default()).unwrap();
        source.vt_write("x".repeat(255).as_bytes());
        source.vt_write(b"\x1b_Ga=t,t=d,f=24,I=77,s=1,v=1,q=2;/wAA\x1b\\");
        let snapshot = source.kitty_graphics_snapshot().unwrap();
        let image = snapshot.images.first().unwrap();
        let max_bytes = kitty_replay_image_len(image).unwrap() + b"\x1bc".len();
        let text = source
            .vt_replay_text_layout_bounded(
                max_bytes,
                &super::KittyReplayRowIndex::default(),
                None,
                false,
            )
            .unwrap();
        assert_eq!(text.range, None, "fixture did not reach the minimal reset fallback");

        let replay = source.vt_replay_bounded_theme_portable_with_aliases(max_bytes).unwrap();
        assert_eq!(
            replay.kitty_image_aliases,
            vec![KittyImageAlias { image_id: image.id, image_number: 77 }]
        );
        assert!(
            replay.bytes.starts_with(b"\x1bc\x1b_G"),
            "the terminal reset cleared a preceding image transmission: {:?}",
            replay.bytes
        );

        let mut target = Terminal::new(256, 1, 0, Callbacks::default()).unwrap();
        target.vt_write(&replay.bytes);
        target.restore_kitty_image_aliases(&replay.kitty_image_aliases).unwrap();
        target.vt_write(b"\x1b_Ga=p,I=77,p=5,c=1,r=1,q=2;\x1b\\");
        assert_eq!(target.kitty_graphics_snapshot().unwrap().placements[0].image_id, image.id);
    }

    #[test]
    fn bounded_vt_replay_limits_rows_before_formatting_large_history() {
        let rows = vt_replay_row_window(1_000_000, 24, 80, 8 * 1024 * 1024);

        assert_eq!(rows, 3_276);
    }

    #[test]
    fn bounded_text_replay_snaps_to_the_oldest_fitting_placement_anchor() {
        let mut source = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
        for row in 0..40 {
            source.vt_write(format!("row-{row:02}\r\n").as_bytes());
        }
        source.vt_write(b"tail");
        let scrollbar = source.scrollbar().unwrap();
        let anchor_row = scrollbar.total - 12;
        let placement_rows = [anchor_row].into_iter().collect();
        let anchor_range = super::ReplayRowRange { start: anchor_row, end: scrollbar.total - 1 };
        let anchor_bytes = source
            .vt_replay_text_range_bounded(anchor_range, &placement_rows, usize::MAX, true)
            .unwrap()
            .unwrap()
            .bytes
            .len();
        let older_range =
            super::ReplayRowRange { start: scrollbar.total - 16, end: scrollbar.total - 1 };
        assert!(
            source
                .vt_replay_text_range_bounded(older_range, &placement_rows, anchor_bytes, true)
                .unwrap()
                .is_none(),
            "fixture must put the anchor between a fitting and oversized geometric window"
        );

        let replay = source
            .vt_replay_text_layout_bounded(
                anchor_bytes,
                &placement_rows,
                Some(scrollbar.total - scrollbar.len),
                true,
            )
            .unwrap();

        assert_eq!(replay.range.unwrap().start, anchor_row);
    }

    #[test]
    fn kitty_replay_groups_each_placement_once() {
        let image_count = 64_u32;
        let images = (1..=image_count)
            .map(|id| KittyImage {
                id,
                number: 0,
                generation: u64::from(id),
                width: 1,
                height: 1,
                format: KittyImageFormat::Rgb,
                data: std::sync::Arc::from([0_u8, 0, 0]),
            })
            .collect::<Vec<_>>();
        let placements = (1..=image_count)
            .map(|id| {
                let mut placement =
                    replay_placement_fixture((1, 1), (1, 1), (1, 1), (1, 1), (0, 0), (0, 0));
                placement.key.image_id = id;
                placement.image_id = id;
                placement
            })
            .collect::<Vec<_>>();
        let anchors = placements
            .iter()
            .enumerate()
            .map(|(row, placement)| {
                (placement.key, KittyPlacementAnchor { col: 0, row: u32::try_from(row).unwrap() })
            })
            .collect();
        let snapshot = KittyReplaySnapshot {
            graphics: KittyGraphicsSnapshot { generation: 1, images, placements },
            anchors,
        };

        let catalog = KittyReplayCatalog::new(&snapshot, (1, 1), 24);

        assert_eq!(catalog.placement_grouping_visits, snapshot.graphics.placements.len());
    }

    #[test]
    fn kitty_replay_does_not_encode_images_rejected_by_the_budget() {
        let snapshot = KittyReplaySnapshot {
            graphics: KittyGraphicsSnapshot {
                generation: 1,
                images: vec![KittyImage {
                    id: 1,
                    number: 0,
                    generation: 1,
                    width: 1,
                    height: 1,
                    format: KittyImageFormat::Rgb,
                    data: std::sync::Arc::from([0_u8, 0, 0]),
                }],
                placements: Vec::new(),
            },
            anchors: Default::default(),
        };

        reset_kitty_replay_image_encodings();
        let catalog = KittyReplayCatalog::new(&snapshot, (1, 1), 24);
        let replay = catalog.plan(None, 0, false);

        assert!(replay.image_bytes.is_empty());
        assert_eq!(
            kitty_replay_image_encodings(),
            0,
            "catalog construction encoded an image that the replay budget rejected"
        );
    }

    #[test]
    fn bounded_replay_clips_a_placement_overlapping_the_retained_window() {
        let mut source = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
        source.resize(12, 4, 10, 20).unwrap();
        for row in 0..12 {
            source.vt_write(format!("row-{row:02}\r\n").as_bytes());
        }
        source.vt_write(b"tail");
        let end = source.scrollbar().unwrap().total - 1;
        let range = super::ReplayRowRange { start: end - 5, end };
        let anchor = KittyPlacementAnchor { col: 0, row: u32::try_from(range.start - 1).unwrap() };
        let placement =
            replay_placement_fixture((10, 60), (1, 3), (10, 60), (1, 3), (0, 0), (0, 0));
        let snapshot = KittyReplaySnapshot {
            graphics: KittyGraphicsSnapshot {
                generation: 1,
                images: vec![KittyImage {
                    id: 1,
                    number: 0,
                    generation: 1,
                    width: 10,
                    height: 60,
                    format: KittyImageFormat::Rgb,
                    data: std::sync::Arc::from(vec![127_u8; 10 * 60 * 3]),
                }],
                placements: vec![placement.clone()],
            },
            anchors: [(placement.key, anchor)].into_iter().collect(),
        };
        let catalog = KittyReplayCatalog::new(&snapshot, (10, 20), 4);
        let text = source
            .vt_replay_text_range_bounded(range, catalog.placement_rows(), usize::MAX, true)
            .unwrap()
            .unwrap();
        let graphics = catalog.plan(Some(range), usize::MAX, false);
        let mut replay = graphics.image_bytes;
        replay.extend(text.interleave(&graphics.placements).unwrap());

        let mut restored = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
        restored.resize(12, 4, 10, 20).unwrap();
        restored.vt_write(&replay);
        let restored_graphics = restored.kitty_graphics_snapshot().unwrap();
        let restored_placement =
            restored_graphics.placements.first().expect("overlapping placement");

        assert_eq!(restored_placement.source_y, 20);
        assert_eq!(restored_placement.source_height, 40);
        assert_eq!(restored_placement.rows, 2);
        assert_eq!(restored_placement.grid_rows, 2);
    }

    #[test]
    fn kitty_inflight_tracking_uses_the_normalized_c1_stream() {
        let mut terminal = Terminal::new(20, 4, 100, Callbacks::default()).unwrap();
        terminal.vt_write(&[0xe0]);
        terminal.vt_write(b"\x9fGa=t,t=d,f=24,i=92,s=1,v=2,m=1;AAAA\x9c");

        assert!(
            terminal.kitty_inflight.replay_prefix(usize::MAX).is_empty(),
            "a UTF-8 continuation byte that Ghostty parsed as text became a replayable Kitty APC"
        );
    }

    #[test]
    fn c1_control_string_introducers_normalize_to_escape_forms() {
        let mut normalizer = C1Normalizer::default();
        assert_eq!(normalizer.normalize(b"a\x90b"), b"a\x1bPb".as_slice());
        assert_eq!(normalizer.normalize(b"a\x98b"), b"a\x1bXb".as_slice());
        assert_eq!(normalizer.normalize(b"a\x9eb"), b"a\x1b^b".as_slice());
    }

    #[test]
    fn c1_control_string_normalization_handles_split_sequences_and_st() {
        let mut normalizer = C1Normalizer::default();
        assert_eq!(normalizer.normalize(b"\x90payload"), b"\x1bPpayload".as_slice());
        assert_eq!(normalizer.normalize(b"\x9c"), b"\x1b\\".as_slice());

        assert_eq!(normalizer.normalize(b"\x98part"), b"\x1bXpart".as_slice());
        assert_eq!(normalizer.normalize(b"ial\x9e"), b"ial\x1b^".as_slice());
        assert_eq!(normalizer.normalize(b"body\x9c"), b"body\x1b\\".as_slice());
    }

    #[test]
    fn c1_control_string_continuation_bytes_are_not_normalized() {
        let mut normalizer = C1Normalizer::default();
        assert_eq!(normalizer.normalize(&[0xe2]).as_ref(), &[0xe2]);
        assert_eq!(normalizer.normalize(&[0x98, 0x80]).as_ref(), &[0x98, 0x80]);
    }

    #[test]
    fn replay_native_left_clip_preserves_native_pixel_size() {
        let command = replay_placement_command(&replay_placement_fixture(
            (15, 10),
            (2, 1),
            (15, 10),
            (0, 0),
            (-1, 0),
            (4, 0),
        ));

        assert!(command.contains("x=6,y=0,w=9,h=10,X=0,Y=0"), "{command:?}");
        assert!(!command.contains(",c="), "{command:?}");
        assert!(!command.contains(",r="), "{command:?}");
    }

    #[test]
    fn replay_column_only_top_clip_keeps_rows_inferred() {
        let command = replay_placement_command(&replay_placement_fixture(
            (20, 10),
            (2, 2),
            (20, 10),
            (2, 0),
            (0, -1),
            (0, 15),
        ));

        assert!(command.contains("x=0,y=5,w=20,h=5,X=0,Y=0,c=2"), "{command:?}");
        assert!(!command.contains(",r="), "{command:?}");
    }

    #[test]
    fn replay_row_only_left_clip_keeps_columns_inferred() {
        let command = replay_placement_command(&replay_placement_fixture(
            (10, 40),
            (2, 2),
            (10, 40),
            (0, 2),
            (-1, 0),
            (5, 0),
        ));

        assert!(command.contains("x=5,y=0,w=5,h=40,X=0,Y=0,r=2"), "{command:?}");
        assert!(!command.contains(",c="), "{command:?}");
    }
}
