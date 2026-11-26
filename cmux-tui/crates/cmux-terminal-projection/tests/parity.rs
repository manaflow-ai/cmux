//! Parity: the phone's projected view against the Mac's own grid, cell by cell.
//!
//! Leo, 2026-11-21: "we need to expand and prove at least correctness parity,
//! then push beyond. whatever symbols, etc."
//!
//! The oracle is Ghostty's VT core (`ghostty-vt`), the emulator the Mac's pane
//! runs, at the Mac's grid. The phone is the same core at the phone's grid,
//! fed what the projection writes, the way the app feeds its Ghostty surface
//! (a reset is a fresh terminal; on the alternate screen the surface takes the
//! Mac's grid). The projection's own VT model never judges itself.
//!
//! What must match, per corpus, per phone width, per chunking:
//!
//! - **Primary screen, exact** (`compact` off): every logical line (rows
//!   joined across soft wraps) of the phone's document equals the Mac's,
//!   cell by cell: the grapheme, wide or narrow, foreground, background,
//!   bold, faint, italic, underline style, strikethrough, inverse, blink,
//!   invisible. A blank cell's foreground and text attributes do not show
//!   and are not compared. Trailing default blanks are trimmed. The cursor
//!   sits on the same logical line, at the same column of it, with the same
//!   shape and visibility.
//! - **Primary screen, compact** (the default): a right-anchored row's
//!   padding shrinks on purpose, so the glyphs are compared in order, with
//!   their styles, ignoring blank cells and line breaks.
//! - **Alternate screen**: the phone's grid equals the Mac's row by row, and
//!   the cursor is at the same cell.
//!
//! The result is mismatched cells per corpus, with a target of 0. The run
//! writes a table to stdout and, with `PARITY_OUT=DIR`, `DIR/parity.json` and
//! `DIR/parity.md`.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use cmux_terminal_projection::{Projection, Segment};
use ghostty_vt::{
    Callbacks, Cell, CellWidth, ColorSpec, CursorShape, Terminal as Vt, UnderlineStyle,
};

const SCROLLBACK_BYTES: usize = 256 << 20;
const HISTORY_ROWS: usize = 100_000;

fn vt(cols: usize, rows: usize) -> Vt {
    Vt::new(cols as u16, rows as u16, SCROLLBACK_BYTES, Callbacks::default())
        .expect("ghostty terminal")
}

// ---------------------------------------------------------------------------
// Cells as compared.

#[derive(Debug, Clone, PartialEq, Eq)]
struct Key {
    text: String,
    wide: bool,
    fg: ColorSpec,
    bg: ColorSpec,
    attrs: u16,
    underline: Option<UnderlineStyle>,
    /// The cell carries an OSC 8 link (Ghostty reads presence, not the URI).
    link: bool,
}

/// A cell as read, with its link flag.
type Read = (Cell, bool);

impl Key {
    fn of((cell, link): &Read) -> Key {
        let text = if cell.text.is_empty() { " ".to_string() } else { cell.text.clone() };
        let blank = text == " ";
        let mut key = Key {
            text,
            wide: cell.width == CellWidth::Wide,
            fg: cell.fg,
            bg: cell.bg,
            attrs: cell.attrs(),
            underline: if cell.underline {
                cell.underline_style.or(Some(UnderlineStyle::Single))
            } else {
                None
            },
            link: *link,
        };
        if blank {
            // What a blank shows: its background, or its foreground when
            // inverse; an underline or a strike line.
            let inverse = key.attrs & ghostty_vt::ATTR_INVERSE != 0;
            if !inverse {
                key.fg = ColorSpec::Default;
            }
            key.attrs &= ghostty_vt::ATTR_INVERSE | ghostty_vt::ATTR_STRIKETHROUGH;
        }
        key
    }

    fn is_default_blank(&self) -> bool {
        self.text == " "
            && self.fg == ColorSpec::Default
            && self.bg == ColorSpec::Default
            && self.attrs == 0
            && self.underline.is_none()
            && !self.link
    }

    fn label(&self) -> String {
        let mut s = format!("{:?}", self.text);
        if self.fg != ColorSpec::Default {
            let _ = write!(s, " fg={:?}", self.fg);
        }
        if self.bg != ColorSpec::Default {
            let _ = write!(s, " bg={:?}", self.bg);
        }
        if self.attrs != 0 {
            let _ = write!(s, " attrs={:#x}", self.attrs);
        }
        if let Some(u) = self.underline {
            let _ = write!(s, " ul={u:?}");
        }
        if self.link {
            s.push_str(" link");
        }
        s
    }
}

// ---------------------------------------------------------------------------
// A terminal read whole.

struct Snapshot {
    /// Every retained row of the active screen, oldest first: cells and wrap.
    rows: Vec<(Vec<Read>, bool)>,
    /// Cursor row (in `rows`) and column.
    cursor: (usize, usize),
    cursor_visible: bool,
    cursor_shape: (CursorShape, bool),
    alternate: bool,
}

fn snapshot(term: &Vt) -> Snapshot {
    let alternate = matches!(term.active_screen(), ghostty_vt::Screen::Alternate);
    let total = (term.scrollback_rows() + usize::from(term.rows())) as u64;
    let mut rows = Vec::with_capacity(total as usize);
    for y in 0..total {
        match term.styled_screen_row(y) {
            Some((cells, links, wraps)) => {
                rows.push((cells.into_iter().zip(links).collect(), wraps));
            }
            None => break,
        }
    }
    let (x, y) = term.cursor_position().unwrap_or((0, 0));
    let top = rows.len().saturating_sub(usize::from(term.rows()));
    Snapshot {
        rows,
        cursor: (top + usize::from(y), usize::from(x)),
        cursor_visible: term.mode(25, false),
        cursor_shape: term.effective_cursor_visual().unwrap_or((CursorShape::Block, false)),
        alternate,
    }
}

/// Logical lines (rows joined across soft wraps) with their cells as keys,
/// and the cursor as (line, column within the line).
struct Lines {
    lines: Vec<Vec<Key>>,
    cursor: (usize, usize),
}

fn logical_lines(snap: &Snapshot) -> Lines {
    let mut lines: Vec<Vec<Key>> = Vec::new();
    let mut current: Vec<Key> = Vec::new();
    let mut cursor = (0, 0);
    let mut columns_before = 0usize;
    for (index, (cells, wraps)) in snap.rows.iter().enumerate() {
        if index == snap.cursor.0 {
            cursor = (lines.len(), columns_before + snap.cursor.1);
        }
        let mut row_columns = 0;
        for cell in cells {
            match cell.0.width {
                CellWidth::SpacerTail | CellWidth::SpacerHead => {}
                CellWidth::Wide => {
                    row_columns += 2;
                    current.push(Key::of(cell));
                }
                CellWidth::Narrow => {
                    row_columns += 1;
                    current.push(Key::of(cell));
                }
            }
        }
        if *wraps {
            // A spacer head is not part of the line: the columns before the
            // next row are only the cells kept.
            columns_before += row_columns;
            // Cells past the content on a wrapped row (none: it wrapped
            // because it was full) are kept as they are.
            continue;
        }
        while current.last().is_some_and(Key::is_default_blank) {
            current.pop();
        }
        lines.push(std::mem::take(&mut current));
        columns_before = 0;
    }
    if !current.is_empty() {
        lines.push(current);
    }
    // Empty lines at the end, below the cursor's line, are the screen's
    // unused rows, which differ with the screen's height.
    while lines.len() > cursor.0 + 1 && lines.last().is_some_and(Vec::is_empty) {
        lines.pop();
    }
    Lines { lines, cursor }
}

// ---------------------------------------------------------------------------
// Comparisons.

#[derive(Default, Debug, Clone)]
struct Score {
    cells: usize,
    mismatched: usize,
    cursor_mismatches: usize,
    first: Vec<String>,
}

impl Score {
    fn note(&mut self, what: String) {
        if self.first.len() < 6 {
            self.first.push(what);
        }
    }

    fn add(&mut self, other: Score) {
        self.cells += other.cells;
        self.mismatched += other.mismatched;
        self.cursor_mismatches += other.cursor_mismatches;
        for what in other.first {
            self.note(what);
        }
    }
}

fn line_text(line: &[Key]) -> String {
    line.iter().map(|k| k.text.as_str()).collect()
}

/// The phone's lines against the Mac's, aligned at the end. `partial_top`:
/// the phone's document starts inside the Mac's history, so its first line
/// may be the tail of a longer one and is not compared, and Mac lines above
/// the phone's are not missing.
fn compare_exact(mac: &Snapshot, phone: &Snapshot, partial_top: bool) -> Score {
    let mut score = Score::default();
    let m = logical_lines(mac);
    let p = logical_lines(phone);
    let (m_lines, p_lines) = (&m.lines, &p.lines);
    let skip = usize::from(partial_top && !p_lines.is_empty());
    let p_count = p_lines.len() - skip;
    let m_count = if partial_top { p_count.min(m_lines.len()) } else { m_lines.len() };
    let compared = p_count.min(m_count);
    for i in 0..compared {
        let ml = &m_lines[m_lines.len() - compared + i];
        let pl = &p_lines[p_lines.len() - compared + i];
        let n = ml.len().max(pl.len());
        score.cells += n;
        let mut bad = 0;
        let mut first_bad = None;
        for c in 0..n {
            if ml.get(c) != pl.get(c) {
                bad += 1;
                first_bad.get_or_insert(c);
            }
        }
        if bad > 0 {
            score.mismatched += bad;
            let c = first_bad.unwrap_or(0);
            score.note(format!(
                "line -{} col {c}: mac {} / phone {}\n      mac:   {:?}\n      phone: {:?}",
                compared - i,
                ml.get(c).map_or("(none)".into(), Key::label),
                pl.get(c).map_or("(none)".into(), Key::label),
                line_text(ml),
                line_text(pl),
            ));
        }
    }
    // Lines one side has and the other does not.
    for (side, lines, count) in [("mac", m_lines, m_count), ("phone", p_lines, p_count)] {
        if count > compared {
            for line in &lines[lines.len() - count..lines.len() - compared] {
                score.cells += line.len().max(1);
                score.mismatched += line.len().max(1);
                score.note(format!("only on the {side}: {:?}", line_text(line)));
            }
        }
    }
    // The cursor: its line counted from the end, and its column in it.
    let from_end =
        |lines: &Lines| (lines.lines.len().saturating_sub(lines.cursor.0), lines.cursor.1);
    if from_end(&m) != from_end(&p) {
        score.cursor_mismatches += 1;
        score.note(format!(
            "cursor: mac (line -{}, col {}) / phone (line -{}, col {})",
            from_end(&m).0,
            from_end(&m).1,
            from_end(&p).0,
            from_end(&p).1
        ));
    }
    score.add(compare_cursor_look(mac, phone));
    score
}

fn compare_cursor_look(mac: &Snapshot, phone: &Snapshot) -> Score {
    let mut score = Score::default();
    if mac.cursor_visible != phone.cursor_visible {
        score.cursor_mismatches += 1;
        score.note(format!(
            "cursor visible: mac {} / phone {}",
            mac.cursor_visible, phone.cursor_visible
        ));
    }
    if mac.cursor_shape != phone.cursor_shape {
        score.cursor_mismatches += 1;
        score.note(format!(
            "cursor shape: mac {:?} / phone {:?}",
            mac.cursor_shape, phone.cursor_shape
        ));
    }
    score
}

