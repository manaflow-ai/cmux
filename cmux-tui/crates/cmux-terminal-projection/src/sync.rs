//! Viewport state sync over datagrams.
//!
//! Leo: "the scroll occurs or whatever on f***ing mac / then it delays on my
//! actual iphone display. thats the asinine part."
//!
//! The live viewport goes to the phone as newest-wins screen diffs in
//! unreliable datagrams instead of an ordered byte stream, so a lost or late
//! packet never holds back a newer screen:
//!
//! - The host captures the active screen ([`ScreenState::capture`]) and
//!   [`SyncSender`] numbers each new state (seq 1, 2, ...). Every send is a
//!   diff from the state the phone last ACKED (never the last sent), carrying
//!   its seq and its base seq; base 0 is a keyframe from nothing.
//! - [`SyncReceiver`] applies a diff only if it holds its base and the seq is
//!   newer than the one it holds, and acks the newest seq it holds. Nothing
//!   is waited for: a newer diff replaces an older one in flight.
//! - Diffs larger than a datagram are fragmented (header: seq, base, frag
//!   i/n); the receiver reassembles only the newest few seqs.
//! - Rows that scroll off into the scrollback go on the reliable stream as VT
//!   bytes ([`HistoryTracker`]), so the phone's history stays exact.
//!
//! Payloads work at row granularity: only the changed span of each changed
//! row, with a per-payload style table, run-length repeats and varints. A
//! typical redraw of a few rows fits one datagram.

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

use crate::style::{Color, Style};
use crate::terminal::{Cell, NARROW, Row, SPACER_HEAD, Terminal, WIDE, WIDE_TAIL};

/// First two bytes of every sync datagram.
pub const MAGIC: [u8; 2] = *b"VS";
/// A (fragment of a) diff, host to phone.
pub const KIND_DIFF: u8 = 1;
/// An ack, phone to host.
pub const KIND_ACK: u8 = 2;
/// The payload format version [`diff`] writes. Version 3 sends the grid only from blank, the
/// cursor as deltas from the base's and its shape and the modes only when they change, and
/// leaves out empty tables and the span count (spans run to the payload's end): a one-key
/// echo is 11 bytes, not 21. [`apply`] still reads version 2.
const VERSION: u8 = 3;
/// The version before (cols, rows, cursor, shape and modes in every payload).
const VERSION_V2: u8 = 2;
/// The most states sent and not yet acked that the sender keeps (to diff
/// from once acked). Acks trail by a round trip, so at 60 Hz this covers
/// about 17 s of them. Kept as the states themselves (shared, never
/// re-encoded: a keyframe encode per state cost the host milliseconds).
pub const SENT_RING: usize = 1024;
/// The most bytes of states the sender keeps (see [`ScreenState::footprint`]).
pub const SENT_RING_BYTES: usize = 64 << 20;
/// The most states the receiver keeps to apply a diff from: every state
/// newer than the newest base seen (the sender diffs from what it saw
/// acked, a round trip behind), as the states themselves.
pub const HELD_RING: usize = 512;
/// The most bytes of states the receiver keeps (see [`ScreenState::footprint`]).
pub const HELD_RING_BYTES: usize = 32 << 20;
/// Seqs the receiver reassembles fragments for at once.
pub const PARTIALS: usize = 4;
/// The most fragments one diff may have (a sanity bound for the receiver).
pub const MAX_FRAGMENTS: u64 = 4096;
/// The largest grid a payload may describe (a sanity bound for the receiver).
const MAX_CELLS: u64 = 1 << 22;

// Mode bits of [`ScreenState::modes`].
pub const MODE_ALTERNATE: u32 = 1;
/// DECCKM (`?1`).
pub const MODE_APP_CURSOR: u32 = 1 << 1;
/// DECKPAM (`ESC =`).
pub const MODE_KEYPAD_APP: u32 = 1 << 2;
/// `?2004`.
pub const MODE_BRACKETED_PASTE: u32 = 1 << 3;
/// `?1004`.
pub const MODE_FOCUS_EVENTS: u32 = 1 << 4;
/// `?9`.
pub const MODE_MOUSE_X10: u32 = 1 << 5;
/// `?1000`.
pub const MODE_MOUSE_NORMAL: u32 = 1 << 6;
/// `?1002`.
pub const MODE_MOUSE_BUTTON: u32 = 1 << 7;
/// `?1003`.
pub const MODE_MOUSE_ANY: u32 = 1 << 8;
/// `?1005`.
pub const MODE_MOUSE_UTF8: u32 = 1 << 9;
/// `?1006`.
pub const MODE_MOUSE_SGR: u32 = 1 << 10;
/// `?1007`.
pub const MODE_ALT_SCROLL: u32 = 1 << 11;
/// `?1015`.
pub const MODE_MOUSE_URXVT: u32 = 1 << 12;
/// `?1016`.
pub const MODE_MOUSE_SGR_PIXELS: u32 = 1 << 13;
/// `?12` (set explicitly).
pub const MODE_CURSOR_BLINK: u32 = 1 << 14;
/// `?5`.
pub const MODE_REVERSE_VIDEO: u32 = 1 << 15;
/// `?2027` (grapheme clustering; on unless the program turned it off).
pub const MODE_GRAPHEME_CLUSTER: u32 = 1 << 16;
/// The kitty keyboard flags in use (5 bits) start at this bit.
pub const KITTY_FLAGS_SHIFT: u32 = 24;

/// DEC private modes and their bits.
const PRIVATE_MODES: &[(u16, u32)] = &[
    (1, MODE_APP_CURSOR),
    (5, MODE_REVERSE_VIDEO),
    (9, MODE_MOUSE_X10),
    (12, MODE_CURSOR_BLINK),
    (1000, MODE_MOUSE_NORMAL),
    (1002, MODE_MOUSE_BUTTON),
    (1003, MODE_MOUSE_ANY),
    (1004, MODE_FOCUS_EVENTS),
    (1005, MODE_MOUSE_UTF8),
    (1006, MODE_MOUSE_SGR),
    (1007, MODE_ALT_SCROLL),
    (1015, MODE_MOUSE_URXVT),
    (1016, MODE_MOUSE_SGR_PIXELS),
    (2004, MODE_BRACKETED_PASTE),
];

// ---------------------------------------------------------------------------
// The state.

/// A cell's style: what the phone draws, and enough to compare with Ghostty.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct SyncStyle {
    pub fg: Color,
    pub bg: Color,
    pub underline_color: Color,
    /// [`crate::style`] attribute bits (BOLD, FAINT, ...).
    pub flags: u16,
    /// 0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed.
    pub underline: u8,
    /// The OSC 8 link the cell is in (`params;uri`), "" for none.
    pub link: String,
}

impl SyncStyle {
    pub fn is_default(&self) -> bool {
        *self == SyncStyle::default()
    }

