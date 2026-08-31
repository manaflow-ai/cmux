//! Passive OSC 9 progress capture for screen detection.
//!
//! Ported from herdrdev/herdr `src/pane/osc.rs` at commit 7b675f42af35
//! (Apache-2.0, see `cmux-tui/ATTRIBUTIONS.md`), modified by manaflow:
//! only the OSC 9 payload is retained (titles already flow through the
//! terminal), and observation is gated to panes whose foreground process
//! is a known agent so ordinary shells never pay the byte scan.
//!
//! Nothing here affects rendering; the retained payload feeds the
//! manifests' `osc_progress` region (e.g. ConEmu progress `"4;3;50"`).

const MAX_BODY_BYTES: usize = 4096;
/// Progress payload text is untrusted child output; cap retained size.
const MAX_PROGRESS_CHARS: usize = 256;

/// Collects complete OSC bodies from a raw byte stream. Consumers receive
/// only bodies; the framing state machine is command-agnostic.
#[derive(Debug, Default)]
struct OscStreamCollector {
    state: OscStreamState,
    body: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum OscStreamState {
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

fn is_ignored_string_intro(byte: u8) -> bool {
    // DCS, SOS, PM, APC: string sequences whose bodies must be skipped so
    // an OSC-looking payload inside them is not misparsed.
    matches!(byte, b'P' | b'X' | b'^' | b'_')
}

impl OscStreamCollector {
    fn observe(&mut self, bytes: &[u8], mut receive: impl FnMut(&[u8])) {
        for &byte in bytes {
            match self.state {
                OscStreamState::Ground => {
                    if byte == 0x1b {
                        self.state = OscStreamState::Escape;
                    }
                }
                OscStreamState::Escape => match byte {
                    b']' => {
                        self.body.clear();
                        self.state = OscStreamState::Body;
                    }
                    0x1b => self.state = OscStreamState::Escape,
                    byte if is_ignored_string_intro(byte) => {
                        self.state = OscStreamState::IgnoringString;
                    }
                    _ => self.state = OscStreamState::Ground,
                },
                OscStreamState::Body => match byte {
                    0x07 => self.finish(&mut receive),
                    0x1b => self.state = OscStreamState::BodyEscape,
                    _ => self.push(byte),
                },
                OscStreamState::BodyEscape => match byte {
                    b'\\' => self.finish(&mut receive),
                    0x07 => {
                        self.push(0x1b);
                        if matches!(self.state, OscStreamState::Body) {
                            self.finish(&mut receive);
                        } else {
                            self.state = OscStreamState::Ground;
                        }
                    }
                    0x1b => {
                        self.push(0x1b);
                        self.state = match self.state {
                            OscStreamState::Body => OscStreamState::BodyEscape,
                            OscStreamState::Discarding => OscStreamState::DiscardingEscape,
                            state => state,
                        };
                    }
                    _ => {
                        self.push(0x1b);
                        if matches!(self.state, OscStreamState::Body) {
                            self.push(byte);
                        }
                    }
                },
                OscStreamState::IgnoringString => {
                    if byte == 0x1b {
                        self.state = OscStreamState::IgnoringStringEscape;
                    }
                }
                OscStreamState::IgnoringStringEscape => {
                    if byte == b'\\' {
                        self.state = OscStreamState::Ground;
                    } else if byte != 0x1b {
                        self.state = OscStreamState::IgnoringString;
                    }
                }
                OscStreamState::Discarding => {
                    if byte == 0x07 {
                        self.state = OscStreamState::Ground;
                    } else if byte == 0x1b {
                        self.state = OscStreamState::DiscardingEscape;
                    }
                }
                OscStreamState::DiscardingEscape => {
                    if byte == b'\\' {
                        self.state = OscStreamState::Ground;
                    } else if byte != 0x1b {
                        self.state = OscStreamState::Discarding;
                    }
                }
            }
        }
    }

    fn push(&mut self, byte: u8) {
        self.body.push(byte);
        if self.body.len() > MAX_BODY_BYTES {
            self.body.clear();
            self.state = OscStreamState::Discarding;
        } else {
            self.state = OscStreamState::Body;
        }
    }

    fn finish(&mut self, receive: &mut impl FnMut(&[u8])) {
        receive(&self.body);
        self.body.clear();
        self.state = OscStreamState::Ground;
    }
}

/// Retains the latest OSC 9 payload (the part after `9;`) emitted by the
/// pane's child. Sequences spanning chunk boundaries parse correctly; a
/// new foreground agent must not inherit prior evidence (`clear_retained`).
#[derive(Debug, Default)]
pub(crate) struct AgentOscProgressTracker {
    collector: OscStreamCollector,
    latest_progress: Option<String>,
}

impl AgentOscProgressTracker {
    pub(crate) fn observe(&mut self, bytes: &[u8]) {
        let latest_progress = &mut self.latest_progress;
        self.collector.observe(bytes, |body| {
            let Some((command, payload)) = split_osc_body(body) else { return };
            if command == b"9" {
                *latest_progress = Some(sanitize_osc_string(payload, MAX_PROGRESS_CHARS));
            }
        });
    }

    /// The latest retained OSC 9 payload, `""` if none.
    pub(crate) fn latest_progress(&self) -> &str {
        self.latest_progress.as_deref().unwrap_or("")
    }

    /// Drops retained evidence so a new foreground agent starts clean. The
    /// in-flight parse state is kept: a sequence spanning the agent change
    /// finalizes normally and is attributed to the new agent.
    pub(crate) fn clear_retained(&mut self) {
        self.latest_progress = None;
    }
}

/// Splits an OSC body at the first `;` into `(command, payload)`.
fn split_osc_body(body: &[u8]) -> Option<(&[u8], &[u8])> {
    let sep = body.iter().position(|&byte| byte == b';')?;
    Some((&body[..sep], &body[sep + 1..]))
}

fn sanitize_osc_string(payload: &[u8], max_chars: usize) -> String {
    String::from_utf8_lossy(payload).chars().filter(|ch| !ch.is_control()).take(max_chars).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn screen_detect_osc_progress_tracks_the_latest_payload() {
        let mut tracker = AgentOscProgressTracker::default();
        tracker.observe(b"plain output\x1b]9;4;3;\x07more");
        assert_eq!(tracker.latest_progress(), "4;3;");
        tracker.observe(b"\x1b]9;4;1;50\x1b\\");
        assert_eq!(tracker.latest_progress(), "4;1;50");
        tracker.clear_retained();
        assert_eq!(tracker.latest_progress(), "");
    }

    #[test]
    fn screen_detect_osc_progress_survives_chunk_splits_and_ignores_others() {
        let mut tracker = AgentOscProgressTracker::default();
        tracker.observe(b"\x1b]9;4");
        tracker.observe(b";2;");
        tracker.observe(b"\x07");
        assert_eq!(tracker.latest_progress(), "4;2;");
        // Titles and DCS strings never contaminate progress.
        tracker.observe(b"\x1b]0;a title\x07\x1bP+q544e\x1b\\");
        assert_eq!(tracker.latest_progress(), "4;2;");
        // Oversized bodies are discarded, not truncated into evidence.
        let mut oversized = b"\x1b]9;".to_vec();
        oversized.extend(std::iter::repeat_n(b'x', MAX_BODY_BYTES + 8));
        oversized.push(0x07);
        tracker.observe(&oversized);
        assert_eq!(tracker.latest_progress(), "4;2;");
    }
}
