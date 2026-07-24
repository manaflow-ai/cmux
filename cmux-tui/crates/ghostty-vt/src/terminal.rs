use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::ffi::c_void;
use std::ptr;
use std::sync::atomic::{AtomicU64, Ordering};

use base64::Engine as _;
use ghostty_vt_sys as sys;

use crate::kitty::{
    self, KittyGraphicsSnapshot, KittyImage, KittyImageAlias, KittyInFlightTracker, KittyPlacement,
    KittyPlacementAnchor, KittyReplaySnapshot, MAX_KITTY_IMAGE_BYTES,
};
use crate::render::{Cell, CursorShape, read_grid_ref_cell, terminal_palette};
use crate::{Error, Result, check};

static NEXT_TERMINAL_ID: AtomicU64 = AtomicU64::new(1);
const VT_REPLAY_ESTIMATED_BYTES_PER_CELL: u64 = 32;
const DEFAULT_KITTY_IMAGE_STORAGE_LIMIT: u64 = MAX_KITTY_IMAGE_BYTES as u64;
const DEFAULT_KITTY_IMAGE_COUNT_LIMIT: u64 = 4_096;
const DEFAULT_KITTY_PLACEMENT_COUNT_LIMIT: u64 = 16_384;
const KITTY_REPLAY_CHUNK: usize = 4096;
const MAX_COLOR_OSC_BYTES: usize = 16 * 1024;

/// Terminal state replay plus Kitty aliases that cannot share one APC command.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct VtReplay {
    pub bytes: Vec<u8>,
    pub kitty_image_aliases: Vec<KittyImageAlias>,
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

#[derive(Default)]
enum MouseModeScan {
    #[default]
    Ground,
    Escape,
    Csi {
        private: bool,
        at_start: bool,
        parameter: u16,
        has_parameter: bool,
        has_mouse_mode: bool,
        soft_reset: bool,
    },
}

impl MouseModeScan {
    fn feed(&mut self, data: &[u8]) -> bool {
        let mut changed = false;
        for &byte in data {
            let state = std::mem::take(self);
            *self = match state {
                Self::Ground => match byte {
                    0x1b => Self::Escape,
                    0x9b => Self::csi(),
                    _ => Self::Ground,
                },
                Self::Escape => match byte {
                    b'[' => Self::csi(),
                    0x1b => Self::Escape,
                    b'c' => {
                        changed = true;
                        Self::Ground
                    }
                    _ => Self::Ground,
                },
                Self::Csi {
                    mut private,
                    mut at_start,
                    mut parameter,
                    mut has_parameter,
                    mut has_mouse_mode,
                    mut soft_reset,
                } => match byte {
                    b'?' if at_start => {
                        private = true;
                        at_start = false;
                        Self::Csi {
                            private,
                            at_start,
                            parameter,
                            has_parameter,
                            has_mouse_mode,
                            soft_reset,
                        }
                    }
                    b'0'..=b'9' => {
                        at_start = false;
                        has_parameter = true;
                        parameter =
                            parameter.saturating_mul(10).saturating_add(u16::from(byte - b'0'));
                        Self::Csi {
                            private,
                            at_start,
                            parameter,
                            has_parameter,
                            has_mouse_mode,
                            soft_reset,
                        }
                    }
                    b';' => {
                        has_mouse_mode |=
                            private && has_parameter && Self::is_mouse_mode(parameter);
                        at_start = false;
                        parameter = 0;
                        has_parameter = false;
                        Self::Csi {
                            private,
                            at_start,
                            parameter,
                            has_parameter,
                            has_mouse_mode,
                            soft_reset,
                        }
                    }
                    b'!' => {
                        soft_reset = true;
                        Self::Csi {
                            private,
                            at_start,
                            parameter,
                            has_parameter,
                            has_mouse_mode,
                            soft_reset,
                        }
                    }
                    0x40..=0x7e => {
                        has_mouse_mode |=
                            private && has_parameter && Self::is_mouse_mode(parameter);
                        if (has_mouse_mode && matches!(byte, b'h' | b'l' | b'r'))
                            || (soft_reset && byte == b'p')
                        {
                            changed = true;
                        }
                        Self::Ground
                    }
                    0x1b => Self::Escape,
                    _ => Self::Ground,
                },
            };
        }
        changed
    }

    fn csi() -> Self {
        Self::Csi {
            private: false,
            at_start: true,
            parameter: 0,
            has_parameter: false,
            has_mouse_mode: false,
            soft_reset: false,
        }
    }

    fn is_mouse_mode(mode: u16) -> bool {
        matches!(mode, 9 | 1000 | 1002 | 1003 | 1005 | 1006 | 1015 | 1016)
    }
}

