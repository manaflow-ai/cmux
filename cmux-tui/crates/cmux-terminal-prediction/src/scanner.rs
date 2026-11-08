//! What each byte of remote output means for a prediction.
//!
//! This is not a terminal emulator. Ghostty stays the only thing that renders
//! the screen; the scanner answers one question about each byte the remote
//! sent: does it confirm what the user typed, leave the grid alone, or move the
//! cursor somewhere a prediction cannot follow?

/// The classification of remote output that prediction depends on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutputSignal {
    /// A byte that prints at the cursor and advances it one cell.
    Printable(u8),
    /// Changes styling or host state but no grid content: SGR, and the string
    /// sequences (OSC, DCS, APC, PM, SOS) whatever their payload.
    Ignorable,
    /// Entered (`true`) or left (`false`) the alternate screen.
    AlternateScreen(bool),
    /// Moved the cursor exactly one cell left: BS, `CSI D` or `CSI 1 D`.
    /// Disruptive unless the engine waits for the erase of a glyph the user
    /// backspaced over; this is the first half of every common form.
    CursorLeft,
    /// Moved the cursor left by more than one cell: `CSI n D`, n > 1. Line
    /// editors do this to rewrite text they already echoed (zsh recolouring a
    /// word), which only the engine's model of the line tells apart from a redraw.
    CursorLeftBy(usize),
    /// Cleared the cell under the cursor without moving it: `CSI K`, `CSI 0 K`,
    /// `CSI P` or `CSI 1 P`. The same caveat as `CursorLeft`.
    ClearAtCursor,
    /// Anything else: cursor motion, erases, newlines, unknown escapes, and
    /// images (kitty graphics, sixel), which move the cursor past them.
    Disruptive,
}

/// What a chunk did, as far as a surface with nothing in flight cares.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct OutputSkim {
    /// Whether anything but styling and host state went by.
    pub touched_the_screen: bool,
    /// The last alternate-screen switch, if any.
    pub alternate_screen: Option<bool>,
}

/// The string sequences: a payload of arbitrary bytes, none of which reach the
/// grid, running to a terminator.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ControlString {
    /// OSC, which also ends at BEL.
    OperatingSystemCommand,
    /// DCS, SOS, PM and APC (`ESC P`, `ESC X`, `ESC ^`, `ESC _`), which end at
    /// ST, at any other ESC, or at a C1 byte. Ghostty passes BEL through as
    /// payload here, so ending on it would read the rest of, say, a sixel
    /// image as printed text.
    Other,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Ground,
    Escape,
    /// After `ESC` and at least one intermediate byte (0x20..=0x2F), final byte
    /// pending. Holds the intermediate when there was exactly one, 0x20 when
    /// there were more.
    EscapeIntermediate(u8),
    /// Inside a CSI sequence, final byte pending; its bytes are in `parameters`.
    ControlSequence,
    /// Inside a string sequence, terminator pending.
    ControlString(ControlString),
    /// Saw ESC inside a string sequence: the next byte decides whether it was ST.
    ControlStringEscape,
}

const MAXIMUM_DETOUR_BYTES: usize = 4_096;
const MAXIMUM_PARAMETER_BYTES: usize = 16;

/// Incremental byte classifier for the output tee. Output comes in arbitrary
/// chunks, so escape sequences split across calls; the parse state is kept
/// between chunks, because a sequence cut in half must not read as two
/// disruptive events and withdraw a correct prediction.
#[derive(Clone, Debug)]
pub struct TerminalOutputScanner {
    state: State,
    /// The byte after `ESC` that opened the current string sequence, and
    /// whether its header is still being read. A kitty graphics command
    /// (`ESC _ G`) or a sixel image (`ESC P ... q`) places an image and moves
    /// the cursor past it, so it ends as `Disruptive`, not `Ignorable`.
    string_introducer: u8,
    is_reading_string_header: bool,
    string_is_image: bool,
    /// Between a cursor save (`ESC 7`, `CSI s`) and its restore, whatever is
    /// drawn happens somewhere else: a status line or clock repainting. The
    /// restore puts the cursor back, so none of it is disruptive. Bounded, in
    /// case a save is never restored.
    detour_bytes: Option<usize>,
    /// Parameter and intermediate bytes of the current CSI sequence, up to
    /// `MAXIMUM_PARAMETER_BYTES`. The remote controls how long a sequence is,
    /// and classification only compares against short mode numbers, so bytes
    /// past the cap count as overflow rather than being stored.
    parameters: Vec<u8>,
    parameters_overflowed: bool,
}

impl Default for TerminalOutputScanner {
    fn default() -> Self {
        Self::new()
    }
}

impl TerminalOutputScanner {
    pub fn new() -> Self {
        Self {
            state: State::Ground,
            string_introducer: 0,
            is_reading_string_header: false,
            string_is_image: false,
            detour_bytes: None,
            parameters: Vec::with_capacity(MAXIMUM_PARAMETER_BYTES),
            parameters_overflowed: false,
        }
    }

