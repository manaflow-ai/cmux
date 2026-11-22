//! The host-width VT model: the screen and scrollback the PTY's bytes draw,
//! with the soft-wrap flag of every row. Only what a reflow needs is kept:
//! cells, styles, wraps, the cursor and the modes the phone's own terminal
//! must follow (key encoding, mouse, bracketed paste), which are passed on.

use std::collections::{BTreeMap, VecDeque};

use crate::style::{Interner, Style, StyleTable};
use crate::unicode::{self, WidthEffect};

/// A cell holding one narrow glyph (or nothing).
pub const NARROW: u8 = 0;
/// The first cell of a wide glyph.
pub const WIDE: u8 = 1;
/// The second cell of a wide glyph (no glyph of its own).
pub const WIDE_TAIL: u8 = 2;
/// The last cell of a row whose wide glyph went on to the next row.
pub const SPACER_HEAD: u8 = 3;

/// `Cell::ch` with this bit is a grapheme (an index into the grapheme table).
pub const GRAPHEME: u32 = 0x8000_0000;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Cell {
    /// The code point (0: empty), or `GRAPHEME | index`.
    pub ch: u32,
    pub style: u16,
    pub kind: u8,
}

impl Cell {
    pub fn blank(style: u16) -> Cell {
        Cell { ch: 0, style, kind: NARROW }
    }

    pub fn is_empty_or_space(self) -> bool {
        self.ch == 0 || self.ch == u32::from(b' ')
    }

    pub fn width(self) -> usize {
        if self.kind == WIDE { 2 } else { 1 }
    }
}

/// One row: its cells (a history row drops its trailing empty cells) and
/// whether it soft-wraps into the next row.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Row {
    pub cells: Vec<Cell>,
    pub wrapped: bool,
    /// A shell prompt (or its continuation) is on this row, by OSC 133
    /// marks: `ED 2` here moves the screen into the scrollback, as Ghostty does.
    pub prompt: bool,
}

/// What the cursor writes, by OSC 133 (shell integration) marks.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum Semantic {
    #[default]
    Output,
    Prompt,
    Input,
}

#[derive(Clone, Copy, Debug, Default)]
struct Cursor {
    x: usize,
    y: usize,
    pending_wrap: bool,
    style: Style,
}

#[derive(Clone, Copy, Debug, Default)]
struct Saved {
    x: usize,
    y: usize,
    pending_wrap: bool,
    style: Style,
    origin: bool,
    charsets: [bool; 2],
    shift_out: bool,
}

/// DEC private modes the model follows itself; every other one is passed on
/// to the phone's terminal (and repeated after its reset).
const OWN_MODES: &[u16] = &[3, 6, 7, 25, 47, 69, 1047, 1048, 1049, 2026];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Ground,
    Escape,
    Csi,
    Osc,
    OscEscape,
    Dcs,
    DcsEscape,
    /// SOS, PM, APC: dropped.
    Ignore,
    IgnoreEscape,
}

/// The longest escape sequence kept; longer ones are dropped (a stray image).
const MAX_SEQUENCE: usize = 64 * 1024;

pub struct Terminal {
    pub cols: usize,
    pub rows: usize,
    primary: Vec<Row>,
    alt: Vec<Row>,
    alt_active: bool,
    /// Primary-screen rows that scrolled off the top, oldest first.
    pub history: VecDeque<Row>,
    /// Rows dropped from the front of `history` (its limit) since the last reset.
    pub history_dropped: u64,
    history_limit: usize,
    /// Bytes `history` holds ([`row_bytes`]), at most `history_cap_bytes`.
    history_bytes: usize,
    history_cap_bytes: usize,
    cursor: Cursor,
    /// The primary screen's cursor while the alternate screen is up.
    primary_cursor: Cursor,
    saved: [Saved; 2],
    scroll_top: usize,
    scroll_bottom: usize,
    autowrap: bool,
    origin: bool,
    insert: bool,
    newline_mode: bool,
    pub cursor_visible: bool,
    /// G0 and G1 are DEC special graphics.
    charsets: [bool; 2],
    shift_out: bool,
    last_printed: Option<(u32, usize)>,
    pub styles: StyleTable,
    pub graphemes: Interner,
    /// Hyperlinks: `params;uri` of OSC 8.
    pub links: Interner,
    // Passed on to the phone's terminal.
    modes: BTreeMap<u16, bool>,
    keypad_application: bool,
    cursor_shape: Option<Vec<u8>>,
    kitty_flags: Vec<u32>,
    title: Option<Vec<u8>>,
    /// Sequences for the phone's terminal as they came (modes, titles, bells).
    pub passthrough: Vec<u8>,
    /// Answers for the program (cursor and size reports in host cells).
    pub replies: Vec<u8>,
    /// The private mode the alternate screen was entered with (47, 1047 or
    /// 1049), for the phone's terminal to enter it the same way.
    pub alt_mode: u16,
    /// The scrollback or every row changed in a way a diff cannot follow
    /// (RIS, ED 3, a host resize): the view starts over.
    pub reset_needed: bool,
    /// Counts the primary screen's clears and switches between screens:
    /// after one, the host's screen lays out the rows again.
    pub screen_cleared: u64,
    /// An OSC 133 prompt or input mark was seen (Ghostty's `semantic_prompt.seen`).
    prompt_seen: bool,
    semantic: Semantic,
    /// Input ends at the end of its line (OSC 133;I).
    semantic_clear_eol: bool,
    // Parser.
    state: State,
    seq: Vec<u8>,
    utf8: [u8; 4],
    utf8_len: usize,
    utf8_need: usize,
}

/// Bytes one scrollback row holds: the row and its cells (8 bytes each;
/// trailing empty cells are dropped).
pub fn row_bytes(row: &Row) -> usize {
    size_of::<Row>() + row.cells.len() * size_of::<Cell>()
}

impl Terminal {
    pub fn new(cols: usize, rows: usize, history_limit: usize) -> Terminal {
        let cols = cols.max(1);
        let rows = rows.max(1);
        Terminal {
            cols,
            rows,
            primary: blank_rows(cols, rows),
            alt: blank_rows(cols, rows),
            alt_active: false,
            history: VecDeque::new(),
            history_dropped: 0,
            history_limit,
            history_bytes: 0,
            history_cap_bytes: usize::MAX,
            cursor: Cursor::default(),
            primary_cursor: Cursor::default(),
            saved: [Saved::default(); 2],
            scroll_top: 0,
            scroll_bottom: rows - 1,
            autowrap: true,
            origin: false,
            insert: false,
            newline_mode: false,
            cursor_visible: true,
            charsets: [false; 2],
            shift_out: false,
            last_printed: None,
            styles: StyleTable::default(),
            graphemes: Interner::default(),
            links: Interner::default(),
            modes: BTreeMap::new(),
            keypad_application: false,
            cursor_shape: None,
            kitty_flags: Vec::new(),
            title: None,
            passthrough: Vec::new(),
            replies: Vec::new(),
            alt_mode: 1049,
            reset_needed: true,
            screen_cleared: 0,
            prompt_seen: false,
            semantic: Semantic::Output,
            semantic_clear_eol: false,
            state: State::Ground,
            seq: Vec::new(),
            utf8: [0; 4],
            utf8_len: 0,
            utf8_need: 0,
        }
    }

    pub fn is_alternate(&self) -> bool {
        self.alt_active
    }

    /// The primary screen's rows.
    pub fn primary_rows(&self) -> &[Row] {
        &self.primary
    }

    /// The primary screen's cursor (column, row), also while the alternate
    /// screen is up.
    pub fn primary_cursor(&self) -> (usize, usize) {
        let cursor = if self.alt_active { self.primary_cursor } else { self.cursor };
        (cursor.x, cursor.y)
    }

    /// The rows of the screen in use (the alternate one while it is up).
    pub fn screen_rows(&self) -> &[Row] {
        if self.alt_active { &self.alt } else { &self.primary }
    }

    /// The cursor (column, row) on the screen in use.
    pub fn cursor(&self) -> (usize, usize) {
        (self.cursor.x, self.cursor.y)
    }

