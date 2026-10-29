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
    pub(super) screen_modes: ScreenModeFlags,
    pub(super) saved_screen_modes: ScreenModeFlags,
    pub(super) revision: u64,
}

/// The DEC private modes that switch to the alternate screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ScreenMode {
    /// `?47`
    Alternate,
    /// `?1047`
    AlternateClear,
    /// `?1049`
    AlternateSaveCursor,
}

impl ScreenMode {
    const ALL: [Self; 3] = [Self::Alternate, Self::AlternateClear, Self::AlternateSaveCursor];

    pub(super) fn from_parameter(mode: u16) -> Option<Self> {
        match mode {
            47 => Some(Self::Alternate),
            1047 => Some(Self::AlternateClear),
            1049 => Some(Self::AlternateSaveCursor),
            _ => None,
        }
    }
}

/// One flag per [`ScreenMode`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(super) struct ScreenModeFlags {
    alternate: bool,
    alternate_clear: bool,
    alternate_save_cursor: bool,
}

impl ScreenModeFlags {
    pub(super) fn get(self, mode: ScreenMode) -> bool {
        match mode {
            ScreenMode::Alternate => self.alternate,
            ScreenMode::AlternateClear => self.alternate_clear,
            ScreenMode::AlternateSaveCursor => self.alternate_save_cursor,
        }
    }

    pub(super) fn set(&mut self, mode: ScreenMode, enabled: bool) {
        let flag = match mode {
            ScreenMode::Alternate => &mut self.alternate,
            ScreenMode::AlternateClear => &mut self.alternate_clear,
            ScreenMode::AlternateSaveCursor => &mut self.alternate_save_cursor,
        };
        *flag = enabled;
    }
}

/// The screen modes one CSI sequence names, and the one it names last
/// (a restore leaves the alternate screen as that mode's saved value).
#[derive(Debug, Clone, Copy, Default)]
pub(super) struct ScreenModeSelection {
    pub(super) selected: ScreenModeFlags,
    pub(super) last: Option<ScreenMode>,
}

impl ScreenModeSelection {
    pub(super) fn push(&mut self, mode: u16) {
        let Some(mode) = ScreenMode::from_parameter(mode) else {
            return;
        };
        self.selected.set(mode, true);
        self.last = Some(mode);
    }

    pub(super) fn modes(self) -> impl Iterator<Item = ScreenMode> {
        ScreenMode::ALL.into_iter().filter(move |mode| self.selected.get(*mode))
    }

    pub(super) fn is_empty(&self) -> bool {
        self.last.is_none()
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
        if let Some(expected) = PREFIX.get(usize::from(self.prefix_len)) {
            if byte == *expected {
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
    pub(super) fn is_ground(&self) -> bool {
        matches!(self.state, PromptTrackState::Ground)
    }

    /// Whether a line end (LF, VT, FF) in ground state would change the
    /// semantic: only while input runs until the end of the line.
    pub(super) fn waits_for_line_end(&self) -> bool {
        let current = if self.alternate_active { self.alternate } else { self.primary };
        current == PromptSemantic::InputUntilEndOfLine
    }

    /// Original byte-at-a-time feed, kept as the exactness reference.
    pub(super) fn feed_reference(&mut self, data: &[u8]) {
        for &byte in data {
            self.step(byte);
        }
    }

    #[inline(always)]
    pub(super) fn step(&mut self, byte: u8) {
        {
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
                        self.screen_modes = ScreenModeFlags::default();
                        self.saved_screen_modes = ScreenModeFlags::default();
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

    pub(super) fn apply_screen_modes(&mut self, action: u8, screen_modes: ScreenModeSelection) {
        match action {
            b'h' | b'l' if !screen_modes.is_empty() => {
                let enabled = action == b'h';
                for mode in screen_modes.modes() {
                    self.screen_modes.set(mode, enabled);
                }
                self.alternate_active = enabled;
            }
            b's' => {
                for mode in screen_modes.modes() {
                    self.saved_screen_modes.set(mode, self.screen_modes.get(mode));
                }
            }
            b'r' => {
                for mode in screen_modes.modes() {
                    self.screen_modes.set(mode, self.saved_screen_modes.get(mode));
                }
                if let Some(last) = screen_modes.last {
                    self.alternate_active = self.saved_screen_modes.get(last);
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
