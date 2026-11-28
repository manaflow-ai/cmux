//! Tracks OSC 10/11/12 color overrides the program sets, so replay restores them.

use super::*;

#[derive(Default)]
pub(super) struct ColorOverrideTracker {
    pub(super) state: ColorTrackState,
    pub(super) utf8_remaining: u8,
    pub(super) foreground: bool,
    pub(super) background: bool,
    pub(super) cursor: bool,
    pub(super) palette: [u64; 4],
}

#[derive(Default)]
pub(super) enum ColorTrackState {
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
    pub(super) fn write(&mut self, data: &[u8]) {
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
                            // CAN and SUB cancel the OSC, as in Ghostty.
                            0x18 | 0x1a => ColorTrackState::Ground,
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

    pub(super) fn ground(&mut self, byte: u8) -> ColorTrackState {
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

    pub(super) fn escape(&mut self, byte: u8) -> ColorTrackState {
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

    pub(super) fn osc(&mut self) -> ColorTrackState {
        self.utf8_remaining = 0;
        ColorTrackState::Osc { payload: Vec::new(), overflowed: false }
    }

    pub(super) fn push_osc_byte(payload: &mut Vec<u8>, overflowed: &mut bool, byte: u8) {
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

    pub(super) fn consume_utf8_continuation(&mut self, byte: u8) -> bool {
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

    pub(super) fn note_utf8_lead(&mut self, byte: u8) {
        self.utf8_remaining = match byte {
            0xc2..=0xdf => 1,
            0xe0..=0xef => 2,
            0xf0..=0xf4 => 3,
            _ => 0,
        };
    }

    pub(super) fn finish_osc(&mut self, payload: &[u8], overflowed: bool) {
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
                        // Codes start at 10 and stop after 12 (above).
                        _ => {}
                    }
                }
            }
            110 => self.foreground = false,
            111 => self.background = false,
            112 => self.cursor = false,
            _ => {}
        }
    }

    pub(super) fn reset_all(&mut self) {
        self.foreground = false;
        self.background = false;
        self.cursor = false;
        self.palette.fill(0);
    }

    pub(super) fn set_palette_authored(&mut self, index: usize, authored: bool) {
        let (word, bit) = (index / 64, index % 64);
        if authored {
            self.palette[word] |= 1u64 << bit;
        } else {
            self.palette[word] &= !(1u64 << bit);
        }
    }

    pub(super) fn palette_authored(&self, index: usize) -> bool {
        self.palette[index / 64] & (1u64 << (index % 64)) != 0
    }
}