/// Horizontal rules compact mode shrinks as padding (`is_rule` in
/// `src/project.rs`): `─` in `╭────╮`.
fn is_rule(text: &str) -> bool {
    matches!(text, "─" | "━" | "═" | "┄" | "┅" | "┈" | "┉" | "╌" | "╍")
}

/// Glyphs in order with their styles, blanks and line structure aside.
///
/// A run of one rule glyph (the same text and style in cells side by side,
/// or across a soft wrap) counts once. Compact mode lays a right-anchored
/// row out at the phone's width by shrinking its padding, and a frame's
/// padding is such a run (`╭────╮` becomes `╭─╮`); it keeps at least one
/// cell of every run, so the phone still shows every glyph of the row, in
/// order, with its style. A run that is gone, or a rule glyph that is not
/// in a run, still counts.
fn glyphs(snap: &Snapshot) -> Vec<Key> {
    let mut out = Vec::new();
    let mut previous: Option<Key> = None;
    for (cells, wraps) in &snap.rows {
        for cell in cells {
            if matches!(cell.0.width, CellWidth::SpacerTail | CellWidth::SpacerHead) {
                continue;
            }
            let key = Key::of(cell);
            let repeat = is_rule(&key.text) && previous.as_ref() == Some(&key);
            if key.text != " " && !repeat {
                out.push(key.clone());
            }
            previous = Some(key);
        }
        if !*wraps {
            previous = None;
        }
    }
    out
}

fn compare_glyphs(mac: &Snapshot, phone: &Snapshot, partial_top: bool) -> Score {
    let mut score = Score::default();
    let m = glyphs(mac);
    let p = glyphs(phone);
    let (m, p) = if partial_top {
        // Compare the tail the phone holds (less its possibly partial first line's worth).
        let n = p.len().min(m.len());
        (&m[m.len() - n..], &p[p.len() - n..])
    } else {
        (&m[..], &p[..])
    };
    let n = m.len().max(p.len());
    score.cells = n;
    // Aligned from the end: a missing glyph shows as a shift from there up.
    for i in 0..n {
        let a = m.len().checked_sub(n - i).and_then(|j| m.get(j));
        let b = p.len().checked_sub(n - i).and_then(|j| p.get(j));
        if a != b {
            score.mismatched += 1;
            if score.first.is_empty() {
                score.note(format!(
                    "glyph -{}: mac {} / phone {}",
                    n - i,
                    a.map_or("(none)".into(), Key::label),
                    b.map_or("(none)".into(), Key::label)
                ));
            }
        }
    }
    score.add(compare_cursor_look(mac, phone));
    score
}

fn compare_alternate(mac: &Snapshot, phone: &Snapshot) -> Score {
    let mut score = Score::default();
    let rows = |s: &Snapshot| s.rows.len();
    let n = rows(mac).max(rows(phone));
    for i in 0..n {
        let mr = mac.rows.get(i).map(|(c, _)| c.as_slice()).unwrap_or(&[]);
        let pr = phone.rows.get(i).map(|(c, _)| c.as_slice()).unwrap_or(&[]);
        let w = mr.len().max(pr.len());
        score.cells += w;
        for c in 0..w {
            let a = mr.get(c).map(Key::of);
            let b = pr.get(c).map(Key::of);
            if a != b {
                score.mismatched += 1;
                score.note(format!(
                    "alt row {i} col {c}: mac {} / phone {}",
                    a.map_or("(none)".into(), |k| k.label()),
                    b.map_or("(none)".into(), |k| k.label())
                ));
            }
        }
    }
    if mac.cursor != phone.cursor {
        score.cursor_mismatches += 1;
        score.note(format!("alt cursor: mac {:?} / phone {:?}", mac.cursor, phone.cursor));
    }
    score.add(compare_cursor_look(mac, phone));
    score
}

// ---------------------------------------------------------------------------
// One run: a corpus through the Mac and through the projection to the phone.

struct Run {
    mac: Vt,
    projection: Projection,
    phone: Vt,
    host: (usize, usize),
    grid: (usize, usize),
    compact: bool,
    bytes_out: usize,
    resets: usize,
}

impl Run {
    fn new(host: (usize, usize), grid: (usize, usize), compact: bool) -> Run {
        let mut projection = Projection::new(host.0, host.1, HISTORY_ROWS);
        let _ = projection.set_compact(compact);
        let mut run = Run {
            mac: vt(host.0, host.1),
            projection,
            phone: vt(grid.0, grid.1),
            host,
            grid,
            compact,
            bytes_out: 0,
            resets: 0,
        };
        let first = run.projection.set_viewport(grid.0, grid.1);
        run.apply(first);
        run
    }

    fn apply(&mut self, segments: Vec<Segment>) {
        for segment in segments {
            match segment {
                Segment::Paint(bytes) | Segment::Raw(bytes) => {
                    self.bytes_out += bytes.len();
                    self.phone.vt_write(&bytes);
                }
                Segment::Reset(bytes) => {
                    self.resets += 1;
                    self.bytes_out += bytes.len();
                    self.phone = vt(self.grid.0, self.grid.1);
                    self.phone.vt_write(&bytes);
                }
                Segment::Alternate(on) => {
                    let (cols, rows) = if on { self.host } else { self.grid };
                    let _ = self.phone.resize(cols as u16, rows as u16, 0, 0);
                }
            }
        }
    }

    fn feed(&mut self, bytes: &[u8]) {
        self.mac.vt_write(bytes);
        let segments = self.projection.feed(bytes, true);
        self.apply(segments);
        let _ = self.projection.take_replies();
    }

    fn set_viewport(&mut self, cols: usize, rows: usize) {
        self.grid = (cols, rows);
        if !self.projection.is_alternate() {
            let _ = self.phone.resize(cols as u16, rows as u16, 0, 0);
        }
        let segments = self.projection.set_viewport(cols, rows);
        self.apply(segments);
    }

    /// The reader scrolls to the top: the phone loads every older row.
    fn load_all(&mut self) {
        for _ in 0..10_000 {
            if self.projection.older_rows() == 0 {
                break;
            }
            let segments = self.projection.load_older(HISTORY_ROWS);
            if segments.is_empty() {
                break;
            }
            self.apply(segments);
        }
    }

    fn compare(&mut self) -> Score {
        let mac = snapshot(&self.mac);
        let phone = snapshot(&self.phone);
        let mut score = Score::default();
        if mac.alternate != phone.alternate {
            score.mismatched += 1;
            score.cells += 1;
            score.note(format!(
                "screen: mac alternate {} / phone {}",
                mac.alternate, phone.alternate
            ));
            return score;
        }
        if mac.alternate {
            return compare_alternate(&mac, &phone);
        }
        let partial = self.projection.older_rows() > 0;
        if self.compact {
            compare_glyphs(&mac, &phone, partial)
        } else {
            compare_exact(&mac, &phone, partial)
        }
    }
}

// ---------------------------------------------------------------------------
// Corpora.

struct Corpus {
    name: String,
    host: (usize, usize),
    bytes: Vec<u8>,
    /// Where the run also compares, besides the end (byte offsets).
    checkpoints: Vec<usize>,
}

fn corpus(name: &str, host: (usize, usize), steps: &[&[u8]]) -> Corpus {
    let mut bytes = Vec::new();
    let mut checkpoints = Vec::new();
    for step in steps {
        bytes.extend_from_slice(step);
        checkpoints.push(bytes.len());
    }
    Corpus { name: name.into(), host, bytes, checkpoints }
}

fn s(text: &str) -> Vec<u8> {
    text.as_bytes().to_vec()
}