    /// The SGR part (no link) as the crate's [`Style`].
    pub fn sgr(&self) -> Style {
        Style {
            fg: self.fg,
            bg: self.bg,
            underline_color: self.underline_color,
            flags: self.flags,
            underline: self.underline,
            link: 0,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct SyncCell {
    /// The full grapheme ("" for a blank or a wide glyph's tail).
    pub text: String,
    /// [`crate::terminal::NARROW`], `WIDE`, `WIDE_TAIL` or `SPACER_HEAD`.
    pub width: u8,
    pub style: SyncStyle,
}

/// One viewport snapshot of the active screen (primary or alternate).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ScreenState {
    pub cols: u16,
    pub rows: u16,
    /// `rows * cols`, row-major.
    pub cells: Vec<SyncCell>,
    /// (col, row).
    pub cursor: (u16, u16),
    pub cursor_visible: bool,
    /// The DECSCUSR parameter last set (0: the terminal's default).
    pub cursor_shape: u8,
    /// `MODE_*` bits.
    pub modes: u32,
    pub alternate: bool,
}

fn to_u16(n: usize) -> u16 {
    u16::try_from(n).unwrap_or(u16::MAX)
}

impl ScreenState {
    /// The viewport of `term`'s active screen.
    pub fn capture(term: &Terminal) -> ScreenState {
        let (cols, rows) = (term.cols, term.rows);
        let mut cells = Vec::with_capacity(cols * rows);
        let mut styles: HashMap<u16, SyncStyle> = HashMap::new();
        let screen = term.screen_rows();
        for y in 0..rows {
            let row = screen.get(y);
            for x in 0..cols {
                let cell = row.and_then(|r| r.cells.get(x)).copied().unwrap_or_default();
                let style =
                    styles.entry(cell.style).or_insert_with(|| sync_style(term, cell.style));
                cells.push(SyncCell {
                    text: if cell.ch == 0 { String::new() } else { term.cell_text(cell) },
                    width: cell.kind,
                    style: style.clone(),
                });
            }
        }
        let (x, y) = term.cursor();
        let (mut modes, cursor_shape) = modes_of(term);
        if term.is_alternate() {
            modes |= MODE_ALTERNATE;
        }
        ScreenState {
            cols: to_u16(cols),
            rows: to_u16(rows),
            cells,
            cursor: (to_u16(x), to_u16(y)),
            cursor_visible: term.cursor_visible,
            cursor_shape,
            modes,
            alternate: term.is_alternate(),
        }
    }

    /// A blank screen: nothing written, cursor home, visible.
    pub fn blank(cols: u16, rows: u16) -> ScreenState {
        ScreenState {
            cols,
            rows,
            cells: vec![SyncCell::default(); usize::from(cols) * usize::from(rows)],
            cursor: (0, 0),
            cursor_visible: true,
            cursor_shape: 0,
            modes: MODE_GRAPHEME_CLUSTER,
            alternate: false,
        }
    }

    /// The cell at (col, row).
    pub fn cell(&self, col: u16, row: u16) -> Option<&SyncCell> {
        if col >= self.cols {
            return None;
        }
        self.cells.get(usize::from(row) * usize::from(self.cols) + usize::from(col))
    }

    /// About how many bytes the state holds in memory (what the rings count).
    pub fn footprint(&self) -> usize {
        size_of::<ScreenState>()
            + self.cells.len() * size_of::<SyncCell>()
            + self.cells.iter().map(|c| c.text.len() + c.style.link.len()).sum::<usize>()
    }

    /// The cells of one row.
    pub fn row(&self, row: u16) -> &[SyncCell] {
        let cols = usize::from(self.cols);
        let start = usize::from(row) * cols;
        self.cells.get(start..start + cols).unwrap_or_default()
    }

    /// A stable 32-bit digest (FNV-1a) of everything in the state; a diff
    /// carries the digest of the state it makes, so applying it to a wrong
    /// base is caught.
    pub fn digest(&self) -> u32 {
        let mut h = Fnv::default();
        h.u64(u64::from(self.cols));
        h.u64(u64::from(self.rows));
        h.u64(u64::from(self.cursor.0));
        h.u64(u64::from(self.cursor.1));
        h.u64(u64::from(self.cursor_visible));
        h.u64(u64::from(self.cursor_shape));
        h.u64(u64::from(self.modes));
        h.u64(u64::from(self.alternate));
        h.u64(self.cells.len() as u64);
        // Equal styles side by side are hashed once.
        let mut previous: Option<&SyncStyle> = None;
        for cell in &self.cells {
            h.bytes(cell.text.as_bytes());
            h.u64(u64::from(cell.width));
            if previous != Some(&cell.style) {
                h.byte(0xFE);
                let s = &cell.style;
                for color in [s.fg, s.bg, s.underline_color] {
                    h.color(color);
                }
                h.u64(u64::from(s.flags));
                h.u64(u64::from(s.underline));
                h.bytes(s.link.as_bytes());
                previous = Some(&cell.style);
            }
        }
        h.0
    }
}

#[derive(Clone, Copy)]
struct Fnv(u32);

impl Default for Fnv {
    fn default() -> Self {
        Fnv(0x811c_9dc5)
    }
}

impl Fnv {
    fn byte(&mut self, b: u8) {
        self.0 ^= u32::from(b);
        self.0 = self.0.wrapping_mul(0x0100_0193);
    }
    fn u64(&mut self, mut v: u64) {
        loop {
            let b = (v & 0x7f) as u8;
            v >>= 7;
            if v == 0 {
                self.byte(b);
                return;
            }
            self.byte(b | 0x80);
        }
    }
    fn bytes(&mut self, b: &[u8]) {
        self.u64(b.len() as u64);
        for &x in b {
            self.byte(x);
        }
    }
    fn color(&mut self, c: Color) {
        match c {
            Color::Default => self.byte(0),
            Color::Indexed(n) => {
                self.byte(1);
                self.byte(n);
            }
            Color::Rgb(r, g, b) => {
                self.byte(2);
                self.byte(r);
                self.byte(g);
                self.byte(b);
            }
        }
    }
}

fn sync_style(term: &Terminal, id: u16) -> SyncStyle {
    let s = term.styles.get(id);
    SyncStyle {
        fg: s.fg,
        bg: s.bg,
        underline_color: s.underline_color,
        flags: s.flags,
        underline: s.underline,
        link: if s.link == 0 { String::new() } else { term.links.get(s.link).to_string() },
    }
}

/// The passed-on modes and the DECSCUSR parameter, read back from what the
/// terminal would write to bring a reset terminal to them.
fn modes_of(term: &Terminal) -> (u32, u8) {
    let mut out = Vec::new();
    term.write_modes(&mut out);
    let mut modes = 0u32;
    let mut shape = 0u8;
    let mut clustering = true;
    let mut i = 0;
    while i < out.len() {
        if out.get(i) != Some(&0x1b) {
            i += 1;
            continue;
        }
        match out.get(i + 1) {
            Some(b'=') => {
                modes |= MODE_KEYPAD_APP;
                i += 2;
            }
            Some(b'[') => {
                // Parameters, intermediates, final.
                let start = i + 2;
                let mut end = start;
                while out.get(end).is_some_and(|b| !(0x40..=0x7e).contains(b)) {
                    end += 1;
                }
                let Some(&last) = out.get(end) else { break };
                let body = out.get(start..end).unwrap_or_default();
                let number = |digits: &[u8]| -> u32 {
                    std::str::from_utf8(digits).ok().and_then(|s| s.parse().ok()).unwrap_or(0)
                };
                match (body.first(), last) {
                    (Some(b'?'), b'h' | b'l') => {
                        let mode = number(body.get(1..).unwrap_or_default());
                        let on = last == b'h';
                        if mode == 2027 {
                            clustering = on;
                        }
                        if let Some(&(_, bit)) =
                            PRIVATE_MODES.iter().find(|(m, _)| u32::from(*m) == mode)
                        {
                            if on {
                                modes |= bit;
                            } else {
                                modes &= !bit;
                            }
                        }
                    }
                    (Some(b'>'), b'u') => {
                        let flags = number(body.get(1..).unwrap_or_default()) & 0x1f;
                        modes |= flags << KITTY_FLAGS_SHIFT;
                    }
                    (_, b'q') if body.last() == Some(&b' ') => {
                        let n = number(body.get(..body.len() - 1).unwrap_or_default());
                        shape = u8::try_from(n).unwrap_or(0);
                    }
                    _ => {}
                }
                i = end + 1;
            }
            // The title (an OSC) comes last.
            _ => break,
        }
    }
    if clustering {
        modes |= MODE_GRAPHEME_CLUSTER;
    }
    (modes, shape)
}

// ---------------------------------------------------------------------------
// Diffs.

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SyncError {
    /// The payload ends early.
    Truncated,
    /// Not a payload of this version.
    Version(u8),
    /// A diff from a base, and no base given.
    NoBase,
    /// The base's grid is not the one the diff was made from.
    GridMismatch,
    /// Something in the payload is out of range.
    Malformed(&'static str),
    /// The result is not the state the diff was made for (a wrong base).
    Digest,
}

impl std::fmt::Display for SyncError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SyncError::Truncated => write!(f, "sync payload truncated"),
            SyncError::Version(v) => write!(f, "sync payload version {v}"),
            SyncError::NoBase => write!(f, "sync diff needs a base"),
            SyncError::GridMismatch => write!(f, "sync diff base grid differs"),
            SyncError::Malformed(what) => write!(f, "sync payload malformed: {what}"),
            SyncError::Digest => write!(f, "sync diff applied to the wrong base"),
        }
    }
}

