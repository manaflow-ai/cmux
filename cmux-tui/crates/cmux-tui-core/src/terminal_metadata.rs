//! Bounded, generic terminal metadata collected from PTY output.
//!
//! The OSC string framing state machine is adapted from herdrdev/herdr's
//! `src/pane/osc.rs`, Apache-2.0, commit
//! `7b675f42af35508eab66ac42fe1598628597a893`. The cmux implementation is
//! modified by manaflow: it retains only OSC 9 progress text, applies strict
//! byte and character bounds, accepts C1 ST, and exposes the result as a
//! terminal primitive. It has no agent names, manifests, or roster policy.

const MAX_OSC_BODY_BYTES: usize = 4096;
pub(crate) const MAX_PROGRESS_CHARS: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum OscState {
    #[default]
    Ground,
    Escape,
    Body,
    BodyEscape,
    IgnoringString,
    IgnoringStringEscape,
    Discarding,
    DiscardingEscape,
}

#[derive(Debug, Default)]
struct OscCollector {
    state: OscState,
    body: Vec<u8>,
    /// Number of UTF-8 continuation bytes still expected after a lead byte.
    /// Raw C1 values share this byte range, so framing is recognized only at
    /// code-point boundaries.
    utf8_continuations: u8,
}

impl OscCollector {
    fn observe(&mut self, bytes: &[u8], mut receive: impl FnMut(&[u8])) {
        for &byte in bytes {
            if self.utf8_continuations > 0 {
                if is_utf8_continuation(byte) {
                    self.utf8_continuations -= 1;
                    if self.state == OscState::Body {
                        self.push(byte);
                    }
                    continue;
                }
                // An invalid or truncated UTF-8 sequence cannot hide the
                // next control byte. Process this byte again as framing.
                self.utf8_continuations = 0;
            }
            self.utf8_continuations = utf8_continuation_count(byte);
            match self.state {
                OscState::Ground => match byte {
                    0x1b => self.state = OscState::Escape,
                    // C1 OSC. This is uncommon in UTF-8 PTYs but valid in an
                    // 8-bit control stream.
                    0x9d => {
                        self.body.clear();
                        self.state = OscState::Body;
                    }
                    // C1 DCS, SOS, PM, and APC. Their payloads are ignored
                    // so an embedded OSC cannot leak metadata.
                    0x90 | 0x98 | 0x9e | 0x9f => {
                        self.state = OscState::IgnoringString;
                    }
                    _ => {}
                },
                OscState::Escape => match byte {
                    b']' => {
                        self.body.clear();
                        self.state = OscState::Body;
                    }
                    0x18 | 0x1a => self.state = OscState::Ground,
                    0x1b => self.state = OscState::Escape,
                    b'P' | b'X' | b'^' | b'_' => {
                        // DCS, SOS, PM, and APC are string controls. Ignore
                        // their bodies so embedded OSC bytes cannot leak.
                        self.state = OscState::IgnoringString;
                    }
                    _ => self.state = OscState::Ground,
                },
                OscState::Body => match byte {
                    0x18 | 0x1a => self.cancel(),
                    0x07 | 0x9c => self.finish(&mut receive),
                    0x1b => self.state = OscState::BodyEscape,
                    _ => self.push(byte),
                },
                OscState::BodyEscape => match byte {
                    0x18 | 0x1a => self.cancel(),
                    b'\\' => self.finish(&mut receive),
                    0x07 | 0x9c => self.finish(&mut receive),
                    0x1b => {
                        // A second ESC remains a possible ST prefix. Keep
                        // one literal ESC in the bounded body and wait.
                        self.push(0x1b);
                        if self.state == OscState::Body {
                            self.state = OscState::BodyEscape;
                        }
                    }
                    _ => {
                        // The ESC was not an ST prefix. Preserve it and the
                        // current byte as payload, unless the body overflowed.
                        self.push(0x1b);
                        if self.state == OscState::Body {
                            self.push(byte);
                        }
                    }
                },
                OscState::IgnoringString => match byte {
                    0x18 | 0x1a => self.cancel(),
                    0x1b => self.state = OscState::IgnoringStringEscape,
                    0x9c => self.state = OscState::Ground,
                    _ => {}
                },
                OscState::IgnoringStringEscape => match byte {
                    0x18 | 0x1a => self.cancel(),
                    b'\\' | 0x9c => self.state = OscState::Ground,
                    0x1b => self.state = OscState::IgnoringStringEscape,
                    _ => self.state = OscState::IgnoringString,
                },
                OscState::Discarding => match byte {
                    0x18 | 0x1a => self.cancel(),
                    0x07 | 0x9c => self.state = OscState::Ground,
                    0x1b => self.state = OscState::DiscardingEscape,
                    _ => {}
                },
                OscState::DiscardingEscape => match byte {
                    0x18 | 0x1a => self.cancel(),
                    b'\\' | 0x9c => self.state = OscState::Ground,
                    0x1b => self.state = OscState::DiscardingEscape,
                    _ => self.state = OscState::Discarding,
                },
            }
        }
    }