fn synthetic() -> Vec<Corpus> {
    let mut out = Vec::new();

    // Wide and CJK: wide glyphs at the Mac's edge (spacer head), at the
    // phone's edges, runs of wide glyphs, and half-width katakana.
    let mut a = String::new();
    a += &"a".repeat(119);
    a += "漢字かな交じり文\r\n";
    for cut in [31, 53, 79] {
        a += &"b".repeat(cut);
        a += "日本語のテキストと한국어 텍스트\r\n";
    }
    a += &"中文".repeat(70);
    a += "\r\nｶﾀｶﾅ half width, ＦＵＬＬ ｗｉｄｔｈ, 〜〜〜\r\n$ ";
    out.push(corpus("wide_and_cjk", (120, 40), &[a.as_bytes()]));

    // Emoji: modifiers, ZWJ families, flags, VS16 and VS15, keycaps, tags.
    let mut e = String::new();
    e += "thumbs 👍 👍🏻 👍🏽 👍🏿 family 👨‍👩‍👧‍👦 👩‍❤️‍💋‍👨 rainbow 🏳️‍🌈 pirate 🏴‍☠️\r\n";
    e += "flags 🇯🇵🇺🇸🇫🇷 england 🏴󠁧󠁢󠁥󠁮󠁧󠁿 keycaps 1️⃣ #️⃣ *️⃣ heart ❤️ ❤ text ☺︎ emoji ☺️\r\n";
    e += "work 🧑‍💻 👩🏽‍🚀 🐻‍❄️ ✔️ ✅ ⚠️ ⏳ 🚀 🔥 💡 📦 🧪\r\n";
    for cut in [30, 53, 79, 118] {
        e += &"x".repeat(cut);
        e += "🧑‍💻👨‍👩‍👧‍👦🇯🇵❤️✅\r\n";
    }
    e += &"🔥".repeat(80);
    e += "\r\n$ ";
    out.push(corpus("emoji_zwj_and_flags", (120, 40), &[e.as_bytes()]));

    // Combining marks: accents, stacked marks, Hangul jamo, Indic, Thai, Arabic.
    let mut c = String::new();
    c += "cafe\u{301} nai\u{308}ve a\u{30a}\u{301}\u{323} z\u{335}\u{30d}\u{30e} q\u{307}\u{323}\r\n";
    c += "jamo \u{1100}\u{1161}\u{11a8} devanagari नमस्ते क्षत्रिय thai กำลัง arabic مرحبا\r\n";
    for cut in [31, 53, 79, 119] {
        c += &"m".repeat(cut);
        c += "e\u{301}e\u{301}e\u{301} done\r\n";
    }
    c += "$ ";
    out.push(corpus("combining_marks", (120, 40), &[c.as_bytes()]));

    // Box drawing, blocks, braille, Powerline and Nerd Font symbols (PUA,
    // BMP and supplementary).
    let mut b = String::new();
    b += "┌──────┬──────┐ ╔══════╦══════╗ ╭──────╮\r\n";
    b += "│ cell │ cell │ ║ cell ║ cell ║ │ ╳ ╱╲ │\r\n";
    b += "├──────┼──────┤ ╠══════╬══════╣ ╰──────╯\r\n";
    b += "└──────┴──────┘ ╚══════╩══════╝ ▀▄█▌▐░▒▓ ⠿⠇⠋⣿ ▁▂▃▄▅▆▇█\r\n";
    b += "\x1b[38;5;15;48;5;24m user \x1b[38;5;24;48;5;238m\u{e0b0}\x1b[38;5;15m ~/src/cmux \x1b[38;5;238;48;5;28m\u{e0b0}\x1b[38;5;15m \u{e0a0} main \x1b[0m\x1b[38;5;28m\u{e0b0}\x1b[0m \u{e0b2}\u{e0b3}\u{e0b1}\u{e0b6}\u{e0b4}\r\n";
    b += "nerd \u{f015} \u{f07b} \u{e702} \u{e7a8} \u{f121} \u{f0001} \u{f02a2} \u{e62b} \u{f489} \u{eb99}\r\n";
    b += &"─".repeat(120);
    b += &"═".repeat(160);
    b += "\r\n";
    // A full-width rule as Claude Code draws its prompt box.
    b += &format!("╭{}╮\r\n│ > {}│\r\n╰{}╯\r\n", "─".repeat(118), " ".repeat(115), "─".repeat(118));
    b += "$ ";
    out.push(corpus("box_drawing_powerline_nerd", (120, 40), &[b.as_bytes()]));

    // SGR colours and attributes, across wraps; erase with a background.
    let mut g = String::new();
    for i in 0..8 {
        g += &format!(
            "\x1b[3{i}mfg{i}\x1b[9{i}mbright{i}\x1b[4{i}mbg{i}\x1b[10{i}mbrightbg{i}\x1b[0m "
        );
    }
    g += "\r\n";
    for i in (0..256).step_by(7) {
        g += &format!("\x1b[38;5;{i}m{i:03}\x1b[48;5;{}m▄\x1b[0m", 255 - i);
    }
    g += "\r\n\x1b[38;2;255;128;0mtruecolor;\x1b[38:2::0:200:255mcolon form\x1b[48;2;20;20;40m on rgb bg\x1b[0m\r\n";
    g += "\x1b[1mbold\x1b[22m \x1b[2mfaint\x1b[22m \x1b[3mitalic\x1b[23m \x1b[4munder\x1b[24m \x1b[4:2mdouble\x1b[4:3mcurly\x1b[4:4mdotted\x1b[4:5mdashed\x1b[24m \x1b[21mdouble21\x1b[24m \x1b[5mblink\x1b[25m \x1b[7minverse\x1b[27m \x1b[8minvisible\x1b[28m \x1b[9mstrike\x1b[29m \x1b[53moverline\x1b[55m \x1b[58;5;196;4mulcolor\x1b[0m\r\n";
    g += "plain \x1b[1;31;48;5;236mbold red on grey that runs on past the phone's edge and the Mac's edge too ";
    g += &"r".repeat(120);
    g += "\x1b[0m back to plain\r\n";
    g += "\x1b[44mblue band erased to the end\x1b[K\x1b[0m\r\n";
    g += "\x1b[41m\x1b[2K\x1b[0mred whole row erased, text after reset\r\n";
    g += "\x1b[7m inverse blank tail       \x1b[0m\r\n";
    g += "\x1b[1;3;4;9;38;5;208mall at once\x1b[m and reset by bare m\r\n$ ";
    out.push(corpus("sgr_colors_and_attributes", (120, 40), &[g.as_bytes()]));

    // Cursor: shapes, visibility, save/restore, CUP, a command line edited
    // mid-wrap, the pending wrap at the last column.
    let cmd = "git commit -m 'a long message that wraps on the phone and keeps the cursor where the shell put it'";
    let cur: Vec<Vec<u8>> = vec![
        s(&format!("$ {cmd}")),
        s("\x1b[30D"),
        s("\x1b[2 q"),
        s("\x1b[30C\r\n\x1b[5 q"),
        [b"Q".repeat(120)].concat(),
        s("\x1b[?25l"),
        s("\r\n\x1b[?25h\x1b[4 q\x1b7\x1b[3;7Hsaved\x1b8 back"),
        s("\x1b[6 q\x1b[0 q\r\n$ "),
    ];
    let steps: Vec<&[u8]> = cur.iter().map(Vec::as_slice).collect();
    out.push(corpus("cursor_shapes_and_positions", (120, 40), &steps));

    // Shell editing: CR overwrite, backspace, erase in line and display, tabs,
    // a clear with its scrollback, insert and delete characters.
    let mut sh: Vec<Vec<u8>> = Vec::new();
    sh.push(s("$ ls\r\nfile1\tfile2\tfile3\tlonger_file_name\tx\r\n"));
    sh.push(s("progress 10%\rprogress 55%\rprogress 100%\r\n"));
    sh.push(s("typo\x08\x08\x08\x08fixed\r\n"));
    sh.push(s("abcdefghij\x1b[5D\x1b[2@++\x1b[3P\r\n"));
    sh.push(s(&format!("{}\x1b[60D\x1b[K\r\n", "w".repeat(110))));
    sh.push(s(&format!("{}\r\n", "long line ".repeat(30))));
    sh.push(s("\x1b[2J\x1b[3J\x1b[H$ cleared\r\n"));
    sh.push(s(&format!("{}\x1b[A\x1b[1J\r\n", "z".repeat(200))));
    sh.push(s("$ "));
    let steps: Vec<&[u8]> = sh.iter().map(Vec::as_slice).collect();
    out.push(corpus("shell_editing", (120, 40), &steps));

    // Scrollback: lines of every length, wrapped lines in history, styles in
    // history, past several screens.
    let mut sb = String::new();
    for i in 0..1500 {
        let len = (i * 37) % 300;
        sb += &format!("\x1b[3{}m{i:05}\x1b[0m {}\r\n", i % 8, "·".repeat(len));
    }
    sb += "$ ";
    out.push(corpus("scrollback_reflow", (120, 40), &[sb.as_bytes()]));

    // OSC 8 links across wraps.
    let mut l = String::new();
    l += "see \x1b]8;;https://example.com/docs\x1b\\\x1b[34mhttps://example.com/docs - a link whose text crosses the phone's edge and goes on\x1b[0m\x1b]8;;\x1b\\ end\r\n";
    l += "\x1b]8;id=a;https://example.com/a\x07first\x1b]8;;\x07 \x1b]8;id=b;https://example.com/b\x07second\x1b]8;;\x07\r\n$ ";
    out.push(corpus("osc8_links", (120, 40), &[l.as_bytes()]));

    // Full-screen TUI on the alternate screen: scroll regions, insert and
    // delete lines, then back to the shell.
    let mut t: Vec<Vec<u8>> = Vec::new();
    t.push(s("$ top\r\n"));
    t.push(s("\x1b[?1049h\x1b[H\x1b[2J\x1b[1;1H\x1b[7m  PID USER      %CPU COMMAND                          \x1b[0m"));
    let mut body = String::new();
    for i in 0..30 {
        body += &format!(
            "\x1b[{};1H{:5} user      {:4.1} \x1b[32mprocess-{i}\x1b[0m",
            i + 2,
            1000 + i,
            (i * 7 % 100) as f32
        );
    }
    t.push(s(&body));
    t.push(s("\x1b[5;30r\x1b[30;1H\n\n\x1b[1;40r\x1b[10;1H\x1b[2L\x1b[3M\x1b[40;1H\x1b[44m status ✔ 中文 👍 \x1b[K\x1b[0m\x1b[12;20H"));
    t.push(s("\x1b[?1049l$ "));
    t.push(s("echo back\r\nback\r\n$ "));
    let steps: Vec<&[u8]> = t.iter().map(Vec::as_slice).collect();
    out.push(corpus("full_screen_tui_and_back", (120, 40), &steps));

    out
}

/// Recorded programs: the existing golden byte streams and real sessions.
fn recorded() -> Vec<Corpus> {
    let mut out = Vec::new();
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests");
    let mut push_dir = |dir: &Path,
                        default: (usize, usize),
                        grids: &BTreeMap<&str, (usize, usize)>| {
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        let mut paths: Vec<PathBuf> = entries.filter_map(|e| e.ok().map(|e| e.path())).collect();
        paths.sort();
        for path in paths {
            if path.extension().and_then(|e| e.to_str()) != Some("vt") {
                continue;
            }
            let name = path.file_stem().unwrap().to_string_lossy().to_string();
            let grid_file = path.with_extension("grid");
            let host = std::fs::read_to_string(&grid_file)
                .ok()
                .and_then(|g| {
                    let (c, r) = g.trim().split_once('x')?;
                    Some((c.parse().ok()?, r.parse().ok()?))
                })
                .or_else(|| grids.get(name.as_str()).copied())
                .unwrap_or(default);
            let bytes = std::fs::read(&path).unwrap();
            // Checkpoints every 1/8 of the stream.
            let checkpoints = (1..=8).map(|i| bytes.len() * i / 8).collect();
            out.push(Corpus { name, host, bytes, checkpoints });
        }
    };
    let golden: BTreeMap<&str, (usize, usize)> =
        [("alternate_screen_codex_and_back", (120, 40))].into();
    push_dir(&root.join("golden/vt"), (120, 24), &golden);
    push_dir(&root.join("parity/real"), (120, 40), &BTreeMap::new());
    out
}

// ---------------------------------------------------------------------------
// The harness.

const PHONE_GRIDS: [(usize, usize); 4] = [(33, 30), (54, 38), (80, 24), (120, 40)];

#[derive(Default, Clone)]
struct Row {
    cells: usize,
    exact: usize,
    compact: usize,
    cursor: usize,
    bytes_out: usize,
    resets: usize,
    notes: Vec<String>,
}

fn run_corpus(corpus: &Corpus) -> Row {
    let mut row = Row::default();
    // Whole, network-sized and tiny chunks (escape sequences split anywhere).
    let mut chunkings = vec![usize::MAX, 4096, 61];
    if corpus.bytes.len() <= 16 << 10 {
        chunkings.push(1);
    }
    for &grid in &PHONE_GRIDS {
        for &chunk in &chunkings {
            for compact in [false, true] {
                let mut run = Run::new(corpus.host, grid, compact);
                let mut at = 0;
                let mut checkpoints = corpus.checkpoints.iter().copied().peekable();
                let mut score = Score::default();
                while at < corpus.bytes.len() {
                    let next_checkpoint = checkpoints.peek().copied().unwrap_or(corpus.bytes.len());
                    let end = at.saturating_add(chunk).min(next_checkpoint).min(corpus.bytes.len());
                    run.feed(&corpus.bytes[at..end]);
                    at = end;
                    if at == next_checkpoint {
                        checkpoints.next();
                        if at < corpus.bytes.len() {
                            score.add(run.compare());
                        }
                    }
                }
                // Rotation at the end: the phone's grid changes once and back.
                let end_score = {
                    let mut s = run.compare();
                    let (c, r) = run.grid;
                    run.set_viewport(r.max(c), c.min(r).max(10));
                    s.add(run.compare());
                    run.set_viewport(c, r);
                    s.add(run.compare());
                    run.load_all();
                    s.add(run.compare());
                    s
                };
                score.add(end_score);
                row.cells += score.cells;
                row.cursor += score.cursor_mismatches;
                if compact {
                    row.compact += score.mismatched;
                } else {
                    row.exact += score.mismatched;
                }
                if compact && chunk == usize::MAX {
                    row.bytes_out += run.bytes_out;
                    row.resets += run.resets;
                }
                if !score.first.is_empty() && row.notes.len() < 12 {
                    let label = format!(
                        "phone {}x{}, chunk {}, {}",
                        grid.0,
                        grid.1,
                        if chunk == usize::MAX { "whole".into() } else { chunk.to_string() },
                        if compact { "compact" } else { "exact" }
                    );
                    for what in score.first.iter().take(3) {
                        row.notes.push(format!("{label}: {what}"));
                    }
                }
            }
        }
    }
    row
}

fn snapshot_of(cols: usize, rows: usize, bytes: &[u8]) -> Snapshot {
    let mut term = vt(cols, rows);
    term.vt_write(bytes);
    snapshot(&term)
}