impl std::error::Error for SyncError {}

const FLAG_FROM_BLANK: u8 = 1;
const FLAG_CURSOR_VISIBLE: u8 = 1 << 1;
const FLAG_ALTERNATE: u8 = 1 << 2;
// Version 3: which header fields follow.
/// A zigzag varint: the cursor column minus the base's.
const FLAG_CURSOR_X: u8 = 1 << 3;
/// A zigzag varint: the cursor row minus the base's.
const FLAG_CURSOR_Y: u8 = 1 << 4;
/// The cursor shape byte and the modes varint.
const FLAG_SHAPE_MODES: u8 = 1 << 5;
/// The style table.
const FLAG_STYLES: u8 = 1 << 6;
/// The move runs.
const FLAG_MOVES: u8 = 1 << 7;

// Cell stream tokens. A byte >= 0x20 starts a UTF-8 char: a narrow cell of
// that one char.
/// A narrow cell, empty.
const T_EMPTY: u8 = 0x00;
/// A narrow cell: varint length, then its text.
const T_TEXT: u8 = 0x01;
/// The next text token is a wide cell.
const T_WIDE: u8 = 0x02;
/// An empty wide tail.
const T_TAIL: u8 = 0x03;
/// The next text token is a spacer head.
const T_SPACER_HEAD: u8 = 0x04;
/// Varint n: the previous cell n more times.
const T_REPEAT: u8 = 0x05;
/// Varint index into the payload's style table (0 = default).
const T_STYLE: u8 = 0x06;
/// The next text token is a wide tail (one with text).
const T_TAIL_TEXT: u8 = 0x07;

/// A compact payload turning `base` (None: nothing held) into `latest`.
/// A base of another grid is ignored (the payload starts from a blank screen).
pub fn diff(base: Option<&ScreenState>, latest: &ScreenState) -> Vec<u8> {
    let mut out = Vec::new();
    diff_into(base, latest, &mut out);
    out
}

/// [`diff`] into `out` (cleared first), so a sender reuses one buffer. Only the changed spans
/// are written; the base is read in place (a scroll's moved rows are not copied).
pub fn diff_into(base: Option<&ScreenState>, latest: &ScreenState, out: &mut Vec<u8>) {
    out.clear();
    let base = base.filter(|b| b.cols == latest.cols && b.rows == latest.rows);
    let from_blank = base.is_none();
    let cols = usize::from(latest.cols);
    // Rows the base has elsewhere (a scroll): copied, not resent.
    let moves = base.map(|b| row_moves(b, latest)).unwrap_or_default();
    // The base row each latest row is compared with (after the moves), with
    // no copy of the base: None is a blank row.
    let mut source: Vec<Option<u16>> = (0..latest.rows).map(|y| base.map(|_| y)).collect();
    for &(dst, src) in &moves {
        if let Some(slot) = source.get_mut(usize::from(dst)) {
            *slot = Some(src);
        }
    }
    let blank_row = vec![SyncCell::default(); cols];
    // Changed spans: (row, first col, end col).
    let mut spans = Vec::new();
    for y in 0..latest.rows {
        let a = match (base, source.get(usize::from(y)).copied().flatten()) {
            (Some(b), Some(src)) => b.row(src),
            _ => &blank_row[..],
        };
        let b = latest.row(y);
        let Some(first) = (0..cols).find(|&x| a.get(x) != b.get(x)) else { continue };
        let last = (0..cols).rev().find(|&x| a.get(x) != b.get(x)).unwrap_or(first);
        spans.push((y, first, last + 1));
    }
    // The styles the spans use.
    let mut table: Vec<&SyncStyle> = Vec::new();
    let mut index: HashMap<&SyncStyle, u64> = HashMap::new();
    for &(y, a, b) in &spans {
        for cell in latest.row(y).get(a..b).unwrap_or_default() {
            if !cell.style.is_default() && !index.contains_key(&cell.style) {
                table.push(&cell.style);
                index.insert(&cell.style, table.len() as u64);
            }
        }
    }

    out.reserve(64 + spans.len() * 32);
    out.push(VERSION);
    let mut flags = 0;
    if from_blank {
        flags |= FLAG_FROM_BLANK;
    }
    if latest.cursor_visible {
        flags |= FLAG_CURSOR_VISIBLE;
    }
    if latest.alternate {
        flags |= FLAG_ALTERNATE;
    }
    let (base_cursor, base_shape_modes) = match base {
        Some(b) => (b.cursor, Some((b.cursor_shape, b.modes))),
        None => ((0, 0), None),
    };
    let dx = i64::from(latest.cursor.0) - i64::from(base_cursor.0);
    let dy = i64::from(latest.cursor.1) - i64::from(base_cursor.1);
    let shape_modes = (latest.cursor_shape, latest.modes);
    if dx != 0 {
        flags |= FLAG_CURSOR_X;
    }
    if dy != 0 {
        flags |= FLAG_CURSOR_Y;
    }
    if base_shape_modes != Some(shape_modes) {
        flags |= FLAG_SHAPE_MODES;
    }
    if !table.is_empty() {
        flags |= FLAG_STYLES;
    }
    if !moves.is_empty() {
        flags |= FLAG_MOVES;
    }
    out.push(flags);
    if from_blank {
        put_varint(out, u64::from(latest.cols));
        put_varint(out, u64::from(latest.rows));
    }
    if dx != 0 {
        put_varint(out, zigzag(dx));
    }
    if dy != 0 {
        put_varint(out, zigzag(dy));
    }
    if flags & FLAG_SHAPE_MODES != 0 {
        out.push(latest.cursor_shape);
        put_varint(out, u64::from(latest.modes));
    }
    out.extend_from_slice(&latest.digest().to_le_bytes());
    if !table.is_empty() {
        put_varint(out, table.len() as u64);
        for style in &table {
            put_style(out, style);
        }
    }
    // Moves as runs: (rows skipped, first base row, rows).
    let mut runs: Vec<(u16, u16, u16)> = Vec::new();
    for &(dst, src) in &moves {
        match runs.last_mut() {
            Some((d, s, n)) if *d + *n == dst && *s + *n == src => *n += 1,
            _ => runs.push((dst, src, 1)),
        }
    }
    if !runs.is_empty() {
        put_varint(out, runs.len() as u64);
    }
    let mut next_row = 0u64;
    for &(dst, src, n) in &runs {
        put_varint(out, u64::from(dst) - next_row);
        next_row = u64::from(dst) + u64::from(n);
        put_varint(out, u64::from(src));
        put_varint(out, u64::from(n));
    }
    // The spans run to the payload's end.
    let mut next_row = 0u64;
    for &(y, a, b) in &spans {
        put_varint(out, u64::from(y) - next_row);
        next_row = u64::from(y) + 1;
        put_varint(out, a as u64);
        put_varint(out, (b - a) as u64);
        let cells = latest.row(y).get(a..b).unwrap_or_default();
        let mut style = 0u64;
        let mut i = 0;
        while let Some(cell) = cells.get(i) {
            let id = index.get(&cell.style).copied().unwrap_or(0);
            if id != style {
                out.push(T_STYLE);
                put_varint(out, id);
                style = id;
            }
            let start = out.len();
            put_cell(out, cell);
            let token = out.len() - start;
            let mut same = 1;
            while cells.get(i + same) == Some(cell) {
                same += 1;
            }
            let more = same - 1;
            if more > 0 {
                if more * token > 1 + varint_len(more as u64) {
                    out.push(T_REPEAT);
                    put_varint(out, more as u64);
                } else {
                    for _ in 0..more {
                        put_cell(out, cell);
                    }
                }
            }
            i += same;
        }
    }
}

