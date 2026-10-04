//! Tracks OSC 133 prompt semantics (prompt, input, output) and the screen-mode selection.

use super::*;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(super) enum PromptSemantic {
    #[default]
    Unknown,
    Prompt,
    Input,
    InputUntilEndOfLine,
    Output,
}

#[derive(Default)]
pub(super) struct PromptSemanticTracker {
    pub(super) state: PromptTrackState,
    pub(super) primary: PromptSemantic,
    pub(super) alternate: PromptSemantic,
    pub(super) alternate_active: bool,
    pub(super) screen_modes: [bool; 3],
    pub(super) saved_screen_modes: [bool; 3],
    pub(super) revision: u64,
}

#[derive(Debug, Clone, Copy, Default)]
pub(super) struct ScreenModeSelection {
    pub(super) indices: [u8; 3],
    pub(super) len: u8,
}

impl ScreenModeSelection {
    pub(super) fn push(&mut self, mode: u16) {
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

    pub(super) fn indices(&self) -> impl Iterator<Item = usize> + '_ {
        self.indices[..usize::from(self.len)].iter().map(|index| usize::from(*index))
    }

    pub(super) fn is_empty(&self) -> bool {
        self.len == 0
    }
}

#[derive(Default)]
pub(super) enum PromptTrackState {
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
pub(super) struct PromptOsc {
    pub(super) prefix_len: u8,
    pub(super) action: Option<u8>,
    pub(super) options_started: bool,
    pub(super) invalid: bool,
}

impl PromptOsc {
    pub(super) fn feed(&mut self, byte: u8) {
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

    pub(super) fn valid_action(&self) -> Option<u8> {
        if self.invalid { None } else { self.action }
    }
}

impl PromptSemanticTracker {
    pub(super) fn feed(&mut self, data: &[u8]) {
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

    pub(super) fn csi() -> PromptTrackState {
        PromptTrackState::Csi {
            private: false,
            at_start: true,
            parameter: 0,
            has_parameter: false,
            screen_modes: ScreenModeSelection::default(),
        }
    }

    pub(super) fn screen_mode_index(mode: u16) -> Option<usize> {
        match mode {
            47 => Some(0),
            1047 => Some(1),
            1049 => Some(2),
            _ => None,
        }
    }

    pub(super) fn apply_screen_modes(&mut self, action: u8, screen_modes: ScreenModeSelection) {
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

    pub(super) fn semantic(&self, screen: Screen) -> PromptSemantic {
        match screen {
            Screen::Primary => self.primary,
            Screen::Alternate => self.alternate,
        }
    }

    pub(super) fn revision(&self) -> u64 {
        self.revision
    }

    pub(super) fn current_mut(&mut self) -> &mut PromptSemantic {
        if self.alternate_active { &mut self.alternate } else { &mut self.primary }
    }

    pub(super) fn end_line(&mut self) {
        if *self.current_mut() == PromptSemantic::InputUntilEndOfLine {
            *self.current_mut() = PromptSemantic::Output;
        }
    }

    pub(super) fn finish_osc(&mut self, action: Option<u8>) {
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