/// Compact mode's glyph comparison: a rule run counts once, so a frame laid
/// out at the phone's width matches, and a lost run, a lost glyph or a
/// rule in another style still does not.
#[test]
fn the_glyph_comparison_counts_a_rule_run_once_and_still_sees_a_lost_one() {
    let mac = snapshot_of(20, 3, "╭──────╮ x\r\n═ ═".as_bytes());
    for (phone, matches) in [
        ("╭─╮ x\r\n═ ═", true),
        ("╭───╮ x\r\n═ ═", true),
        ("╭╮ x\r\n═ ═", false),
        ("╭\x1b[31m─\x1b[0m╮ x\r\n═ ═", false),
        ("╭─╮\r\n═ ═", false),
        ("╭─╮ x\r\n═", false),
    ] {
        let score = compare_glyphs(&mac, &snapshot_of(10, 3, phone.as_bytes()), false);
        assert_eq!(score.mismatched == 0, matches, "phone {phone:?}: {:?}", score.first);
    }
}

/// Claude Code's frame at the Mac's width, on a phone narrower than it, in
/// compact mode: the rules and the padding shrink, every glyph is there.
#[test]
fn a_frame_wider_than_the_phone_keeps_every_glyph_in_compact_mode() {
    let edge = |s: &str| format!("\x1b[38;5;174m{s}\x1b[0m");
    let frame = format!(
        "{}\r\n{} > hi{}{}\r\n{}\r\n$ ",
        edge(&format!("╭{}╮", "─".repeat(118))),
        edge("│"),
        " ".repeat(113),
        edge("│"),
        edge(&format!("╰{}╯", "─".repeat(118))),
    );
    for grid in PHONE_GRIDS {
        let mut run = Run::new((120, 40), grid, true);
        run.feed(frame.as_bytes());
        let score = run.compare();
        assert_eq!(score.mismatched, 0, "phone {grid:?}: {:?}", score.first);
    }
}

/// A space typed after a link closes (`link end`) is not in the link: the
/// phone's echo of it must not carry the link the phone's style still has.
#[test]
fn a_space_after_a_link_is_not_linked_on_the_phone() {
    let bytes = b"see \x1b]8;;https://example.com\x1b\\\x1b[34mlink\x1b[0m\x1b]8;;\x1b\\ end\r\n$ ";
    for chunk in [1, 2, 61] {
        let mut run = Run::new((120, 40), (33, 30), false);
        for part in bytes.chunks(chunk) {
            run.feed(part);
        }
        let score = run.compare();
        assert_eq!(score.mismatched, 0, "chunk {chunk}: {:?}", score.first);
    }
}

/// A row erased in a background, then written over in the default style,
/// wraps on the phone: the phone's autowrap and line feeds scroll new rows
/// in, which take the current background (BCE). Past the line's end the
/// phone has no background, as the Mac has none.
#[test]
fn a_background_never_spills_past_a_lines_end_on_the_phone() {
    let bytes = b"\x1b[41m\x1b[2K\x1b[0mred whole row erased, text after reset\r\n\x1b[7m inverse blank tail       \x1b[0m\r\n$ ";
    for chunk in [usize::MAX, 61, 1] {
        let mut run = Run::new((120, 40), (33, 3), false);
        // Rows the phone has scrolled past, so its writes scroll.
        run.feed(b"1\r\n2\r\n3\r\n4\r\n");
        for part in bytes.chunks(chunk.min(bytes.len())) {
            run.feed(part);
        }
        let score = run.compare();
        assert_eq!(score.mismatched, 0, "chunk {chunk}: {:?}", score.first);
        run.set_viewport(33, 30);
        let score = run.compare();
        assert_eq!(score.mismatched, 0, "chunk {chunk}, after a reset: {:?}", score.first);
    }
}

#[test]
fn projection_matches_the_macs_grid_cell_by_cell() {
    let corpora: Vec<Corpus> = synthetic().into_iter().chain(recorded()).collect();
    let mut table = String::from(
        "| corpus | host | bytes | cells compared | mismatched (exact) | mismatched (compact) | cursor | bytes to phone | resets |\n|---|---|---:|---:|---:|---:|---:|---:|---:|\n",
    );
    let mut json = Vec::new();
    let mut total = Row::default();
    let mut details = String::new();
    for corpus in &corpora {
        let row = run_corpus(corpus);
        let _ = writeln!(
            table,
            "| {} | {}x{} | {} | {} | {} | {} | {} | {} | {} |",
            corpus.name,
            corpus.host.0,
            corpus.host.1,
            corpus.bytes.len(),
            row.cells,
            row.exact,
            row.compact,
            row.cursor,
            row.bytes_out,
            row.resets
        );
        json.push(format!(
            "{{\"corpus\":{:?},\"host\":\"{}x{}\",\"bytes\":{},\"cells\":{},\"exact\":{},\"compact\":{},\"cursor\":{}}}",
            corpus.name, corpus.host.0, corpus.host.1, corpus.bytes.len(), row.cells, row.exact, row.compact, row.cursor
        ));
        if !row.notes.is_empty() {
            let _ = writeln!(details, "\n{}:", corpus.name);
            for note in &row.notes {
                let _ = writeln!(details, "  {note}");
            }
        }
        total.cells += row.cells;
        total.exact += row.exact;
        total.compact += row.compact;
        total.cursor += row.cursor;
    }
    let _ = writeln!(
        table,
        "| **total** | | | {} | {} | {} | {} | | |",
        total.cells, total.exact, total.compact, total.cursor
    );
    // The table last: a fleet log keeps the tail.
    if !details.is_empty() {
        println!("First mismatches:{details}");
    }
    println!("{table}");
    if let Ok(dir) = std::env::var("PARITY_OUT") {
        let dir = PathBuf::from(dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("parity.md"), format!("{table}\n{details}")).unwrap();
        std::fs::write(dir.join("parity.json"), format!("[{}]\n", json.join(",\n"))).unwrap();
    }
    if std::env::var("PARITY_REPORT_ONLY").is_err() {
        assert_eq!(
            (total.exact, total.compact, total.cursor),
            (0, 0, 0),
            "the phone's projection differs from the Mac's grid (exact, compact, cursor mismatches); see the table above"
        );
    }
}

// ---------------------------------------------------------------------------
// Resize equivalence.
//
// Leo, 2026-11-22: "i mean it's not about testing it on the mac, but rather
// on the phone and whatever behaviours we'd want there, i.e. that the
// resizing behaviour is indeed the same as it would've been if the recalc
// and resize had truly happened on the mac."
//
// The same byte stream two ways, at each phone size of a rotation and
// keyboard sequence:
//
// - (a) the phone path: the Mac's PTY keeps its grid; the projection writes
//   the phone's N by M view (the app's surface is `phone`).
// - (b) a real resize: the Mac's terminal resizes to N by M (Ghostty's own
//   reflow, what the Mac pane does on a PTY resize), then the program's
//   redraw at N by M (a shell reprints its prompt line; a full-screen TUI
//   repaints).
//
// On the primary screen the two grids must match cell by cell: every row of
// the screen and of scrollback (aligned at the bottom), its glyph, width,
// colors, attributes, link flag and soft-wrap flag, and the cursor. On the
// alternate screen the phone shows the Mac's own grid by design (the scaled
// view; "Fit to Phone" is the real resize), so there it is compared with the
// unresized Mac, and the primary screen it returns to is compared with (b).

/// Sizes the phone's terminal takes at 12 pt (a 7.2 by 15.6 pt cell, 6 pt
/// side padding): iPhone portrait 52x38, its keyboard up 52x20, landscape
/// 112x17, its keyboard up 112x7, a small phone 43x33, the largest text
/// 33x30, and a grid wider than the Mac's (an iPad) 140x50.
const SEQUENCES: [(&str, &[(usize, usize)]); 3] = [
    ("rotate+keyboard", &[(52, 38), (52, 20), (52, 38), (112, 17), (112, 7), (52, 38)]),
    ("small+large text", &[(43, 33), (33, 30), (43, 33)]),
    ("wider than the Mac", &[(140, 50), (52, 38)]),
];

type Redraw = Box<dyn Fn(usize, usize) -> Vec<u8>>;

struct ResizeCase {
    name: String,
    host: (usize, usize),
    before: Vec<u8>,
    /// The program's own bytes after a resize to (cols, rows).
    redraw: Redraw,
    /// Width-independent bytes after the last resize.
    after: Vec<u8>,
    note: &'static str,
}

fn no_redraw() -> Redraw {
    Box::new(|_, _| Vec::new())
}

/// A shell's redraw of its prompt line on SIGWINCH, the way a correct line
/// editor does it: back to the start of the line at the new width, clear to
/// the end of the screen, reprint prompt and buffer.
fn prompt_redraw(line: &'static str) -> Redraw {
    Box::new(move |cols, _| {
        let width = unicode_width::UnicodeWidthStr::width(line);
        let up = width.saturating_sub(1) / cols.max(1);
        let mut out = String::from("\r");
        if up > 0 {
            out += &format!("\x1b[{up}A");
        }
        out += "\x1b[J";
        out += line;
        out.into_bytes()
    })
}

/// A full-screen TUI that lays itself out for its grid.
fn tui_frame(cols: usize, rows: usize) -> Vec<u8> {
    let mut out = String::from("\x1b[H\x1b[2J");
    let title = format!(" PID USER %CPU COMMAND {cols}x{rows} ");
    out += &format!("\x1b[1;1H\x1b[7m{title:<cols$}\x1b[0m");
    for i in 0..rows.saturating_sub(2) {
        let cmd = format!("process-{i} ✔ 中文");
        let line = format!("{:5} user {:4.1} ", 1000 + i, (i * 7 % 100) as f32);
        out += &format!("\x1b[{};1H{line}\x1b[32m{cmd}\x1b[0m", i + 2);
    }
    out += &format!("\x1b[{rows};1H\x1b[44m status 👍 \x1b[K\x1b[0m\x1b[2;1H");
    out.into_bytes()
}

