//! What one chunk of encoded input was, for the engine.
//!
//! Classic cmux read the key before Ghostty encoded it. cmux NEXT sees what
//! Ghostty wrote for the terminal's owner instead (`io_write_cb`): each key
//! press is one write, already encoded for the remote's input modes. So the
//! key is read back from its bytes. Anything not listed here is
//! [`InputKind::Untracked`], which withdraws: a paste (bracketed or not, more
//! than one byte), an arrow or function key, Return, a mouse report, UTF-8.

/// One write's meaning for the engine.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InputKind {
    /// One printable ASCII byte: the remote echoes it and advances one cell.
    Printable(u8),
    /// DEL (what Ghostty sends for Backspace by default) or BS.
    Backspace,
    /// A key that deletes backwards by more than one character: Ctrl-U,
    /// Ctrl-W, or Option-Backspace (`ESC DEL`, `ESC BS`).
    LineErase,
    /// A focus report (`CSI I`, `CSI O`): Ghostty sends it only to a program
    /// that asked for focus events, and it moves nothing on the screen.
    Nothing,
    /// Anything else.
    Untracked,
}

impl InputKind {
    pub fn of(bytes: &[u8]) -> InputKind {
        match bytes {
            [byte @ 0x20..=0x7E] => InputKind::Printable(*byte),
            [0x7F | 0x08] => InputKind::Backspace,
            [0x15 | 0x17] | [0x1B, 0x7F | 0x08] => InputKind::LineErase,
            [0x1B, b'[', b'I' | b'O'] => InputKind::Nothing,
            _ => InputKind::Untracked,
        }
    }
}
