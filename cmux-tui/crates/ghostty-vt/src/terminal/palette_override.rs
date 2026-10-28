//! Tracks OSC 4/104 palette overrides the program sets, so replay restores them.

use super::*;

/// One flag per palette index, so every `u8` index is in range.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(super) struct PaletteSet {
    /// Indices 0..=127, bit `index`.
    low: u128,
    /// Indices 128..=255, bit `index - 128`.
    high: u128,
}

impl PaletteSet {
    /// The index's bit within its half (a rotation by `index` is one by `index % 128`).
    fn mask(index: u8) -> u128 {
        1u128.rotate_left(u32::from(index))
    }

    pub(super) fn contains(&self, index: u8) -> bool {
        let half = if index < 128 { self.low } else { self.high };
        half & Self::mask(index) != 0
    }

    pub(super) fn set(&mut self, index: u8, present: bool) {
        let mask = Self::mask(index);
        let half = if index < 128 { &mut self.low } else { &mut self.high };
        if present {
            *half |= mask;
        } else {
            *half &= !mask;
        }
    }

    pub(super) fn clear(&mut self) {
        *self = Self::default();
    }
}

/// The indices one OSC 4/104/21 command sets or resets; the last request
/// for an index wins.
#[derive(Default)]
pub(super) struct PendingPalette {
    set: PaletteSet,
    reset: PaletteSet,
}

impl PendingPalette {
    pub(super) fn mark(&mut self, index: u8, set: bool) {
        self.set.set(index, set);
        self.reset.set(index, !set);
    }

    pub(super) fn apply(&self, active: &mut PaletteSet) {
        for index in 0..=u8::MAX {
            if self.set.contains(index) {
                active.set(index, true);
            } else if self.reset.contains(index) {
                active.set(index, false);
            }
        }
    }
}

pub(super) struct PaletteOverrideTracker {
    pub(super) state: PaletteTrackState,
    pub(super) active: PaletteSet,
    pub(super) revision: u64,
    pub(super) reapply_revision: u64,
}

impl Default for PaletteOverrideTracker {
    fn default() -> Self {
        Self {
            state: PaletteTrackState::Ground,
            active: PaletteSet::default(),
            revision: 0,
            reapply_revision: 0,
        }
    }
}

#[derive(Default)]
pub(super) enum PaletteTrackState {
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

pub(super) enum PaletteOsc {
    Operation { bytes: [u8; 3], len: u8, invalid: bool },
    Palette(Box<PaletteCommand>),
    Ignore,
}

impl Default for PaletteOsc {
    fn default() -> Self {
        Self::Operation { bytes: [0; 3], len: 0, invalid: false }
    }
}

pub(super) struct PaletteCommand {
    pub(super) mode: PaletteOscMode,
    pub(super) token: [u8; Self::MAX_CAPTURE_BYTES],
    pub(super) token_len: usize,
    pub(super) captured: usize,
    pub(super) pending: PendingPalette,
    pub(super) request_count: usize,
    pub(super) kitty_request_count: usize,
    pub(super) stopped: bool,
    pub(super) overflowed: bool,
    pub(super) color_changed: bool,
}

impl PaletteCommand {
    const MAX_CAPTURE_BYTES: usize = 2048;

    pub(super) fn new(mode: PaletteOscMode) -> Self {
        Self {
            mode,
            token: [0; Self::MAX_CAPTURE_BYTES],
            token_len: 0,
            captured: 0,
            pending: PendingPalette::default(),
            request_count: 0,
            kitty_request_count: 0,
            stopped: false,
            overflowed: false,
            color_changed: false,
        }
    }
}

#[derive(Default)]
pub(super) enum PaletteOscMode {
    #[default]
    Ignore,
    SetIndex,
    SetColor(PaletteTarget),
    Reset,
    Kitty,
}

#[derive(Clone, Copy)]
pub(super) enum PaletteTarget {
    Palette(u8),
    Special,
    Invalid,
}

impl PaletteOverrideTracker {
    pub(super) fn is_ground(&self) -> bool {
        matches!(self.state, PaletteTrackState::Ground)
    }

    /// Original byte-at-a-time write, kept as the exactness reference.
    pub(super) fn write_reference(&mut self, data: &[u8]) {
        for &byte in data {
            self.step(byte);
        }
    }