fn resize_cases() -> Vec<ResizeCase> {
    let mut out = Vec::new();

    // Shell soft-wrap reflow: long soft-wrapped output, styled wraps, and a
    // prompt line short enough to fit every width.
    let mut sh = String::new();
    sh += "$ cat notes.txt\r\n";
    for i in 0..12 {
        sh += &format!(
            "{i:02} {}\r\n",
            "the quick brown fox jumps over the lazy dog ".repeat(i % 5 + 1)
        );
    }
    sh += "\x1b[1;31mred bold run that wraps across the phone's edge and on past the Mac's own edge as well, twice over\x1b[0m\r\n";
    sh += "hard\r\nlines\r\n";
    let line = "$ echo hi";
    sh += line;
    out.push(ResizeCase {
        name: "shell_soft_wrap_reflow".into(),
        host: (120, 40),
        before: sh.into_bytes(),
        redraw: prompt_redraw(line),
        after: s("\r\nhi\r\n$ "),
        note: "",
    });

    // A typed command longer than the phone: the shell's prompt line wraps
    // at the phone's width and the shell redraws it there.
    let typed = "$ git commit -m 'projection keeps the Mac grid and rewraps it here'";
    out.push(ResizeCase {
        name: "shell_prompt_longer_than_phone".into(),
        host: (120, 40),
        before: format!("$ ls\r\nREADME.md  src\r\n{typed}").into_bytes(),
        redraw: prompt_redraw(typed),
        after: Vec::new(),
        note: "",
    });

    // Wide chars, emoji, symbols, colors and attributes across the phone's
    // edges.
    let mut w = String::new();
    for cut in [31, 42, 51, 53, 111] {
        w += &"b".repeat(cut);
        w += "日本語のテキストと한국어 텍스트 中文\r\n";
    }
    w += "emoji 👍 👍🏽 👨‍👩‍👧‍👦 🏳️‍🌈 ❤️ 1️⃣ ";
    w += &"🙂".repeat(40);
    w += "\r\n";
    w += "symbols ✔ ✘ ⚠ → ← ⏺ ⎿ ● │ ─ ┌┐└┘ ╭╮╰╯  λ ∑ ≠ ≤ ∞ ";
    w += &"═".repeat(100);
    w += "\r\n";
    for (i, sgr) in [
        "1",
        "2",
        "3",
        "4",
        "4:3",
        "5",
        "7",
        "9",
        "38;5;208",
        "48;5;24",
        "38;2;255;128;0",
        "48;2;10;20;30;1",
    ]
    .iter()
    .enumerate()
    {
        w += &format!("\x1b[{sgr}m{} {}\x1b[0m\r\n", sgr, "styled ".repeat(4 + i * 2));
    }
    w += "$ ";
    out.push(ResizeCase {
        name: "wide_emoji_symbols_colors".into(),
        host: (120, 40),
        before: w.into_bytes(),
        redraw: prompt_redraw("$ "),
        after: Vec::new(),
        note: "",
    });

    // Scrollback: many screens of every line length, styled.
    let mut sb = String::new();
    for i in 0..1500 {
        let len = (i * 37) % 300;
        sb += &format!("\x1b[3{}m{i:05}\x1b[0m {}\r\n", i % 8, "·".repeat(len));
    }
    sb += "$ ";
    out.push(ResizeCase {
        name: "scrollback".into(),
        host: (120, 40),
        before: sb.into_bytes(),
        redraw: prompt_redraw("$ "),
        after: Vec::new(),
        note: "",
    });

    // A full-screen TUI on the alternate screen, resized while it runs, then
    // quit back to the shell.
    let mut t = s("$ for i in 1 2 3; do echo line $i of the output before the TUI opens; done\r\n");
    for i in 1..=3 {
        t.extend(s(&format!("line {i} of the output before the TUI opens\r\n")));
    }
    t.extend(s("$ top\r\n\x1b[?1049h"));
    t.extend(tui_frame(120, 40));
    out.push(ResizeCase {
        name: "full_screen_tui".into(),
        host: (120, 40),
        before: t,
        redraw: Box::new(tui_frame),
        after: s("\x1b[?1049l$ echo back\r\nback\r\n$ "),
        note: "alternate screen: the phone shows the Mac's grid (scaled view); the shell it returns to is compared with the resize",
    });

    // Every parity corpus and recording, as a byte stream a resize reflows
    // with no redraw of its own (output already printed). The Claude Code
    // recordings are here: its own SIGWINCH redraw of the live region is not
    // recorded.
    for corpus in synthetic().into_iter().chain(recorded()) {
        let note = if corpus.name.contains("claude") {
            "the CLI's own redraw on resize is not recorded: reflow of what it printed"
        } else {
            ""
        };
        out.push(ResizeCase {
            name: corpus.name,
            host: corpus.host,
            before: corpus.bytes,
            redraw: no_redraw(),
            after: Vec::new(),
            note,
        });
    }
    out
}

/// The grid as a real terminal holds it: every row (scrollback, then the
/// screen) aligned at the bottom, cell by cell, with wrap flags, and the
/// cursor counted from the bottom.
fn compare_grid(mac: &Snapshot, phone: &Snapshot) -> Score {
    let mut score = Score::default();
    let (m, p) = (&mac.rows, &phone.rows);
    let both = m.len().min(p.len());
    let extra = |rows: &[(Vec<Read>, bool)]| -> usize {
        rows.iter()
            .map(|(cells, _)| cells.iter().filter(|c| !Key::of(c).is_default_blank()).count())
            .sum()
    };
    let (m_extra, p_extra) = (extra(&m[..m.len() - both]), extra(&p[..p.len() - both]));
    if m_extra + p_extra > 0 {
        score.mismatched += m_extra + p_extra;
        score.cells += m_extra + p_extra;
        score.note(format!(
            "rows: mac {} / phone {} ({} and {} non-blank cells unmatched above)",
            m.len(),
            p.len(),
            m_extra,
            p_extra
        ));
        // Where the two part: the first row from the top whose text differs.
        let text = |r: &(Vec<Read>, bool)| -> String {
            r.0.iter().map(|c| Key::of(c).text).collect::<String>().trim_end().to_string()
        };
        if let Some(i) = (0..both).find(|&i| text(&m[i]) != text(&p[i])) {
            let show = |rows: &[(Vec<Read>, bool)]| -> String {
                rows[i.saturating_sub(1)..(i + 2).min(rows.len())]
                    .iter()
                    .map(|r| format!("{:?}{}", text(r), if r.1 { " (soft)" } else { "" }))
                    .collect::<Vec<_>>()
                    .join(" | ")
            };
            score.note(format!(
                "first parting row {i} from the top:\n      mac   {}\n      phone {}",
                show(m),
                show(p)
            ));
        }
    }
    let blank = Key::of(&(Cell::default(), false));
    for i in 1..=both {
        let (mr, pr) = (&m[m.len() - i], &p[p.len() - i]);
        let width = mr.0.len().max(pr.0.len());
        let from_bottom = i - 1;
        let mut row_bad = 0;
        for x in 0..width {
            let a = mr.0.get(x).map(Key::of).unwrap_or_else(|| blank.clone());
            let b = pr.0.get(x).map(Key::of).unwrap_or_else(|| blank.clone());
            score.cells += 1;
            if a != b {
                score.mismatched += 1;
                if row_bad == 0 {
                    score.note(format!(
                        "row {from_bottom} from bottom, col {x}: mac {} / phone {}\n      mac   {:?}\n      phone {:?}",
                        a.label(),
                        b.label(),
                        mr.0.iter().map(|c| Key::of(c).text).collect::<String>().trim_end(),
                        pr.0.iter().map(|c| Key::of(c).text).collect::<String>().trim_end(),
                    ));
                }
                row_bad += 1;
            }
        }
        if mr.1 != pr.1 {
            score.mismatched += 1;
            score.note(format!(
                "row {from_bottom} from bottom: soft wrap mac {} / phone {}",
                mr.1, pr.1
            ));
        }
    }
    let at = |s: &Snapshot| (s.rows.len() - 1 - s.cursor.0, s.cursor.1, s.cursor_visible);
    if at(mac) != at(phone) {
        score.cursor_mismatches += 1;
        score.note(format!(
            "cursor (rows from bottom, col, visible): mac {:?} / phone {:?}",
            at(mac),
            at(phone)
        ));
    }
    score
}

#[derive(Default)]
struct ResizeRow {
    steps: usize,
    passed: usize,
    cells: usize,
    mismatched: usize,
    compact_mismatched: usize,
    cursor: usize,
    notes: Vec<String>,
}

fn run_resize_case(case: &ResizeCase) -> ResizeRow {
    let mut row = ResizeRow::default();
    for (label, sizes) in SEQUENCES {
        for compact in [false, true] {
            // (a) the phone path, and the unresized Mac it projects.
            let mut run = Run::new(case.host, sizes[0], compact);
            run.feed(&case.before);
            // (b) the Mac resized for real.
            let mut resized = vt(case.host.0, case.host.1);
            resized.vt_write(&case.before);
            let total = sizes.len() + 1;
            for step in 0..total {
                let last = step == sizes.len();
                if last {
                    run.feed(&case.after);
                    resized.vt_write(&case.after);
                } else {
                    let (cols, rows) = sizes[step];
                    if step > 0 {
                        run.set_viewport(cols, rows);
                    }
                    let _ = resized.resize(cols as u16, rows as u16, 0, 0);
                    let redraw = (case.redraw)(cols, rows);
                    resized.vt_write(&redraw);
                    // The program's redraw reaches the unresized Mac's PTY
                    // only under a real resize; path (a) sends none.
                }
                run.load_all();
                let mac = snapshot(&resized);
                let phone = snapshot(&run.phone);
                let score = if mac.alternate || phone.alternate {
                    if mac.alternate != phone.alternate {
                        let mut s = Score { cells: 1, mismatched: 1, ..Score::default() };
                        s.note(format!(
                            "screen: mac alternate {} / phone {}",
                            mac.alternate, phone.alternate
                        ));
                        s
                    } else {
                        compare_alternate(&snapshot(&run.mac), &phone)
                    }
                } else if compact {
                    let mut s = compare_glyphs(&mac, &phone, false);
                    s.cursor_mismatches = 0;
                    s
                } else {
                    compare_grid(&mac, &phone)
                };
                let size = if last {
                    "after".to_string()
                } else {
                    format!("{}x{}", sizes[step].0, sizes[step].1)
                };
                row.steps += 1;
                row.cells += score.cells;
                row.cursor += score.cursor_mismatches;
                if compact {
                    row.compact_mismatched += score.mismatched;
                } else {
                    row.mismatched += score.mismatched;
                }
                if score.mismatched == 0 && score.cursor_mismatches == 0 {
                    row.passed += 1;
                } else if row.notes.len() < 8 {
                    let mode = if compact { "compact" } else { "exact" };
                    for what in score.first.iter().take(2) {
                        row.notes.push(format!("{label} {mode} step {step} ({size}): {what}"));
                    }
                }
            }
        }
    }
    row
}

#[test]
fn projection_matches_a_real_resize_cell_by_cell() {
    let cases = resize_cases();
    let mut table = String::from(
        "| case | host | steps passed | cells compared | mismatched (grid, exact) | mismatched (glyphs, compact) | cursor | result | note |\n|---|---|---:|---:|---:|---:|---:|---|---|\n",
    );
    let mut json = Vec::new();
    let mut details = String::new();
    let (mut failed, mut steps, mut passed) = (0, 0, 0);
    for case in &cases {
        let row = run_resize_case(case);
        let ok = row.passed == row.steps;
        failed += usize::from(!ok);
        steps += row.steps;
        passed += row.passed;
        let _ = writeln!(
            table,
            "| {} | {}x{} | {}/{} | {} | {} | {} | {} | {} | {} |",
            case.name,
            case.host.0,
            case.host.1,
            row.passed,
            row.steps,
            row.cells,
            row.mismatched,
            row.compact_mismatched,
            row.cursor,
            if ok { "pass" } else { "FAIL" },
            case.note
        );
        json.push(format!(
            "{{\"case\":{:?},\"host\":\"{}x{}\",\"steps\":{},\"passed\":{},\"cells\":{},\"exact\":{},\"compact\":{},\"cursor\":{},\"pass\":{}}}",
            case.name, case.host.0, case.host.1, row.steps, row.passed, row.cells, row.mismatched, row.compact_mismatched, row.cursor, ok
        ));
        if !row.notes.is_empty() {
            let _ = writeln!(details, "\n{}:", case.name);
            for note in &row.notes {
                let _ = writeln!(details, "  {note}");
            }
        }
    }
    let _ = writeln!(
        table,
        "| **total** | | {passed}/{steps} | | | | | {} of {} cases pass | |",
        cases.len() - failed,
        cases.len()
    );
    if !details.is_empty() {
        println!("First resize mismatches:{details}");
    }
    println!(
        "Resize equivalence (phone projection vs a real resize of the Mac's terminal):\n{table}"
    );
    if let Ok(dir) = std::env::var("PARITY_OUT") {
        let dir = PathBuf::from(dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("resize.md"), format!("{table}\n{details}")).unwrap();
        std::fs::write(dir.join("resize.json"), format!("[{}]\n", json.join(",\n"))).unwrap();
    }
    if std::env::var("PARITY_REPORT_ONLY").is_err() {
        assert_eq!(
            failed, 0,
            "{failed} resize-equivalence cases differ from a real resize; see the table above"
        );
    }
}