    /// Classifies one chunk: one signal per byte-or-sequence, in order.
    pub fn scan(&mut self, bytes: &[u8]) -> Vec<OutputSignal> {
        bytes.iter().filter_map(|&byte| self.next(byte)).collect()
    }

    /// Classifies one byte: the signal it completes, if any.
    pub fn next(&mut self, byte: u8) -> Option<OutputSignal> {
        let signal = self.consume(byte);
        let Some(bytes) = self.detour_bytes else { return signal };
        if let Some(OutputSignal::AlternateScreen(_)) = signal {
            return signal;
        }
        if bytes >= MAXIMUM_DETOUR_BYTES {
            self.detour_bytes = None;
            return Some(OutputSignal::Disruptive);
        }
        self.detour_bytes = Some(bytes + 1);
        None
    }

    /// Reads a chunk only for what a surface with nothing in flight needs:
    /// whether it touched the screen, and alternate-screen switches. Keeps the
    /// parse state exactly as `scan` would, but jumps over plain text.
    pub fn skim(&mut self, bytes: &[u8]) -> OutputSkim {
        let mut skim = OutputSkim::default();
        let mut rest = bytes;
        loop {
            if self.state == State::Ground && self.detour_bytes.is_none() && skim.touched_the_screen
            {
                // Text, controls and newlines only touch the screen, which is
                // already known; only an escape can switch screens.
                match rest.iter().position(|&byte| byte == 0x1B) {
                    Some(found) => rest = rest.get(found..).unwrap_or_default(),
                    None => break,
                }
            }
            let Some((&byte, after)) = rest.split_first() else { break };
            rest = after;
            match self.next(byte) {
                None | Some(OutputSignal::Ignorable) => {}
                Some(OutputSignal::AlternateScreen(entered)) => {
                    skim.alternate_screen = Some(entered);
                    skim.touched_the_screen = true;
                }
                Some(_) => skim.touched_the_screen = true,
            }
        }
        skim
    }

    fn open_string(&mut self, introducer: u8) {
        self.string_introducer = introducer;
        self.is_reading_string_header = introducer == b'_' || introducer == b'P';
        self.string_is_image = false;
    }

    fn read_string_header(&mut self, byte: u8) {
        if self.string_introducer == b'_' {
            self.string_is_image = byte == b'G';
            self.is_reading_string_header = false;
        } else {
            // DCS parameters, then its final byte: `q` is sixel.
            if (0x30..=0x3B).contains(&byte) {
                return;
            }
            self.string_is_image = byte == b'q';
            self.is_reading_string_header = false;
        }
    }

    fn end_of_string(&self) -> OutputSignal {
        if self.string_is_image { OutputSignal::Disruptive } else { OutputSignal::Ignorable }
    }

