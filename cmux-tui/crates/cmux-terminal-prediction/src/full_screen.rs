//! Prediction inside a full-screen application (the alternate screen), the
//! way mosh does it: a typed key is predicted at a cell, and only the
//! application printing that character in that cell confirms it.
//!
//! The primary-screen engine reads output as a stream: the echo of a key is
//! the next byte, and anything else ends the run. An agent's TUI (Codex, Claude
//! Code) never echoes that way. It redraws: it moves the cursor to the input
//! box, prints the key among styling, redraws a spinner or a transcript
//! elsewhere, and parks the cursor back after the key. So here the output is
//! followed with a cursor model instead, and only what lands in a predicted
//! cell counts: the transcript streaming above the input box is ignored.
//!
//! Never drawn unless the run is armed: two keys in a row confirmed in their
//! cell. An application that does not echo (vim's normal mode, a pager, a
//! password field) never confirms, so it never sees a glyph. A different
//! visible character printed in a predicted cell is a mismatch: everything is
//! withdrawn and the run starts over from no confirmations. A key the model
//! does not place (Return, an arrow, a chord) withdraws and needs one fresh
//! confirmation. A blank printed in a predicted cell is an older frame being
//! repainted, not a contradiction: it leaves the prediction in place.
//!
//! Positions come from the output alone. The model starts at an arbitrary
//! origin on entering the screen, which is fine: only differences between the
//! cursor and a predicted cell are ever used, and an absolute move (`CUP`) that
//! changes the origin under predictions in flight shows up as their echo
//! landing elsewhere, which expires or mismatches them.

use crate::glyph::{PredictedGlyph, Standing};
use std::time::Duration;

/// A key sent, waiting for the application to print it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Pending {
    row: i32,
    column: i32,
    character: u8,
    typed_at: Duration,
    /// Whether it was drawn; only these misfire visibly.
    is_displayed: bool,
}

/// An echo seen in its cell, drawn until the frame carrying it is presented.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Held {
    row: i32,
    column: i32,
    character: u8,
    confirmed_at: Duration,
}

/// What one chunk of output did to the predictions.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Reconciled {
    /// Round trips of the keys confirmed, for the latency estimate.
    pub confirmed: Vec<Duration>,
    /// A visible character contradicted a prediction.
    pub mismatched: bool,
    /// A drawn glyph went (a mismatch or a mode switch).
    pub withdrew_displayed: bool,
    /// The alternate screen was entered (`true`) or left.
    pub switched: Option<bool>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Parse {
    Ground,
    Escape,
    /// `ESC (`, `ESC )` and friends: one more byte names a character set.
    Designate,
    Csi,
    /// OSC, DCS, APC, PM, SOS: runs to BEL or `ESC \`.
    Text,
    TextEscape,
    /// Inside a UTF-8 sequence, with this many bytes to go.
    Utf8(u8),
}

#[derive(Clone, Debug)]
pub(crate) struct FullScreenEcho {
    parse: Parse,
    params: Vec<u8>,
    row: i32,
    column: i32,
    saved: (i32, i32),
    /// The code point being decoded, for its width.
    code_point: u32,
    pending: Vec<Pending>,
    held: Vec<Held>,
    /// Keys confirmed in their cell in a row; drawing starts at two.
    streak: u32,
}

impl Default for FullScreenEcho {
    fn default() -> Self {
        Self::new()
    }
}

const STRING_LIMIT: usize = 64;

impl FullScreenEcho {
    pub(crate) fn new() -> Self {
        Self {
            parse: Parse::Ground,
            params: Vec::new(),
            row: 0,
            column: 0,
            saved: (0, 0),
            code_point: 0,
            pending: Vec::new(),
            held: Vec::new(),
            streak: 0,
        }
    }

    pub(crate) fn is_armed(&self) -> bool {
        self.streak >= 2
    }