// ---------------------------------------------------------------------------
// What one scroll step costs.
//
// Leo, 2026-11-22: "the scroll occurs or whatever on f***ing mac / then it
// delays on my actual iphone display. thats the asinine part."
//
// `claude_code_scroll.vt` is a real Claude Code session (2.1.330, fullscreen
// renderer, `CLAUDE_CODE_NO_FLICKER=1`, 120x40 PTY): a long reply, then 30
// mouse-wheel steps up, 30 down, 8 PageUp and 8 PageDown, one input every
// ~500 ms. `claude_code_scroll.steps` lists every PTY read as it came:
// `t_ms offset len phase`, so a read is one write batch the Mac forwards.
// This test replays it read by read through the Mac's terminal and the
// projection (phone 54x38, compact) and reports, per scroll step, the bytes
// and batches, the rows the step wrote and changed, and whether it scrolled a
// region (DECSTBM with SU/SD or IND/RI) or rewrote the rows.

/// Escape-sequence counts and the rows written, from the bytes alone.
#[derive(Default)]
struct StepBytes {
    stbm: usize,
    su_sd: usize,
    ind_ri: usize,
    rows_written: std::collections::BTreeSet<i64>,
}

fn scan_step(bytes: &[u8], mut row: i64, rows: i64) -> (StepBytes, i64) {
    let mut out = StepBytes::default();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == 0x1b && i + 1 < bytes.len() {
            match bytes[i + 1] {
                b'[' => {
                    let mut j = i + 2;
                    let start = j;
                    while j < bytes.len() && (0x20..0x40).contains(&bytes[j]) {
                        j += 1;
                    }
                    let Some(&fin) = bytes.get(j) else { break };
                    let params = std::str::from_utf8(&bytes[start..j]).unwrap_or("");
                    let private = params.starts_with(['?', '<', '>', '=']);
                    let n = |k: usize| -> i64 {
                        params
                            .split(';')
                            .nth(k)
                            .and_then(|p| p.parse().ok())
                            .filter(|&v| v > 0)
                            .unwrap_or(1)
                    };
                    if !private {
                        match fin {
                            b'r' => out.stbm += 1,
                            b'S' | b'T' => out.su_sd += 1,
                            b'H' | b'f' => row = n(0) - 1,
                            b'd' => row = n(0) - 1,
                            b'A' => row -= n(0),
                            b'B' | b'e' => row += n(0),
                            b'E' => row += n(0),
                            b'F' => row -= n(0),
                            _ => {}
                        }
                        row = row.clamp(0, rows - 1);
                    }
                    i = j + 1;
                    continue;
                }
                b']' | b'P' | b'_' | b'^' => {
                    // String sequences: up to BEL or ST.
                    let mut j = i + 2;
                    while j < bytes.len()
                        && bytes[j] != 0x07
                        && !(bytes[j] == 0x1b && bytes.get(j + 1) == Some(&b'\\'))
                    {
                        j += 1;
                    }
                    i = j + if bytes.get(j) == Some(&0x07) { 1 } else { 2 };
                    continue;
                }
                b'D' | b'M' => {
                    out.ind_ri += 1;
                    row = (row + if bytes[i + 1] == b'D' { 1 } else { -1 }).clamp(0, rows - 1);
                    i += 2;
                    continue;
                }
                b'E' => {
                    row = (row + 1).min(rows - 1);
                    i += 2;
                    continue;
                }
                _ => {
                    i += 2;
                    continue;
                }
            }
        }
        match b {
            b'\n' | 0x0b | 0x0c => row = (row + 1).min(rows - 1),
            0x00..=0x1f | 0x7f => {}
            _ => {
                out.rows_written.insert(row);
            }
        }
        i += 1;
    }
    (out, row)
}

fn screen_rows(term: &Vt) -> Vec<String> {
    let snap = snapshot(term);
    let top = snap.rows.len().saturating_sub(usize::from(term.rows()));
    snap.rows[top..]
        .iter()
        .map(|(cells, _)| cells.iter().map(|r| format!("{:?}", Key::of(r))).collect())
        .collect()
}

fn pct(sorted: &[usize], p: f64) -> usize {
    if sorted.is_empty() {
        return 0;
    }
    let i = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted[i.min(sorted.len() - 1)]
}

#[test]
fn a_claude_code_scroll_step_costs() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/parity/real");
    let bytes = std::fs::read(dir.join("claude_code_scroll.vt")).unwrap();
    let steps = std::fs::read_to_string(dir.join("claude_code_scroll.steps")).unwrap();
    let host = (120usize, 40usize);
    let phone_grid = (54usize, 38usize);
    let mut reads: Vec<(f64, usize, usize, String)> = Vec::new();
    for line in steps.lines().filter(|l| !l.starts_with('#') && !l.trim().is_empty()) {
        let mut f = line.split_whitespace();
        let t: f64 = f.next().unwrap().parse().unwrap();
        let off: usize = f.next().unwrap().parse().unwrap();
        let len: usize = f.next().unwrap().parse().unwrap();
        reads.push((t, off, len, f.next().unwrap().to_string()));
    }
    assert_eq!(
        reads.iter().map(|r| r.2).sum::<usize>(),
        bytes.len(),
        "the steps file covers the recording"
    );

    let mut run = Run::new(host, phone_grid, true);
    #[derive(Default)]
    struct Step {
        name: String,
        bytes: usize,
        batches: usize,
        phone_bytes: usize,
        phone_batches: usize,
        rows_written: usize,
        rows_changed: usize,
        stbm: usize,
        su_sd: usize,
        ind_ri: usize,
        span_ms: f64,
    }
    let mut out: Vec<Step> = Vec::new();
    let mut row: i64 = 0;
    let mut i = 0;
    while i < reads.len() {
        let phase = reads[i].3.clone();
        let scroll = phase.starts_with("wheel_") || phase.starts_with("page");
        let before = scroll.then(|| screen_rows(&run.mac));
        let mut step = Step { name: phase.clone(), ..Step::default() };
        let t0 = reads[i].0;
        let mut chunk = Vec::new();
        while i < reads.len() && reads[i].3 == phase {
            let (t, off, len, _) = &reads[i];
            let data = &bytes[*off..*off + *len];
            chunk.extend_from_slice(data);
            let out_before = run.bytes_out;
            run.mac.vt_write(data);
            let segments = run.projection.feed(data, true);
            step.phone_batches += segments
                .iter()
                .filter(|s| matches!(s, Segment::Paint(b) | Segment::Raw(b) | Segment::Reset(b) if !b.is_empty()))
                .count()
                .min(1);
            run.apply(segments);
            let _ = run.projection.take_replies();
            step.phone_bytes += run.bytes_out - out_before;
            step.bytes += len;
            step.batches += 1;
            step.span_ms = t - t0;
            i += 1;
        }
        let (scan, next_row) = scan_step(&chunk, row, host.1 as i64);
        row = next_row;
        if let Some(before) = before {
            let after = screen_rows(&run.mac);
            step.rows_changed = before.iter().zip(&after).filter(|(a, b)| a != b).count();
            step.rows_written = scan.rows_written.len();
            step.stbm = scan.stbm;
            step.su_sd = scan.su_sd;
            step.ind_ri = scan.ind_ri;
            out.push(step);
        }
    }
    assert!(out.len() >= 60, "the recording has its scroll steps ({})", out.len());

    let mut table = String::from(
        "| step | bytes | batches | bytes to phone | phone batches | rows written | rows changed | DECSTBM | SU/SD | IND/RI | span ms |\n|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n",
    );
    for s in &out {
        let _ = writeln!(
            table,
            "| {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {:.1} |",
            s.name,
            s.bytes,
            s.batches,
            s.phone_bytes,
            s.phone_batches,
            s.rows_written,
            s.rows_changed,
            s.stbm,
            s.su_sd,
            s.ind_ri,
            s.span_ms
        );
    }
    let mut summary = String::from(
        "| per scroll step | p50 | p95 | max | per minute at 1 step / 16 ms (p50 / max) |\n|---|---:|---:|---:|---:|\n",
    );
    let col = |f: &dyn Fn(&Step) -> usize| {
        let mut v: Vec<usize> = out.iter().map(f).collect();
        v.sort_unstable();
        (pct(&v, 0.5), pct(&v, 0.95), *v.last().unwrap())
    };
    let per_min = 60_000.0 / 16.0;
    for (name, f, rate) in [
        ("PTY bytes (Mac forwards)", &(|s: &Step| s.bytes) as &dyn Fn(&Step) -> usize, true),
        ("PTY write batches", &|s: &Step| s.batches, true),
        ("bytes to phone (projection)", &|s: &Step| s.phone_bytes, true),
        ("phone batches", &|s: &Step| s.phone_batches, true),
        ("rows written (of 40)", &|s: &Step| s.rows_written, false),
        ("rows changed (of 40)", &|s: &Step| s.rows_changed, false),
        ("DECSTBM", &|s: &Step| s.stbm, false),
        ("SU/SD", &|s: &Step| s.su_sd, false),
        ("IND/RI", &|s: &Step| s.ind_ri, false),
    ] {
        let (p50, p95, max) = col(f);
        let rate = if rate {
            format!("{:.0} / {:.0}", p50 as f64 * per_min, max as f64 * per_min)
        } else {
            String::new()
        };
        let _ = writeln!(summary, "| {name} | {p50} | {p95} | {max} | {rate} |");
    }
    let full = out.iter().filter(|s| s.rows_written >= host.1 - 4).count();
    let region = out.iter().filter(|s| s.stbm + s.su_sd + s.ind_ri > 0).count();
    let _ = writeln!(
        summary,
        "\n{} scroll steps; {} write {}+ of the {} rows (full-screen repaint); {} use a scroll region or SU/SD/IND/RI.",
        out.len(),
        full,
        host.1 - 4,
        host.1,
        region
    );
    println!("Claude Code scroll, per step:\n{table}");
    println!(
        "Claude Code scroll, summary (real recording, 120x40, phone {}x{} compact):\n{summary}",
        phone_grid.0, phone_grid.1
    );
    if let Ok(dir) = std::env::var("PARITY_OUT") {
        let dir = PathBuf::from(dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("scroll.md"), format!("{summary}\n{table}")).unwrap();
    }
}

// ---------------------------------------------------------------------------
// Phone-width parity: the phone shows what the Mac would draw at its width.
//
// Leo, 2026-11-25: "we know what a Mac's Claude code pane looks like. And we
// know it/can know it for any variation/combination at various phone sizes.
// [...] do everything at parity on the phone", "you obviously fit to phone by
// default? [...] why would the Mac on an iPhone connection ALWAYS be resized
// down anyways!?", and "I think we should be able to get best of both worlds
// correctness and speed".
//
// The target is each program run at the phone's grid from its start (what
// the Mac's pane would show had it been that size); the phone path is the
// projection of the same program run at the Mac's 120x40, its PTY never
// resized. On the primary screen, the phone's grid against the target's,
// every row of the screen and of scrollback, cell by cell, with wrap flags
// and the cursor (`compare_grid`), in compact mode (the default view; exact
// mode is Ghostty's reflow of the Mac's rows, reported for reference). On
// the alternate screen (vim, htop) the phone shows the Mac's grid scaled:
// only the app knows its frame at another width, and the only other route
// is resizing the Mac's pane, which the phone no longer does. Those steps
// are compared with the Mac's grid (`compare_alternate`). Target: 0
// mismatched cells per case and width.