    /// The host's grid changed (its PTY was resized). Rows are cut or added
    /// without a reflow: the host's own replay follows a resize.
    pub fn resize(&mut self, cols: usize, rows: usize) {
        let cols = cols.max(1);
        let rows = rows.max(1);
        if cols == self.cols && rows == self.rows {
            return;
        }
        let primary_cursor_y = if self.alt_active { self.primary_cursor.y } else { self.cursor.y };
        // Rows above a cursor that no longer fits go to the scrollback.
        let push = (primary_cursor_y + 1).saturating_sub(rows);
        for _ in 0..push {
            let row = self.primary.remove(0);
            self.push_history(row);
        }
        for (screen, keep) in [(&mut self.primary, true), (&mut self.alt, false)] {
            let _ = keep;
            screen.truncate(rows);
            while screen.len() < rows {
                screen.push(Row::default());
            }
            for row in screen.iter_mut() {
                fit(row, cols);
            }
        }
        self.cols = cols;
        self.rows = rows;
        self.scroll_top = 0;
        self.scroll_bottom = rows - 1;
        if self.alt_active {
            self.primary_cursor.y = self.primary_cursor.y.saturating_sub(push);
        } else {
            self.cursor.y = self.cursor.y.saturating_sub(push);
        }
        for cursor in [&mut self.cursor, &mut self.primary_cursor] {
            cursor.x = cursor.x.min(cols - 1);
            cursor.y = cursor.y.min(rows - 1);
            cursor.pending_wrap = false;
        }
        self.reset_needed = true;
    }

    /// Sequences that bring a reset terminal to this one's passed-on modes.
    pub fn write_modes(&self, out: &mut Vec<u8>) {
        for (mode, on) in &self.modes {
            out.extend_from_slice(
                format!("\x1b[?{mode}{}", if *on { 'h' } else { 'l' }).as_bytes(),
            );
        }
        if self.keypad_application {
            out.extend_from_slice(b"\x1b=");
        }
        if let Some(shape) = &self.cursor_shape {
            out.extend_from_slice(shape);
        }
        if let Some(&flags) = self.kitty_flags.last() {
            out.extend_from_slice(format!("\x1b[>{flags}u").as_bytes());
        }
        if let Some(title) = &self.title {
            out.extend_from_slice(title);
        }
    }

    // MARK: Parser

    /// Parses one byte.
    pub fn advance(&mut self, byte: u8) {
        match self.state {
            State::Ground => self.ground(byte),
            State::Escape => self.escape(byte),
            State::Csi => {
                self.seq.push(byte);
                if (0x40..=0x7e).contains(&byte) {
                    self.state = State::Ground;
                    let seq = std::mem::take(&mut self.seq);
                    self.csi(&seq);
                    self.seq = seq;
                    self.seq.clear();
                } else if byte == 0x1b {
                    // An ESC inside a CSI starts over.
                    self.seq.clear();
                    self.seq.push(0x1b);
                    self.state = State::Escape;
                } else if byte < 0x20 {
                    // C0 controls inside CSI act at once.
                    self.seq.pop();
                    self.execute(byte);
                } else if self.seq.len() > 256 {
                    self.seq.clear();
                    self.state = State::Ground;
                }
            }
            State::Osc => match byte {
                0x07 => {
                    self.seq.push(byte);
                    self.finish_osc();
                }
                0x1b => self.state = State::OscEscape,
                _ => self.push_seq(byte),
            },
            State::OscEscape => {
                if byte == b'\\' {
                    self.seq.extend_from_slice(b"\x1b\\");
                    self.finish_osc();
                } else {
                    self.seq.clear();
                    self.state = State::Escape;
                    self.seq.push(0x1b);
                    self.escape(byte);
                }
            }
            State::Dcs => match byte {
                0x1b => self.state = State::DcsEscape,
                _ => self.push_seq(byte),
            },
            State::DcsEscape => {
                if byte == b'\\' {
                    self.seq.extend_from_slice(b"\x1b\\");
                    // DCS queries (XTGETTCAP, DECRQSS) are answered by the phone's terminal.
                    let seq = std::mem::take(&mut self.seq);
                    self.passthrough.extend_from_slice(&seq);
                    self.seq = seq;
                    self.seq.clear();
                    self.state = State::Ground;
                } else {
                    self.seq.clear();
                    self.seq.push(0x1b);
                    self.state = State::Escape;
                    self.escape(byte);
                }
            }
            State::Ignore => {
                if byte == 0x1b {
                    self.state = State::IgnoreEscape;
                } else if byte == 0x07 {
                    self.state = State::Ground;
                }
            }
            State::IgnoreEscape => {
                if byte == b'\\' {
                    self.state = State::Ground;
                } else {
                    self.state = State::Ignore;
                }
            }
        }
    }

    fn push_seq(&mut self, byte: u8) {
        if self.seq.len() < MAX_SEQUENCE {
            self.seq.push(byte);
        } else {
            self.seq.clear();
            self.state = State::Ignore;
        }
    }

    fn ground(&mut self, byte: u8) {
        if self.utf8_need > 0 {
            if byte & 0xc0 == 0x80 {
                if let Some(slot) = self.utf8.get_mut(self.utf8_len) {
                    *slot = byte;
                }
                self.utf8_len += 1;
                if self.utf8_len == self.utf8_need {
                    let ch =
                        std::str::from_utf8(self.utf8.get(..self.utf8_len).unwrap_or_default())
                            .ok()
                            .and_then(|s| s.chars().next())
                            .unwrap_or('\u{fffd}');
                    self.utf8_need = 0;
                    self.utf8_len = 0;
                    self.print(ch);
                }
                return;
            }
            self.utf8_need = 0;
            self.utf8_len = 0;
            self.print('\u{fffd}');
        }
        match byte {
            0x1b => {
                self.seq.clear();
                self.seq.push(0x1b);
                self.state = State::Escape;
            }
            0x00..=0x1f | 0x7f => self.execute(byte),
            0x20..=0x7e => self.print(char::from(byte)),
            _ => {
                let need = match byte {
                    0xc2..=0xdf => 2,
                    0xe0..=0xef => 3,
                    0xf0..=0xf4 => 4,
                    _ => 0,
                };
                if need == 0 {
                    self.print('\u{fffd}');
                } else {
                    self.utf8[0] = byte;
                    self.utf8_len = 1;
                    self.utf8_need = need;
                }
            }
        }
    }