/// (latest row, base row) for every changed, non-blank row of `latest` that
/// the base holds whole at another row, ascending: what a scroll moved.
fn row_moves(base: &ScreenState, latest: &ScreenState) -> Vec<(u16, u16)> {
    use std::hash::{BuildHasher, BuildHasherDefault, DefaultHasher};
    let hasher = BuildHasherDefault::<DefaultHasher>::default();
    let blank = |row: &[SyncCell]| row.iter().all(|c| *c == SyncCell::default());
    let mut at: HashMap<u64, Vec<u16>> = HashMap::new();
    for y in 0..base.rows {
        let row = base.row(y);
        if !blank(row) {
            at.entry(hasher.hash_one(row)).or_default().push(y);
        }
    }
    let mut moves = Vec::new();
    if at.is_empty() {
        return moves;
    }
    // The shift of the last move: a scroll moves rows together.
    let mut shift = 0i64;
    for y in 0..latest.rows {
        let row = latest.row(y);
        if base.row(y) == row || blank(row) {
            continue;
        }
        let Some(candidates) = at.get(&hasher.hash_one(row)) else { continue };
        let best = candidates
            .iter()
            .filter(|&&src| base.row(src) == row)
            .min_by_key(|&&src| (i64::from(src) - i64::from(y) - shift).abs());
        if let Some(&src) = best {
            shift = i64::from(src) - i64::from(y);
            moves.push((y, src));
        }
    }
    moves
}

fn put_cell(out: &mut Vec<u8>, cell: &SyncCell) {
    match cell.width {
        WIDE => out.push(T_WIDE),
        WIDE_TAIL if cell.text.is_empty() => {
            out.push(T_TAIL);
            return;
        }
        WIDE_TAIL => out.push(T_TAIL_TEXT),
        SPACER_HEAD => out.push(T_SPACER_HEAD),
        _ => {}
    }
    let mut chars = cell.text.chars();
    match (chars.next(), chars.next()) {
        (None, _) => out.push(T_EMPTY),
        (Some(c), None) if u32::from(c) >= 0x20 => {
            let mut buf = [0; 4];
            out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
        }
        _ => {
            out.push(T_TEXT);
            put_varint(out, cell.text.len() as u64);
            out.extend_from_slice(cell.text.as_bytes());
        }
    }
}

fn put_color(out: &mut Vec<u8>, color: Color) {
    match color {
        Color::Default => out.push(0),
        Color::Indexed(n) => {
            out.push(1);
            out.push(n);
        }
        Color::Rgb(r, g, b) => {
            out.push(2);
            out.extend_from_slice(&[r, g, b]);
        }
    }
}

fn put_style(out: &mut Vec<u8>, s: &SyncStyle) {
    let mut mask = 0u8;
    if s.fg != Color::Default {
        mask |= 1;
    }
    if s.bg != Color::Default {
        mask |= 2;
    }
    if s.underline_color != Color::Default {
        mask |= 4;
    }
    if s.flags != 0 {
        mask |= 8;
    }
    if s.underline != 0 {
        mask |= 16;
    }
    if !s.link.is_empty() {
        mask |= 32;
    }
    out.push(mask);
    if mask & 1 != 0 {
        put_color(out, s.fg);
    }
    if mask & 2 != 0 {
        put_color(out, s.bg);
    }
    if mask & 4 != 0 {
        put_color(out, s.underline_color);
    }
    if mask & 8 != 0 {
        put_varint(out, u64::from(s.flags));
    }
    if mask & 16 != 0 {
        out.push(s.underline);
    }
    if mask & 32 != 0 {
        put_varint(out, s.link.len() as u64);
        out.extend_from_slice(s.link.as_bytes());
    }
}