/// iPhone grids at 12 pt: the largest text 33x30, a small phone 43x33,
/// portrait 52x38, landscape 112x17.
const PHONE_WIDTH_GRIDS: [(usize, usize); 4] = [(33, 30), (43, 33), (52, 38), (112, 17)];
const MAC_GRID: (usize, usize) = (120, 40);

/// Words wrapped at `width` columns (ASCII text), the way an Ink or ratatui
/// app wraps a paragraph itself.
fn wrap_words(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut lines = Vec::new();
    let mut line = String::new();
    for word in text.split(' ') {
        let mut word = word.to_string();
        while word.len() > width {
            if !line.is_empty() {
                lines.push(std::mem::take(&mut line));
            }
            let rest = word.split_off(width);
            lines.push(word);
            word = rest;
        }
        if line.is_empty() {
            line = word;
        } else if line.len() + 1 + word.len() <= width {
            line.push(' ');
            line += &word;
        } else {
            lines.push(std::mem::replace(&mut line, word));
        }
    }
    if !line.is_empty() {
        lines.push(line);
    }
    lines
}

/// An inline app's live region (Ink's log-update): erase the last frame's
/// rows, print what scrolled into the transcript, then the new frame. The
/// cursor rests at the end of the frame's last row.
struct Inline {
    last_rows: usize,
}

impl Inline {
    fn frame(&mut self, out: &mut String, history: &[String], frame: &[String]) {
        if self.last_rows > 0 {
            out.push_str("\x1b[2K");
            for _ in 1..self.last_rows {
                out.push_str("\x1b[1A\x1b[2K");
            }
            out.push('\r');
        }
        for line in history {
            out.push_str(line);
            out.push_str("\r\n");
        }
        out.push_str(&frame.join("\r\n"));
        self.last_rows = frame.len();
    }
}

const REPLY: &str = "The projection keeps the Mac grid and lays the primary screen out again at the phone width, so a shell and its output read the same on both screens. A full screen app is the hard part: it draws for one grid, and only the app knows how its frame looks at another width.";
const TOOL_OUT: &str = "test result: ok. 214 passed; 0 failed; 3 ignored; 0 measured; 0 filtered out; finished in 4.21s";

/// Claude Code's pane (model of its Ink layout): transcript paragraphs
/// wrapped at the width with a `⏺` gutter, a tool call with its `⎿` result
/// wrapped under a hanging indent, a rounded input box across the width, a status row;
/// typing redraws the box.
fn claude_code_pane(
    cols: usize,
    _rows: usize,
    typed_steps: &[&str],
    log: &[String],
) -> Vec<Vec<u8>> {
    let gutter = |first: &str, text: &str, color: &str| -> Vec<String> {
        wrap_words(text, cols.saturating_sub(2))
            .into_iter()
            .enumerate()
            .map(
                |(i, l)| {
                    if i == 0 { format!("{color}{first}\x1b[0m {l}") } else { format!("  {l}") }
                },
            )
            .collect()
    };
    // A tool's result: `⎿` and a hanging indent, wrapped at the width.
    let result = |text: &str| -> Vec<String> {
        wrap_words(text.trim(), cols.saturating_sub(5))
            .into_iter()
            .enumerate()
            .map(|(i, l)| if i == 0 { format!("  ⎿  {l}") } else { format!("     {l}") })
            .collect()
    };
    let frame = |typed: &str| -> Vec<String> {
        let inner = cols.saturating_sub(4);
        let mut rows =
            vec![String::new(), format!("\x1b[38;5;244m╭{}╮\x1b[0m", "─".repeat(cols - 2))];
        let lines = wrap_words(typed, inner.saturating_sub(2));
        let lines = if lines.is_empty() { vec![String::new()] } else { lines };
        for (i, l) in lines.iter().enumerate() {
            let lead = if i == 0 { "> " } else { "  " };
            rows.push(format!(
                "\x1b[38;5;244m│\x1b[0m {lead}{l:<w$} \x1b[38;5;244m│\x1b[0m",
                w = inner.saturating_sub(2)
            ));
        }
        rows.push(format!("\x1b[38;5;244m╰{}╯\x1b[0m", "─".repeat(cols - 2)));
        let left = "  ? for shortcuts";
        let right = "● high";
        let pad = cols.saturating_sub(left.len() + 6 + 1);
        rows.push(format!("\x1b[2m{left}{}{right}\x1b[0m", " ".repeat(pad)));
        rows
    };
    let mut app = Inline { last_rows: 0 };
    let mut steps = Vec::new();
    let mut out = String::from("\x1b[?25l");
    let mut history = vec![format!("\x1b[38;5;174m✻\x1b[0m Welcome to Claude Code"), String::new()];
    history.extend(gutter(">", "make the phone render the pane at its own width", "\x1b[2m"));
    history.push(String::new());
    history.extend(gutter("⏺", REPLY, "\x1b[37m"));
    history.push(String::new());
    history.extend(gutter("⏺", "Bash(cargo test -p cmux-terminal-projection)", "\x1b[32m"));
    history.extend(result(TOOL_OUT));
    app.frame(&mut out, &history, &frame(""));
    steps.push(std::mem::take(&mut out).into_bytes());
    let mut typed = String::new();
    for (i, step) in typed_steps.iter().enumerate() {
        typed.push_str(step);
        let lines: Vec<String> = if log.is_empty() {
            Vec::new()
        } else {
            let per = log.len() / typed_steps.len().max(1);
            log[i * per..(i + 1) * per].iter().flat_map(|l| result(l)).collect()
        };
        app.frame(&mut out, &lines, &frame(&typed));
        steps.push(std::mem::take(&mut out).into_bytes());
    }
    steps
}

/// Codex's pane (model of its ratatui inline viewport): `•` history cells
/// wrapped at the width, a composer with a `›` lead on a tinted background
/// across the width, a key-hint footer.
fn codex_pane(cols: usize, _rows: usize, typed_steps: &[&str]) -> Vec<Vec<u8>> {
    let cell = |text: &str| -> Vec<String> {
        wrap_words(text, cols.saturating_sub(2))
            .into_iter()
            .enumerate()
            .map(|(i, l)| if i == 0 { format!("\x1b[1m•\x1b[0m {l}") } else { format!("  {l}") })
            .collect()
    };
    let frame = |typed: &str| -> Vec<String> {
        let mut rows = vec![String::new()];
        let lines = wrap_words(typed, cols.saturating_sub(3));
        let lines = if lines.is_empty() { vec![String::new()] } else { lines };
        for (i, l) in lines.iter().enumerate() {
            let lead = if i == 0 { "› " } else { "  " };
            rows.push(format!("\x1b[48;5;236m {lead}{l:<w$}\x1b[0m", w = cols.saturating_sub(3)));
        }
        rows.push(String::new());
        let hint = "  ⏎ send   ⌃J newline   ⌃T transcript   ⌃C quit";
        let hint: String = hint.chars().take(cols).collect();
        rows.push(format!("\x1b[2m{hint}\x1b[0m"));
        rows
    };
    let mut app = Inline { last_rows: 0 };
    let mut steps = Vec::new();
    let mut out = String::from("\x1b[?25l");
    let mut history = vec![">_ OpenAI Codex (v0.63.0)".to_string(), String::new()];
    history.extend(cell("make the phone render the pane at its own width"));
    history.push(String::new());
    history.extend(cell(REPLY));
    app.frame(&mut out, &history, &frame(""));
    steps.push(std::mem::take(&mut out).into_bytes());
    let mut typed = String::new();
    for step in typed_steps {
        typed.push_str(step);
        app.frame(&mut out, &[], &frame(&typed));
        steps.push(std::mem::take(&mut out).into_bytes());
    }
    steps
}

/// vim on the alternate screen: a file whose long lines vim wraps at the
/// width, `~` past its end, a reversed status line with the position right
/// aligned, insert mode typing, then `:q` back to the shell.
fn vim(cols: usize, rows: usize, typed_steps: &[&str]) -> Vec<Vec<u8>> {
    let file: Vec<String> = (0..12)
        .map(|i| format!("{i:02} {}", "let projection = phone.width(); ".repeat(i % 4 + 1)))
        .collect();
    let paint = |first: &str, mode: &str| -> String {
        let mut out = String::from("\x1b[H\x1b[2J");
        let mut screen: Vec<String> = Vec::new();
        for (i, line) in file.iter().enumerate() {
            let line = if i == 0 { format!("{first}{line}") } else { line.clone() };
            let mut rest = line.as_str();
            while !rest.is_empty() {
                let take = rest.len().min(cols);
                screen.push(rest[..take].to_string());
                rest = &rest[take..];
            }
        }
        let body = rows - 2;
        screen.truncate(body);
        while screen.len() < body {
            screen.push("\x1b[34m~\x1b[0m".to_string());
        }
        for (y, line) in screen.iter().enumerate() {
            out += &format!("\x1b[{};1H{line}", y + 1);
        }
        let name = " src/project.rs [+]";
        let pos = format!("1,{}  All ", first.len() + 1);
        let pad = cols.saturating_sub(name.len() + pos.len());
        out += &format!("\x1b[{};1H\x1b[7m{name}{}{pos}\x1b[0m", rows - 1, " ".repeat(pad));
        out += &format!("\x1b[{rows};1H\x1b[1m{mode}\x1b[0m\x1b[K");
        out += &format!("\x1b[1;{}H", first.len() + 1);
        out
    };
    let mut steps = vec![s(&format!("$ vim src/project.rs\r\n\x1b[?1049h{}", paint("", "")))];
    let mut typed = String::new();
    for step in typed_steps {
        typed.push_str(step);
        steps.push(paint(&typed, "-- INSERT --").into_bytes());
    }
    steps.push(s("\x1b[?1049l$ "));
    steps
}

/// htop: header meters sized to the width, the process table, a refresh,
/// then `q`.
fn htop(cols: usize, rows: usize) -> Vec<Vec<u8>> {
    let paint = |tick: usize| -> String {
        let mut out = String::from("\x1b[H\x1b[2J");
        let bar = cols.saturating_sub(10);
        for cpu in 0..2 {
            let used = (bar * (30 + 20 * cpu + tick * 7)) / 100;
            out += &format!(
                "\x1b[{};1H{cpu:>2}[\x1b[32m{}\x1b[0m{}{:>4.1}%]",
                cpu + 1,
                "|".repeat(used.min(bar)),
                " ".repeat(bar - used.min(bar)),
                (30 + 20 * cpu + tick * 7) as f32
            );
        }
        let title = format!(
            "{:<w$}",
            "  PID USER      PRI  NI  VIRT   RES S CPU% MEM%   TIME+  Command",
            w = cols
        );
        let title: String = title.chars().take(cols).collect();
        out += &format!("\x1b[4;1H\x1b[30;42m{title}\x1b[0m");
        for i in 0..rows.saturating_sub(6) {
            let line = format!(
                "{:5} cmux       20   0 {:4}M {:4}M S {:4.1}  0.{i}  0:0{}.{:02} /usr/bin/cmux-process-{i} --flag",
                1000 + i,
                400 + i,
                90 + i,
                ((i * 7 + tick) % 100) as f32,
                i % 10,
                (i * 13 + tick) % 60
            );
            let line: String = line.chars().take(cols).collect();
            out += &format!("\x1b[{};1H{line}", i + 5);
        }
        let keys = "F1Help  F2Setup F3Search F4Filter F5Tree  F6SortBy F9Kill  F10Quit";
        let keys: String = keys.chars().take(cols).collect();
        out += &format!("\x1b[{rows};1H\x1b[30;46m{keys}\x1b[0m\x1b[K");
        out
    };
    vec![
        s(&format!("$ htop\r\n\x1b[?1049h\x1b[?25l{}", paint(0))),
        paint(1).into_bytes(),
        s("\x1b[?25h\x1b[?1049l$ "),
    ]
}