    fn push(&mut self, byte: u8) {
        if self.body.len() >= MAX_OSC_BODY_BYTES {
            self.body.clear();
            self.state = OscState::Discarding;
            return;
        }
        self.body.push(byte);
        self.state = OscState::Body;
    }

    fn finish(&mut self, receive: &mut impl FnMut(&[u8])) {
        receive(&self.body);
        self.body.clear();
        self.state = OscState::Ground;
    }

    fn cancel(&mut self) {
        self.body.clear();
        self.state = OscState::Ground;
        self.utf8_continuations = 0;
    }
}

fn is_utf8_continuation(byte: u8) -> bool {
    (0x80..=0xbf).contains(&byte)
}

fn utf8_continuation_count(byte: u8) -> u8 {
    match byte {
        0xc2..=0xdf => 1,
        0xe0..=0xef => 2,
        0xf0..=0xf4 => 3,
        _ => 0,
    }
}

fn is_string_opener(byte: u8) -> bool {
    matches!(byte, 0x90 | 0x98 | 0x9d | 0x9f | 0x9e)
}

/// Generic terminal metadata retained from the output stream.
#[derive(Debug, Default)]
pub(crate) struct TerminalMetadata {
    osc: OscCollector,
    progress: String,
}

impl TerminalMetadata {
    /// Observe raw child output. The fast path avoids the state machine for
    /// ordinary output, which is the common case for non-OSC terminals.
    pub(crate) fn observe_output(&mut self, bytes: &[u8]) {
        // A framed string can cross reader chunks. Continue feeding bytes
        // while the collector is inside a control sequence, even when this
        // chunk contains no new ESC or C1 introducer.
        if self.osc.state == OscState::Ground
            && self.osc.utf8_continuations == 0
            && !bytes.iter().any(|byte| {
                *byte == 0x1b || is_string_opener(*byte) || utf8_continuation_count(*byte) != 0
            })
        {
            return;
        }
        let progress = &mut self.progress;
        self.osc.observe(bytes, |body| {
            let Some(separator) = body.iter().position(|byte| *byte == b';') else {
                return;
            };
            if &body[..separator] != b"9" {
                return;
            }
            *progress = String::from_utf8_lossy(&body[separator + 1..])
                .chars()
                .filter(|character| !character.is_control())
                .take(MAX_PROGRESS_CHARS)
                .collect();
        });
    }

    pub(crate) fn osc_progress(&self) -> &str {
        &self.progress
    }

