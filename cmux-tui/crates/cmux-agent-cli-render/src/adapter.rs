//! Which stream a viewer gets for a terminal: what each program needs drawn, not a 1:1 PTY
//! mirror (Leo, 2026-11-16, about the phone: "surely we dont need to stream the [...] thing").
//!
//! - [`Adapter::Agent`]: Claude Code, Codex and opencode, the cell deltas of the hybrid stream
//!   ([`crate::stream`]), lean on the wire ([`crate::lean`]).
//! - [`Adapter::Shell`]: a plain shell, the same lean frames, which carry its lines (changed
//!   cells, scrolls as a shift) and its cursor. A full-screen program it runs (the alternate
//!   screen, or mouse tracking) goes as PTY bytes until it ends: the viewer's terminal then
//!   tracks the modes that program's input needs. [`FullScreenScan`] finds the byte where one
//!   starts.
//! - [`Adapter::Pty`]: anything else, the PTY bytes as before.

/// The stream a terminal's viewer gets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Adapter {
    Agent,
    Shell,
    Pty,
}

/// The agent adapters (`cmux_agent` hook `adapter.id`) drawn as cell deltas.
pub const AGENT_CLIS: &[&str] = &["claude", "claude-code", "codex", "opencode"];

/// Shells, by executable name, whose terminal gets [`Adapter::Shell`].
pub const SHELLS: &[&str] =
    &["bash", "zsh", "fish", "sh", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "elvish", "xonsh"];

impl Adapter {
    /// The adapter for a terminal whose running agent (its hook's adapter id) is `agent` and
    /// whose own program (the PTY's child) is the executable at `program`: a path, or an
    /// `argv[0]` (a login shell's starts with `-`).
    pub fn of(agent: Option<&str>, program: Option<&str>) -> Adapter {
        if agent.is_some_and(|agent| AGENT_CLIS.contains(&agent)) {
            return Adapter::Agent;
        }
        let name = program
            .map(|program| program.rsplit('/').next().unwrap_or(program).trim_start_matches('-'));
        if name.is_some_and(|name| SHELLS.contains(&name)) {
            return Adapter::Shell;
        }
        Adapter::Pty
    }
}

/// DEC private modes that make a program full-screen for [`Adapter::Shell`]: the alternate
/// screen (47, 1047, 1049) and mouse tracking (1000, 1002, 1003).
pub const FULL_SCREEN_MODES: &[u16] = &[47, 1047, 1049, 1000, 1002, 1003];

/// DEC private modes that change what the viewer's keys and pastes send, which a shell's lean
/// frames do not carry: cursor keys (1), focus events (1004), bracketed paste (2004) and mouse
/// encodings (1005, 1006, 1015). [`FullScreenScan::take_modes`] hands their sets and resets on.
pub const INPUT_MODES: &[u16] = &[1, 1004, 2004, 1005, 1006, 1015];

/// Longest control sequence the scan keeps across writes; a longer one is not a mode set.
const MAX_HELD: usize = 64;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
enum State {
    #[default]
    Ground,
    Escape,
    /// After `ESC [`: a `?` makes it a private mode sequence.
    CsiStart,
    /// Inside `ESC [ ?`, reading parameters.
    Private,
    /// Inside another control sequence, skipped to its final byte.
    Other,
}

/// Finds where a write starts a full-screen program: a `CSI ? Pm h` that sets one of
/// [`FULL_SCREEN_MODES`], also when the sequence is split across writes.
#[derive(Debug, Clone, Default)]
pub struct FullScreenScan {
    state: State,
    /// The bytes of the sequence being read, from its `ESC`, while they may be a mode set.
    held: Vec<u8>,
    param: u32,
    hit: bool,
    /// Every parameter so far is one of [`INPUT_MODES`].
    input: bool,
    /// Input mode sets and resets (and keypad `ESC =`, `ESC >`) seen, for the viewer.
    modes: Vec<u8>,
}

/// Where in a write a full-screen program starts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FullScreenStart {
    /// The start of the sequence that came in earlier writes (they reached the screen as
    /// frames already; the viewer needs them as bytes before `bytes[at..]`).
    pub carried: Vec<u8>,
    /// Where the sequence starts in this write (0 when it started in an earlier one).
    pub at: usize,
}

impl FullScreenScan {
    pub fn new() -> FullScreenScan {
        FullScreenScan::default()
    }