/// A terminal instance: VT parser plus full screen/scrollback state.
pub struct Terminal {
    raw: sys::GhosttyTerminal,
    instance_id: u64,
    mouse_mode_revision: u64,
    mouse_mode_scan: MouseModeScan,
    kitty_inflight: KittyInFlightTracker,
    // Heap-pinned so the userdata pointer stays valid for the terminal's
    // lifetime.
    callbacks: Box<Callbacks>,
    cursor_override: CursorOverrideTracker,
    palette_override: Box<PaletteOverrideTracker>,
    color_overrides: ColorOverrideTracker,
    c1_normalizer: C1Normalizer,
}

/// Ghostty's parser intentionally treats bytes >= 0x80 as UTF-8 in ground
/// state, while PTYs can still emit the 8-bit OSC/ST forms. Normalize only
/// standalone C1 OSC/ST bytes; continuation bytes inside UTF-8 text remain
/// byte-for-byte unchanged.
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
                0x9d => Some(b']'),
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
            mouse_mode_revision: 0,
            mouse_mode_scan: MouseModeScan::default(),
            kitty_inflight: KittyInFlightTracker::default(),
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

    /// Feed VT-encoded bytes (pty output) into the terminal.
    pub fn vt_write(&mut self, data: &[u8]) {
        let _ = self.vt_write_with_normalized(data);
    }

    /// Feed VT-encoded bytes and return the exact byte stream accepted by
    /// Ghostty. Standalone 8-bit OSC/ST controls are returned in their 7-bit
    /// forms, while UTF-8 continuation bytes remain unchanged across calls.
    ///
    /// Process hosts should publish this returned stream so every frontend
    /// parses the same bytes as the authoritative terminal.
    pub fn vt_write_with_normalized<'a>(&mut self, data: &'a [u8]) -> Cow<'a, [u8]> {
        if data.is_empty() {
            return Cow::Borrowed(data);
        }
        if self.mouse_mode_scan.feed(data) {
            self.mouse_mode_revision = self.mouse_mode_revision.wrapping_add(1);
        }
        self.kitty_inflight.write(data);
        let normalized = self.c1_normalizer.normalize(data);
        self.cursor_override.write(&normalized);
        self.palette_override.write(&normalized);
        self.color_overrides.write(&normalized);
        unsafe { sys::ghostty_terminal_vt_write(self.raw, normalized.as_ptr(), normalized.len()) };
        normalized
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
        })
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

    /// Set the active terminal's bounded Kitty image storage in bytes.
    pub fn set_kitty_image_storage_limit(&mut self, bytes: u64) -> Result<()> {
        check(unsafe {
            sys::ghostty_terminal_set(
                self.raw,
                sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,
                (&bytes as *const u64).cast(),
            )
        })
    }

    pub fn kitty_image_storage_limit(&self) -> Result<u64> {
        self.get(sys::GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_STORAGE_LIMIT)
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

    /// Whether any mouse tracking mode is enabled by the application.
    pub fn mouse_tracking(&self) -> bool {
        self.get::<bool>(sys::GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING).unwrap_or(false)
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

    fn vt_replay_bounded_with_palette(
        &mut self,
        max_bytes: usize,
        include_palette: bool,
    ) -> Result<VtReplay> {
        let inflight = self.kitty_inflight.replay_prefix_checked(max_bytes)?;
        let remaining = max_bytes.checked_sub(inflight.len()).ok_or(Error::OutOfSpace)?;
        let snapshot = kitty::snapshot_for_replay(self, &mut HashMap::new(), true)?;
        let catalog =
            KittyReplayCatalog::new(&snapshot, self.cell_pixel_size(), self.rows().max(1));

        let active_start = self.scrollbar().and_then(|scrollbar| {
            let viewport_start = scrollbar.total.saturating_sub(scrollbar.len);
            let visible_start = catalog.visible_anchor_start().unwrap_or(viewport_start);
            Some(viewport_start.min(visible_start))
        });
        let active_text = self.vt_replay_text_layout_bounded(
            remaining,
            catalog.placement_rows(),
            active_start,
            include_palette,
        )?;
        let visible_budget = remaining.saturating_sub(active_text.bytes.len());
        let visible_cost =
            active_text.range.map(|range| catalog.visible_cost(range, visible_budget)).unwrap_or(0);

        let text_budget = remaining.saturating_sub(visible_cost);
        let text = self.vt_replay_text_layout_bounded(
            text_budget,
            catalog.placement_rows(),
            active_start,
            include_palette,
        )?;
        let graphics_budget = remaining.saturating_sub(text.bytes.len());
        let graphics = catalog.plan(text.range, graphics_budget, false);
        let interleaved = text.interleave(&graphics.placements).ok_or(Error::OutOfSpace)?;

        let total = graphics
            .image_bytes
            .len()
            .checked_add(interleaved.len())
            .and_then(|total| total.checked_add(inflight.len()))
            .ok_or(Error::OutOfSpace)?;
        if total > max_bytes || graphics.total_len > graphics_budget {
            return Err(Error::OutOfSpace);
        }
        let mut bytes = Vec::with_capacity(total);
        bytes.extend_from_slice(&graphics.image_bytes);
        bytes.extend_from_slice(&interleaved);
        bytes.extend_from_slice(&inflight);
        Ok(VtReplay { bytes, kitty_image_aliases: graphics.aliases })
    }

    /// Bounded byte-only compatibility replay. This discards Kitty aliases.
    pub fn vt_replay_bounded_bytes(&mut self, max_bytes: usize) -> Result<Vec<u8>> {
        Ok(self.vt_replay_bounded(max_bytes)?.bytes)
    }

    fn vt_replay_text_layout_bounded(
        &mut self,
        max_bytes: usize,
        placement_rows: &BTreeSet<u64>,
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
        placement_rows: &BTreeSet<u64>,
        max_bytes: usize,
        include_palette: bool,
    ) -> Result<ReplayText> {
        let Some(best_range) = best.range else {
            return Ok(best);
        };
        let candidates =
            placement_rows.range(failed_start..best_range.start).copied().collect::<Vec<_>>();
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
        placement_rows: &BTreeSet<u64>,
        max_bytes: usize,
        include_palette: bool,
    ) -> Result<Option<ReplayText>> {
        let cols = self.cols();
        if cols == 0 || range.start > range.end {
            return Err(Error::InvalidValue);
        }
        let suffix = self.cursor_position_escape();
        let suffix_len = suffix.as_ref().map_or(0, Vec::len);
        let Some(format_max_bytes) = max_bytes.checked_sub(suffix_len) else {
            return Ok(None);
        };
        let mut segment_ends =
            placement_rows.range(range.start..=range.end).copied().collect::<BTreeSet<_>>();
        segment_ends.insert(range.end);

        let mut bytes = Vec::new();
        let mut insertion_offsets = BTreeMap::new();
        let mut segment_start = range.start;
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
            bytes.extend_from_slice(&chunk);
            if placement_rows.contains(&segment_end) {
                insertion_offsets.insert(segment_end, bytes.len());
            }
            if !last {
                if bytes.len().saturating_add(2) > format_max_bytes {
                    return Ok(None);
                }
                bytes.extend_from_slice(b"\r\n");
                segment_start = segment_end.saturating_add(1);
            }
        }
        let replay_rows = range.end - range.start + 1;
        let screen_rows = u64::from(self.rows().max(1));
        if replay_rows > screen_rows {
            // A history-bearing selection must advance once per row so the
            // reconstructed scrollback keeps Kitty anchors aligned. A
            // viewport-only selection may use direct cursor positioning for
            // sparse rows; padding that case would scroll visible text away.
            let expected_breaks = usize::try_from(replay_rows - 1).unwrap_or(usize::MAX);
            let emitted_breaks = bytes.windows(2).filter(|bytes| *bytes == b"\r\n").count();
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

    fn cursor_position_escape(&self) -> Option<Vec<u8>> {
        let (x, y) = self.cursor_position()?;
        Some(format!("\x1b[{};{}H", u32::from(y) + 1, u32::from(x) + 1).into_bytes())
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
    transmission: Vec<u8>,
    placements: Vec<KittyReplayPlacement<'a>>,
}

struct KittyReplayCatalog<'a> {
    images: Vec<KittyReplayImage<'a>>,
    placement_rows: BTreeSet<u64>,
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
        let mut placement_rows = BTreeSet::new();
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
            placement_rows.insert(u64::from(anchor.row));
            placements_by_image
                .entry(placement.image_id)
                .or_default()
                .push(KittyReplayPlacement { placement, anchor });
        }

        let mut images = snapshot.graphics.images.iter().collect::<Vec<_>>();
        images.sort_by_key(|image| (image.generation, image.id));
        let images = images
            .into_iter()
            .map(|image| KittyReplayImage {
                image,
                transmission: kitty_replay_image(image),
                placements: placements_by_image.remove(&image.id).unwrap_or_default(),
            })
            .collect();
        Self {
            images,
            placement_rows,
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

    fn placement_rows(&self) -> &BTreeSet<u64> {
        &self.placement_rows
    }

    fn visible_cost(&self, range: ReplayRowRange, max_bytes: usize) -> usize {
        self.plan(Some(range), max_bytes, true).total_len
    }

    fn plan(
        &self,
        range: Option<ReplayRowRange>,
        max_bytes: usize,
        visible_only: bool,
    ) -> KittyReplayPlan {
        let mut candidates = Vec::with_capacity(self.images.len());
        for (image_index, image) in self.images.iter().enumerate() {
            let mut visible = false;
            let mut placements = Vec::new();
            if let Some(range) = range {
                for replay_placement in &image.placements {
                    let row = u64::from(replay_placement.anchor.row);
                    if row < range.start || row > range.end {
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
                    placements.push((row, command));
                }
            }
            let Some(cost) =
                placements.iter().try_fold(image.transmission.len(), |total, (_, command)| {
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

        let mut image_bytes = Vec::new();
        let mut placements = BTreeMap::<u64, Vec<Vec<u8>>>::new();
        let mut aliases = Vec::new();
        for (candidate, admitted) in candidates.into_iter().zip(admitted) {
            if !admitted {
                continue;
            }
            let image = &self.images[candidate.image_index];
            image_bytes.extend_from_slice(&image.transmission);
            for (row, command) in candidate.placements {
                placements.entry(row).or_default().push(command);
            }
            if image.image.number != 0 {
                aliases.push(KittyImageAlias {
                    image_id: image.image.id,
                    image_number: image.image.number,
                });
            }
        }
        KittyReplayPlan { image_bytes, placements, aliases, total_len }
    }
}

fn kitty_replay_image(image: &KittyImage) -> Vec<u8> {
    let mut bytes = Vec::new();
    let payload = base64::engine::general_purpose::STANDARD.encode(&image.data);
    for (index, chunk) in payload.as_bytes().chunks(KITTY_REPLAY_CHUNK).enumerate() {
        let more = usize::from((index + 1) * KITTY_REPLAY_CHUNK < payload.len());
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
        bytes.extend_from_slice(chunk);
        bytes.extend_from_slice(b"\x1b\\");
    }
    bytes
}

fn kitty_replay_placement_at(
    placement: &KittyPlacement,
    anchor: KittyPlacementAnchor,
    replay_start_row: u64,
    terminal_rows: u16,
    _cell_pixels: (u32, u32),
) -> Option<Vec<u8>> {
    if placement.pixel_width == 0
        || placement.pixel_height == 0
        || placement.source_width == 0
        || placement.source_height == 0
    {
        return None;
    }
    let relative_row = u64::from(anchor.row).checked_sub(replay_start_row)?;
    let row = relative_row.min(u64::from(terminal_rows.saturating_sub(1))).saturating_add(1);
    let col = u32::from(anchor.col).saturating_add(1);
    let placement_id = if placement.is_internal { 0 } else { placement.placement_id };
    let mut command = format!(
        "\x1b7\x1b[{row};{col}H\x1b_Ga=p,i={},p={},x={},y={},w={},h={},X={},Y={}",
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
    command.push_str(&format!(",z={},C=1,q=2;\x1b\\\x1b8", placement.z));
    Some(command.into_bytes())
}

#[cfg(test)]
fn kitty_replay_placement(placement: &KittyPlacement, cell_pixels: (u32, u32)) -> Option<Vec<u8>> {
    if placement.pixel_width == 0
        || placement.pixel_height == 0
        || placement.source_width == 0
        || placement.source_height == 0
    {
        return None;
    }

    let cell_width = cell_pixels.0.max(1);
    let cell_height = cell_pixels.1.max(1);
    let image_left =
        i64::from(placement.viewport_col) * i64::from(cell_width) + i64::from(placement.x_offset);
    let image_top =
        i64::from(placement.viewport_row) * i64::from(cell_height) + i64::from(placement.y_offset);
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
        "\x1b7\x1b[{row};{col}H\x1b_Ga=p,i={},p={},x={source_x},y={source_y},w={source_width},h={source_height},X={x_offset},Y={y_offset}",
        placement.image_id, placement_id
    );
    if let Some(columns) = columns {
        command.push_str(&format!(",c={columns}"));
    }
    if let Some(rows) = rows {
        command.push_str(&format!(",r={rows}"));
    }
    command.push_str(&format!(",z={},C=1,q=2;\x1b\\\x1b8", placement.z));
    Some(command.into_bytes())
}

#[cfg(test)]
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

#[cfg(test)]
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

#[cfg(test)]
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
        Callbacks, KittyReplayCatalog, MouseModeScan, PaletteOsc, Terminal, kitty_replay_placement,
        vt_replay_row_window,
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
    fn mouse_mode_scan_tracks_split_private_mode_sequences() {
        let mut scan = MouseModeScan::default();

        assert!(!scan.feed(b"\x1b[?10"));
        assert!(scan.feed(b"00;1006h"));
        assert!(!scan.feed(b"ordinary output\x1b[31m"));
        assert!(scan.feed(b"\x9b?1002l"));
        assert!(scan.feed(b"\x1b[?1000r"));
        assert!(scan.feed(b"\x1b[!p"));
        assert!(scan.feed(b"\x1bc"));
    }

    #[test]
    fn terminal_instances_have_lifetime_stable_ids() {
        let first = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        let second = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();

        assert_ne!(first.instance_id(), second.instance_id());
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