    /// A printable key. Drawn when `display` (the engine is predicting and the
    /// run here is armed). Answers whether something new is drawn.
    pub(crate) fn typed(&mut self, byte: u8, now: Duration, display: bool, limit: usize) -> bool {
        if self.pending.len() >= limit {
            return self.withdraw_all();
        }
        // After the newest key still in flight on this row, else at the
        // cursor: one left elsewhere (typed before the screen was placed)
        // says nothing about this row.
        let column = match self.pending.last() {
            Some(last) if last.row == self.row => last.column + 1,
            _ => self.column,
        };
        let display = display && self.is_armed();
        self.pending.push(Pending {
            row: self.row,
            column,
            character: byte,
            typed_at: now,
            is_displayed: display,
        });
        display
    }

    /// A key whose effect is not modelled: what was predicted cannot be
    /// placed any more, and the next key needs its own confirmation first.
    pub(crate) fn typed_unmodelled(&mut self) -> bool {
        self.streak = self.streak.min(1);
        self.withdraw_all()
    }

    /// Output lost, the grid resized: nothing can be placed, nor trusted.
    pub(crate) fn lost_track(&mut self) -> bool {
        self.streak = 0;
        self.withdraw_all()
    }

    /// Drops every prediction; answers whether one was drawn.
    pub(crate) fn withdraw_all(&mut self) -> bool {
        let drew = self.pending.iter().any(|p| p.is_displayed) || !self.held.is_empty();
        self.pending.clear();
        self.held.clear();
        drew
    }

    /// Glyphs at offsets from the live cursor. Nothing when the cursor is not
    /// on the row the predictions are on: the application parked it elsewhere
    /// and the overlay, which anchors on the cursor, cannot place them.
    pub(crate) fn glyphs(&self) -> Vec<PredictedGlyph> {
        let mut drawn = Vec::new();
        for held in &self.held {
            if held.row == self.row {
                drawn.push(PredictedGlyph {
                    character: held.character,
                    offset: held.column - self.column,
                    standing: Standing::Confirmed,
                });
            }
        }
        for pending in self.pending.iter().filter(|p| p.is_displayed) {
            if pending.row != self.row {
                return Vec::new();
            }
            drawn.push(PredictedGlyph {
                character: pending.character,
                offset: pending.column - self.column,
                standing: Standing::Speculative,
            });
        }
        drawn
    }

    /// Withdraws predictions older than `lifetime` (the application never
    /// printed them: it does not echo, or echoes somewhere else), and held
    /// confirmations older than `hold`. Answers whether a drawn glyph went.
    pub(crate) fn expire(&mut self, now: Duration, lifetime: Duration, hold: Duration) -> bool {
        let mut changed = false;
        if self.pending.iter().any(|p| now >= p.typed_at + lifetime) {
            // An echo that never came means echo is off or lands elsewhere.
            self.streak = 0;
            changed = self.pending.iter().any(|p| p.is_displayed);
            self.pending.clear();
        }
        let before = self.held.len();
        self.held.retain(|h| now < h.confirmed_at + hold);
        changed || self.held.len() != before
    }

    /// A frame reached the screen: held confirmations are now real cells.
    pub(crate) fn presented_frame(&mut self) -> bool {
        let had = !self.held.is_empty();
        self.held.clear();
        had
    }

    /// The earliest instant something drawn changes on its own.
    pub(crate) fn next_expiry(&self, lifetime: Duration, hold: Duration) -> Option<Duration> {
        let pending =
            self.pending.iter().filter(|p| p.is_displayed).map(|p| p.typed_at + lifetime).min();
        let held = self.held.iter().map(|h| h.confirmed_at + hold).min();
        [pending, held].into_iter().flatten().min()
    }

    /// Follows the cursor through `bytes` and settles each prediction whose
    /// cell the application printed.
    pub(crate) fn observe(&mut self, bytes: &[u8], now: Duration) -> Reconciled {
        let mut result = Reconciled::default();
        for &byte in bytes {
            self.step(byte, now, &mut result);
        }
        // A TUI prints nothing for a typed space: the cell is already blank,
        // so it only parks the cursor past it. The oldest keys, while they
        // are spaces the cursor now sits beyond on their row, are done.
        while let Some(&first) = self.pending.first() {
            if first.character != b' ' || first.row != self.row || self.column <= first.column {
                break;
            }
            self.pending.remove(0);
            result.confirmed.push(now.saturating_sub(first.typed_at));
        }
        result
    }

