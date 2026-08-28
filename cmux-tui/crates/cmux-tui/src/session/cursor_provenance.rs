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
    /// Inside an OSC string body. BEL is an OSC terminator.
    OscBody,
    /// Inside a DCS/APC/PM/SOS string body. Only ST terminates these.
    StringBody,
    /// Saw ESC inside a string body (possible ST). The flag preserves the
    /// body's terminator rules while the next byte is inspected.
    StringBodyEscape {
        osc: bool,
    },
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
            State::Ground => match byte {
                0x1b => self.state = State::Escape,
                0x90 | 0x98 | 0x9b | 0x9d | 0x9e | 0x9f => self.dispatch_c1(byte),
                _ => {}
            },
            State::Escape => self.dispatch_escape(byte),
            State::Csi(csi) => self.step_csi(csi, byte),
            State::OscBody => self.step_string_body(true, byte),
            State::StringBody => self.step_string_body(false, byte),
            State::StringBodyEscape { osc } => {
                if byte == b'\\' {
                    // ST terminates the string.
                    self.state = State::Ground;
                } else {
                    // An ESC that is not followed by '\\' is string data. Do
                    // not dispatch the byte as a fresh terminal escape: doing
                    // so would let payload bytes synthesize DECSCUSR.
                    self.step_string_body(osc, byte);
                }
            }
        }
    }

    /// Consume one byte in a string body, preserving OSC's BEL terminator
    /// distinction from DCS/APC/PM/SOS bodies.
    fn step_string_body(&mut self, osc: bool, byte: u8) {
        match byte {
            0x9c => self.state = State::Ground,
            0x18 | 0x1a => self.state = State::Ground,
            0x1b => self.state = State::StringBodyEscape { osc },
            0x07 if osc => self.state = State::Ground,
            _ => {
                self.state = if osc { State::OscBody } else { State::StringBody };
            }
        }
    }

    fn dispatch_escape(&mut self, byte: u8) {
        match byte {
            b'[' => self.state = State::Csi(CsiState::default()),
            b']' => self.state = State::OscBody,
            b'P' | b'_' | b'^' | b'X' => self.state = State::StringBody,
            b'c' => {
                // RIS resets DECSCUSR to the terminal default.
                self.authored = false;
                self.state = State::Ground;
            }
            0x1b => {}
            _ => self.dispatch_c1(byte),
        }
    }

    /// Dispatch the single-byte C1 forms of the sequence introducers.
    ///
    /// ECMA-48 defines these controls alongside their 7-bit `ESC` forms:
    /// `CSI` is 0x9B, while DCS/SOS/OSC/PM/APC are 0x90/0x98/0x9D/0x9E/0x9F.
    /// Keeping this mapping in one place prevents the streaming parser from
    /// treating an 8-bit sequence opener as ordinary payload.
    fn dispatch_c1(&mut self, byte: u8) {
        match byte {
            0x9b => self.state = State::Csi(CsiState::default()),
            0x90 | 0x98 | 0x9e | 0x9f => self.state = State::StringBody,
            0x9d => self.state = State::OscBody,
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
    fn c1_string_terminator_ends_all_string_bodies() {
        let mut p = CursorStyleProvenance::default();
        for opener in *b"]P_^X" {
            p.scan(&[0x1b, opener]);
            p.scan(b"payload 5 q");
            p.scan(&[0x9c]);
            assert!(!p.authored(), "string body payload must not author");
        }

        p.scan(b"\x1b[5 q");
        assert!(p.authored(), "C1 ST must return the parser to ground");
    }

    #[test]
    fn c1_csi_decscusr_authors_and_resets() {
        let mut p = CursorStyleProvenance::default();
        // CSI may be encoded as the single C1 byte 0x9B instead of ESC [.
        p.scan(&[0x9b]);
        p.scan(b"5 ");
        p.scan(b"q");
        assert!(p.authored());
        p.scan(b"\x9b0 q");
        assert!(!p.authored());
    }

    #[test]
    fn c1_string_introducers_skip_payload_until_st() {
        let mut p = CursorStyleProvenance::default();
        // Every ECMA-48 string opener has an 8-bit C1 spelling.  Payloads
        // can contain bytes that look like either 7-bit or 8-bit CSI, but
        // neither is a control sequence while the string is open.
        for opener in [0x90, 0x98, 0x9d, 0x9e, 0x9f] {
            p.scan(&[opener]);
            p.scan(b"payload \x9b6 q");
            assert!(!p.authored(), "C1 string payload must not author");
            p.scan(&[0x9c]);
        }

        p.scan(b"\x9b7 q");
        assert!(p.authored(), "C1 ST must return the parser to ground");
    }

    #[test]
    fn c1_string_openers_and_st_split_across_chunks() {
        let mut p = CursorStyleProvenance::default();
        p.scan(&[0x9d]);
        p.scan(b"payload \x9b");
        p.scan(b"5 q");
        assert!(!p.authored());
        p.scan(&[0x9c]);
        p.scan(b"\x9b5 q");
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

#[test]
fn bell_only_terminates_osc_strings() {
    let mut p = CursorStyleProvenance::default();
    p.scan(b"\x1b]payload\x07\x1b[5 q");
    assert!(p.authored());

    // An ESC that is not followed by ST does not change the body's
    // terminator rules. BEL must still close an OSC body after such a byte.
    let mut p = CursorStyleProvenance::default();
    p.scan(b"\x1b]payload\x1b\x07\x1b[5 q");
    assert!(p.authored(), "BEL must still close OSC after a non-ST ESC");

    for opener in *b"P_^X" {
        let mut p = CursorStyleProvenance::default();
        p.scan(&[0x1b, opener]);
        p.scan(b"payload\x07\x1b[5 q");
        assert!(!p.authored(), "BEL must not close non-OSC string");
        p.scan(b"\x1b\\\x1b[5 q");
        assert!(p.authored(), "ST must close non-OSC string");
    }
}

#[test]
fn can_and_sub_abort_string_bodies() {
    for opener in *b"]P_^X" {
        for abort in [0x18, 0x1a] {
            let mut p = CursorStyleProvenance::default();
            p.scan(&[0x1b, opener, abort]);
            p.scan(b"\x1b[5 q");
            assert!(p.authored(), "CAN/SUB must abort the string");
        }
    }
}