    fn consume(&mut self, byte: u8) -> Option<OutputSignal> {
        match self.state {
            State::Ground => {
                if byte == 0x1B {
                    self.state = State::Escape;
                    return None;
                }
                if (0x20..=0x7E).contains(&byte) {
                    return Some(OutputSignal::Printable(byte));
                }
                if byte == 0x08 {
                    return Some(OutputSignal::CursorLeft);
                }
                // C1 and the rest of C0 (newline, carriage return, bell, tab)
                // all move the cursor or the screen.
                Some(OutputSignal::Disruptive)
            }
            State::Escape => match byte {
                b'[' => {
                    self.state = State::ControlSequence;
                    self.parameters.clear();
                    self.parameters_overflowed = false;
                    None
                }
                b']' => {
                    self.state = State::ControlString(ControlString::OperatingSystemCommand);
                    self.open_string(byte);
                    None
                }
                b'P' | b'X' | b'^' | b'_' => {
                    self.state = State::ControlString(ControlString::Other);
                    self.open_string(byte);
                    None
                }
                b'7' => {
                    self.state = State::Ground;
                    self.detour_bytes = Some(0);
                    None
                }
                b'8' => {
                    self.state = State::Ground;
                    self.detour_bytes = None;
                    Some(OutputSignal::Ignorable)
                }
                // Another ESC restarts the escape, as it does in ghostty.
                0x1B => None,
                b'\\' => {
                    // A string terminator with no string open changes nothing.
                    self.state = State::Ground;
                    Some(OutputSignal::Ignorable)
                }
                0x20..=0x2F => {
                    // Intermediates, as in `ESC ( B`, the start of xterm's sgr0.
                    self.state = State::EscapeIntermediate(byte);
                    None
                }
                _ => {
                    self.state = State::Ground;
                    Some(OutputSignal::Disruptive)
                }
            },
            State::EscapeIntermediate(intermediate) => {
                if (0x20..=0x2F).contains(&byte) {
                    self.state = State::EscapeIntermediate(0x20);
                    return None;
                }
                if byte == 0x1B {
                    self.state = State::Escape;
                    return None;
                }
                self.state = State::Ground;
                if !(0x30..=0x7E).contains(&byte) {
                    return Some(OutputSignal::Disruptive);
                }
                // Designating ASCII into G0-G3 changes no cell. Any other set
                // (DEC line drawing, say) changes how later printables render.
                let designates_ascii = (0x28..=0x2B).contains(&intermediate) && byte == b'B';
                Some(if designates_ascii {
                    OutputSignal::Ignorable
                } else {
                    OutputSignal::Disruptive
                })
            }
            State::ControlSequence => {
                // Parameter and intermediate bytes accumulate; 0x40..=0x7E ends it.
                if (0x20..=0x3F).contains(&byte) {
                    if self.parameters.len() < MAXIMUM_PARAMETER_BYTES {
                        self.parameters.push(byte);
                    } else {
                        self.parameters_overflowed = true;
                    }
                    return None;
                }
                self.state = State::Ground;
                if !(0x40..=0x7E).contains(&byte) {
                    return Some(OutputSignal::Disruptive);
                }
                if self.parameters.is_empty() && byte == b's' {
                    self.detour_bytes = Some(0);
                    return None;
                }
                if self.parameters.is_empty() && byte == b'u' {
                    self.detour_bytes = None;
                    return Some(OutputSignal::Ignorable);
                }
                Some(classify_control_sequence(&self.parameters, self.parameters_overflowed, byte))
            }
            State::ControlString(kind) => match byte {
                0x07 if kind == ControlString::OperatingSystemCommand => {
                    self.state = State::Ground;
                    Some(self.end_of_string())
                }
                0x18 | 0x1A => {
                    // CAN and SUB abort the sequence and are executed as controls.
                    self.state = State::Ground;
                    Some(OutputSignal::Disruptive)
                }
                0x1B => {
                    self.state = State::ControlStringEscape;
                    None
                }
                0x9C if kind == ControlString::Other => {
                    // The 8-bit string terminator.
                    self.state = State::Ground;
                    Some(self.end_of_string())
                }
                0x80..=0x9F if kind == ControlString::Other => {
                    // Ghostty leaves a DCS, APC, PM or SOS at any other C1 byte.
                    self.state = State::Ground;
                    Some(OutputSignal::Disruptive)
                }
                _ => {
                    if self.is_reading_string_header {
                        self.read_string_header(byte);
                    }
                    None
                }
            },
            State::ControlStringEscape => {
                if byte == b'\\' {
                    self.state = State::Ground;
                    return Some(self.end_of_string());
                }
                if self.string_is_image {
                    // Left for a new sequence, the image was still placed.
                    self.state = State::Escape;
                    let _ = self.consume(byte);
                    return Some(OutputSignal::Disruptive);
                }
                // Ghostty leaves the string at any ESC, not only at ST, and
                // parses the next byte as the start of a new sequence. Staying
                // in the string here would miss everything ghostty then applies.
                self.state = State::Escape;
                self.consume(byte)
            }
        }
    }
}

fn classify_control_sequence(parameters: &[u8], overflowed: bool, final_byte: u8) -> OutputSignal {
    // SGR only repaints existing cells, which is how shells colour the line
    // they are echoing. Treating it as disruptive would withdraw a correct
    // prediction on every syntax-highlighted keystroke.
    if final_byte == b'm' {
        return OutputSignal::Ignorable;
    }
    // The halves of a line editor erasing one character. Only the counts that
    // mean one cell qualify; anything wider is a redraw. An overflowed list
    // holds the capped bytes, so it never matches.
    let default_or_one = parameters.is_empty() || parameters == b"1";
    let default_or_zero = parameters.is_empty() || parameters == b"0";
    match final_byte {
        b'D' if default_or_one => return OutputSignal::CursorLeft,
        b'D' if !overflowed
            && parameters.len() <= 3
            && parameters.iter().all(u8::is_ascii_digit) =>
        {
            let count = parameters
                .iter()
                .fold(0usize, |count, digit| count * 10 + usize::from(digit - b'0'));
            return if count <= 1 {
                OutputSignal::CursorLeft
            } else {
                OutputSignal::CursorLeftBy(count)
            };
        }
        b'P' if default_or_one => return OutputSignal::ClearAtCursor,
        b'K' if default_or_zero => return OutputSignal::ClearAtCursor,
        _ => {}
    }
    if final_byte != b'h' && final_byte != b'l' {
        return OutputSignal::Disruptive;
    }
    // A truncated parameter list could spuriously match a mode below, and no
    // alternate-screen form is anywhere near the cap.
    if overflowed {
        return OutputSignal::Disruptive;
    }
    // 1049 is the modern alternate screen; 47 and 1047 are the older forms
    // still emitted by some remotes.
    if [b"?1049".as_slice(), b"?47", b"?1047"].contains(&parameters) {
        return OutputSignal::AlternateScreen(final_byte == b'h');
    }
    // Any other private mode change (bracketed paste, mouse reporting,
    // application cursor keys) means the remote is switching input
    // conventions, so stop predicting what its echo will look like.
    OutputSignal::Disruptive
}