/// Applies a payload from [`diff`] to `base` (None: nothing held).
pub fn apply(base: Option<&ScreenState>, payload: &[u8]) -> Result<ScreenState, SyncError> {
    let mut r = Reader::new(payload);
    let version = r.u8()?;
    if version != VERSION && version != VERSION_V2 {
        return Err(SyncError::Version(version));
    }
    let v3 = version == VERSION;
    let flags = r.u8()?;
    let from_blank = flags & FLAG_FROM_BLANK != 0;
    let (cols, rows) = if v3 && !from_blank {
        let base = base.ok_or(SyncError::NoBase)?;
        (base.cols, base.rows)
    } else {
        let cols = r.small(u64::from(u16::MAX), "cols")?;
        let rows = r.small(u64::from(u16::MAX), "rows")?;
        if cols == 0 || rows == 0 || cols * rows > MAX_CELLS {
            return Err(SyncError::Malformed("grid"));
        }
        (cols as u16, rows as u16)
    };
    let base = if from_blank {
        None
    } else {
        let base = base.ok_or(SyncError::NoBase)?;
        if base.cols != cols || base.rows != rows {
            return Err(SyncError::GridMismatch);
        }
        Some(base)
    };
    let mut state = match base {
        Some(b) => b.clone(),
        None => ScreenState::blank(cols, rows),
    };
    if v3 {
        let (bx, by) = base.map_or((0, 0), |b| b.cursor);
        let mut axis = |flag: u8, from: u16| -> Result<u16, SyncError> {
            if flags & flag == 0 {
                return Ok(from);
            }
            let v = i64::from(from) + unzigzag(r.varint()?);
            u16::try_from(v).map_err(|_| SyncError::Malformed("cursor"))
        };
        let cx = axis(FLAG_CURSOR_X, bx)?;
        let cy = axis(FLAG_CURSOR_Y, by)?;
        state.cursor = (cx, cy);
        if flags & FLAG_SHAPE_MODES != 0 {
            state.cursor_shape = r.u8()?;
            state.modes = r.small(u64::from(u32::MAX), "modes")? as u32;
        } else if base.is_none() {
            return Err(SyncError::Malformed("modes from blank"));
        }
    } else {
        let cx = r.small(u64::from(u16::MAX), "cursor")? as u16;
        let cy = r.small(u64::from(u16::MAX), "cursor")? as u16;
        state.cursor = (cx, cy);
        state.cursor_shape = r.u8()?;
        state.modes = r.small(u64::from(u32::MAX), "modes")? as u32;
    }
    state.cursor_visible = flags & FLAG_CURSOR_VISIBLE != 0;
    state.alternate = flags & FLAG_ALTERNATE != 0;
    let digest = u32::from_le_bytes(r.array::<4>()?);
    let count = if !v3 || flags & FLAG_STYLES != 0 { r.small(MAX_CELLS, "styles")? } else { 0 };
    let mut table = vec![SyncStyle::default()];
    for _ in 0..count {
        table.push(r.style()?);
    }
    let moves = if !v3 || flags & FLAG_MOVES != 0 { r.small(u64::from(rows), "moves")? } else { 0 };
    let mut dst = 0u64;
    let width = usize::from(cols);
    for _ in 0..moves {
        dst = dst.saturating_add(r.varint()?);
        if dst >= u64::from(rows) {
            return Err(SyncError::Malformed("move"));
        }
        let src = r.small(u64::from(rows) - 1, "move")?;
        let n = r.small(u64::from(rows) - dst.max(src), "move")?;
        let from = base.ok_or(SyncError::Malformed("move from blank"))?;
        let (d, s, n) = (dst as usize * width, src as usize * width, n as usize * width);
        let to = state.cells.get_mut(d..d + n).ok_or(SyncError::Malformed("move"))?;
        to.clone_from_slice(from.cells.get(s..s + n).ok_or(SyncError::Malformed("move"))?);
        dst += n as u64 / width as u64;
    }
    // Version 2 counts its spans; version 3's run to the payload's end.
    let mut spans = if v3 { u64::MAX } else { r.small(u64::from(rows), "spans")? };
    let mut y = 0u64;
    let cols_u = u64::from(cols);
    while spans > 0 && !(v3 && r.remaining() == 0) {
        spans -= 1;
        // The delta counts from the row after the previous span.
        y = y.saturating_add(r.varint()?);
        if y >= u64::from(rows) {
            return Err(SyncError::Malformed("row"));
        }
        let start = r.small(cols_u, "col")?;
        let len = r.small(cols_u - start, "span")?;
        let row_start = (y * cols_u + start) as usize;
        let mut style = 0usize;
        let mut done = 0u64;
        let mut previous: Option<SyncCell> = None;
        while done < len {
            let token = r.peek()?;
            match token {
                T_STYLE => {
                    r.u8()?;
                    let id = r.small(table.len() as u64 - 1, "style")?;
                    style = id as usize;
                    continue;
                }
                T_REPEAT => {
                    r.u8()?;
                    let n = r.small(len - done, "repeat")?;
                    let cell = previous.clone().ok_or(SyncError::Malformed("repeat"))?;
                    for k in 0..n {
                        if let Some(slot) = state.cells.get_mut(row_start + (done + k) as usize) {
                            *slot = cell.clone();
                        }
                    }
                    done += n;
                    continue;
                }
                _ => {}
            }
            let (width, text) = r.cell()?;
            let cell =
                SyncCell { text, width, style: table.get(style).cloned().unwrap_or_default() };
            if let Some(slot) = state.cells.get_mut(row_start + done as usize) {
                *slot = cell.clone();
            }
            previous = Some(cell);
            done += 1;
        }
        y += 1;
    }
    if r.remaining() != 0 {
        return Err(SyncError::Malformed("trailing bytes"));
    }
    if state.digest() != digest {
        return Err(SyncError::Digest);
    }
    Ok(state)
}

struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Reader { buf, pos: 0 }
    }

    fn remaining(&self) -> usize {
        self.buf.len() - self.pos
    }

    fn peek(&self) -> Result<u8, SyncError> {
        self.buf.get(self.pos).copied().ok_or(SyncError::Truncated)
    }

    fn u8(&mut self) -> Result<u8, SyncError> {
        let b = self.peek()?;
        self.pos += 1;
        Ok(b)
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], SyncError> {
        let end = self.pos.checked_add(n).ok_or(SyncError::Truncated)?;
        let out = self.buf.get(self.pos..end).ok_or(SyncError::Truncated)?;
        self.pos = end;
        Ok(out)
    }

    fn array<const N: usize>(&mut self) -> Result<[u8; N], SyncError> {
        let bytes = self.take(N)?;
        let mut out = [0; N];
        out.copy_from_slice(bytes);
        Ok(out)
    }

    fn varint(&mut self) -> Result<u64, SyncError> {
        let mut value = 0u64;
        for shift in (0..64).step_by(7) {
            let b = self.u8()?;
            value |= u64::from(b & 0x7f) << shift;
            if b & 0x80 == 0 {
                return Ok(value);
            }
        }
        Err(SyncError::Malformed("varint"))
    }

    /// A varint no larger than `max`.
    fn small(&mut self, max: u64, what: &'static str) -> Result<u64, SyncError> {
        let v = self.varint()?;
        if v > max {
            return Err(SyncError::Malformed(what));
        }
        Ok(v)
    }

    fn string(&mut self) -> Result<String, SyncError> {
        let len = self.small(self.remaining() as u64, "length")? as usize;
        let bytes = self.take(len)?;
        String::from_utf8(bytes.to_vec()).map_err(|_| SyncError::Malformed("utf-8"))
    }

    fn color(&mut self) -> Result<Color, SyncError> {
        match self.u8()? {
            0 => Ok(Color::Default),
            1 => Ok(Color::Indexed(self.u8()?)),
            2 => {
                let [r, g, b] = self.array::<3>()?;
                Ok(Color::Rgb(r, g, b))
            }
            _ => Err(SyncError::Malformed("color")),
        }
    }

    fn style(&mut self) -> Result<SyncStyle, SyncError> {
        let mask = self.u8()?;
        let mut s = SyncStyle::default();
        if mask & 1 != 0 {
            s.fg = self.color()?;
        }
        if mask & 2 != 0 {
            s.bg = self.color()?;
        }
        if mask & 4 != 0 {
            s.underline_color = self.color()?;
        }
        if mask & 8 != 0 {
            s.flags = self.small(u64::from(u16::MAX), "flags")? as u16;
        }
        if mask & 16 != 0 {
            s.underline = self.u8()?;
        }
        if mask & 32 != 0 {
            s.link = self.string()?;
        }
        Ok(s)
    }

    /// One cell token (a kind prefix, then its text).
    fn cell(&mut self) -> Result<(u8, String), SyncError> {
        let width = match self.peek()? {
            T_WIDE => WIDE,
            T_TAIL => {
                self.u8()?;
                return Ok((WIDE_TAIL, String::new()));
            }
            T_TAIL_TEXT => WIDE_TAIL,
            T_SPACER_HEAD => SPACER_HEAD,
            _ => NARROW,
        };
        if width != NARROW {
            self.u8()?;
        }
        let text = match self.peek()? {
            T_EMPTY => {
                self.u8()?;
                String::new()
            }
            T_TEXT => {
                self.u8()?;
                self.string()?
            }
            b if b >= 0x20 => {
                let len = match b {
                    0x00..=0x7f => 1,
                    0xc0..=0xdf => 2,
                    0xe0..=0xef => 3,
                    0xf0..=0xf7 => 4,
                    _ => return Err(SyncError::Malformed("utf-8")),
                };
                let bytes = self.take(len)?;
                std::str::from_utf8(bytes).map_err(|_| SyncError::Malformed("utf-8"))?.to_string()
            }
            _ => return Err(SyncError::Malformed("cell token")),
        };
        Ok((width, text))
    }
}