    fn step(&mut self, byte: u8, now: Duration, result: &mut Reconciled) {
        match self.parse {
            Parse::Ground => self.ground(byte, now, result),
            Parse::Utf8(left) => {
                if byte & 0xC0 != 0x80 {
                    // A broken sequence: count what was started, then reparse.
                    self.parse = Parse::Ground;
                    self.print_wide(0x20, now, result);
                    self.ground(byte, now, result);
                    return;
                }
                self.code_point = (self.code_point << 6) | u32::from(byte & 0x3F);
                if left > 1 {
                    self.parse = Parse::Utf8(left - 1);
                } else {
                    self.parse = Parse::Ground;
                    self.print_wide(self.code_point, now, result);
                }
            }
            Parse::Escape => self.escape(byte, result),
            Parse::Designate => self.parse = Parse::Ground,
            Parse::Csi => {
                if (0x40..=0x7E).contains(&byte) {
                    self.parse = Parse::Ground;
                    self.csi(byte, result);
                } else if self.params.len() < STRING_LIMIT {
                    self.params.push(byte);
                }
            }
            Parse::Text => match byte {
                0x07 => self.parse = Parse::Ground,
                0x1B => self.parse = Parse::TextEscape,
                _ => {}
            },
            Parse::TextEscape => {
                self.parse = if byte == b'\\' { Parse::Ground } else { Parse::Text };
            }
        }
    }

    fn ground(&mut self, byte: u8, now: Duration, result: &mut Reconciled) {
        match byte {
            0x1B => self.parse = Parse::Escape,
            b'\r' => self.column = 0,
            b'\n' | 0x0B | 0x0C => self.row += 1,
            0x08 => self.column = (self.column - 1).max(0),
            b'\t' => self.column = (self.column / 8 + 1) * 8,
            0x20..=0x7E => self.print(byte, now, result),
            0xC0..=0xDF => {
                self.code_point = u32::from(byte & 0x1F);
                self.parse = Parse::Utf8(1);
            }
            0xE0..=0xEF => {
                self.code_point = u32::from(byte & 0x0F);
                self.parse = Parse::Utf8(2);
            }
            0xF0..=0xF7 => {
                self.code_point = u32::from(byte & 0x07);
                self.parse = Parse::Utf8(3);
            }
            _ => {}
        }
    }

    fn escape(&mut self, byte: u8, result: &mut Reconciled) {
        self.parse = Parse::Ground;
        match byte {
            b'[' => {
                self.params.clear();
                self.parse = Parse::Csi;
            }
            b']' | b'P' | b'_' | b'^' | b'X' => self.parse = Parse::Text,
            b'(' | b')' | b'*' | b'+' | b'-' | b'.' | b'/' | b'#' | b'%' => {
                self.parse = Parse::Designate;
            }
            b'7' => self.saved = (self.row, self.column),
            b'8' => (self.row, self.column) = self.saved,
            b'D' => self.row += 1,
            b'E' => {
                self.row += 1;
                self.column = 0;
            }
            b'M' => self.row -= 1,
            b'c' => {
                self.row = 0;
                self.column = 0;
                result.switched = Some(false);
                self.switch_screen(result);
            }
            _ => {}
        }
    }

