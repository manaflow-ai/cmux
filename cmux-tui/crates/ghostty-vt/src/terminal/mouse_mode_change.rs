//! Recognizes control sequences that can change Ghostty's mouse modes, so the terminal re-queries them only when needed.

use super::*;

/// Conservatively recognizes control sequences that can change Ghostty's
/// authoritative mouse modes. False positives only trigger a state query;
/// C0 controls and DEL remain inside CSI so valid split sequences cannot be
/// missed by this hot-path filter.
#[derive(Default)]
pub(super) struct MouseModeChangeDetector {
    pub(super) state: MouseModeChangeState,
    pub(super) utf8_remaining: u8,
    pub(super) csi_private: bool,
    pub(super) csi_parameter: u16,
    pub(super) csi_has_digits: bool,
    pub(super) csi_has_mouse_mode: bool,
    pub(super) csi_intermediate: Option<u8>,
    pub(super) csi_invalid: bool,
}

#[derive(Default)]
pub(super) enum MouseModeChangeState {
    #[default]
    Ground,
    Escape,
    Csi,
}

impl MouseModeChangeDetector {
    pub(super) fn write(&mut self, data: &[u8]) -> bool {
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

    pub(super) fn start_csi(&mut self) {
        self.csi_private = false;
        self.csi_parameter = 0;
        self.csi_has_digits = false;
        self.csi_has_mouse_mode = false;
        self.csi_intermediate = None;
        self.csi_invalid = false;
    }

    pub(super) fn finish_csi_parameter(&mut self) {
        if self.csi_has_digits && MOUSE_DEC_MODES.contains(&self.csi_parameter) {
            self.csi_has_mouse_mode = true;
        }
        self.csi_parameter = 0;
        self.csi_has_digits = false;
    }

    pub(super) fn csi_changes_mouse_mode(&self, final_byte: u8) -> bool {
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
}