    fn escape(&mut self, byte: u8) {
        self.seq.push(byte);
        match byte {
            b'[' => {
                self.state = State::Csi;
                return;
            }
            b']' => {
                self.state = State::Osc;
                return;
            }
            b'P' => {
                self.state = State::Dcs;
                return;
            }
            b'X' | b'^' | b'_' => {
                self.state = State::Ignore;
                return;
            }
            0x20..=0x2f => return, // intermediates
            0x18 | 0x1a => {
                self.state = State::Ground;
                return;
            }
            0x00..=0x1f => {
                self.seq.pop();
                self.execute(byte);
                return;
            }
            _ => {}
        }
        self.state = State::Ground;
        let intermediate =
            if self.seq.len() > 2 { self.seq.get(1).copied().unwrap_or(0) } else { 0 };
        match (intermediate, byte) {
            (b'(', b'0') => self.charsets[0] = true,
            (b'(', _) => self.charsets[0] = false,
            (b')', b'0') => self.charsets[1] = true,
            (b')', _) => self.charsets[1] = false,
            (0, b'7') => self.save_cursor(),
            (0, b'8') => self.restore_cursor(),
            (0, b'D') => self.linefeed(),
            (0, b'E') => {
                self.carriage_return();
                self.linefeed();
            }
            (0, b'M') => self.reverse_index(),
            (0, b'c') => self.full_reset(),
            (0, b'=') => {
                self.keypad_application = true;
                self.passthrough.extend_from_slice(b"\x1b=");
            }
            (0, b'>') => {
                self.keypad_application = false;
                self.passthrough.extend_from_slice(b"\x1b>");
            }
            _ => {}
        }
        self.seq.clear();
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            0x07 => self.passthrough.push(0x07),
            0x08 => {
                if self.cursor.pending_wrap {
                    self.cursor.pending_wrap = false;
                } else if self.cursor.x > 0 {
                    self.cursor.x -= 1;
                }
            }
            0x09 => {
                self.cursor.pending_wrap = false;
                self.cursor.x = ((self.cursor.x / 8 + 1) * 8).min(self.cols - 1);
            }
            0x0a..=0x0c => {
                if self.newline_mode {
                    self.carriage_return();
                }
                self.linefeed();
                self.semantic_next_row(false);
            }
            0x0d => self.carriage_return(),
            0x0e => self.shift_out = true,
            0x0f => self.shift_out = false,
            _ => {}
        }
    }

    fn finish_osc(&mut self) {
        self.state = State::Ground;
        let seq = std::mem::take(&mut self.seq);
        // `ESC ]` .. body .. (BEL | ESC \)
        let end = if seq.ends_with(b"\x07") { seq.len() - 1 } else { seq.len() - 2 };
        let body = seq.get(2..end.max(2)).unwrap_or_default();
        let mut parts = body.splitn(2, |&b| b == b';');
        let number = parts.next().unwrap_or_default();
        let rest = parts.next().unwrap_or_default();
        if number == b"133" {
            self.semantic_prompt(rest);
        }
        match number {
            b"8" => {
                // `8;params;uri`: the link the next cells are in.
                let text = String::from_utf8_lossy(rest);
                let uri = text.split_once(';').map_or("", |(_, uri)| uri);
                self.cursor.style.link = if uri.is_empty() { 0 } else { self.links.id(&text) };
            }
            _ => {
                if number == b"0" || number == b"2" {
                    self.title = Some(seq.clone());
                }
                self.passthrough.extend_from_slice(&seq);
            }
        }
        self.seq = seq;
        self.seq.clear();
    }

    fn csi(&mut self, seq: &[u8]) {
        // ESC [ (private marker) params (intermediates) final
        let Some(body) = seq.get(2..) else { return };
        let Some((&last, head)) = body.split_last() else { return };
        let mut start = 0;
        let private = match head.first() {
            Some(&b @ (b'?' | b'>' | b'<' | b'=')) => {
                start = 1;
                b
            }
            _ => 0,
        };
        let mut end = head.len();
        while end > start && head.get(end - 1).is_some_and(|b| (0x20..=0x2f).contains(b)) {
            end -= 1;
        }
        let intermediate = head.get(end).copied().unwrap_or(0);
        let params: Vec<Vec<u16>> = if end > start {
            head.get(start..end)
                .unwrap_or_default()
                .split(|&b| b == b';')
                .map(|group| {
                    group
                        .split(|&b| b == b':')
                        .map(|v| {
                            std::str::from_utf8(v)
                                .ok()
                                .and_then(|v| v.parse::<u32>().ok())
                                .map_or(0, |v| v.min(u32::from(u16::MAX)) as u16)
                        })
                        .collect()
                })
                .collect()
        } else {
            Vec::new()
        };
        let p = |i: usize| params.get(i).and_then(|g| g.first()).copied().unwrap_or(0);
        let n = |i: usize| usize::from(p(i).max(1));
        match (private, intermediate, last) {
            (0, 0, b'm') => self.cursor.style.apply_sgr(&params),
            (0, 0, b'A') => self.cursor_up(n(0)),
            (0, 0, b'B' | b'e') => self.cursor_down(n(0)),
            (0, 0, b'C' | b'a') => self.cursor_forward(n(0)),
            (0, 0, b'D') => self.cursor_back(n(0)),
            (0, 0, b'E') => {
                self.cursor_down(n(0));
                self.carriage_return();
            }
            (0, 0, b'F') => {
                self.cursor_up(n(0));
                self.carriage_return();
            }
            (0, 0, b'G' | b'`') => self.set_column(n(0) - 1),
            (0, 0, b'H' | b'f') => self.cursor_position(n(0) - 1, n(1) - 1),
            (0, 0, b'd') => {
                let x = self.cursor.x;
                self.cursor_position(n(0) - 1, x);
            }
            (0, 0, b'I') => {
                for _ in 0..n(0) {
                    self.execute(0x09);
                }
            }
            (0, 0, b'Z') => {
                self.cursor.pending_wrap = false;
                for _ in 0..n(0) {
                    self.cursor.x =
                        if self.cursor.x == 0 { 0 } else { (self.cursor.x - 1) / 8 * 8 };
                }
            }
            (0 | b'?', 0, b'J') => self.erase_display(p(0)),
            (0 | b'?', 0, b'K') => self.erase_line(p(0)),
            (0, 0, b'@') => self.insert_chars(n(0)),
            (0, 0, b'P') => self.delete_chars(n(0)),
            (0, 0, b'X') => self.erase_chars(n(0)),
            (0, 0, b'L') => self.insert_lines(n(0)),
            (0, 0, b'M') => self.delete_lines(n(0)),
            (0, 0, b'S') => self.scroll_up(n(0)),
            (0, 0, b'T') => self.scroll_down(n(0)),
            (0, 0, b'b') => {
                if let Some((ch, _)) = self.last_printed
                    && let Some(ch) = char::from_u32(ch)
                {
                    for _ in 0..n(0).min(self.cols * self.rows) {
                        self.print(ch);
                    }
                }
            }
            (0, 0, b'r') => {
                let top = n(0) - 1;
                let bottom = if p(1) == 0 { self.rows - 1 } else { usize::from(p(1)) - 1 };
                if top < bottom && bottom < self.rows {
                    self.scroll_top = top;
                    self.scroll_bottom = bottom;
                    self.cursor_position(0, 0);
                }
            }
            (0, 0, b's') => self.save_cursor(),
            (0, 0, b'u') => self.restore_cursor(),
            (b'?', 0, b'h' | b'l') => {
                let on = last == b'h';
                for group in &params {
                    let mode = group.first().copied().unwrap_or(0);
                    self.set_private_mode(mode, on);
                }
            }
            (0, 0, b'h' | b'l') => {
                let on = last == b'h';
                for group in &params {
                    match group.first().copied().unwrap_or(0) {
                        4 => self.insert = on,
                        20 => self.newline_mode = on,
                        _ => {}
                    }
                }
            }
            // On the alternate screen the program's bytes reach the phone's
            // terminal unchanged and it answers at the host's grid: one answer.
            (0, 0, b'n') if p(0) == 6 && !self.alt_active => {
                let (row, col) = self.report_position();
                self.replies.extend_from_slice(format!("\x1b[{row};{col}R").as_bytes());
            }
            (b'?', 0, b'n') if p(0) == 6 && !self.alt_active => {
                let (row, col) = self.report_position();
                self.replies.extend_from_slice(format!("\x1b[?{row};{col}R").as_bytes());
            }
            (0, 0, b't') if p(0) == 18 && !self.alt_active => {
                self.replies
                    .extend_from_slice(format!("\x1b[8;{};{}t", self.rows, self.cols).as_bytes());
            }
            (0, 0, b't') => {
                // Pixel sizes and the title stack: the phone's terminal answers.
                if matches!(p(0), 14 | 16 | 22 | 23) {
                    self.passthrough.extend_from_slice(seq);
                }
            }
            (0, b' ', b'q') => {
                self.cursor_shape = Some(seq.to_vec());
                self.passthrough.extend_from_slice(seq);
            }
            // Kitty keyboard flags: push, pop, set.
            (b'>', 0, b'u') => {
                if self.kitty_flags.len() > 64 {
                    self.kitty_flags.remove(0);
                }
                self.kitty_flags.push(u32::from(p(0)));
                self.passthrough.extend_from_slice(seq);
            }
            (b'<', 0, b'u') => {
                for _ in 0..n(0) {
                    self.kitty_flags.pop();
                }
                self.passthrough.extend_from_slice(seq);
            }
            (b'=', 0, b'u') => {
                let flags = u32::from(p(0));
                let current = self.kitty_flags.last().copied().unwrap_or(0);
                let next = match p(1) {
                    2 => current | flags,
                    3 => current & !flags,
                    _ => flags,
                };
                match self.kitty_flags.last_mut() {
                    Some(top) => *top = next,
                    None => self.kitty_flags.push(next),
                }
                self.passthrough.extend_from_slice(seq);
            }
            // Queries the phone's terminal answers the same at any width
            // (device attributes, mode reports, versions, key modifiers).
            (_, _, b'c')
            | (b'?', b'$', b'p')
            | (0, b'$', b'p')
            | (b'?', 0, b'u')
            | (b'>', 0, b'q')
            | (b'>', 0, b'm')
            | (b'?', 0, b'n')
            | (0, 0, b'n') => {
                self.passthrough.extend_from_slice(seq);
            }
            _ => {}
        }
    }

    fn set_private_mode(&mut self, mode: u16, on: bool) {
        match mode {
            6 => {
                self.origin = on;
                self.cursor_position(0, 0);
            }
            7 => self.autowrap = on,
            25 => self.cursor_visible = on,
            47 | 1047 | 1049 => {
                if on && !self.alt_active {
                    self.alt_mode = mode;
                }
                match mode {
                    1049 => self.set_alternate(on, true, true),
                    _ => self.set_alternate(on, false, mode == 1047),
                }
            }
            1048 => {
                if on {
                    self.save_cursor();
                } else {
                    self.restore_cursor();
                }
            }
            _ if OWN_MODES.contains(&mode) => {}
            _ => {
                self.modes.insert(mode, on);
                self.passthrough.extend_from_slice(
                    format!("\x1b[?{mode}{}", if on { 'h' } else { 'l' }).as_bytes(),
                );
            }
        }
    }

    fn set_alternate(&mut self, on: bool, save_cursor: bool, clear: bool) {
        if on == self.alt_active {
            return;
        }
        self.screen_cleared += 1;
        if on {
            if save_cursor {
                self.save_cursor();
            }
            self.primary_cursor = self.cursor;
            self.alt_active = true;
            if clear {
                self.alt = blank_rows(self.cols, self.rows);
            }
        } else {
            if clear {
                self.alt = blank_rows(self.cols, self.rows);
            }
            self.alt_active = false;
            self.cursor = self.primary_cursor;
            if save_cursor {
                self.restore_cursor();
            }
        }
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
    }

    fn full_reset(&mut self) {
        let (cols, rows, limit) = (self.cols, self.rows, self.history_limit);
        let cap_bytes = self.history_cap_bytes;
        let styles = std::mem::take(&mut self.styles);
        let graphemes = std::mem::take(&mut self.graphemes);
        let links = std::mem::take(&mut self.links);
        let passthrough = std::mem::take(&mut self.passthrough);
        let replies = std::mem::take(&mut self.replies);
        *self = Terminal::new(cols, rows, limit);
        self.history_cap_bytes = cap_bytes;
        // Interned strings stay valid for cells still on the phone.
        self.styles = styles;
        self.graphemes = graphemes;
        self.links = links;
        self.passthrough = passthrough;
        self.replies = replies;
        self.reset_needed = true;
    }

    // MARK: Cursor

    fn report_position(&self) -> (usize, usize) {
        let row = if self.origin { self.cursor.y - self.scroll_top } else { self.cursor.y };
        (row + 1, self.cursor.x + 1)
    }

    fn carriage_return(&mut self) {
        self.cursor.x = 0;
        self.cursor.pending_wrap = false;
    }

    fn cursor_up(&mut self, n: usize) {
        let top = if self.cursor.y >= self.scroll_top { self.scroll_top } else { 0 };
        self.cursor.y = self.cursor.y.saturating_sub(n).max(top);
        self.cursor.pending_wrap = false;
    }

    fn cursor_down(&mut self, n: usize) {
        let bottom =
            if self.cursor.y <= self.scroll_bottom { self.scroll_bottom } else { self.rows - 1 };
        self.cursor.y = (self.cursor.y + n).min(bottom);
        self.cursor.pending_wrap = false;
    }

    fn cursor_forward(&mut self, n: usize) {
        self.cursor.x = (self.cursor.x + n).min(self.cols - 1);
        self.cursor.pending_wrap = false;
    }

    fn cursor_back(&mut self, n: usize) {
        self.cursor.x = self.cursor.x.saturating_sub(n);
        self.cursor.pending_wrap = false;
    }

    fn set_column(&mut self, x: usize) {
        self.cursor.x = x.min(self.cols - 1);
        self.cursor.pending_wrap = false;
    }

    fn cursor_position(&mut self, row: usize, col: usize) {
        let (top, bottom) =
            if self.origin { (self.scroll_top, self.scroll_bottom) } else { (0, self.rows - 1) };
        self.cursor.y = (top + row).min(bottom);
        self.cursor.x = col.min(self.cols - 1);
        self.cursor.pending_wrap = false;
    }

    fn save_cursor(&mut self) {
        let slot = usize::from(self.alt_active);
        let saved = Saved {
            x: self.cursor.x,
            y: self.cursor.y,
            pending_wrap: self.cursor.pending_wrap,
            style: self.cursor.style,
            origin: self.origin,
            charsets: self.charsets,
            shift_out: self.shift_out,
        };
        if let Some(slot) = self.saved.get_mut(slot) {
            *slot = saved;
        }
    }

    fn restore_cursor(&mut self) {
        let saved = self.saved.get(usize::from(self.alt_active)).copied().unwrap_or_default();
        self.cursor.x = saved.x.min(self.cols - 1);
        self.cursor.y = saved.y.min(self.rows - 1);
        self.cursor.pending_wrap = saved.pending_wrap;
        self.cursor.style = saved.style;
        self.origin = saved.origin;
        self.charsets = saved.charsets;
        self.shift_out = saved.shift_out;
    }

    // MARK: Drawing

    fn screen(&mut self) -> &mut Vec<Row> {
        if self.alt_active { &mut self.alt } else { &mut self.primary }
    }

    fn erased_id(&mut self) -> u16 {
        let style = self.cursor.style.erased();
        self.styles.id(style)
    }

    fn print(&mut self, ch: char) {
        let special = self.charsets.get(usize::from(self.shift_out)).copied().unwrap_or(false);
        let ch = if special { dec_special(ch) } else { ch };
        // Grapheme clustering (mode 2027, on by default as in Ghostty): a
        // code point that does not start a cluster joins the glyph before
        // the cursor, whatever its width, as Ghostty's `print` does. Only
        // code points past U+00FF are checked, as there.
        let clustering = self.modes.get(&2027).copied().unwrap_or(true);
        if clustering && u32::from(ch) > 0xFF && self.cursor.x > 0 && self.cluster(ch) {
            return;
        }
        let width = unicode::width(ch);
        if width == 0 {
            if !clustering {
                self.combine(ch);
            }
            return;
        }
        let cols = self.cols;
        if self.cursor.pending_wrap && self.autowrap {
            let y = self.cursor.y;
            if let Some(row) = self.screen().get_mut(y) {
                row.wrapped = true;
            }
            self.linefeed();
            self.semantic_next_row(true);
            self.cursor.x = 0;
        }
        self.cursor.pending_wrap = false;
        if width == 2 && cols < 2 {
            return;
        }
        if width == 2 && self.cursor.x == cols - 1 {
            if !self.autowrap {
                return;
            }
            let (x, y) = (self.cursor.x, self.cursor.y);
            let erased = self.erased_id();
            self.clear_wide(y, x);
            if let Some(row) = self.screen().get_mut(y) {
                if let Some(cell) = row.cells.get_mut(x) {
                    *cell = Cell { ch: 0, style: erased, kind: SPACER_HEAD };
                }
                row.wrapped = true;
            }
            self.linefeed();
            self.cursor.x = 0;
        }
        let style = self.styles.id(self.cursor.style);
        let (x, y) = (self.cursor.x, self.cursor.y);
        if self.insert
            && let Some(row) = self.screen().get_mut(y)
        {
            for _ in 0..width {
                row.cells.insert(x, Cell::blank(0));
            }
            row.cells.truncate(cols);
        }
        self.clear_wide(y, x);
        if width == 2 {
            self.clear_wide(y, x + 1);
        }
        if let Some(row) = self.screen().get_mut(y) {
            if let Some(cell) = row.cells.get_mut(x) {
                *cell =
                    Cell { ch: u32::from(ch), style, kind: if width == 2 { WIDE } else { NARROW } };
            }
            if width == 2
                && let Some(cell) = row.cells.get_mut(x + 1)
            {
                *cell = Cell { ch: 0, style, kind: WIDE_TAIL };
            }
        }
        self.last_printed = Some((u32::from(ch), width));
        let next = x + width;
        if next >= cols {
            self.cursor.x = cols - 1;
            self.cursor.pending_wrap = self.autowrap;
        } else {
            self.cursor.x = next;
        }
    }

    /// Joins `ch` to the glyph before the cursor when it continues that
    /// glyph's grapheme cluster (Ghostty's `print` with mode 2027): a
    /// variation selector or a code point that widens the cluster makes
    /// the glyph wide (wrapping it when it sits in the last column) or
    /// narrow. False: `ch` starts a glyph of its own.
    fn cluster(&mut self, ch: char) -> bool {
        let (y, cursor_x, pending, cols, autowrap) =
            (self.cursor.y, self.cursor.x, self.cursor.pending_wrap, self.cols, self.autowrap);
        let Some(row) = self.screen().get(y) else { return false };
        let left = if autowrap {
            usize::from(!pending)
        } else if cursor_x != cols - 1 {
            1
        } else {
            usize::from(row.cells.get(cursor_x).is_none_or(|c| c.ch == 0))
        };
        let Some(mut x) = cursor_x.checked_sub(left) else { return false };
        if row.cells.get(x).is_some_and(|c| c.kind == WIDE_TAIL) {
            let Some(before) = x.checked_sub(1) else { return false };
            x = before;
        }
        let Some(&cell) = row.cells.get(x) else { return false };
        if cell.ch == 0 {
            return false;
        }
        let mut text = self.cell_text(cell);
        if !unicode::is_break(&text, ch) {
            let prev = text.chars().next_back().unwrap_or(' ');
            let mut at = (y, x);
            match unicode::width_effect(prev, ch) {
                WidthEffect::Ignore => return true,
                WidthEffect::NoChange => {}
                WidthEffect::Wide if cell.kind == WIDE => {}
                WidthEffect::Wide => {
                    let style = self.styles.id(self.cursor.style);
                    self.cursor.x = x;
                    if x == cols - 1 {
                        if !autowrap {
                            return true;
                        }
                        // No room for a wide glyph: a spacer head, and the
                        // glyph again at the next row's start.
                        if let Some(row) = self.screen().get_mut(y) {
                            row.wrapped = true;
                            if let Some(c) = row.cells.get_mut(x) {
                                *c = Cell { ch: 0, style, kind: SPACER_HEAD };
                            }
                        }
                        self.linefeed();
                        self.cursor.x = 0;
                        let y = self.cursor.y;
                        self.clear_wide(y, 0);
                        if let Some(c) = self.screen().get_mut(y).and_then(|r| r.cells.get_mut(0)) {
                            *c = Cell { ch: cell.ch, style, kind: WIDE };
                        }
                        at = (y, 0);
                    } else if let Some(c) =
                        self.screen().get_mut(y).and_then(|r| r.cells.get_mut(x))
                    {
                        c.kind = WIDE;
                    }
                    let (y, x) = at;
                    if x + 1 < cols {
                        self.clear_wide(y, x + 1);
                        if let Some(c) =
                            self.screen().get_mut(y).and_then(|r| r.cells.get_mut(x + 1))
                        {
                            *c = Cell { ch: 0, style, kind: WIDE_TAIL };
                        }
                    }
                    if x + 1 >= cols - 1 {
                        self.cursor.x = cols - 1;
                        self.cursor.pending_wrap = true;
                    } else {
                        self.cursor.x = x + 2;
                        self.cursor.pending_wrap = false;
                    }
                }
                WidthEffect::Narrow if cell.kind != WIDE => {}
                WidthEffect::Narrow => {
                    if let Some(row) = self.screen().get_mut(y) {
                        if let Some(c) = row.cells.get_mut(x) {
                            c.kind = NARROW;
                        }
                        if let Some(c) = row.cells.get_mut(x + 1) {
                            c.kind = NARROW;
                        }
                    }
                    self.cursor.pending_wrap = false;
                    self.cursor.x = (x + 1).min(cols - 1);
                }
            }
            text.push(ch);
            let id = self.graphemes.id(&text);
            let (y, x) = at;
            if let Some(c) = self.screen().get_mut(y).and_then(|r| r.cells.get_mut(x)) {
                c.ch = GRAPHEME | id;
            }
            return true;
        }
        false
    }

    /// With grapheme clustering off (mode 2027 reset): a zero-width code
    /// point joins the glyph before the cursor.
    fn combine(&mut self, ch: char) {
        let (y, cursor_x, pending) = (self.cursor.y, self.cursor.x, self.cursor.pending_wrap);
        let mut x = if pending {
            cursor_x
        } else if cursor_x > 0 {
            cursor_x - 1
        } else {
            return;
        };
        let Some(row) = self.screen().get(y) else { return };
        if row.cells.get(x).is_some_and(|c| c.kind == WIDE_TAIL) && x > 0 {
            x -= 1;
        }
        let Some(&cell) = row.cells.get(x) else { return };
        if cell.ch == 0 {
            return;
        }
        let mut text = self.cell_text(cell);
        text.push(ch);
        let id = self.graphemes.id(&text);
        if let Some(cell) = self.screen().get_mut(y).and_then(|r| r.cells.get_mut(x)) {
            cell.ch = GRAPHEME | id;
        }
    }

    /// A cell's UTF-8 bytes, appended without allocating.
    pub fn write_cell(&self, cell: Cell, out: &mut Vec<u8>) {
        if cell.ch & GRAPHEME != 0 {
            out.extend_from_slice(self.graphemes.get(cell.ch & !GRAPHEME).as_bytes());
        } else if cell.ch < 0x80 {
            out.push(cell.ch as u8);
        } else if let Some(c) = char::from_u32(cell.ch) {
            let mut buf = [0; 4];
            out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
        }
    }

    pub fn cell_text(&self, cell: Cell) -> String {
        if cell.ch & GRAPHEME != 0 {
            self.graphemes.get(cell.ch & !GRAPHEME).to_string()
        } else {
            char::from_u32(cell.ch).map_or_else(String::new, String::from)
        }
    }

    /// Writing over half of a wide glyph clears its other half.
    fn clear_wide(&mut self, y: usize, x: usize) {
        let cols = self.cols;
        let Some(row) = self.screen().get_mut(y) else { return };
        let Some(kind) = row.cells.get(x).map(|c| c.kind) else { return };
        let other = match kind {
            WIDE_TAIL if x > 0 => row.cells.get_mut(x - 1),
            WIDE if x + 1 < cols => row.cells.get_mut(x + 1),
            _ => None,
        };
        if let Some(cell) = other {
            *cell = Cell::blank(cell.style);
        }
    }

    fn linefeed(&mut self) {
        self.cursor.pending_wrap = false;
        if self.cursor.y == self.scroll_bottom {
            self.scroll_up(1);
        } else if self.cursor.y < self.rows - 1 {
            self.cursor.y += 1;
        }
    }

    fn reverse_index(&mut self) {
        self.cursor.pending_wrap = false;
        if self.cursor.y == self.scroll_top {
            self.scroll_down(1);
        } else if self.cursor.y > 0 {
            self.cursor.y -= 1;
        }
    }

    /// Rows of the scroll region move up `n`; on the primary screen, rows
    /// leaving a region that starts at the top go to the scrollback.
    fn scroll_up(&mut self, n: usize) {
        let (top, bottom, cols) = (self.scroll_top, self.scroll_bottom, self.cols);
        let n = n.min(bottom - top + 1);
        let erased = self.erased_id();
        let to_history = !self.alt_active && top == 0;
        for _ in 0..n {
            let row = self.screen().remove(top);
            self.screen().insert(bottom, blank_row(cols, erased));
            if to_history {
                self.push_history(row);
            }
        }
    }

    fn scroll_down(&mut self, n: usize) {
        let (top, bottom, cols) = (self.scroll_top, self.scroll_bottom, self.cols);
        let n = n.min(bottom - top + 1);
        let erased = self.erased_id();
        for _ in 0..n {
            self.screen().remove(bottom);
            self.screen().insert(top, blank_row(cols, erased));
        }
    }

    fn push_history(&mut self, mut row: Row) {
        let keep = row.cells.iter().rposition(|c| *c != Cell::default()).map_or(0, |i| i + 1);
        row.cells.truncate(keep);
        row.cells.shrink_to_fit();
        self.history_bytes += row_bytes(&row);
        self.history.push_back(row);
        self.trim_history();
    }

    /// Drops the oldest rows past the row limit or the byte cap.
    fn trim_history(&mut self) {
        while self.history.len() > self.history_limit
            || (self.history_bytes > self.history_cap_bytes && !self.history.is_empty())
        {
            if let Some(row) = self.history.pop_front() {
                self.history_bytes = self.history_bytes.saturating_sub(row_bytes(&row));
            }
            self.history_dropped += 1;
        }
    }

    /// Bytes the scrollback holds (its rows' cells and the rows themselves).
    pub fn history_bytes(&self) -> usize {
        self.history_bytes
    }

    /// Bounds the scrollback by rows and by bytes (0: no byte cap); the
    /// oldest rows past either go.
    pub fn set_history_cap(&mut self, rows: usize, bytes: usize) {
        self.history_limit = rows.max(1);
        self.history_cap_bytes = if bytes == 0 { usize::MAX } else { bytes };
        self.trim_history();
    }

    /// The host's number of `history[0]`: the rows of its scrollback this
    /// model never had (a replay that starts inside it, as
    /// `history_rows_omitted`). The view starts over: its rows are numbered
    /// anew.
    pub fn set_history_origin(&mut self, omitted: u64) {
        if self.history_dropped != omitted {
            self.history_dropped = omitted;
            self.reset_needed = true;
        }
    }

    /// The host rows to fetch next, never one this model holds or had: up
    /// to `chunk` rows just above `history[0]`, as (first row, rows). None
    /// at the host's first row or when the scrollback is full.
    pub fn older_fetch(&self, chunk: usize) -> Option<(u64, usize)> {
        let room = self.history_limit.saturating_sub(self.history.len());
        if self.history_dropped == 0
            || chunk == 0
            || room == 0
            || self.history_bytes >= self.history_cap_bytes
        {
            return None;
        }
        let rows = (chunk.min(room) as u64).min(self.history_dropped);
        Some((self.history_dropped - rows, rows as usize))
    }

    /// Puts a fetched page of older host rows above `history[0]`, with no
    /// reset: `page` is rows `start..` as VT bytes, each ended by CRLF, at
    /// the host's width. Rows the model already holds are skipped; a page
    /// that ends above `history[0]` (a gap) is refused. Takes the newest
    /// rows first and stops at the row limit or the byte cap. Returns the
    /// rows added.
    pub fn prepend_history(&mut self, start: u64, page: &[u8]) -> usize {
        let mut scratch = Terminal::new(self.cols, 1, usize::MAX);
        for &byte in page {
            scratch.advance(byte);
        }
        if scratch
            .primary
            .first()
            .is_some_and(|row| row.cells.iter().any(|c| *c != Cell::default()))
        {
            scratch.advance(b'\r');
            scratch.advance(b'\n');
        }
        let rows = scratch.history.len() as u64;
        let end = start + rows;
        if end < self.history_dropped || start >= self.history_dropped {
            return 0;
        }
        // Rows at or past `history_dropped` are held already.
        let skip = (end - self.history_dropped) as usize;
        let mut added = 0;
        let mut page_rows = std::mem::take(&mut scratch.history);
        page_rows.truncate(page_rows.len() - skip);
        while let Some(mut row) = page_rows.pop_back() {
            let cost = row_bytes(&row);
            if self.history.len() >= self.history_limit
                || self.history_bytes.saturating_add(cost) > self.history_cap_bytes
            {
                break;
            }
            for cell in &mut row.cells {
                if cell.style != 0 {
                    let mut style = scratch.styles.get(cell.style);
                    if style.link != 0 {
                        style.link = self.links.id(scratch.links.get(style.link));
                    }
                    cell.style = self.styles.id(style);
                }
                if cell.ch & GRAPHEME != 0 {
                    cell.ch =
                        GRAPHEME | self.graphemes.id(scratch.graphemes.get(cell.ch & !GRAPHEME));
                }
            }
            self.history_bytes += cost;
            self.history.push_front(row);
            self.history_dropped -= 1;
            added += 1;
        }
        added
    }

    fn erase_display(&mut self, mode: u16) {
        let erased = self.erased_id();
        let (x, y, rows, cols) = (self.cursor.x, self.cursor.y, self.rows, self.cols);
        match mode {
            0 => {
                self.erase_line(0);
                for row in self.screen().get_mut(y + 1..rows).unwrap_or_default() {
                    *row = blank_row(cols, erased);
                }
            }
            1 => {
                for row in self.screen().iter_mut().take(y) {
                    *row = blank_row(cols, erased);
                }
                self.clear_wide(y, x);
                if let Some(row) = self.screen().get_mut(y) {
                    for cell in row.cells.get_mut(..=x).unwrap_or_default() {
                        *cell = Cell::blank(erased);
                    }
                }
            }
            2 | 22 => {
                // As Ghostty: `ED 2` clears the screen in place, unless the
                // last row with something on it is a shell prompt (OSC 133
                // marks; Ctrl+L at a prompt), and `ED 22` (Kitty's
                // scroll-clear) always: then the screen's rows up to its
                // last non-blank one go to the scrollback first.
                if !self.alt_active {
                    self.screen_cleared += 1;
                }
                if !self.alt_active && (mode == 22 || self.at_prompt()) {
                    let last = self.primary.iter().rposition(|row| {
                        row.cells.iter().any(|c| !c.is_empty_or_space() || c.style != 0)
                    });
                    if let Some(last) = last {
                        for i in 0..=last {
                            if let Some(row) = self.primary.get_mut(i) {
                                let row = std::mem::take(row);
                                self.push_history(row);
                            }
                        }
                    }
                }
                for row in self.screen().iter_mut() {
                    *row = blank_row(cols, erased);
                }
            }
            3 if !self.alt_active => {
                self.history.clear();
                self.history_bytes = 0;
                self.history_dropped = 0;
                self.reset_needed = true;
            }
            _ => {}
        }
        self.cursor.pending_wrap = false;
    }

    /// Ghostty's "clearing at a prompt": with OSC 133 marks seen, the last
    /// row of the primary screen with text (blank rows below it skipped) is
    /// a prompt row.
    fn at_prompt(&self) -> bool {
        if !self.prompt_seen {
            return false;
        }
        for row in self.primary.iter().rev() {
            if row.prompt {
                return true;
            }
            if row.cells.iter().any(|c| !c.is_empty_or_space()) {
                return false;
            }
        }
        false
    }

    /// OSC 133 (`A`, `N`, `P`: a prompt starts; `B`, `I`: input; `C`, `D`:
    /// output), as Ghostty marks rows. Only the marks a clear reads.
    fn semantic_prompt(&mut self, body: &[u8]) {
        if self.alt_active {
            return;
        }
        match body.first() {
            Some(b'A' | b'N' | b'P') => {
                self.prompt_seen = true;
                self.semantic = Semantic::Prompt;
                self.semantic_clear_eol = false;
                let y = self.cursor.y;
                if let Some(row) = self.primary.get_mut(y) {
                    row.prompt = true;
                }
            }
            Some(b'B' | b'I') => {
                self.prompt_seen = true;
                self.semantic = Semantic::Input;
                self.semantic_clear_eol = body.first() == Some(&b'I');
            }
            Some(b'C') => {
                self.semantic = Semantic::Output;
                self.semantic_clear_eol = false;
                let (x, y) = (self.cursor.x, self.cursor.y);
                if x == 0
                    && let Some(row) = self.primary.get_mut(y)
                {
                    row.prompt = false;
                }
            }
            Some(b'D') => {
                self.semantic = Semantic::Output;
                self.semantic_clear_eol = false;
            }
            _ => {}
        }
    }

    /// The cursor went to the next row inside a prompt or its input: that
    /// row continues the prompt (input marked to end at its line's end
    /// ends at a line feed instead).
    fn semantic_next_row(&mut self, wrap: bool) {
        if self.alt_active || self.semantic == Semantic::Output {
            return;
        }
        if !wrap && self.semantic_clear_eol {
            self.semantic = Semantic::Output;
            self.semantic_clear_eol = false;
            return;
        }
        let y = self.cursor.y;
        if let Some(row) = self.primary.get_mut(y) {
            row.prompt = true;
        }
    }

    fn erase_line(&mut self, mode: u16) {
        let erased = self.erased_id();
        let (x, y, cols) = (self.cursor.x, self.cursor.y, self.cols);
        let range = match mode {
            0 => x..cols,
            1 => 0..x + 1,
            2 => 0..cols,
            _ => return,
        };
        self.clear_wide(y, range.start);
        self.clear_wide(y, range.end - 1);
        if let Some(row) = self.screen().get_mut(y) {
            for cell in row.cells.get_mut(range).unwrap_or_default() {
                *cell = Cell::blank(erased);
            }
            if mode != 1 {
                row.wrapped = false;
            }
        }
        self.cursor.pending_wrap = false;
    }

    fn erase_chars(&mut self, n: usize) {
        let erased = self.erased_id();
        let (x, y, cols) = (self.cursor.x, self.cursor.y, self.cols);
        let end = (x + n).min(cols);
        self.clear_wide(y, x);
        self.clear_wide(y, end - 1);
        if let Some(cells) = self.screen().get_mut(y).and_then(|r| r.cells.get_mut(x..end)) {
            for cell in cells {
                *cell = Cell::blank(erased);
            }
        }
        self.cursor.pending_wrap = false;
    }

    fn insert_chars(&mut self, n: usize) {
        let erased = self.erased_id();
        let (x, y, cols) = (self.cursor.x, self.cursor.y, self.cols);
        self.clear_wide(y, x);
        let Some(row) = self.screen().get_mut(y) else { return };
        for _ in 0..n.min(cols - x) {
            row.cells.insert(x, Cell::blank(erased));
        }
        row.cells.truncate(cols);
        if let Some(cell) = row.cells.get_mut(cols - 1)
            && cell.kind == WIDE
        {
            *cell = Cell::blank(erased);
        }
        self.cursor.pending_wrap = false;
    }

    fn delete_chars(&mut self, n: usize) {
        let erased = self.erased_id();
        let (x, y, cols) = (self.cursor.x, self.cursor.y, self.cols);
        self.clear_wide(y, x);
        let n = n.min(cols - x);
        let Some(row) = self.screen().get_mut(y) else { return };
        row.cells.drain(x..x + n);
        while row.cells.len() < cols {
            row.cells.push(Cell::blank(erased));
        }
        if let Some(cell) = row.cells.get_mut(x)
            && cell.kind == WIDE_TAIL
        {
            *cell = Cell::blank(erased);
        }
        self.cursor.pending_wrap = false;
    }

    fn insert_lines(&mut self, n: usize) {
        let (y, top, bottom, cols) =
            (self.cursor.y, self.scroll_top, self.scroll_bottom, self.cols);
        if y < top || y > bottom {
            return;
        }
        let erased = self.erased_id();
        for _ in 0..n.min(bottom - y + 1) {
            self.screen().remove(bottom);
            self.screen().insert(y, blank_row(cols, erased));
        }
        self.cursor.x = 0;
        self.cursor.pending_wrap = false;
    }

    fn delete_lines(&mut self, n: usize) {
        let (y, top, bottom, cols) =
            (self.cursor.y, self.scroll_top, self.scroll_bottom, self.cols);
        if y < top || y > bottom {
            return;
        }
        let erased = self.erased_id();
        for _ in 0..n.min(bottom - y + 1) {
            self.screen().remove(y);
            self.screen().insert(bottom, blank_row(cols, erased));
        }
        self.cursor.x = 0;
        self.cursor.pending_wrap = false;
    }
}

