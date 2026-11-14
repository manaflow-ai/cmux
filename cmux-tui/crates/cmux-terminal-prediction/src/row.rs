//! What the cursor row holds left of the cursor, read from plain output: the
//! text printed since the last line start, or nothing when that cannot be told.
//!
//! The engine compares it with the prompts it saw the remote's line editor
//! echo after ([`crate::engine`]): a row that reads exactly like one, printed
//! in answer to Return, is the shell waiting at its line editor, so the first
//! key typed there can be drawn at once instead of after two more echoes.
//!
//! Only a row built from text, styling and host state is known. A cursor
//! move, a tab, a backspace, an image, or anything this does not read makes
//! the row unknown until the next line start, so an unknown row never matches.
//! Each chunk costs a scan back to its last line start and at most
//! [`MAXIMUM_TAIL_BYTES`] bytes after it.

/// Row text kept at most; a longer row is unknown (no prompt is that long).
const MAXIMUM_ROW_BYTES: usize = 256;
/// Bytes after the last line start read per chunk; a longer tail is unknown.
const MAXIMUM_TAIL_BYTES: usize = 1_024;
/// Parameter bytes of a control sequence read; a longer one is unknown.
const MAXIMUM_PARAMETER_BYTES: usize = 16;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Ground,
    Escape,
    /// `ESC` and an intermediate byte: only `ESC ( B` (ASCII into G0, part of
    /// xterm's sgr0) leaves the row as it was.
    EscapeIntermediate,
    ControlSequence,
    /// An OSC payload (a title, a working directory, a shell-integration mark).
    OperatingSystemCommand,
    OperatingSystemCommandEscape,
}

#[derive(Clone, Debug)]
pub(crate) struct RowText {
    text: Option<Vec<u8>>,
    state: State,
    parameters: Vec<u8>,
    /// The previous chunk ended with CR, so a chunk opening with LF starts a
    /// row at column 0.
    ended_with_carriage_return: bool,
}

impl Default for RowText {
    fn default() -> Self {
        Self::new()
    }
}

impl RowText {
    pub(crate) fn new() -> Self {
        Self {
            // A new terminal starts with its cursor at the start of an empty row.
            text: Some(Vec::new()),
            state: State::Ground,
            parameters: Vec::new(),
            ended_with_carriage_return: false,
        }
    }

    /// The row left of the cursor, when known.
    pub(crate) fn text(&self) -> Option<&[u8]> {
        self.text.as_deref()
    }

    /// Output was lost, or the grid changed under it: the row is unknown.
    pub(crate) fn forget(&mut self) {
        self.text = None;
        self.state = State::Ground;
        self.ended_with_carriage_return = false;
    }

    /// One chunk of remote output, in order.
    pub(crate) fn observe(&mut self, bytes: &[u8]) {
        let Some(&last) = bytes.last() else { return };
        let starts_after_carriage_return = self.ended_with_carriage_return;
        self.ended_with_carriage_return = last == b'\r';
        let tail = match bytes.iter().rposition(|&byte| byte == b'\r' || byte == b'\n') {
            Some(index) => {
                let after_carriage_return = match index.checked_sub(1) {
                    Some(before) => bytes.get(before) == Some(&b'\r'),
                    None => starts_after_carriage_return,
                };
                // CR, or CR LF, puts the cursor at column 0; a bare LF keeps
                // the column, which this does not know.
                let at_line_start = bytes.get(index) == Some(&b'\r') || after_carriage_return;
                self.text = at_line_start.then(Vec::new);
                self.state = State::Ground;
                bytes.get(index + 1..).unwrap_or_default()
            }
            None => bytes,
        };
        if self.text.is_none() {
            return;
        }
        if tail.len() > MAXIMUM_TAIL_BYTES {
            self.forget();
            return;
        }
        for &byte in tail {
            if !self.read(byte) {
                self.text = None;
                return;
            }
        }
    }

    /// Reads one byte of a known row; `false` when the row is no longer known.
    fn read(&mut self, byte: u8) -> bool {
        match self.state {
            State::Ground => match byte {
                0x1B => {
                    self.state = State::Escape;
                    true
                }
                // BEL changes no cell. UTF-8 text is compared, not measured.
                0x07 => true,
                0x20..=0x7E | 0x80..=0xFF => self.push(byte),
                _ => false,
            },
            State::Escape => match byte {
                b'[' => {
                    self.state = State::ControlSequence;
                    self.parameters.clear();
                    true
                }
                b']' => {
                    self.state = State::OperatingSystemCommand;
                    true
                }
                // Keypad modes (DECKPAM, DECKPNM): input conventions only.
                b'=' | b'>' => {
                    self.state = State::Ground;
                    true
                }
                b'(' => {
                    self.state = State::EscapeIntermediate;
                    true
                }
                _ => false,
            },
            State::EscapeIntermediate => {
                self.state = State::Ground;
                byte == b'B'
            }
            State::ControlSequence => {
                if (0x20..=0x3F).contains(&byte) {
                    if self.parameters.len() >= MAXIMUM_PARAMETER_BYTES {
                        return false;
                    }
                    self.parameters.push(byte);
                    return true;
                }
                self.state = State::Ground;
                self.leaves_row(byte)
            }
            State::OperatingSystemCommand => {
                match byte {
                    0x07 => self.state = State::Ground,
                    0x1B => self.state = State::OperatingSystemCommandEscape,
                    _ => {}
                }
                true
            }
            State::OperatingSystemCommandEscape => {
                self.state = State::Ground;
                byte == b'\\'
            }
        }
    }

    /// Whether the control sequence ending in `final_byte` leaves the cursor
    /// and the text left of it as they were.
    fn leaves_row(&self, final_byte: u8) -> bool {
        let parameters = self.parameters.as_slice();
        match final_byte {
            // Styling.
            b'm' => true,
            // Clears right of the cursor or below it (zsh's `CSI J`, readline's
            // `CSI K` after a prompt).
            b'K' | b'J' => parameters.is_empty() || parameters == b"0",
            // A private mode other than the alternate screen: bracketed paste,
            // application cursor keys, a hidden or shown cursor.
            b'h' | b'l' => parameters.strip_prefix(b"?").is_some_and(|modes| {
                !modes
                    .split(|&byte| byte == b';')
                    .any(|mode| [b"1049".as_slice(), b"47", b"1047"].contains(&mode))
            }),
            _ => false,
        }
    }

    fn push(&mut self, byte: u8) -> bool {
        let Some(text) = self.text.as_mut() else { return false };
        if text.len() >= MAXIMUM_ROW_BYTES {
            return false;
        }
        text.push(byte);
        true
    }
}