    /// Reads `bytes`; `Some` at the first sequence that sets a full-screen mode, after which
    /// the scan starts over.
    pub fn scan(&mut self, bytes: &[u8]) -> Option<FullScreenStart> {
        let carried_len = self.held.len();
        // Where this write's part of the sequence being read starts.
        let mut start = 0;
        let mut started_here = false;
        for (i, &byte) in bytes.iter().enumerate() {
            if byte == 0x1b {
                self.reset();
                self.state = State::Escape;
                self.held.push(byte);
                start = i;
                started_here = true;
                continue;
            }
            match self.state {
                State::Ground => continue,
                State::Escape => {
                    if matches!(byte, b'=' | b'>') {
                        self.modes.extend([0x1b, byte]);
                    }
                    self.state = if byte == b'[' { State::CsiStart } else { State::Ground };
                }
                State::CsiStart => {
                    self.state = match byte {
                        b'?' => {
                            self.input = true;
                            State::Private
                        }
                        0x40..=0x7e => State::Ground,
                        _ => State::Other,
                    };
                }
                State::Private => match byte {
                    b'0'..=b'9' => {
                        self.param =
                            self.param.saturating_mul(10).saturating_add(u32::from(byte - b'0'));
                    }
                    b';' => self.end_param(),
                    b'h' | b'l' => {
                        self.end_param();
                        if self.input && !self.hit {
                            self.modes.extend_from_slice(&self.held);
                            self.modes.push(byte);
                        }
                        if self.hit && byte == b'h' {
                            let carried = if started_here {
                                Vec::new()
                            } else {
                                self.held.get(..carried_len).map(<[u8]>::to_vec).unwrap_or_default()
                            };
                            self.reset();
                            return Some(FullScreenStart { carried, at: start });
                        }
                        self.state = State::Ground;
                    }
                    0x40..=0x7e => self.state = State::Ground,
                    _ => {}
                },
                State::Other => {
                    if (0x40..=0x7e).contains(&byte) {
                        self.state = State::Ground;
                    }
                }
            }
            if self.state == State::Ground {
                self.reset();
            } else {
                self.held.push(byte);
                if self.held.len() > MAX_HELD {
                    self.reset();
                }
            }
        }
        None
    }

    /// The input mode changes read since the last call, as bytes for the viewer's terminal.
    pub fn take_modes(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.modes)
    }

    fn end_param(&mut self) {
        let mode = u16::try_from(self.param).ok();
        if mode.is_some_and(|mode| FULL_SCREEN_MODES.contains(&mode)) {
            self.hit = true;
        }
        if !mode.is_some_and(|mode| INPUT_MODES.contains(&mode)) {
            self.input = false;
        }
        self.param = 0;
    }

    fn reset(&mut self) {
        self.state = State::Ground;
        self.held.clear();
        self.param = 0;
        self.hit = false;
        self.input = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agents_shells_and_everything_else() {
        assert_eq!(Adapter::of(Some("claude"), Some("/bin/zsh")), Adapter::Agent);
        assert_eq!(Adapter::of(Some("opencode"), None), Adapter::Agent);
        assert_eq!(Adapter::of(None, Some("/bin/zsh")), Adapter::Shell);
        assert_eq!(Adapter::of(None, Some("-zsh")), Adapter::Shell);
        assert_eq!(Adapter::of(Some("vim"), Some("bash")), Adapter::Shell);
        assert_eq!(Adapter::of(None, Some("/usr/bin/htop")), Adapter::Pty);
        assert_eq!(Adapter::of(None, Some("sleep")), Adapter::Pty);
        assert_eq!(Adapter::of(None, None), Adapter::Pty);
    }

    #[test]
    fn a_full_screen_mode_set_is_found_where_it_starts() {
        let mut scan = FullScreenScan::new();
        assert_eq!(scan.scan(b"ls\r\n\x1b[1;32mok\x1b[0m\x1b[?25l\x1b[?2004h"), None);
        let found = scan.scan(b"abc\x1b[?1049h\x1b[H").unwrap();
        assert_eq!(found, FullScreenStart { carried: Vec::new(), at: 3 });
        // Among other modes, and mouse tracking.
        assert_eq!(scan.scan(b"\x1b[?12;1002hx").unwrap().at, 0);
        // A reset is not a set.
        assert_eq!(scan.scan(b"\x1b[?1049l\x1b[?1000l"), None);
    }

    #[test]
    fn input_modes_are_handed_on_and_drawing_is_not() {
        let mut scan = FullScreenScan::new();
        assert_eq!(scan.scan(b"\x1b[?2004h$ \x1b[1mls\x1b[0m\x1b[?1h\x1b=\x1b[?25l\x1b[?20"), None);
        assert_eq!(scan.scan(b"04l\x1b[?2004;1004h"), None);
        assert_eq!(
            scan.take_modes(),
            b"\x1b[?2004h\x1b[?1h\x1b=\x1b[?2004l\x1b[?2004;1004h".to_vec()
        );
        assert!(scan.take_modes().is_empty());
        // A sequence that also sets something else is not handed on.
        assert_eq!(scan.scan(b"\x1b[?2004;25h"), None);
        assert!(scan.take_modes().is_empty());
    }

    #[test]
    fn a_mode_set_split_across_writes_carries_its_start() {
        let mut scan = FullScreenScan::new();
        assert_eq!(scan.scan(b"vim\r\n\x1b[?10"), None);
        let found = scan.scan(b"49h\x1b[H").unwrap();
        assert_eq!(found, FullScreenStart { carried: b"\x1b[?10".to_vec(), at: 0 });
        assert_eq!(scan.scan(b"\x1b"), None);
        assert_eq!(scan.scan(b"["), None);
        let found = scan.scan(b"?47h").unwrap();
        assert_eq!(found.carried, b"\x1b[".to_vec());
    }
}