fn blank_row(cols: usize, style: u16) -> Row {
    Row { cells: vec![Cell::blank(style); cols], wrapped: false, prompt: false }
}

fn blank_rows(cols: usize, rows: usize) -> Vec<Row> {
    (0..rows).map(|_| blank_row(cols, 0)).collect()
}

fn fit(row: &mut Row, cols: usize) {
    row.cells.resize(cols, Cell::default());
    if let Some(last) = row.cells.last_mut()
        && last.kind == WIDE
    {
        *last = Cell::default();
    }
    if row.cells.len() < cols || cols == 0 {
        row.wrapped = false;
    }
}

/// DEC special graphics (`ESC ( 0`): line drawing for ASCII.
fn dec_special(ch: char) -> char {
    match ch {
        '`' => '◆',
        'a' => '▒',
        'f' => '°',
        'g' => '±',
        'j' => '┘',
        'k' => '┐',
        'l' => '┌',
        'm' => '└',
        'n' => '┼',
        'o' => '⎺',
        'p' => '⎻',
        'q' => '─',
        'r' => '⎼',
        's' => '⎽',
        't' => '├',
        'u' => '┤',
        'v' => '┴',
        'w' => '┬',
        'x' => '│',
        'y' => '≤',
        'z' => '≥',
        '{' => 'π',
        '|' => '≠',
        '}' => '£',
        '~' => '·',
        _ => ch,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed(term: &mut Terminal, text: &str) {
        for &b in text.as_bytes() {
            term.advance(b);
        }
    }

    fn text(term: &Terminal, row: &Row) -> String {
        row.cells
            .iter()
            .filter(|c| c.kind != WIDE_TAIL && c.kind != SPACER_HEAD)
            .map(|c| if c.ch == 0 { " ".to_string() } else { term.cell_text(*c) })
            .collect::<String>()
            .trim_end()
            .to_string()
    }

    #[test]
    fn autowrap_marks_the_row() {
        let mut term = Terminal::new(5, 3, 100);
        feed(&mut term, "abcdefg");
        assert!(term.primary[0].wrapped);
        assert!(!term.primary[1].wrapped);
        assert_eq!(text(&term, &term.primary[0]), "abcde");
        assert_eq!(text(&term, &term.primary[1]), "fg");
        assert_eq!(term.primary_cursor(), (2, 1));
    }

    #[test]
    fn rows_scroll_into_history() {
        let mut term = Terminal::new(10, 2, 100);
        feed(&mut term, "one\r\ntwo\r\nthree");
        assert_eq!(term.history.len(), 1);
        assert_eq!(text(&term, &term.history[0]), "one");
        assert_eq!(text(&term, &term.primary[1]), "three");
    }

    #[test]
    fn wide_glyph_at_the_edge_wraps_with_a_spacer_head() {
        let mut term = Terminal::new(5, 3, 100);
        feed(&mut term, "abcd世");
        assert_eq!(term.primary[0].cells[4].kind, SPACER_HEAD);
        assert!(term.primary[0].wrapped);
        assert_eq!(term.primary[1].cells[0].kind, WIDE);
    }

    #[test]
    fn cursor_reports_are_answered_in_host_cells() {
        let mut term = Terminal::new(80, 24, 100);
        feed(&mut term, "\x1b[5;9H\x1b[6n");
        assert_eq!(term.replies, b"\x1b[5;9R");
        assert!(term.passthrough.is_empty());
    }

    #[test]
    fn key_modes_are_passed_on() {
        let mut term = Terminal::new(80, 24, 100);
        feed(&mut term, "\x1b[?2004h\x1b[?1h\x1b[>1u\x1b]0;title\x07\x1b[?25l");
        assert_eq!(term.passthrough, b"\x1b[?2004h\x1b[?1h\x1b[>1u\x1b]0;title\x07");
        assert!(!term.cursor_visible);
    }

    #[test]
    fn alternate_screen_keeps_the_primary() {
        let mut term = Terminal::new(10, 3, 100);
        feed(&mut term, "shell$ \x1b[?1049h\x1b[2Jvim\x1b[?1049l");
        assert!(!term.is_alternate());
        assert_eq!(text(&term, &term.primary[0]), "shell$");
        assert_eq!(term.primary_cursor(), (7, 0));
    }

    #[test]
    fn erase_display_clears_in_place_as_ghostty_does() {
        // No OSC 133 marks: `ED 2` is a plain clear (the rows do not go to
        // the scrollback), as Ghostty's.
        let mut term = Terminal::new(10, 3, 100);
        feed(&mut term, "a\r\nb\x1b[H\x1b[2J$ ");
        assert!(term.history.is_empty());
        assert_eq!(text(&term, &term.primary[0]), "$");
        // Kitty's scroll-clear moves them first.
        feed(&mut term, "\r\nc\x1b[H\x1b[22J");
        assert_eq!(term.history.len(), 2);
        feed(&mut term, "\x1b[3J");
        assert!(term.history.is_empty());
        assert!(term.reset_needed);
    }

    #[test]
    fn erase_display_at_a_marked_prompt_scrolls_into_history() {
        // Ctrl+L at a prompt the shell marked (OSC 133): the screen goes to
        // the scrollback first, as Ghostty's "clearing at a prompt".
        let mut term = Terminal::new(10, 3, 100);
        feed(&mut term, "out\r\n\x1b]133;A\x07$ \x1b]133;B\x07\x1b[H\x1b[2J");
        assert_eq!(term.history.len(), 2);
        // Output after the prompt (the command ran): a plain clear again.
        let mut term = Terminal::new(10, 3, 100);
        feed(&mut term, "\x1b]133;A\x07$ \x1b]133;B\x07ls\r\n\x1b]133;C\x07file\x1b[H\x1b[2J");
        assert!(term.history.is_empty());
    }

    #[test]
    fn split_utf8_and_sequences_across_chunks() {
        let mut term = Terminal::new(10, 3, 100);
        let bytes = "\x1b[31mé世".as_bytes();
        for &b in bytes {
            term.advance(b);
        }
        assert_eq!(text(&term, &term.primary[0]), "é世");
        assert_eq!(
            term.styles.get(term.primary[0].cells[0].style).fg,
            crate::style::Color::Indexed(1)
        );
    }

    #[test]
    fn combining_marks_join_the_previous_glyph() {
        let mut term = Terminal::new(10, 3, 100);
        feed(&mut term, "e\u{301}x");
        assert_eq!(text(&term, &term.primary[0]), "e\u{301}x");
        assert_eq!(term.primary_cursor(), (2, 0));
    }

    /// The glyphs of row `y` as (text, wide), blanks skipped.
    fn glyphs(term: &Terminal, y: usize) -> Vec<(String, bool)> {
        term.primary[y]
            .cells
            .iter()
            .filter(|c| c.ch != 0 && c.kind != WIDE_TAIL)
            .map(|c| (term.cell_text(*c), c.kind == WIDE))
            .collect()
    }

    #[test]
    fn grapheme_clusters_are_one_glyph_as_in_ghostty() {
        let mut term = Terminal::new(20, 3, 100);
        feed(
            &mut term,
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}x\u{1F1EF}\u{1F1F5}\u{1F1FA}\u{1F1F8}",
        );
        assert_eq!(
            glyphs(&term, 0),
            vec![
                ("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}".to_string(), true),
                ("x".to_string(), false),
                ("\u{1F1EF}\u{1F1F5}".to_string(), true),
                ("\u{1F1FA}\u{1F1F8}".to_string(), true),
            ]
        );
        assert_eq!(term.primary_cursor(), (7, 0));
    }

    #[test]
    fn variation_selectors_set_the_glyph_width() {
        let mut term = Terminal::new(20, 3, 100);
        // VS16 widens an emoji base (a keycap too), VS15 narrows one, and
        // on a base it does not vary it is dropped.
        feed(&mut term, "\u{2764}\u{FE0F}|1\u{FE0F}\u{20E3}|\u{231A}\u{FE0E}|a\u{FE0F}|");
        assert_eq!(
            glyphs(&term, 0),
            vec![
                ("\u{2764}\u{FE0F}".to_string(), true),
                ("|".to_string(), false),
                ("1\u{FE0F}\u{20E3}".to_string(), true),
                ("|".to_string(), false),
                ("\u{231A}\u{FE0E}".to_string(), false),
                ("|".to_string(), false),
                ("a".to_string(), false),
                ("|".to_string(), false),
            ]
        );
        assert_eq!(term.primary_cursor(), (10, 0));
    }

    #[test]
    fn a_glyph_widened_in_the_last_column_wraps() {
        let mut term = Terminal::new(10, 3, 100);
        feed(&mut term, &format!("{}\u{2764}\u{FE0F}z", "x".repeat(9)));
        assert!(term.primary[0].wrapped);
        assert_eq!(term.primary[0].cells[9].kind, SPACER_HEAD);
        assert_eq!(
            glyphs(&term, 1),
            vec![("\u{2764}\u{FE0F}".to_string(), true), ("z".to_string(), false)]
        );
        assert_eq!(term.primary_cursor(), (3, 1));
    }

    #[test]
    fn indic_spacing_marks_and_conjuncts_cluster() {
        let mut term = Terminal::new(20, 3, 100);
        // A spacing mark makes its cluster wide, as Ghostty sizes it.
        feed(&mut term, "\u{915}\u{93F}.");
        assert_eq!(
            glyphs(&term, 0),
            vec![("\u{915}\u{93F}".to_string(), true), (".".to_string(), false)]
        );
    }

    fn page(range: std::ops::Range<u64>) -> Vec<u8> {
        range.map(|n| format!("row {n}\r\n")).collect::<String>().into_bytes()
    }

    fn history_text(term: &Terminal) -> Vec<String> {
        term.history.iter().map(|row| text(term, row)).collect()
    }

    #[test]
    fn the_byte_cap_drops_the_oldest_rows() {
        let mut term = Terminal::new(20, 1, 1_000);
        term.set_history_cap(
            1_000,
            3 * row_bytes(&Row { cells: vec![Cell::default(); 5], ..Row::default() }),
        );
        feed(&mut term, &String::from_utf8(page(0..10)).unwrap());
        assert_eq!(history_text(&term), ["row 7", "row 8", "row 9"]);
        assert_eq!(term.history_dropped, 7);
        assert!(term.history_bytes() <= 3 * (std::mem::size_of::<Row>() + 5 * 8));
        feed(&mut term, "\x1b[3J");
        assert_eq!(term.history_bytes(), 0);
    }

    #[test]
    fn a_page_goes_above_the_oldest_row_without_a_reset() {
        let mut term = Terminal::new(20, 1, 1_000);
        feed(&mut term, &String::from_utf8(page(100..103)).unwrap());
        term.set_history_origin(100);
        term.reset_needed = false;
        assert_eq!(term.older_fetch(40), Some((60, 40)));
        assert_eq!(term.prepend_history(60, &page(60..100)), 40);
        assert_eq!(term.history_dropped, 60);
        assert_eq!(history_text(&term)[..2], ["row 60", "row 61"]);
        assert_eq!(history_text(&term)[39..41], ["row 99", "row 100"]);
        assert!(!term.reset_needed);
        // Rows held already are skipped; a page above a gap is refused.
        assert_eq!(term.prepend_history(50, &page(50..70)), 10);
        assert_eq!(term.history_dropped, 50);
        assert_eq!(term.prepend_history(10, &page(10..40)), 0);
        assert_eq!(term.history.len(), 53);
    }

    #[test]
    fn the_fetch_plan_asks_each_row_once_and_stops_at_the_first() {
        let mut term = Terminal::new(20, 1, 100_000);
        feed(&mut term, "row 4999\r\n");
        term.set_history_origin(4_999);
        let mut asked = 0;
        while let Some((start, rows)) = term.older_fetch(2_000) {
            asked += rows;
            assert_eq!(term.prepend_history(start, &page(start..start + rows as u64)), rows);
        }
        assert_eq!(asked, 4_999);
        assert_eq!(term.history_dropped, 0);
        assert_eq!(history_text(&term)[0], "row 0");
        assert_eq!(term.history.len(), 5_000);
    }

    #[test]
    fn a_page_stops_at_the_byte_cap() {
        let mut term = Terminal::new(20, 1, 1_000);
        feed(&mut term, "row 100\r\n");
        term.set_history_origin(100);
        let one = term.history_bytes();
        term.set_history_cap(1_000, 4 * one);
        assert_eq!(term.prepend_history(50, &page(50..100)), 3);
        assert_eq!(history_text(&term), ["row 97", "row 98", "row 99", "row 100"]);
        assert_eq!(term.prepend_history(40, &page(40..97)), 0);
    }

    #[test]
    fn a_page_keeps_its_styles_graphemes_and_links() {
        let mut term = Terminal::new(20, 1, 1_000);
        feed(&mut term, "\x1b[1;34mnew\x1b[0m\r\n");
        term.set_history_origin(1);
        let older = "\x1b[38;2;1;2;3;48;5;22mdiff\x1b[0m e\u{301} \x1b]8;;https://x.test\x07link\x1b]8;;\x07\r\n";
        assert_eq!(term.prepend_history(0, older.as_bytes()), 1);
        let row = term.history[0].clone();
        assert_eq!(text(&term, &row), "diff e\u{301} link");
        let style = term.styles.get(row.cells[0].style);
        assert_eq!(style.fg, crate::style::Color::Rgb(1, 2, 3));
        assert_eq!(style.bg, crate::style::Color::Indexed(22));
        let link = term.styles.get(row.cells[7].style).link;
        assert_eq!(term.links.get(link), ";https://x.test");
        assert_eq!(text(&term, &term.history[1]), "new");
        assert_eq!(term.styles.get(term.history[1].cells[0].style).flags, crate::style::BOLD);
    }
}
