//! Streaming detection of application-authored cursor style (DECSCUSR).
//!
//! A scoped `attach --terminal` client must be a transparent passthrough: it
//! may only assert a cursor shape on the host terminal when the inner
//! application authored one. The daemon's resolved colors payload conflates
//! embedder defaults with application DECSCUSR, so provenance is recovered
//! here by scanning the raw inner-PTY output byte stream (and only that
//! stream; daemon-built vt-state replays and client-side default application
//! never feed this scanner).
//!
//! Authored becomes true on `CSI Ps SP q` with a non-zero style parameter,
//! and false again on `CSI 0 SP q` (reset to default), `CSI ! p` (DECSTR),
//! or `ESC c` (RIS). Sequences split across write chunks are handled; string
//! bodies (OSC/DCS/APC/PM/SOS) are skipped so their payload bytes cannot be
//! misread as sequences.

#[derive(Debug, Default)]
pub(crate) struct CursorStyleProvenance {
    authored: bool,
    state: State,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
enum State {
    #[default]
    Ground,
    Escape,
    Csi(CsiState),
    /// Inside an OSC/DCS/APC/PM/SOS string body.
    StringBody,
    /// Saw ESC inside a string body (possible ST).
    StringBodyEscape,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct CsiState {
    /// First numeric parameter, saturating.
    param: u16,
    /// Number of `;`-separated parameters seen so far (0 = none started).
    extra_params: bool,
    /// Private-marker prefix (`?`, `>`, `<`, `=`) seen.
    private: bool,
    /// Last intermediate byte (0x20..=0x2F), if any.
    intermediate: Option<u8>,
}

impl CursorStyleProvenance {
    /// Whether the inner application currently owns the cursor style.
    pub(crate) fn authored(&self) -> bool {
        self.authored
    }

    /// Forget everything. Used when the mirror is rebuilt from a
    /// daemon-generated vt-state replay, whose bytes are resolved state (not
    /// application intent) and must not count as authored.
    pub(crate) fn reset_for_replay(&mut self) {
        *self = Self::default();
    }

    /// Scan one chunk of raw inner-PTY output bytes.
    pub(crate) fn scan(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            self.step(byte);
        }
    }

    fn step(&mut self, byte: u8) {
        match self.state {
            State::Ground => {
                if byte == 0x1b {
                    self.state = State::Escape;
                }
            }
            State::Escape => self.dispatch_escape(byte),
            State::Csi(csi) => self.step_csi(csi, byte),
            State::StringBody => match byte {
                0x07 => self.state = State::Ground,
                0x1b => self.state = State::StringBodyEscape,
                _ => {}
            },
            State::StringBodyEscape => {
                if byte == b'\\' {
                    // ST terminates the string.
                    self.state = State::Ground;
                } else {
                    // The ESC canceled the string; process the byte as an
                    // ordinary escape dispatch (xterm behavior).
                    self.dispatch_escape(byte);
                }
            }
        }
    }

    fn dispatch_escape(&mut self, byte: u8) {
        match byte {
            b'[' => self.state = State::Csi(CsiState::default()),
            b']' | b'P' | b'_' | b'^' | b'X' => self.state = State::StringBody,
            b'c' => {
                // RIS resets DECSCUSR to the terminal default.
                self.authored = false;
                self.state = State::Ground;
            }
            0x1b => {}
            _ => self.state = State::Ground,
        }
    }

