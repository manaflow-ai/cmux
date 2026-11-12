//! The host-width VT model: the screen and scrollback the PTY's bytes draw,
//! with the soft-wrap flag of every row. Only what a reflow needs is kept:
//! cells, styles, wraps, the cursor and the modes the phone's own terminal
//! must follow (key encoding, mouse, bracketed paste), which are passed on.

use std::collections::{BTreeMap, VecDeque};

use unicode_width::UnicodeWidthChar;

use crate::style::{Interner, Style, StyleTable};

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
    // Parser.
    state: State,
    seq: Vec<u8>,
    utf8: [u8; 4],
    utf8_len: usize,
    utf8_need: usize,
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
                self.utf8[self.utf8_len] = byte;
                self.utf8_len += 1;
                if self.utf8_len == self.utf8_need {
                    let ch = std::str::from_utf8(&self.utf8[..self.utf8_len])
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
        let intermediate = if self.seq.len() > 2 { self.seq[1] } else { 0 };
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
        let body = &seq[2..end.max(2)];
        let (number, rest) = match body.iter().position(|&b| b == b';') {
            Some(i) => (&body[..i], &body[i + 1..]),
            None => (body, &b""[..]),
        };
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
        let body = &seq[2..];
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
        while end > start && (0x20..=0x2f).contains(&head[end - 1]) {
            end -= 1;
        }
        let intermediate = head.get(end).copied().unwrap_or(0);
        let params: Vec<Vec<u16>> = if end > start {
            head[start..end]
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
        let styles = std::mem::take(&mut self.styles);
        let graphemes = std::mem::take(&mut self.graphemes);
        let links = std::mem::take(&mut self.links);
        let passthrough = std::mem::take(&mut self.passthrough);
        let replies = std::mem::take(&mut self.replies);
        *self = Terminal::new(cols, rows, limit);
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
        self.saved[slot] = Saved {
            x: self.cursor.x,
            y: self.cursor.y,
            pending_wrap: self.cursor.pending_wrap,
            style: self.cursor.style,
            origin: self.origin,
            charsets: self.charsets,
            shift_out: self.shift_out,
        };
    }

    fn restore_cursor(&mut self) {
        let saved = self.saved[usize::from(self.alt_active)];
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
        let ch = if self.charsets[usize::from(self.shift_out)] { dec_special(ch) } else { ch };
        let width = ch.width().unwrap_or(0);
        if width == 0 {
            self.combine(ch);
            return;
        }
        let cols = self.cols;
        if self.cursor.pending_wrap && self.autowrap {
            let y = self.cursor.y;
            self.screen()[y].wrapped = true;
            self.linefeed();
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
            let row = &mut self.screen()[y];
            row.cells[x] = Cell { ch: 0, style: erased, kind: SPACER_HEAD };
            row.wrapped = true;
            self.linefeed();
            self.cursor.x = 0;
        }
        let style = self.styles.id(self.cursor.style);
        let (x, y) = (self.cursor.x, self.cursor.y);
        if self.insert {
            let row = &mut self.screen()[y];
            for _ in 0..width {
                row.cells.insert(x, Cell::blank(0));
            }
            row.cells.truncate(cols);
        }
        self.clear_wide(y, x);
        if width == 2 {
            self.clear_wide(y, x + 1);
        }
        let row = &mut self.screen()[y];
        row.cells[x] =
            Cell { ch: u32::from(ch), style, kind: if width == 2 { WIDE } else { NARROW } };
        if width == 2 {
            row.cells[x + 1] = Cell { ch: 0, style, kind: WIDE_TAIL };
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

    /// A zero-width code point joins the glyph before the cursor.
    fn combine(&mut self, ch: char) {
        let (y, cursor_x, pending) = (self.cursor.y, self.cursor.x, self.cursor.pending_wrap);
        let mut x = if pending {
            cursor_x
        } else if cursor_x > 0 {
            cursor_x - 1
        } else {
            return;
        };
        if self.screen()[y].cells[x].kind == WIDE_TAIL && x > 0 {
            x -= 1;
        }
        let cell = self.screen()[y].cells[x];
        if cell.ch == 0 {
            return;
        }
        let mut text = self.cell_text(cell);
        text.push(ch);
        let id = self.graphemes.id(&text);
        self.screen()[y].cells[x].ch = GRAPHEME | id;
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
        let row = &mut self.screen()[y];
        if x >= row.cells.len() {
            return;
        }
        match row.cells[x].kind {
            WIDE_TAIL if x > 0 => {
                let style = row.cells[x - 1].style;
                row.cells[x - 1] = Cell::blank(style);
            }
            WIDE if x + 1 < cols => {
                let style = row.cells[x + 1].style;
                row.cells[x + 1] = Cell::blank(style);
            }
            _ => {}
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
        self.history.push_back(row);
        while self.history.len() > self.history_limit {
            self.history.pop_front();
            self.history_dropped += 1;
        }
    }

    fn erase_display(&mut self, mode: u16) {
        let erased = self.erased_id();
        let (x, y, rows, cols) = (self.cursor.x, self.cursor.y, self.rows, self.cols);
        match mode {
            0 => {
                self.erase_line(0);
                for row in &mut self.screen()[y + 1..rows] {
                    *row = blank_row(cols, erased);
                }
            }
            1 => {
                for row in &mut self.screen()[..y] {
                    *row = blank_row(cols, erased);
                }
                self.clear_wide(y, x);
                for cell in &mut self.screen()[y].cells[..=x] {
                    *cell = Cell::blank(erased);
                }
            }
            2 => {
                // The primary screen scrolls its rows into the scrollback
                // first (as Ghostty does), so a clear keeps what was shown.
                if !self.alt_active {
                    let last = self.primary.iter().rposition(|row| {
                        row.cells.iter().any(|c| !c.is_empty_or_space() || c.style != 0)
                    });
                    if let Some(last) = last {
                        for i in 0..=last {
                            let row = std::mem::take(&mut self.primary[i]);
                            self.push_history(row);
                        }
                    }
                }
                for row in self.screen().iter_mut() {
                    *row = blank_row(cols, erased);
                }
            }
            3 if !self.alt_active => {
                self.history.clear();
                self.history_dropped = 0;
                self.reset_needed = true;
            }
            _ => {}
        }
        self.cursor.pending_wrap = false;
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
        let row = &mut self.screen()[y];
        for cell in &mut row.cells[range] {
            *cell = Cell::blank(erased);
        }
        if mode != 1 {
            row.wrapped = false;
        }
        self.cursor.pending_wrap = false;
    }

    fn erase_chars(&mut self, n: usize) {
        let erased = self.erased_id();
        let (x, y, cols) = (self.cursor.x, self.cursor.y, self.cols);
        let end = (x + n).min(cols);
        self.clear_wide(y, x);
        self.clear_wide(y, end - 1);
        for cell in &mut self.screen()[y].cells[x..end] {
            *cell = Cell::blank(erased);
        }
        self.cursor.pending_wrap = false;
    }

    fn insert_chars(&mut self, n: usize) {
        let erased = self.erased_id();
        let (x, y, cols) = (self.cursor.x, self.cursor.y, self.cols);
        self.clear_wide(y, x);
        let row = &mut self.screen()[y];
        for _ in 0..n.min(cols - x) {
            row.cells.insert(x, Cell::blank(erased));
        }
        row.cells.truncate(cols);
        if row.cells[cols - 1].kind == WIDE {
            row.cells[cols - 1] = Cell::blank(erased);
        }
        self.cursor.pending_wrap = false;
    }

    fn delete_chars(&mut self, n: usize) {
        let erased = self.erased_id();
        let (x, y, cols) = (self.cursor.x, self.cursor.y, self.cols);
        self.clear_wide(y, x);
        let n = n.min(cols - x);
        let row = &mut self.screen()[y];
        row.cells.drain(x..x + n);
        while row.cells.len() < cols {
            row.cells.push(Cell::blank(erased));
        }
        if row.cells[x].kind == WIDE_TAIL {
            row.cells[x] = Cell::blank(erased);
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
    Row { cells: vec![Cell::blank(style); cols], wrapped: false }
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
    fn erase_display_scrolls_the_screen_into_history() {
        let mut term = Terminal::new(10, 3, 100);
        feed(&mut term, "a\r\nb\x1b[H\x1b[2J$ ");
        assert_eq!(term.history.len(), 2);
        assert_eq!(text(&term, &term.primary[0]), "$");
        feed(&mut term, "\x1b[3J");
        assert!(term.history.is_empty());
        assert!(term.reset_needed);
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
}