    fn csi(&mut self, final_byte: u8, result: &mut Reconciled) {
        let private = self.params.first().is_some_and(|b| matches!(b, b'?' | b'>' | b'<' | b'='));
        let text = String::from_utf8_lossy(&self.params).into_owned();
        let numbers: Vec<i32> = text
            .trim_start_matches(['?', '>', '<', '='])
            .split([';', ':'])
            .map(|n| n.parse().unwrap_or(0))
            .collect();
        let n = |i: usize| numbers.get(i).copied().unwrap_or(0).max(1);
        if private {
            if matches!(final_byte, b'h' | b'l')
                && numbers.iter().any(|&mode| matches!(mode, 47 | 1047 | 1049))
            {
                result.switched = Some(final_byte == b'h');
                self.switch_screen(result);
            }
            return;
        }
        // Only intermediates-free sequences move the cursor as below.
        if self.params.iter().any(|b| (0x20..=0x2F).contains(b)) {
            return;
        }
        match final_byte {
            b'A' => self.row -= n(0),
            b'B' | b'e' => self.row += n(0),
            b'C' | b'a' => self.column += n(0),
            b'D' => self.column = (self.column - n(0)).max(0),
            b'E' => {
                self.row += n(0);
                self.column = 0;
            }
            b'F' => {
                self.row -= n(0);
                self.column = 0;
            }
            b'G' | b'`' => self.column = n(0) - 1,
            b'H' | b'f' => {
                self.row = n(0) - 1;
                self.column = n(1) - 1;
            }
            b'd' => self.row = n(0) - 1,
            b's' => self.saved = (self.row, self.column),
            b'u' => (self.row, self.column) = self.saved,
            // Setting the scroll region homes the cursor.
            b'r' => {
                self.row = 0;
                self.column = 0;
            }
            _ => {}
        }
    }

    fn switch_screen(&mut self, result: &mut Reconciled) {
        self.streak = 0;
        result.withdrew_displayed |= self.withdraw_all();
    }

    fn print_wide(&mut self, code_point: u32, now: Duration, result: &mut Reconciled) {
        let width = cell_width(code_point);
        if width == 0 {
            return;
        }
        // Not ASCII, so never what was predicted: a visible character here
        // contradicts a prediction in this cell.
        self.settle(None, now, result);
        self.column += width;
    }

    fn print(&mut self, byte: u8, now: Duration, result: &mut Reconciled) {
        self.settle(Some(byte), now, result);
        self.column += 1;
    }

    /// The application printed `character` (`None`: something not ASCII) at
    /// the cursor.
    fn settle(&mut self, character: Option<u8>, now: Duration, result: &mut Reconciled) {
        let Some(index) =
            self.pending.iter().position(|p| p.row == self.row && p.column == self.column)
        else {
            return;
        };
        let Some(&pending) = self.pending.get(index) else {
            return;
        };
        if character == Some(pending.character) {
            // Keys typed before it are done too. A space was never printed
            // (see `observe`); any other key drawn but not printed in its
            // cell went somewhere else, which is a mismatch.
            let older: Vec<Pending> = self.pending.drain(..index).collect();
            self.pending.remove(0);
            let (row, column) = (pending.row, pending.column);
            for earlier in &older {
                if earlier.character == b' ' && earlier.row == row && earlier.column < column {
                    result.confirmed.push(now.saturating_sub(earlier.typed_at));
                } else if earlier.is_displayed {
                    self.mismatch(result);
                    return;
                }
            }
            self.streak = self.streak.saturating_add(1);
            result.confirmed.push(now.saturating_sub(pending.typed_at));
            if pending.is_displayed {
                self.held.push(Held {
                    row: pending.row,
                    column: pending.column,
                    character: pending.character,
                    confirmed_at: now,
                });
            }
        } else if character != Some(b' ') {
            // A blank there is an older frame repainted; anything visible
            // that is not the key means the key lands somewhere else.
            self.mismatch(result);
        }
    }

    fn mismatch(&mut self, result: &mut Reconciled) {
        self.streak = 0;
        result.mismatched = true;
        result.withdrew_displayed |= self.withdraw_all();
    }
}

/// Cells a code point takes: 0 for combining marks and joiners, 2 for the
/// wide ranges (CJK, Hangul, emoji), 1 otherwise. An error only offsets the
/// model's columns on that row, and only differences are ever used.
fn cell_width(code_point: u32) -> i32 {
    match code_point {
        0x0300..=0x036F | 0x200B..=0x200F | 0xFE00..=0xFE0F | 0x20D0..=0x20FF => 0,
        0x1100..=0x115F
        | 0x2E80..=0xA4CF
        | 0xAC00..=0xD7A3
        | 0xF900..=0xFAFF
        | 0xFE30..=0xFE4F
        | 0xFF00..=0xFF60
        | 0xFFE0..=0xFFE6
        | 0x1F300..=0x1F64F
        | 0x1F900..=0x1F9FF
        | 0x20000..=0x3FFFD => 2,
        _ => 1,
    }
}