    #[inline(always)]
    pub(super) fn step(&mut self, byte: u8) {
        {
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
                            // RIS resets the palette to its defaults (ghostty-next),
                            // and attached byte frontends reset their mirror
                            // palette. Re-emit the authoritative sparse snapshot.
                            self.active.clear();
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
                    0x07 => {
                        self.commit_osc(osc);
                        PaletteTrackState::Ground
                    }
                    // CAN and SUB cancel the OSC (ghostty-next osc.Parser.end
                    // dispatches nothing for them).
                    0x18 | 0x1a => PaletteTrackState::Ground,
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

    pub(super) fn commit_osc(&mut self, osc: PaletteOsc) {
        if osc.commit(&mut self.active) {
            self.revision = self.revision.wrapping_add(1);
        }
    }
}

/// Ghostty's generic C1 transitions for parser states whose state-specific
/// table does not override them. Raw C1 bytes only reach this tracker after an
/// escape-initiated state; ground-state bytes pass through the UTF-8 decoder.
pub(super) fn palette_c1_transition(byte: u8) -> Option<PaletteTrackState> {
    match byte {
        0x80..=0x8f | 0x91..=0x97 | 0x99 | 0x9a | 0x9c => Some(PaletteTrackState::Ground),
        0x90 | 0x98 | 0x9e | 0x9f => Some(PaletteTrackState::String { bell_terminated: false }),
        0x9b => Some(PaletteTrackState::Csi),
        0x9d => Some(PaletteTrackState::Osc(PaletteOsc::default())),
        _ => None,
    }
}

impl PaletteOsc {
    pub(super) fn feed(&mut self, byte: u8) {
        match self {
            Self::Operation { bytes, len, invalid } => {
                if byte == b';' {
                    let mode = if *invalid {
                        None
                    } else {
                        match bytes.get(..usize::from(*len)) {
                            Some(b"4") => Some(PaletteOscMode::SetIndex),
                            Some(b"104") => Some(PaletteOscMode::Reset),
                            Some(b"21") => Some(PaletteOscMode::Kitty),
                            _ => None,
                        }
                    };
                    *self = mode
                        .map(|mode| Self::Palette(Box::new(PaletteCommand::new(mode))))
                        .unwrap_or(Self::Ignore);
                } else if let Some(slot) = bytes.get_mut(usize::from(*len)) {
                    *slot = byte;
                    *len += 1;
                } else {
                    *invalid = true;
                }
            }
            Self::Palette(command) => command.feed(byte),
            Self::Ignore => {}
        }
    }

    pub(super) fn commit(self, active: &mut PaletteSet) -> bool {
        match self {
            Self::Operation { bytes, len, invalid: false }
                if bytes.get(..usize::from(len)) == Some(b"104") =>
            {
                active.clear();
                true
            }
            Self::Palette(command) => command.commit(active),
            Self::Operation { .. } | Self::Ignore => false,
        }
    }
}

impl PaletteCommand {
    pub(super) fn feed(&mut self, byte: u8) {
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
        } else if let Some(slot) = self.token.get_mut(self.token_len) {
            // `captured` stops the command before the token outgrows its buffer.
            *slot = byte;
            self.token_len += 1;
        } else {
            self.stopped = true;
            self.overflowed = true;
            self.token_len = 0;
        }
    }

    pub(super) fn finish_token(&mut self) {
        if self.stopped {
            self.token_len = 0;
            return;
        }
        let Some(token) = self.token.get(..self.token_len) else {
            self.stopped = true;
            self.overflowed = true;
            self.token_len = 0;
            return;
        };
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
                            self.pending.mark(index, true);
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
                            self.pending.mark(index, false);
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
                let mut pair = token.splitn(2, |byte| *byte == b'=');
                let key = pair.next().unwrap_or_default();
                let value = pair.next().unwrap_or_default();
                let key = std::str::from_utf8(key).unwrap_or_default();
                let index =
                    parse_protocol_decimal(key.as_bytes(), u8::MAX.into()).map(|value| value as u8);
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
                let accepted = std::str::from_utf8(trim_ascii_spaces(value)).ok().filter(|value| {
                    recognized
                        && (value.is_empty() || *value == "?" || parse_color(value).is_some())
                });
                if let Some(value) = accepted {
                    self.kitty_request_count += 1;
                    self.color_changed |= value != "?";
                    if value.is_empty()
                        && let Some(index) = index
                    {
                        self.pending.mark(index, false);
                    } else if value != "?"
                        && let Some(index) = index
                    {
                        self.pending.mark(index, true);
                    }
                }
                PaletteOscMode::Kitty
            }
            PaletteOscMode::Ignore => PaletteOscMode::Ignore,
        };
        self.token_len = 0;
    }

    pub(super) fn parse_target(token: &[u8]) -> PaletteTarget {
        // Ghostty parses OSC 4/104 indices as a protocol `u9`: plain decimal.
        let Some(value) = parse_protocol_decimal(token, 0x1ff) else {
            return PaletteTarget::Invalid;
        };
        match value {
            0..=255 => PaletteTarget::Palette(value as u8),
            256..=260 => PaletteTarget::Special,
            _ => PaletteTarget::Invalid,
        }
    }

    pub(super) fn commit(mut self: Box<Self>, active: &mut PaletteSet) -> bool {
        if self.overflowed {
            return false;
        }
        self.finish_token();
        if self.overflowed {
            return false;
        }
        if matches!(self.mode, PaletteOscMode::Reset) && self.request_count == 0 {
            active.clear();
            return true;
        }
        self.pending.apply(active);
        self.color_changed
    }
}
