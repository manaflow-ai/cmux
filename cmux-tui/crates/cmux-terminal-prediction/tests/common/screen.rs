//! The remote's line editor and just enough of a terminal to track the
//! cursor row.

use std::collections::HashMap;
use std::fmt;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SimulatedKey {
    Character(u8),
    Backspace,
}

impl fmt::Display for SimulatedKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Character(byte) => write!(f, "{}", char::from(*byte)),
            Self::Backspace => write!(f, "⌫"),
        }
    }
}

/// How the remote line editor erases one character at the end of the line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SimulatedEraseForm {
    /// bash readline with TERM=xterm-ghostty, as captured on big-red.
    BackspaceClearToEnd,
    /// Canonical tty echo.
    BackspaceSpaceBackspace,
    CursorLeftDeleteCharacter,
}

impl SimulatedEraseForm {
    pub const ALL_CASES: [Self; 3] =
        [Self::BackspaceClearToEnd, Self::BackspaceSpaceBackspace, Self::CursorLeftDeleteCharacter];

    pub fn bytes(self) -> &'static [u8] {
        match self {
            Self::BackspaceClearToEnd => &[0x08, 0x1B, 0x5B, 0x4B],
            Self::BackspaceSpaceBackspace => &[0x08, 0x20, 0x08],
            Self::CursorLeftDeleteCharacter => &[0x1B, 0x5B, 0x44, 0x1B, 0x5B, 0x50],
        }
    }
}

pub const PROMPT: &[u8] = b"leo@big-red:~$ ";

/// The remote's line: what bash readline holds after the keys it has read.
#[derive(Clone, Debug, Default)]
pub struct SimulatedLineEditor {
    pub line: Vec<u8>,
}

impl SimulatedLineEditor {
    /// Applies a key and returns what the remote writes back.
    pub fn read(&mut self, key: SimulatedKey, erase_form: SimulatedEraseForm) -> Vec<u8> {
        match key {
            SimulatedKey::Character(byte) => {
                self.line.push(byte);
                vec![byte]
            }
            SimulatedKey::Backspace => {
                if self.line.pop().is_none() {
                    return vec![0x07];
                }
                erase_form.bytes().to_vec()
            }
        }
    }

    /// The row as it looks once every key read so far is echoed.
    pub fn row(&self) -> Vec<u8> {
        [PROMPT, &self.line].concat()
    }

    /// Applies keys read together and returns one redisplay of the net change.
    pub fn read_together(&mut self, keys: &[SimulatedKey]) -> Vec<u8> {
        let before = self.line.clone();
        for key in keys {
            match key {
                SimulatedKey::Character(byte) => self.line.push(*byte),
                SimulatedKey::Backspace => {
                    self.line.pop();
                }
            }
        }
        let common = before.iter().zip(&self.line).take_while(|(a, b)| a == b).count();
        let mut output = vec![0x08; before.len() - common];
        output.extend_from_slice(&self.line[common..]);
        if self.line.len() < before.len() {
            output.extend_from_slice(&[0x1B, 0x5B, 0x4B]);
        }
        output
    }
}

/// Just enough of a terminal to track the cursor row: printables, BS, BEL,
/// and CSI K, D and P with the counts a line editor uses.
#[derive(Clone, Debug)]
pub struct SimulatedScreen {
    pub row: Vec<u8>,
    pub cursor: i64,
    escape: Option<Vec<u8>>,
    /// How many times each column was written or cleared.
    writes: HashMap<i64, usize>,
}

impl Default for SimulatedScreen {
    fn default() -> Self {
        Self { row: PROMPT.to_vec(), cursor: PROMPT.len() as i64, escape: None, writes: HashMap::new() }
    }
}

impl SimulatedScreen {
    pub fn character(&self, column: i64) -> Option<u8> {
        if column >= 0 && (column as usize) < self.row.len() { Some(self.row[column as usize]) } else { None }
    }

    pub fn write_count(&self, column: i64) -> usize {
        self.writes.get(&column).copied().unwrap_or(0)
    }

    /// Every column from `column` to the end of the row changed.
    fn touch_through_end(&mut self, column: i64) {
        for touched in column..(column + 1).max(self.row.len() as i64) {
            *self.writes.entry(touched).or_default() += 1;
        }
    }

    pub fn apply(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            self.apply_byte(byte);
        }
    }

    fn apply_byte(&mut self, byte: u8) {
        if let Some(mut sequence) = self.escape.take() {
            sequence.push(byte);
            if sequence.len() < 2 || !(0x40..=0x7E).contains(&byte) {
                self.escape = Some(sequence);
                return;
            }
            let digits = std::str::from_utf8(&sequence[1..sequence.len() - 1]).unwrap_or("");
            let count = digits.parse::<i64>().unwrap_or(1).max(1);
            let cursor = self.cursor as usize;
            match byte {
                b'K' => {
                    self.touch_through_end(self.cursor);
                    if cursor < self.row.len() {
                        self.row.truncate(cursor);
                    }
                }
                b'D' => self.cursor = (self.cursor - count).max(0),
                b'P' => {
                    self.touch_through_end(self.cursor);
                    if cursor < self.row.len() {
                        let end = self.row.len().min(cursor + count as usize);
                        self.row.drain(cursor..end);
                    }
                }
                _ => {}
            }
            return;
        }
        match byte {
            0x1B => self.escape = Some(Vec::new()),
            0x08 => self.cursor = (self.cursor - 1).max(0),
            0x20..=0x7E => {
                let cursor = self.cursor as usize;
                while self.row.len() <= cursor {
                    self.row.push(0x20);
                }
                self.row[cursor] = byte;
                *self.writes.entry(self.cursor).or_default() += 1;
                self.cursor += 1;
            }
            _ => {}
        }
    }
}