fn zigzag(v: i64) -> u64 {
    ((v << 1) ^ (v >> 63)) as u64
}

fn unzigzag(v: u64) -> i64 {
    ((v >> 1) as i64) ^ -((v & 1) as i64)
}

fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    loop {
        let b = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            out.push(b);
            return;
        }
        out.push(b | 0x80);
    }
}

fn varint_len(mut v: u64) -> usize {
    let mut n = 1;
    while v >= 0x80 {
        v >>= 7;
        n += 1;
    }
    n
}

// ---------------------------------------------------------------------------
// Datagrams.

/// A parsed diff datagram header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Header {
    pub epoch: u32,
    /// The send's stamp (0: none), set per send by [`stamp_datagram`]; the ack echoes it, so
    /// the host times every datagram's round trip and counts the ones that never came back.
    pub stamp: u32,
    pub seq: u64,
    pub base: u64,
    pub index: u64,
    pub count: u64,
}

/// Parses a diff datagram: its header and its fragment's bytes.
pub fn parse_diff_datagram(datagram: &[u8]) -> Option<(Header, &[u8])> {
    let mut r = Reader::new(datagram);
    if r.array::<2>().ok()? != MAGIC || r.u8().ok()? != KIND_DIFF {
        return None;
    }
    let epoch = u32::from_le_bytes(r.array::<4>().ok()?);
    let stamp = u32::from_le_bytes(r.array::<4>().ok()?);
    let seq = r.varint().ok()?;
    let base = r.varint().ok()?;
    let index = r.varint().ok()?;
    let count = r.varint().ok()?;
    if seq == 0 || base >= seq || count == 0 || count > MAX_FRAGMENTS || index >= count {
        return None;
    }
    let rest = datagram.get(r.pos..)?;
    Some((Header { epoch, stamp, seq, base, index, count }, rest))
}

/// Where a diff datagram's stamp sits: after the magic, the kind and the epoch.
pub const STAMP_OFFSET: usize = 7;

/// Sets a diff datagram's stamp (the sender's per-send number); false for anything else.
pub fn stamp_datagram(datagram: &mut [u8], stamp: u32) -> bool {
    if datagram.get(..3) != Some(&[MAGIC[0], MAGIC[1], KIND_DIFF][..]) {
        return false;
    }
    match datagram.get_mut(STAMP_OFFSET..STAMP_OFFSET + 4) {
        Some(slot) => {
            slot.copy_from_slice(&stamp.to_le_bytes());
            true
        }
        None => false,
    }
}

/// An ack datagram: the sender's epoch and the newest seq the phone holds (stamp 0).
pub fn ack_datagram(epoch: u32, seq: u64) -> Vec<u8> {
    ack_datagram_stamped(epoch, seq, 0)
}

/// An ack datagram echoing the stamp of the diff datagram it answers.
pub fn ack_datagram_stamped(epoch: u32, seq: u64, stamp: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity(20);
    out.extend_from_slice(&MAGIC);
    out.push(KIND_ACK);
    out.extend_from_slice(&epoch.to_le_bytes());
    put_varint(&mut out, seq);
    out.extend_from_slice(&stamp.to_le_bytes());
    out
}

/// Parses an ack datagram: (epoch, seq, stamp).
fn parse_ack(datagram: &[u8]) -> Option<(u32, u64, u32)> {
    let mut r = Reader::new(datagram);
    if r.array::<2>().ok()? != MAGIC || r.u8().ok()? != KIND_ACK {
        return None;
    }
    let epoch = u32::from_le_bytes(r.array::<4>().ok()?);
    let seq = r.varint().ok()?;
    let stamp = u32::from_le_bytes(r.array::<4>().ok()?);
    (r.remaining() == 0).then_some((epoch, seq, stamp))
}

/// Parses an ack datagram: (epoch, seq).
pub fn parse_ack_datagram(datagram: &[u8]) -> Option<(u32, u64)> {
    parse_ack(datagram).map(|(epoch, seq, _)| (epoch, seq))
}

/// The stamp an ack echoes (0: the diff it answers had none).
pub fn parse_ack_stamp(datagram: &[u8]) -> Option<u32> {
    parse_ack(datagram).map(|(_, _, stamp)| stamp)
}

fn diff_header(out: &mut Vec<u8>, epoch: u32, seq: u64, base: u64, index: u64, count: u64) {
    out.extend_from_slice(&MAGIC);
    out.push(KIND_DIFF);
    out.extend_from_slice(&epoch.to_le_bytes());
    out.extend_from_slice(&0_u32.to_le_bytes());
    put_varint(out, seq);
    put_varint(out, base);
    put_varint(out, index);
    put_varint(out, count);
}

/// Splits a payload into datagrams of at most `max_datagram` bytes.
fn fragment(payload: &[u8], max_datagram: usize, epoch: u32, seq: u64, base: u64) -> Vec<Vec<u8>> {
    // The header at its largest for this payload (index and count both
    // bounded by the payload's length).
    let bound = payload.len() as u64 + 1;
    let header = 2 + 1 + 4 + 4 + varint_len(seq) + varint_len(base) + 2 * varint_len(bound);
    let chunk = max_datagram.saturating_sub(header).max(1);
    let count = payload.len().div_ceil(chunk).max(1);
    let mut out = Vec::with_capacity(count);
    for index in 0..count {
        let part = payload.get(index * chunk..((index + 1) * chunk).min(payload.len()));
        let part = part.unwrap_or_default();
        let mut d = Vec::with_capacity(header + part.len());
        diff_header(&mut d, epoch, seq, base, index as u64, count as u64);
        d.extend_from_slice(part);
        out.push(d);
    }
    out
}

/// An epoch for a new sender: differs across host restarts, so a phone
/// holding a seq from an earlier sender takes the new one's keyframe.
fn new_epoch() -> u32 {
    use std::sync::atomic::{AtomicU32, Ordering};
    static COUNTER: AtomicU32 = AtomicU32::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos() as u64);
    let mut h = Fnv::default();
    h.u64(nanos);
    h.u64(u64::from(std::process::id()));
    h.u64(u64::from(COUNTER.fetch_add(1, Ordering::Relaxed)));
    h.0
}

/// Host side.
pub struct SyncSender {
    max_datagram: usize,
    epoch: u32,
    latest: Option<Arc<ScreenState>>,
    latest_seq: u64,
    /// States sent and not yet acked, oldest first, with their footprints.
    sent: VecDeque<(u64, Arc<ScreenState>, usize)>,
    sent_bytes: usize,
    acked_seq: u64,
    acked: Option<Arc<ScreenState>>,
    /// The datagrams for (latest seq, acked seq), resent as they are.
    cache: Option<(u64, u64, Vec<Vec<u8>>)>,
    /// The diff's buffer, reused.
    scratch: Vec<u8>,
    last_payload_len: usize,
    datagrams_sent: u64,
    bytes_sent: u64,
}

impl SyncSender {
    pub fn new(max_datagram: usize) -> Self {
        Self::with_epoch(max_datagram, new_epoch())
    }

    /// A sender with a given epoch (tests, or a host that persists one).
    pub fn with_epoch(max_datagram: usize, epoch: u32) -> Self {
        SyncSender {
            max_datagram: max_datagram.max(32),
            epoch,
            latest: None,
            latest_seq: 0,
            sent: VecDeque::new(),
            sent_bytes: 0,
            acked_seq: 0,
            acked: None,
            cache: None,
            scratch: Vec::new(),
            last_payload_len: 0,
            datagrams_sent: 0,
            bytes_sent: 0,
        }
    }

