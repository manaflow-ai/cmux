//! Finds the byte boundary where a VT stream is not inside a sequence, and normalizes C1 controls.

use super::*;

/// Tracks whether Ghostty's persistent VT stream is between complete
/// sequences and UTF-8 code points.
///
/// Emulator-owned VT bytes may only be inserted at that boundary. The state
/// transitions mirror Ghostty's DEC ANSI parser, while ground-state bytes use
/// its UTF-8 stream behavior. Invalid UTF-8 may keep this tracker unsafe
/// slightly longer than Ghostty, but can never make an incomplete stream look
/// safe.
///
/// While unsafe it also retains the bytes fed since the last safe point. A
/// replay that ends with them leaves a fresh parser in the same incomplete
/// state, so the rest of the live stream completes the sequence there too.
#[derive(Default)]
pub(super) struct VtBoundaryTracker {
    pub(super) state: VtBoundaryState,
    pub(super) utf8_remaining: u8,
    /// Valid range of the next continuation byte. Ghostty's decoder is the
    /// strict Hoehrmann DFA, so the first continuation after E0, ED, F0 and
    /// F4 is narrower than 80..=BF.
    pub(super) utf8_next: (u8, u8),
    pub(super) pending: Vec<u8>,
    pub(super) pending_overflowed: bool,
}

/// Largest incomplete non-Kitty sequence a replay carries. Longer control
/// strings (for example an oversized OSC 52 copy) make the replay
/// non-resumable until the sequence ends.
pub(super) const VT_PENDING_SEQUENCE_REPLAY_MAX_BYTES: usize = 1024 * 1024;

#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub(super) enum VtBoundaryState {
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
    pub(super) fn feed(&mut self, data: &[u8]) {
        for &byte in data {
            let was_safe = self.is_safe();
            // Ghostty prints U+FFFD for a ground-state code point that an
            // invalid continuation abandons. Those bytes are now part of the
            // screen, so they must not be replayed a second time.
            let abandons_text = self.state == VtBoundaryState::Ground
                && self.utf8_remaining != 0
                && !(self.utf8_next.0..=self.utf8_next.1).contains(&byte);
            // ESC or a C1 introducer ends the sequence in progress: Ghostty
            // dispatches an OSC, DCS or APC string there and abandons any
            // other sequence. Only the new sequence is still pending.
            // A C1 value inside a UTF-8 code point is text, not an introducer.
            let restarts = self.state != VtBoundaryState::Ground
                && (byte == 0x1b
                    || (self.utf8_remaining == 0
                        && matches!(byte, 0x90 | 0x98 | 0x9b | 0x9d | 0x9e | 0x9f)));
            self.feed_byte(byte);
            if self.is_safe() {
                self.clear_pending();
                continue;
            }
            if was_safe || abandons_text || restarts {
                self.clear_pending();
            }
            // Inside an escape, CSI or control string Ghostty executes or
            // ignores C0 controls on arrival; only DCS passthrough keeps them.
            if matches!(byte, 0x00..=0x17 | 0x19 | 0x1c..=0x1f)
                && self.state != VtBoundaryState::DcsPassthrough
            {
                continue;
            }
            self.record_pending(byte);
        }
    }

    pub(super) fn is_safe(&self) -> bool {
        self.state == VtBoundaryState::Ground && self.utf8_remaining == 0
    }

    /// Bytes since the last safe point, or `None` when they exceeded the
    /// replay budget.
    pub(super) fn pending_replay(&self) -> Option<&[u8]> {
        (!self.pending_overflowed).then_some(self.pending.as_slice())
    }

    pub(super) fn record_pending(&mut self, byte: u8) {
        if self.pending_overflowed {
            return;
        }
        if self.pending.len() >= VT_PENDING_SEQUENCE_REPLAY_MAX_BYTES {
            self.pending = Vec::new();
            self.pending_overflowed = true;
            return;
        }
        self.pending.push(byte);
    }

    pub(super) fn clear_pending(&mut self) {
        // Do not keep a large control string's allocation for the life of
        // the terminal.
        if self.pending.capacity() > 4096 {
            self.pending = Vec::new();
        } else {
            self.pending.clear();
        }
        self.pending_overflowed = false;
    }

    pub(super) fn feed_byte(&mut self, byte: u8) {
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

    pub(super) fn consume_utf8_byte(&mut self, byte: u8) -> bool {
        if self.utf8_remaining != 0 {
            if (self.utf8_next.0..=self.utf8_next.1).contains(&byte) {
                self.utf8_remaining -= 1;
                self.utf8_next = (0x80, 0xbf);
                return true;
            }
            // Ghostty replaces the incomplete code point and retries this byte
            // from the UTF-8 accept state.
            self.utf8_remaining = 0;
        }

        (self.utf8_remaining, self.utf8_next) = match byte {
            0xc2..=0xdf => (1, (0x80, 0xbf)),
            0xe0 => (2, (0xa0, 0xbf)),
            0xed => (2, (0x80, 0x9f)),
            0xe1..=0xef => (2, (0x80, 0xbf)),
            0xf0 => (3, (0x90, 0xbf)),
            0xf4 => (3, (0x80, 0x8f)),
            0xf1..=0xf3 => (3, (0x80, 0xbf)),
            _ => (0, (0x80, 0xbf)),
        };
        self.utf8_remaining != 0
    }
}

impl VtBoundaryState {
    pub(super) fn transition(self, byte: u8) -> Self {
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
pub(super) struct C1Normalizer {
    pub(super) utf8_remaining: u8,
}

impl C1Normalizer {
    pub(super) fn normalize<'a>(&mut self, data: &'a [u8]) -> Cow<'a, [u8]> {
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
