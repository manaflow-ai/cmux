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
                rows.push((cells.into_iter().zip(links).collect(), wraps))
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

/// Glyphs in order with their styles, blanks and line structure aside.
fn glyphs(snap: &Snapshot) -> Vec<Key> {
    snap.rows
        .iter()
        .flat_map(|(cells, _)| cells.iter())
        .filter(|c| !matches!(c.0.width, CellWidth::SpacerTail | CellWidth::SpacerHead))
        .map(Key::of)
        .filter(|k| k.text != " ")
        .collect()
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
    println!("{table}");
    if !details.is_empty() {
        println!("First mismatches:{details}");
    }
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