    pub fn epoch(&self) -> u32 {
        self.epoch
    }

    /// A new screen; bumps the seq only if it differs from the latest.
    /// Returns the latest seq.
    pub fn update(&mut self, latest: ScreenState) -> u64 {
        if self.latest.as_deref() != Some(&latest) {
            self.latest = Some(Arc::new(latest));
            self.latest_seq += 1;
        }
        self.latest_seq
    }

    /// The datagrams for diff(last acked state, latest). Empty when the
    /// phone already acked the latest.
    pub fn datagrams(&mut self) -> Vec<Vec<u8>> {
        let datagrams = self.make_datagrams();
        self.datagrams_sent += datagrams.len() as u64;
        self.bytes_sent += datagrams.iter().map(|d| d.len() as u64).sum::<u64>();
        datagrams
    }

    fn make_datagrams(&mut self) -> Vec<Vec<u8>> {
        let Some(latest) = &self.latest else { return Vec::new() };
        if self.latest_seq == self.acked_seq {
            return Vec::new();
        }
        if let Some((seq, base, datagrams)) = &self.cache
            && *seq == self.latest_seq
            && *base == self.acked_seq
        {
            return datagrams.clone();
        }
        let base = if self.acked_seq == 0 { None } else { self.acked.as_deref() };
        diff_into(base, latest, &mut self.scratch);
        self.last_payload_len = self.scratch.len();
        let datagrams =
            fragment(&self.scratch, self.max_datagram, self.epoch, self.latest_seq, self.acked_seq);
        if self.sent.back().map(|s| s.0) != Some(self.latest_seq) {
            let footprint = latest.footprint();
            self.sent_bytes += footprint;
            self.sent.push_back((self.latest_seq, Arc::clone(latest), footprint));
            while self.sent.len() > SENT_RING
                || (self.sent_bytes > SENT_RING_BYTES && self.sent.len() > 1)
            {
                if let Some((_, _, bytes)) = self.sent.pop_front() {
                    self.sent_bytes -= bytes;
                }
            }
        }
        self.cache = Some((self.latest_seq, self.acked_seq, datagrams.clone()));
        datagrams
    }

    /// An ack from the phone (the newest seq it holds). Stale and unknown
    /// acks are ignored; an ack of 0 (the phone holds nothing of ours) or of
    /// a state no longer kept starts over from a keyframe.
    pub fn on_ack(&mut self, datagram: &[u8]) {
        let Some((epoch, seq)) = parse_ack_datagram(datagram) else { return };
        if epoch != self.epoch || seq > self.latest_seq {
            return;
        }
        if seq == 0 {
            // The phone holds nothing of ours (or this ack is stale): start
            // over from a keyframe, still able to take an ack of the state
            // acked so far.
            self.forget_acked();
            return;
        }
        if seq <= self.acked_seq {
            return;
        }
        let state = if seq == self.latest_seq {
            // The phone holds the latest: kept or not.
            self.sent.clear();
            self.sent_bytes = 0;
            self.latest.clone()
        } else {
            match self.sent.iter().position(|s| s.0 == seq) {
                Some(i) => {
                    self.sent.drain(..i);
                    self.sent.pop_front().map(|(_, state, _)| state)
                }
                None => None,
            }
        };
        if state.is_some() {
            self.sent_bytes = self.sent.iter().map(|s| s.2).sum();
        }
        match state {
            Some(state) => {
                self.acked_seq = seq;
                self.acked = Some(state);
            }
            // The phone holds a state this sender no longer has.
            None => self.forget_acked(),
        }
    }

    /// Back to keyframes; the acked state stays kept (an ack of it may still
    /// come, from a phone that holds it).
    fn forget_acked(&mut self) {
        if let Some(state) = self.acked.take()
            && self.sent.front().is_none_or(|s| s.0 > self.acked_seq)
        {
            let footprint = state.footprint();
            self.sent_bytes += footprint;
            self.sent.push_front((self.acked_seq, state, footprint));
        }
        self.acked_seq = 0;
    }

    pub fn latest_seq(&self) -> u64 {
        self.latest_seq
    }

    pub fn acked_seq(&self) -> u64 {
        self.acked_seq
    }

    /// The latest state is not acked yet: the host's resend timer re-sends
    /// [`SyncSender::datagrams`].
    pub fn unacked(&self) -> bool {
        self.latest_seq > self.acked_seq
    }

    /// The length of the last diff payload made (before fragmenting).
    pub fn last_payload_len(&self) -> usize {
        self.last_payload_len
    }

    /// Datagrams returned by [`SyncSender::datagrams`] so far (resends too).
    pub fn datagrams_sent(&self) -> u64 {
        self.datagrams_sent
    }

    /// Bytes of the datagrams returned by [`SyncSender::datagrams`] so far.
    pub fn bytes_sent(&self) -> u64 {
        self.bytes_sent
    }

    /// States kept to diff from once acked.
    pub fn kept(&self) -> usize {
        self.sent.len()
    }
}

struct Partial {
    epoch: u32,
    seq: u64,
    base: u64,
    frags: Vec<Option<Vec<u8>>>,
    have: usize,
}

/// Phone side.
#[derive(Default)]
pub struct SyncReceiver {
    epoch: Option<u32>,
    seq: u64,
    /// The state held (seq `seq`).
    current: Option<Arc<ScreenState>>,
    /// States a diff may be based on, oldest first, with their footprints:
    /// every one applied since the newest base seen (the held one too).
    held: VecDeque<(u64, Arc<ScreenState>, usize)>,
    held_bytes: usize,
    /// The newest nonzero base of an applied diff; older states are dropped.
    floor: u64,
    partials: Vec<Partial>,
}

impl SyncReceiver {
    pub fn new() -> Self {
        Self::default()
    }

