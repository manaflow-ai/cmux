//! The streaming scanner: PTY bytes in, the same bytes out except that each
//! complete file-medium Kitty graphics command becomes a direct one.
//!
//! Output is copied in runs: the scanner only advances an index over the
//! input and copies a run when it must divert (start holding a command), so
//! output without `ESC _ G` costs one `memmem` pass plus the copy the caller
//! makes anyway.

use std::sync::LazyLock;

use memchr::memmem;

use crate::command::{CLOSE_OPEN_LOAD, Control, Medium, write_direct};
use crate::{Limits, MediaRefusal, media};

const ESC: u8 = 0x1b;
const CAN: u8 = 0x18;
const SUB: u8 = 0x1a;
/// `ESC _`, built once: building a finder per read would cost more than the
/// search on short reads.
static APC_INTRODUCER: LazyLock<memmem::Finder<'static>> =
    LazyLock::new(|| memmem::Finder::new(b"\x1b_"));
static KITTY_INTRODUCER: LazyLock<memmem::Finder<'static>> =
    LazyLock::new(|| memmem::Finder::new(b"\x1b_G"));

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum State {
    #[default]
    Ground,
    /// After an ESC that went out.
    Escape,
    /// After `ESC _` that went out.
    ApcIntroducer,
    /// Inside an APC that is passed through: until ESC, CAN or SUB.
    ApcBody,
    /// After `ESC _ G` that went out: control data is held in `held`.
    Control,
    /// A file-medium command's payload is held after the control data.
    Payload,
}

/// Rewrites one terminal's output stream. Keep one per PTY: an APC split
/// across reads is carried to the next [`Self::rewrite`].
#[derive(Debug, Default)]
pub struct KittyMediaRewriter {
    limits: Limits,
    state: State,
    /// Bytes after `ESC _ G` of a command that may be file-medium.
    held: Vec<u8>,
    /// The held command's last byte was ESC (a possible `ESC \`).
    held_escape: bool,
    /// A direct chunked load is open (its last chunk said `m=1`).
    direct_load_open: bool,
    rewritten: u64,
    last_refusal: Option<MediaRefusal>,
}

