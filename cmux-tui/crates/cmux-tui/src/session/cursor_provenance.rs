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

#[test]
fn can_and_sub_abort_string_bodies() {
    for opener in [b']', b'P', b'_', b'^', b'X'] {
        for abort in [0x18, 0x1a] {
            let mut p = CursorStyleProvenance::default();
            p.scan(&[0x1b, opener, abort]);
            p.scan(b"\x1b[5 q");
            assert!(p.authored(), "CAN/SUB must abort the string");
        }
    }
}