    fn step_csi(&mut self, mut csi: CsiState, byte: u8) {
        match byte {
            0x18 | 0x1a => self.state = State::Ground,
            0x1b => self.state = State::Escape,
            b'0'..=b'9' => {
                if !csi.extra_params && csi.intermediate.is_none() {
                    csi.param = csi.param.saturating_mul(10).saturating_add(u16::from(byte - b'0'));
                }
                self.state = State::Csi(csi);
            }
            b';' | b':' => {
                csi.extra_params = true;
                self.state = State::Csi(csi);
            }
            b'?' | b'>' | b'<' | b'=' => {
                csi.private = true;
                self.state = State::Csi(csi);
            }
            0x20..=0x2f => {
                csi.intermediate = Some(byte);
                self.state = State::Csi(csi);
            }
            0x40..=0x7e => {
                self.dispatch_csi(csi, byte);
                self.state = State::Ground;
            }
            // Other C0 controls are permitted inside CSI and do not change it.
            _ => self.state = State::Csi(csi),
        }
    }

    fn dispatch_csi(&mut self, csi: CsiState, final_byte: u8) {
        if csi.private {
            return;
        }
        match (final_byte, csi.intermediate) {
            // DECSCUSR: CSI Ps SP q
            (b'q', Some(b' ')) if !csi.extra_params => {
                self.authored = csi.param != 0;
            }
            // DECSTR: CSI ! p resets the cursor style to the default.
            (b'p', Some(b'!')) => {
                self.authored = false;
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_output_never_authors() {
        let mut p = CursorStyleProvenance::default();
        p.scan(b"hello world\r\nprompt $ ");
        assert!(!p.authored());
    }

    #[test]
    fn decscusr_nonzero_authors_and_zero_resets() {
        let mut p = CursorStyleProvenance::default();
        p.scan(b"\x1b[5 q");
        assert!(p.authored());
        p.scan(b"\x1b[0 q");
        assert!(!p.authored());
        p.scan(b"\x1b[2 q");
        assert!(p.authored());
        p.scan(b"\x1b[ q");
        assert!(!p.authored(), "an absent parameter defaults to 0 (reset)");
    }

    #[test]
    fn sequences_split_across_chunks_are_detected() {
        let mut p = CursorStyleProvenance::default();
        p.scan(b"\x1b");
        p.scan(b"[");
        p.scan(b"6");
        p.scan(b" ");
        assert!(!p.authored());
        p.scan(b"q");
        assert!(p.authored());
    }

    #[test]
    fn ris_and_decstr_reset_authorship() {
        let mut p = CursorStyleProvenance::default();
        p.scan(b"\x1b[3 q");
        assert!(p.authored());
        p.scan(b"\x1bc");
        assert!(!p.authored());
        p.scan(b"\x1b[4 q");
        assert!(p.authored());
        p.scan(b"\x1b[!p");
        assert!(!p.authored());
    }

    #[test]
    fn non_decscusr_csi_with_q_finals_do_not_author() {
        let mut p = CursorStyleProvenance::default();
        // DECLL (CSI Ps q, no space intermediate) and private-prefixed and
        // multi-parameter sequences must not count.
        p.scan(b"\x1b[1q");
        p.scan(b"\x1b[?5 q");
        p.scan(b"\x1b[1;2 q");
        assert!(!p.authored());
    }

    #[test]
    fn string_bodies_are_skipped() {
        let mut p = CursorStyleProvenance::default();
        // An OSC body containing DECSCUSR-looking payload bytes is not CSI.
        p.scan(b"\x1b]0;cursor 5 q style\x07");
        assert!(!p.authored(), "OSC body must not author");
        p.scan(b"\x1bP+q544e\x1b\\");
        assert!(!p.authored(), "DCS body must not author");
        // A real DECSCUSR after the strings still counts.
        p.scan(b"\x1b[5 q");
        assert!(p.authored());
    }

    #[test]
    fn replay_reset_clears_authorship_and_parser_state() {
        let mut p = CursorStyleProvenance::default();
        p.scan(b"\x1b[5 q\x1b[");
        assert!(p.authored());
        p.reset_for_replay();
        assert!(!p.authored());
        // Parser is back at ground: the next bytes parse from scratch.
        p.scan(b"6 q");
        assert!(!p.authored(), "stale partial CSI must not leak across a replay");
        p.scan(b"\x1b[6 q");
        assert!(p.authored());
    }
}