impl KittyMediaRewriter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_limits(limits: Limits) -> Self {
        Self { limits, ..Self::default() }
    }

    /// Appends the rewritten form of `input` to `out`.
    // perf-hot: <1% of a 64 KiB copy, terminal-host PTY reader
    pub fn rewrite(&mut self, input: &[u8], out: &mut Vec<u8>) {
        let mut index = 0;
        // Start of the run not yet copied to `out`.
        let mut copied = 0;
        while index < input.len() {
            match self.state {
                State::Ground => {
                    // `ESC _` is the only way in; `memmem` skips the common
                    // `ESC [` inside its vector search.
                    let rest = input.get(index..).unwrap_or(&[]);
                    match APC_INTRODUCER.find(rest) {
                        Some(offset) => {
                            index = index.saturating_add(offset).saturating_add(2);
                            self.state = State::ApcIntroducer;
                        }
                        None => {
                            index = input.len();
                            if rest.last() == Some(&ESC) {
                                self.state = State::Escape;
                            }
                        }
                    }
                }
                State::Escape => {
                    // A non-`_` byte is left for Ground: it may be ESC again.
                    if input.get(index) == Some(&b'_') {
                        index = index.saturating_add(1);
                        self.state = State::ApcIntroducer;
                    } else {
                        self.state = State::Ground;
                    }
                }
                State::ApcIntroducer => {
                    if input.get(index) == Some(&b'G') {
                        index = index.saturating_add(1);
                        out.extend_from_slice(input.get(copied..index).unwrap_or(&[]));
                        copied = index;
                        self.held.clear();
                        self.held_escape = false;
                        self.state = State::Control;
                    } else {
                        self.state = State::ApcBody;
                    }
                }
                State::ApcBody => {
                    let rest = input.get(index..).unwrap_or(&[]);
                    match memchr::memchr3(ESC, CAN, SUB, rest) {
                        Some(offset) => {
                            let at = index.saturating_add(offset);
                            index = at.saturating_add(1);
                            self.state = if input.get(at) == Some(&ESC) {
                                State::Escape
                            } else {
                                State::Ground
                            };
                        }
                        None => index = input.len(),
                    }
                }
                State::Control | State::Payload => {
                    let Some(&byte) = input.get(index) else { break };
                    if self.hold(byte, out) == Step::Consumed {
                        index = index.saturating_add(1);
                    }
                    // Held bytes never go out as a run; a replayed byte
                    // starts the next one.
                    copied = index;
                }
            }
        }
        out.extend_from_slice(input.get(copied..).unwrap_or(&[]));
    }

    /// [`Self::rewrite`] without a copy when nothing changes: `input` itself
    /// when it starts at ground and holds no `ESC _ G`, else the rewritten
    /// bytes in `scratch`.
    // perf-hot: <1% of a 64 KiB copy, local PTY reader
    pub fn rewrite_borrowed<'a>(&mut self, input: &'a [u8], scratch: &'a mut Vec<u8>) -> &'a [u8] {
        if self.state == State::Ground && KITTY_INTRODUCER.find(input).is_none() {
            // Only the last bytes can begin a command the next read ends.
            // An unterminated other APC needs no state: its body ends at the
            // next ESC, which Ground finds too.
            self.state = match input {
                [.., ESC, b'_'] => State::ApcIntroducer,
                [.., ESC] => State::Escape,
                _ => State::Ground,
            };
            return input;
        }
        scratch.clear();
        self.rewrite(input, scratch);
        scratch
    }

    /// Appends whatever is held back (an unfinished command) unchanged; call
    /// at end of stream.
    pub fn finish(&mut self, out: &mut Vec<u8>) {
        if self.is_holding() {
            self.release(out);
        }
        self.state = State::Ground;
    }

    /// Whether bytes of an unfinished file-medium command are held back.
    pub fn is_holding(&self) -> bool {
        matches!(self.state, State::Control | State::Payload)
    }

    /// Commands rewritten so far.
    pub fn rewritten_commands(&self) -> u64 {
        self.rewritten
    }

    /// Why the latest file-medium command was passed through, if it was.
    pub fn last_refusal(&self) -> Option<&MediaRefusal> {
        self.last_refusal.as_ref()
    }

    /// One byte of a held command. A byte that ends the hold without being
    /// part of it is left for the state the hold switched to.
    fn hold(&mut self, byte: u8, out: &mut Vec<u8>) -> Step {
        if self.held_escape {
            if byte == b'\\' {
                self.finish_command(out);
                self.state = State::Ground;
                return Step::Consumed;
            }
            // ESC without `\` aborts the APC and starts a new sequence.
            self.release(out);
            self.state = State::Escape;
            return Step::Replay;
        }
        match byte {
            ESC => {
                self.held_escape = true;
                Step::Consumed
            }
            CAN | SUB => {
                self.release(out);
                self.state = State::Ground;
                Step::Replay
            }
            b';' if self.state == State::Control => {
                let open = self.direct_load_open;
                let parsed = Control::parse(&self.held)
                    .map(|control| (next_load_open(open, &control), control.medium()));
                // A file command updates the load state once it is read.
                if let Some((open, Medium::Direct | Medium::Unknown)) = parsed {
                    self.direct_load_open = open;
                }
                let medium = parsed.map(|(_, medium)| medium);
                if matches!(medium, Some(Medium::File | Medium::TempFile | Medium::SharedMemory)) {
                    self.held.push(byte);
                    self.state = State::Payload;
                    Step::Consumed
                } else {
                    // A direct upload: its payload streams through unheld.
                    self.release(out);
                    self.state = State::ApcBody;
                    Step::Replay
                }
            }
            0x20..=0x7e if self.held.len() < self.limits.max_held_bytes => {
                self.held.push(byte);
                Step::Consumed
            }
            // Other controls, 8-bit bytes or an oversized command: not one
            // this rewriter serves, so the terminal sees it unchanged.
            _ => {
                self.release(out);
                self.state = State::ApcBody;
                Step::Replay
            }
        }
    }

    /// Sends the held bytes (and a held ESC) out unchanged.
    fn release(&mut self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.held);
        if self.held_escape {
            out.push(ESC);
        }
        self.held.clear();
        self.held_escape = false;
    }

    fn note_direct(&mut self, control: &Control<'_>) {
        self.direct_load_open = next_load_open(self.direct_load_open, control);
    }

    /// A held command ended with `ESC \`: rewrite it or send it unchanged.
    fn finish_command(&mut self, out: &mut Vec<u8>) {
        let held = std::mem::take(&mut self.held);
        self.held_escape = false;
        let (control_bytes, payload) = match memchr::memchr(b';', &held) {
            Some(at) => (held.get(..at).unwrap_or(&[]), held.get(at.saturating_add(1)..)),
            None => (&held[..], None),
        };
        let result = match (Control::parse(control_bytes), payload) {
            (Some(control), Some(payload)) => {
                let medium = control.medium();
                let read = match (control.number(b'O'), control.number(b'S')) {
                    (Some(offset), Some(size)) => {
                        media::read(medium, payload, offset, size, self.limits.max_file_bytes)
                    }
                    _ => Err(MediaRefusal::BadRange),
                };
                match read {
                    Ok(data) => {
                        if self.direct_load_open {
                            out.extend_from_slice(CLOSE_OPEN_LOAD);
                        }
                        self.direct_load_open = false;
                        write_direct(out, &control, &data);
                        Ok(())
                    }
                    Err(refusal) => {
                        self.note_direct(&control);
                        Err(Some(refusal))
                    }
                }
            }
            (Some(control), None) => {
                self.note_direct(&control);
                let file = matches!(
                    control.medium(),
                    Medium::File | Medium::TempFile | Medium::SharedMemory
                );
                Err(file.then_some(MediaRefusal::BadPath))
            }
            (None, _) => Err(None),
        };
        match result {
            Ok(()) => {
                self.rewritten = self.rewritten.saturating_add(1);
                self.last_refusal = None;
            }
            Err(refusal) => {
                if refusal.is_some() {
                    self.last_refusal = refusal;
                }
                out.extend_from_slice(&held);
                out.extend_from_slice(b"\x1b\\");
            }
        }
        self.held = held;
        self.held.clear();
    }
}

/// Whether a direct chunked load is open after a command with this control
/// data, given whether one was open before.
fn next_load_open(open: bool, control: &Control<'_>) -> bool {
    match control.medium() {
        Medium::Direct if control.transmits() => control.more_chunks(),
        Medium::Direct | Medium::Unknown => open,
        // Kitty abandons an open load for any other medium.
        Medium::File | Medium::TempFile | Medium::SharedMemory => false,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Step {
    /// The byte is part of the held command (or ended it).
    Consumed,
    /// The hold ended before this byte; scan it in the new state.
    Replay,
}