    /// Restore a progress value carried by an authenticated terminal-host
    /// snapshot. Reject malformed values instead of silently changing the
    /// host's state at a reconnect boundary.
    pub(crate) fn set_osc_progress(&mut self, progress: &str) -> bool {
        if progress.chars().count() > MAX_PROGRESS_CHARS || progress.chars().any(char::is_control) {
            return false;
        }
        self.progress.clear();
        self.progress.push_str(progress);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn captures_bel_st_and_c1_osc_progress() {
        let mut metadata = TerminalMetadata::default();
        metadata.observe_output(b"\x1b]9;4;3;\x07");
        assert_eq!(metadata.osc_progress(), "4;3;");
        metadata.observe_output(b"\x1b]9;4;1;50\x1b\\");
        assert_eq!(metadata.osc_progress(), "4;1;50");
        metadata.observe_output(b"\x9d9;4;2;\x9c");
        assert_eq!(metadata.osc_progress(), "4;2;");
    }

    #[test]
    fn preserves_chunk_boundaries_and_ignores_other_strings() {
        let mut metadata = TerminalMetadata::default();
        metadata.observe_output(b"\x1b]9;4");
        metadata.observe_output(b";2;");
        metadata.observe_output(b"\x07");
        assert_eq!(metadata.osc_progress(), "4;2;");
        metadata.observe_output(b"\x1b]0;title\x07\x1bP+q9;bad\x1b\\");
        assert_eq!(metadata.osc_progress(), "4;2;");
    }

    #[test]
    fn preserves_non_st_escape_bytes_inside_an_osc_payload() {
        let mut metadata = TerminalMetadata::default();
        metadata.observe_output(b"\x1b]9;before\x1bXafter\x07");
        // The ESC is a control character and is removed from the exposed
        // text, but the following byte and the remainder of the payload must
        // survive the framing state transition.
        assert_eq!(metadata.osc_progress(), "beforeXafter");
    }

    #[test]
    fn utf8_continuation_bytes_are_not_c1_framing() {
        let mut metadata = TerminalMetadata::default();
        // U+00DD is encoded as C3 9D. The continuation byte is numerically
        // equal to C1 OSC, but it is ordinary text in this stream.
        metadata.observe_output("Ý".as_bytes());
        let mut first = b"\x1b]9;before".to_vec();
        first.extend_from_slice("Ýafter\x07".as_bytes());
        metadata.observe_output(&first);
        assert_eq!(metadata.osc_progress(), "beforeÝafter");

        // U+00DC is encoded as C3 9C. It must not terminate an OSC payload.
        let mut second = b"\x1b]9;left".to_vec();
        second.extend_from_slice("Üright\x07".as_bytes());
        metadata.observe_output(&second);
        assert_eq!(metadata.osc_progress(), "leftÜright");
    }

    #[test]
    fn c1_string_openers_are_isolated_from_osc() {
        let mut metadata = TerminalMetadata::default();
        for opener in [0x90, 0x98, 0x9e, 0x9f] {
            let mut bytes = vec![opener];
            bytes.extend_from_slice(b"payload \x9d9;leaked\x9c");
            metadata.observe_output(&bytes);
        }
        assert_eq!(metadata.osc_progress(), "");
        metadata.observe_output(b"\x1b]9;valid\x07");
        assert_eq!(metadata.osc_progress(), "valid");
    }

    #[test]
    fn can_and_sub_cancel_all_string_states() {
        let mut metadata = TerminalMetadata::default();
        for cancel in [0x18, 0x1a] {
            metadata.observe_output(&[0x1b, b']', b'9', b';', b'b', b'a', cancel]);
            metadata.observe_output(b"\x1b]9;valid\x07");
            assert_eq!(metadata.osc_progress(), "valid");

            metadata.observe_output(&[0x90, b'\x9d', cancel]);
            metadata.observe_output(b"\x1b]9;valid-again\x07");
            assert_eq!(metadata.osc_progress(), "valid-again");
        }
    }

    #[test]
    fn discards_oversized_bodies_and_bounds_text() {
        let mut metadata = TerminalMetadata::default();
        let mut body = b"\x1b]9;".to_vec();
        body.extend(std::iter::repeat_n(b'x', MAX_OSC_BODY_BYTES + 1));
        body.push(0x07);
        metadata.observe_output(&body);
        assert_eq!(metadata.osc_progress(), "");

        let mut bounded = b"\x1b]9;".to_vec();
        bounded.extend(std::iter::repeat_n(b'x', MAX_PROGRESS_CHARS + 32));
        bounded.push(0x07);
        metadata.observe_output(&bounded);
        assert_eq!(metadata.osc_progress().chars().count(), MAX_PROGRESS_CHARS);
    }
}