    /// Applies a complete diff only if it holds its base and its seq is newer
    /// than the one held (newest wins). Returns the ack to send back (the
    /// newest seq held) for every diff datagram; None for anything else.
    pub fn on_datagram(&mut self, datagram: &[u8]) -> Option<Vec<u8>> {
        let (h, data) = parse_diff_datagram(datagram)?;
        let same_epoch = self.epoch == Some(h.epoch);
        let held_seq = if same_epoch { self.seq } else { 0 };
        let ack = |seq| Some(ack_datagram_stamped(h.epoch, seq, h.stamp));
        if h.seq <= held_seq {
            return ack(held_seq);
        }
        if h.base != 0 && !(same_epoch && self.held.iter().any(|s| s.0 == h.base)) {
            return ack(held_seq);
        }
        let payload: std::borrow::Cow<'_, [u8]> = if h.count == 1 {
            std::borrow::Cow::Borrowed(data)
        } else {
            match self.reassemble(h, data) {
                Some(p) => std::borrow::Cow::Owned(p),
                None => return ack(held_seq),
            }
        };
        let result = if h.base == 0 {
            apply(None, &payload)
        } else if h.base == self.seq {
            apply(self.current.as_deref(), &payload)
        } else {
            let Some(base) = self.held.iter().find(|s| s.0 == h.base).map(|s| &*s.1) else {
                return ack(held_seq);
            };
            apply(Some(base), &payload)
        };
        let Ok(state) = result else { return ack(held_seq) };
        if !same_epoch {
            self.epoch = Some(h.epoch);
            self.held.clear();
            self.held_bytes = 0;
            self.floor = 0;
        }
        self.seq = h.seq;
        let state = Arc::new(state);
        let footprint = state.footprint();
        self.current = Some(Arc::clone(&state));
        self.held_bytes += footprint;
        self.held.push_back((h.seq, state, footprint));
        self.floor = self.floor.max(h.base);
        while self.held.len() > 1
            && (self.held.front().is_some_and(|s| s.0 < self.floor)
                || self.held.len() > HELD_RING
                || self.held_bytes > HELD_RING_BYTES)
        {
            if let Some((_, _, bytes)) = self.held.pop_front() {
                self.held_bytes -= bytes;
            }
        }
        let (epoch, seq) = (h.epoch, self.seq);
        self.partials.retain(|p| p.epoch != epoch || p.seq > seq);
        ack(self.seq)
    }

    /// States kept that a diff may be based on.
    pub fn kept(&self) -> usize {
        self.held.len()
    }

    /// Adds a fragment; the whole payload once every fragment is in.
    fn reassemble(&mut self, h: Header, data: &[u8]) -> Option<Vec<u8>> {
        let (epoch, seq) = (self.epoch, self.seq);
        self.partials.retain(|p| Some(p.epoch) != epoch || p.seq > seq);
        let found = self.partials.iter().position(|p| {
            p.epoch == h.epoch
                && p.seq == h.seq
                && p.base == h.base
                && p.frags.len() as u64 == h.count
        });
        let i = match found {
            Some(i) => i,
            None => {
                // The same seq with another base or count replaces its partial.
                self.partials.retain(|p| p.epoch != h.epoch || p.seq != h.seq);
                if self.partials.len() >= PARTIALS {
                    // Drop the oldest seq (another epoch's first).
                    let oldest = self
                        .partials
                        .iter()
                        .enumerate()
                        .min_by_key(|(_, p)| (p.epoch == h.epoch, p.seq))
                        .map(|(i, _)| i)?;
                    let older = self
                        .partials
                        .get(oldest)
                        .is_some_and(|p| p.epoch != h.epoch || p.seq < h.seq);
                    if !older {
                        // Every partial is newer than this one: it is stale.
                        return None;
                    }
                    self.partials.remove(oldest);
                }
                self.partials.push(Partial {
                    epoch: h.epoch,
                    seq: h.seq,
                    base: h.base,
                    frags: vec![None; h.count as usize],
                    have: 0,
                });
                self.partials.len() - 1
            }
        };
        let partial = self.partials.get_mut(i)?;
        let slot = partial.frags.get_mut(h.index as usize)?;
        if slot.is_none() {
            *slot = Some(data.to_vec());
            partial.have += 1;
        }
        if partial.have < partial.frags.len() {
            return None;
        }
        let partial = self.partials.remove(i);
        Some(partial.frags.into_iter().flatten().flatten().collect())
    }

    /// The state held (None before the first keyframe).
    pub fn screen(&self) -> Option<&ScreenState> {
        self.current.as_deref()
    }

    /// The seq held (0: nothing).
    pub fn seq(&self) -> u64 {
        self.seq
    }

    /// The epoch of the sender whose state is held.
    pub fn epoch(&self) -> Option<u32> {
        self.epoch
    }
}

// ---------------------------------------------------------------------------
// History.

/// Rows that left the viewport (scrolled into history) since the last call,
/// as VT bytes for the reliable stream, so the phone's history stays exact.
///
/// The bytes are for a terminal of the host's columns that holds only the
/// history: each row is written from column 0 and ends with `CR LF`, or, for a
/// row that soft-wraps, runs on into the next. `ESC c` (RIS) means the host's
/// scrollback was cleared (`ED 3`, a reset): the history starts over.
#[derive(Default)]
pub struct HistoryTracker {
    /// The absolute index (rows dropped by the limit included) of the next
    /// history row to write.
    next: u64,
    /// The last row written, to see a clear the count alone hides.
    last: Option<Row>,
    /// The last row written soft-wraps into the next.
    wrapped: bool,
}

impl HistoryTracker {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn take_new_rows(&mut self, term: &Terminal) -> Vec<u8> {
        let mut out = Vec::new();
        if term.is_alternate() {
            return out;
        }
        let dropped = term.history_dropped;
        let total = dropped + term.history.len() as u64;
        let cleared = self.next > total
            || (self.next > dropped
                && self.last.as_ref().is_some_and(|last| {
                    term.history.get((self.next - 1 - dropped) as usize) != Some(last)
                }));
        if cleared {
            out.extend_from_slice(b"\x1bc");
            self.next = 0;
            self.wrapped = false;
        }
        let start = self.next.max(dropped);
        for abs in start..total {
            if let Some(row) = term.history.get((abs - dropped) as usize) {
                write_history_row(term, row, self.wrapped, &mut out);
                self.wrapped = row.wrapped;
            }
        }
        if total > self.next || cleared {
            self.last = term.history.back().cloned();
        }
        self.next = total;
        out
    }
}

fn write_osc8(out: &mut Vec<u8>, link: &str) {
    out.extend_from_slice(b"\x1b]8;");
    if link.is_empty() {
        out.push(b';');
    } else {
        out.extend_from_slice(link.as_bytes());
    }
    out.extend_from_slice(b"\x1b\\");
}

/// One history row. `continuation`: the row before soft-wrapped into this
/// one (the cursor waits at the last column, so its first cell is printed).
fn write_history_row(term: &Terminal, row: &Row, continuation: bool, out: &mut Vec<u8>) {
    let cols = term.cols;
    let mut col = 0usize;
    let mut blanks = 0usize;
    let mut style: Option<u16> = None;
    let mut link = 0u32;
    let mut last_kind = NARROW;
    let reset = |out: &mut Vec<u8>, style: &mut Option<u16>| {
        if *style != Some(0) {
            Style::default().write_sgr(out);
            *style = Some(0);
        }
    };
    for cell in &row.cells {
        last_kind = cell.kind;
        if cell.kind == WIDE_TAIL || cell.kind == SPACER_HEAD {
            continue;
        }
        if *cell == Cell::default() && !(continuation && col == 0) {
            blanks += 1;
            col += 1;
            continue;
        }
        if blanks > 0 {
            out.extend_from_slice(format!("\x1b[{blanks}C").as_bytes());
            blanks = 0;
        }
        let s = term.styles.get(cell.style);
        if style != Some(cell.style) {
            Style { link: 0, ..s }.write_sgr(out);
            style = Some(cell.style);
        }
        if s.link != link {
            write_osc8(out, if s.link == 0 { "" } else { term.links.get(s.link) });
            link = s.link;
        }
        if cell.ch == 0 {
            out.push(b' ');
        } else {
            term.write_cell(*cell, out);
        }
        col += cell.width();
    }
    if link != 0 {
        write_osc8(out, "");
    }
    if row.wrapped {
        // The cursor must wait at the last column for the next row to wrap
        // into: pad with blanks (a trailing spacer head is the terminal's own).
        let written = col - blanks;
        if last_kind != SPACER_HEAD && written < cols {
            reset(out, &mut style);
            out.extend_from_slice(&vec![b' '; cols - written]);
        }
        if style.is_some() {
            reset(out, &mut style);
        }
    } else {
        reset(out, &mut style);
        out.extend_from_slice(b"\r\n");
    }
}

// ---------------------------------------------------------------------------

#[cfg(test)]
#[path = "sync_tests.rs"]
mod tests;