/// A long log a shell prints (no redraw of its own): every line length up
/// to 2.5 Mac widths, styled.
fn long_wrapped_log() -> Vec<Vec<u8>> {
    let mut steps = Vec::new();
    for block in 0..4 {
        let mut out = String::new();
        for i in block * 300..(block + 1) * 300 {
            let len = (i * 37) % 300;
            out += &format!("\x1b[3{}m{i:05}\x1b[0m {}\r\n", i % 8, "log-entry ".repeat(len / 10));
        }
        steps.push(out.into_bytes());
    }
    steps.push(s("$ "));
    steps
}

/// The duress log: about 400 KB of tool output (one second of a busy
/// build at 400 KB/s) streamed above Claude Code's input box while the
/// person types into it.
fn duress_log() -> Vec<String> {
    let mut log = Vec::new();
    let mut bytes = 0;
    let mut i = 0usize;
    while bytes < 400 << 10 {
        let line = format!(
            "   Compiling crate-{i:05} v0.{}.{} (/src/crates/crate-{i:05}) warning: unused {}",
            i % 9,
            i % 31,
            "x".repeat(i % 50)
        );
        bytes += line.len() + 8;
        log.push(line);
        i += 1;
    }
    log
}

struct WidthCase {
    name: &'static str,
    /// The program's output at a grid, as steps compared after each.
    program: Box<dyn Fn(usize, usize) -> Vec<Vec<u8>>>,
    /// Feed chunk for the phone path (bytes arrive in network reads).
    chunk: usize,
}

fn width_cases() -> Vec<WidthCase> {
    const TYPED: [&str; 4] = ["fix", " the", " parity", " at every width please"];
    let log = std::rc::Rc::new(duress_log());
    let duress_typed: Vec<&'static str> =
        "typing while the build streams".split_inclusive(' ').collect();
    vec![
        WidthCase {
            name: "claude_code_pane",
            program: Box::new(|c, r| claude_code_pane(c, r, &TYPED, &[])),
            chunk: 4096,
        },
        WidthCase {
            name: "codex_pane",
            program: Box::new(|c, r| codex_pane(c, r, &TYPED)),
            chunk: 4096,
        },
        WidthCase { name: "vim", program: Box::new(|c, r| vim(c, r, &TYPED)), chunk: 4096 },
        WidthCase { name: "htop", program: Box::new(htop), chunk: 4096 },
        WidthCase {
            name: "long_wrapped_log",
            program: Box::new(|_, _| long_wrapped_log()),
            chunk: 4096,
        },
        WidthCase {
            name: "duress_400KB_while_typing",
            program: Box::new(move |c, r| claude_code_pane(c, r, &duress_typed, &log)),
            chunk: 4096,
        },
    ]
}

#[derive(Default, Clone)]
struct WidthRow {
    steps: usize,
    cells: usize,
    /// Mismatched cells, the projection's exact mode.
    exact: usize,
    /// Mismatched cells, compact (the default).
    compact: usize,
    cursor: usize,
    bytes: usize,
    /// Wall time the projection took for the whole stream, compact (ms).
    feed_ms: f64,
    notes: Vec<String>,
}

fn run_width_case(case: &WidthCase, grid: (usize, usize)) -> WidthRow {
    let mut row = WidthRow::default();
    let mac_steps = (case.program)(MAC_GRID.0, MAC_GRID.1);
    let phone_steps = (case.program)(grid.0, grid.1);
    assert_eq!(mac_steps.len(), phone_steps.len(), "{}: steps differ by width", case.name);
    row.bytes = mac_steps.iter().map(Vec::len).sum();
    for compact in [false, true] {
        let mut run = Run::new(MAC_GRID, grid, compact);
        let mut target = vt(grid.0, grid.1);
        let mut spent = std::time::Duration::ZERO;
        for (i, (mac, phone)) in mac_steps.iter().zip(&phone_steps).enumerate() {
            for part in mac.chunks(case.chunk.max(1)) {
                let start = std::time::Instant::now();
                let segments = run.projection.feed(part, true);
                spent += start.elapsed();
                run.mac.vt_write(part);
                run.apply(segments);
                let _ = run.projection.take_replies();
            }
            target.vt_write(phone);
            run.load_all();
            let mac_now = snapshot(&run.mac);
            let score = if mac_now.alternate {
                // A full-screen app draws for one grid: the phone shows the
                // Mac's, scaled (only the app knows its frame at another
                // width, and the phone never resizes the Mac for it).
                compare_alternate(&mac_now, &snapshot(&run.phone))
            } else {
                compare_grid(&snapshot(&target), &snapshot(&run.phone))
            };
            row.steps += 1;
            row.cells += score.cells;
            if compact {
                row.cursor += score.cursor_mismatches;
            }
            if compact {
                row.compact += score.mismatched;
            } else {
                row.exact += score.mismatched;
            }
            let mode = if compact { "compact" } else { "exact" };
            let noted = row.notes.iter().filter(|n| n.contains(mode)).count();
            if (score.mismatched > 0 || score.cursor_mismatches > 0) && noted < 4 {
                for what in score.first.iter().take(2) {
                    row.notes.push(format!("{}x{} {mode} step {i}: {what}", grid.0, grid.1));
                }
            }
        }
        if compact {
            row.feed_ms = spent.as_secs_f64() * 1000.0;
        }
    }
    row
}

#[test]
fn phone_width_matches_the_program_drawn_at_the_phones_width() {
    let mut table = String::from(
        "| case | phone | bytes | steps | cells compared | mismatched (exact, info) | mismatched (compact, default) | cursor (compact) | projection ms (compact) |\n|---|---|---:|---:|---:|---:|---:|---:|---:|\n",
    );
    let mut json = Vec::new();
    let mut details = String::new();
    let mut bad = 0;
    for case in width_cases() {
        for grid in PHONE_WIDTH_GRIDS {
            let row = run_width_case(&case, grid);
            // Compact is the default view; exact is Ghostty's reflow of the
            // Mac's rows (the resize table pins it), reported for reference.
            bad += row.compact + row.cursor;
            let _ = writeln!(
                table,
                "| {} | {}x{} | {} | {} | {} | {} | {} | {} | {:.1} |",
                case.name,
                grid.0,
                grid.1,
                row.bytes,
                row.steps,
                row.cells,
                row.exact,
                row.compact,
                row.cursor,
                row.feed_ms
            );
            json.push(format!(
                "{{\"case\":{:?},\"phone\":\"{}x{}\",\"bytes\":{},\"cells\":{},\"exact\":{},\"compact\":{},\"cursor\":{},\"feed_ms\":{:.1}}}",
                case.name, grid.0, grid.1, row.bytes, row.cells, row.exact, row.compact, row.cursor, row.feed_ms
            ));
            if !row.notes.is_empty() {
                let _ = writeln!(details, "\n{} {}x{}:", case.name, grid.0, grid.1);
                for note in &row.notes {
                    let _ = writeln!(details, "  {note}");
                }
            }
        }
    }
    if !details.is_empty() {
        println!("First phone-width mismatches:{details}");
    }
    println!(
        "Phone-width parity (projection of the Mac's 120x40 vs the program drawn at the phone's grid):\n{table}"
    );
    if let Ok(dir) = std::env::var("PARITY_OUT") {
        let dir = PathBuf::from(dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("phone_width.md"), format!("{table}\n{details}")).unwrap();
        std::fs::write(dir.join("phone_width.json"), format!("[{}]\n", json.join(",\n"))).unwrap();
    }
    if std::env::var("PARITY_REPORT_ONLY").is_err() {
        assert_eq!(
            bad, 0,
            "the phone differs from the program drawn at its width; see the table above"
        );
    }
}

/// The duress row in real time: the same 400 KB build log streamed above
/// Claude Code's box while the person types, fed in 4 KB network reads paced
/// at 400 KB/s by the wall clock (the phone-width table replays the same
/// bytes as fast as it can). Reports the projection's time per read (p50,
/// p99, max) on the phone's side, the stream's wall time against its
/// 1-second budget, and the compact parity at the end of each step.
#[test]
fn duress_wall_clock_400kb_per_second_while_typing() {
    const RATE: f64 = 400.0 * 1024.0;
    const CHUNK: usize = 4096;
    let log = duress_log();
    let typed: Vec<&str> = "typing while the build streams".split_inclusive(' ').collect();
    let grid = (43, 33);
    let mac_steps = claude_code_pane(MAC_GRID.0, MAC_GRID.1, &typed, &log);
    let phone_steps = claude_code_pane(grid.0, grid.1, &typed, &log);
    let mut run = Run::new(MAC_GRID, grid, true);
    let mut target = vt(grid.0, grid.1);
    let mut per_read: Vec<f64> = Vec::new();
    let mut mismatched = 0;
    let mut sent = 0usize;
    let began = std::time::Instant::now();
    for (mac, phone) in mac_steps.iter().zip(&phone_steps) {
        for part in mac.chunks(CHUNK) {
            // The read arrives when the stream has produced it.
            let due = std::time::Duration::from_secs_f64(sent as f64 / RATE);
            if let Some(wait) = due.checked_sub(began.elapsed()) {
                std::thread::sleep(wait);
            }
            sent += part.len();
            let start = std::time::Instant::now();
            let segments = run.projection.feed(part, true);
            per_read.push(start.elapsed().as_secs_f64() * 1000.0);
            run.mac.vt_write(part);
            run.apply(segments);
            let _ = run.projection.take_replies();
        }
        target.vt_write(phone);
        run.load_all();
        let score = compare_grid(&snapshot(&target), &snapshot(&run.phone));
        mismatched += score.mismatched + score.cursor_mismatches;
    }
    let wall = began.elapsed().as_secs_f64();
    per_read.sort_by(|a, b| a.total_cmp(b));
    let at = |q: f64| per_read[((per_read.len() - 1) as f64 * q).round() as usize];
    println!(
        "Duress, wall clock: {} KB at 400 KB/s in {} reads to a {}x{} phone: wall {:.3} s (budget {:.3} s), projection per read p50 {:.3} ms, p99 {:.3} ms, max {:.3} ms; compact mismatches {}",
        sent / 1024,
        per_read.len(),
        grid.0,
        grid.1,
        wall,
        sent as f64 / RATE,
        at(0.5),
        at(0.99),
        per_read.last().copied().unwrap_or(0.0),
        mismatched
    );
    if std::env::var("PARITY_REPORT_ONLY").is_err() {
        assert_eq!(mismatched, 0, "the phone differs from Claude Code drawn at its width");
    }
}
