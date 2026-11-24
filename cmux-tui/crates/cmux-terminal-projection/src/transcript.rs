//! A full-screen app's transcript, kept on the phone.
//!
//! Leo, 2026-11-24: "where's us simply scrolling a cached-on-phone view of a
//! lot of the existing terminal data that's been sent and rendered? it's
//! literally data we already have and know about. if it won't change, there's
//! no lag that should happen in those cases." And: "we can just treat the
//! scroll like any pedestrian scroll."
//!
//! A full-screen app (Claude Code's full-screen mode, less, a log viewer)
//! scrolls its own screen: rows it moves off the top are gone from the grid,
//! though the phone drew them a moment ago. This keeps them. After every
//! frame of the alternate screen ([`Transcript::observe`]) the rows are
//! matched to the last frame's; when the app moved a band of rows (its
//! transcript, under a fixed input box and status row) the rows that left
//! the band are kept in order, and the rows in it are written over their
//! place, so a line that streams in place stays current. The result is one
//! document: the rows above the band, every row the band has shown, oldest
//! first, and the rows below it ([`Transcript::paint`]), which the phone
//! scrolls natively, with no round trip to the Mac.
//!
//! It works for any app and any input (wheel reports, cursor keys, new
//! output), with no knowledge of the app: only the frames.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

use crate::style::Style;
use crate::terminal::{Row, Terminal};

/// Fewest rows that must have moved, and changed, for a frame to count as
/// scrolled: a spinner redrawn in place, or two blank rows that line up, are
/// not a scroll (the phone's pixel matcher, `TerminalTUIRowMove`, uses the same).
pub const MINIMUM_MOVED_ROWS: usize = 3;

/// The most rows one frame can move and still be followed.
pub const MAXIMUM_SHIFT: usize = 48;

/// The rows kept; the oldest go first past it.
pub const DEFAULT_LIMIT: usize = 10_000;

/// How a frame's rows moved from the last frame's.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Move {
    /// Rows the content moved: positive down (older rows came in at the
    /// top), negative up (newer rows came in at the bottom).
    pub rows: isize,
    /// The rows of the current frame that scrolled, the rows that came in
    /// included.
    pub band: std::ops::Range<usize>,
}

impl Move {
    /// How `current` moved from `previous` (one hash per row): the shift of
    /// at most `max_shift` rows whose longest run of rows equal to the
    /// previous frame's, shifted, holds the most rows that differ from the
    /// same row unshifted. None when nothing moved.
    pub fn between(previous: &[u64], current: &[u64], max_shift: usize) -> Option<Move> {
        let n = previous.len().min(current.len());
        if n <= MINIMUM_MOVED_ROWS || max_shift == 0 {
            return None;
        }
        let mut best: Option<(usize, isize, std::ops::Range<usize>)> = None;
        for magnitude in 1..=max_shift.min(n - 1) {
            for shift in [magnitude as isize, -(magnitude as isize)] {
                // Rows `i` of `current` whose source row `i - shift` is on the screen too.
                let lower = shift.max(0) as usize;
                let upper = (n as isize + shift.min(0)) as usize;
                if lower >= upper {
                    continue;
                }
                let (mut start, mut score) = (lower, 0);
                for i in lower..=upper {
                    let here = current.get(i);
                    let equal = i < upper
                        && here.is_some()
                        && here == previous.get((i as isize - shift) as usize);
                    if equal {
                        if here != previous.get(i) {
                            score += 1;
                        }
                        continue;
                    }
                    if score >= MINIMUM_MOVED_ROWS && score > best.as_ref().map_or(0, |b| b.0) {
                        best = Some((score, shift, start..i));
                    }
                    start = i + 1;
                    score = 0;
                }
            }
        }
        let (_, shift, run) = best?;
        let band = if shift > 0 {
            run.start.saturating_sub(shift as usize)..run.end
        } else {
            run.start..(run.end + (-shift) as usize).min(n)
        };
        Some(Move { rows: shift, band })
    }
}

/// One row's identity: its cells and their styles.
pub fn row_hash(row: &Row) -> u64 {
    let mut h = DefaultHasher::new();
    let keep =
        row.cells.iter().rposition(|c| !c.is_empty_or_space() || c.style != 0).map_or(0, |i| i + 1);
    for cell in row.cells.iter().take(keep) {
        (cell.ch, cell.style, cell.kind).hash(&mut h);
    }
    h.finish()
}

/// The transcript of the alternate screen now up.
#[derive(Clone, Debug, Default)]
pub struct Transcript {
    /// Every row the band has shown, oldest first.
    rows: Vec<Row>,
    /// Where the band's first row is in `rows`.
    at: usize,
    /// The scrolling band of the screen (rows), once a move showed it.
    band: Option<std::ops::Range<usize>>,
    /// The last frame's row hashes, and its rows (the first move's rows
    /// that left the screen are in it).
    previous: Vec<u64>,
    last_screen: Vec<Row>,
    limit: usize,
    /// Rows dropped from the front (`limit`) since the transcript began.
    pub dropped: u64,
    /// Frames observed, and frames that moved.
    pub frames: u64,
    pub moves: u64,
}

impl Transcript {
    pub fn new(limit: usize) -> Transcript {
        Transcript { limit: limit.max(1), ..Transcript::default() }
    }

    /// The app left its screen, or a new one came up: start over.
    pub fn clear(&mut self) {
        let limit = self.limit;
        *self = Transcript::new(limit);
    }

    /// Rows kept in the band's transcript.
    pub fn len(&self) -> usize {
        self.rows.len()
    }

    pub fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }

    /// Rows of the transcript above the band's place on the screen: what the
    /// phone can scroll up to with no round trip (0 before any move).
    pub fn rows_above(&self) -> usize {
        if self.band.is_some() { self.at } else { 0 }
    }

    /// Rows of the transcript below the band (the app scrolled up and
    /// newer rows it showed before are under it).
    pub fn rows_below(&self) -> usize {
        match &self.band {
            Some(band) => self.rows.len().saturating_sub(self.at + band.len()),
            None => 0,
        }
    }

    /// The band, once a move showed it.
    pub fn band(&self) -> Option<std::ops::Range<usize>> {
        self.band.clone()
    }

    /// One complete frame of `term`'s alternate screen (not inside a
    /// synchronized update).
    pub fn observe(&mut self, term: &Terminal) {
        let screen = term.screen_rows();
        let current: Vec<u64> = screen.iter().map(row_hash).collect();
        self.frames += 1;
        if current.len() != self.previous.len() {
            // A new grid: the rows cannot be matched.
            self.clear();
            self.previous = current;
            self.last_screen = screen.to_vec();
            return;
        }
        if current == self.previous {
            return;
        }
        match Move::between(&self.previous, &current, MAXIMUM_SHIFT) {
            Some(m) => {
                self.moves += 1;
                self.moved(&m, screen);
            }
            None => self.redrawn(&current, screen),
        }
        self.previous = current;
        self.last_screen.clone_from(&screen.to_vec());
    }

    fn moved(&mut self, m: &Move, screen: &[Row]) {
        let band = match &self.band {
            // The band so far, grown to what this move shows.
            Some(b) if b.start.max(m.band.start) < b.end.min(m.band.end) => {
                b.start.min(m.band.start)..b.end.max(m.band.end)
            }
            _ => m.band.clone(),
        };
        if self.band.is_none() || self.rows.is_empty() {
            // The first move: the band's rows of the frame before it are the
            // transcript's first rows.
            self.rows.clear();
            let end = band.end.min(self.last_screen.len());
            self.rows.extend(
                self.last_screen.get(band.start.min(end)..end).unwrap_or_default().iter().cloned(),
            );
            self.at = 0;
        } else if let Some(old) = &self.band {
            // The band grew upward: its place in the transcript moves with it.
            let grew = old.start.saturating_sub(band.start);
            self.at = self.at.saturating_sub(grew);
        }
        if m.rows > 0 {
            // Older rows came in at the top.
            let up = m.rows as usize;
            if self.at >= up {
                self.at -= up;
            } else {
                let missing = up - self.at;
                let blanks = std::iter::repeat_with(Row::default).take(missing);
                self.rows.splice(0..0, blanks);
                self.at = 0;
            }
        } else {
            self.at += (-m.rows) as usize;
        }
        self.band = Some(band.clone());
        self.write_band(screen, &band);
    }

    /// A frame with no move: the band's rows were written in place (a line
    /// streamed, a spinner turned). A new screen (most of the band changed,
    /// nothing moved) starts over.
    fn redrawn(&mut self, current: &[u64], screen: &[Row]) {
        let Some(band) = self.band.clone() else { return };
        let changed = band.clone().filter(|&i| current.get(i) != self.previous.get(i)).count();
        if changed * 2 > band.len() && band.len() > MINIMUM_MOVED_ROWS * 2 {
            self.clear();
            return;
        }
        self.write_band(screen, &band);
    }

    fn write_band(&mut self, screen: &[Row], band: &std::ops::Range<usize>) {
        let need = self.at + band.len();
        if self.rows.len() < need {
            self.rows.resize_with(need, Row::default);
        }
        for (k, i) in band.clone().enumerate() {
            if let Some(row) = screen.get(i) {
                if let Some(slot) = self.rows.get_mut(self.at + k) {
                    if slot != row {
                        slot.clone_from(row);
                    }
                }
            }
        }
        if self.rows.len() > self.limit {
            let drop = self.rows.len() - self.limit;
            let drop = drop.min(self.at);
            if drop > 0 {
                self.rows.drain(..drop);
                self.at -= drop;
                self.dropped += drop as u64;
            }
        }
    }

    /// The document the phone scrolls: the screen's rows above the band,
    /// the transcript, and the screen's rows below the band; its rows, and
    /// the row of the document the screen's first row is at (where the
    /// document's last screen begins when the app is at its newest rows).
    pub fn document<'a>(&'a self, term: &'a Terminal) -> (Vec<&'a Row>, usize) {
        let screen = term.screen_rows();
        let Some(band) = &self.band else {
            return (screen.iter().collect(), 0);
        };
        let band = band.start.min(screen.len())..band.end.min(screen.len());
        let mut rows: Vec<&Row> = Vec::with_capacity(screen.len() + self.rows.len());
        rows.extend(screen.iter().take(band.start));
        rows.extend(self.rows.iter());
        rows.extend(screen.iter().skip(band.end));
        (rows, self.at)
    }

    /// VT bytes for a terminal of the screen's columns, fresh (after `ESC c`):
    /// the document's rows, one per line, so its scrollback is the
    /// transcript and its screen ends with the screen's last row. Returns the
    /// bytes, the document's rows and the row the live screen begins at.
    pub fn paint(&self, term: &Terminal) -> (Vec<u8>, usize, usize) {
        let (rows, screen_top) = self.document(term);
        let mut out = Vec::with_capacity(rows.len() * (term.cols + 8));
        out.extend_from_slice(b"\x1b[0m\x1b[H\x1b[2J");
        let mut style = Style::default();
        for (n, row) in rows.iter().enumerate() {
            if n > 0 {
                out.extend_from_slice(b"\r\n");
            }
            let mut width = 0;
            // Plain blanks past the last glyph are not written (the fresh
            // terminal's cells are blank already).
            let keep = row
                .cells
                .iter()
                .rposition(|c| !c.is_empty_or_space() || c.style != 0)
                .map_or(0, |i| i + 1);
            for cell in row.cells.iter().take(keep) {
                if width >= term.cols {
                    break;
                }
                if cell.kind == crate::terminal::WIDE_TAIL
                    || cell.kind == crate::terminal::SPACER_HEAD
                {
                    continue;
                }
                let next = term.styles.get(cell.style);
                if next != style {
                    crate::project::write_style(term, &mut out, Some(style), next);
                    style = next;
                }
                if cell.ch == 0 {
                    out.push(b' ');
                } else {
                    term.write_cell(*cell, &mut out);
                }
                width += cell.width();
            }
            if style != Style::default() {
                crate::project::write_style(term, &mut out, Some(style), Style::default());
                style = Style::default();
            }
        }
        (out, rows.len(), screen_top)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed(term: &mut Terminal, bytes: &[u8]) {
        for &b in bytes {
            term.advance(b);
        }
    }

    /// An app on a `rows`-row alternate screen: a transcript band of every
    /// row but the last, showing `lines` from `first`, and a fixed status row.
    fn frame(term: &mut Terminal, lines: &[String], first: usize, rows: usize) {
        let mut out = String::from("\x1b[H");
        for r in 0..rows - 1 {
            out.push_str(&format!("\x1b[{};1H\x1b[2K", r + 1));
            if let Some(line) = lines.get(first + r) {
                out.push_str(line);
            }
        }
        out.push_str(&format!("\x1b[{rows};1H\x1b[2K> status"));
        feed(term, out.as_bytes());
    }

    fn text(row: &Row) -> String {
        row.cells
            .iter()
            .map(|c| char::from_u32(c.ch).filter(|&c| c != '\0').unwrap_or(' '))
            .collect::<String>()
            .trim_end()
            .to_string()
    }

    fn lines(n: usize) -> Vec<String> {
        (0..n).map(|i| format!("line {i:03} of the transcript")).collect()
    }

    #[test]
    fn rows_an_app_scrolls_off_are_kept_in_order() {
        let mut term = Terminal::new(40, 10, 100);
        feed(&mut term, b"\x1b[?1049h");
        let all = lines(60);
        let mut t = Transcript::new(DEFAULT_LIMIT);
        // New output pushes the transcript up three rows a frame.
        for first in (0..=30).step_by(3) {
            frame(&mut term, &all, first, 10);
            t.observe(&term);
        }
        let (doc, top) = t.document(&term);
        let doc: Vec<String> = doc.iter().map(|r| text(r)).collect();
        assert_eq!(top, 30, "the screen's band begins at line 30 of the transcript");
        assert_eq!(&doc[..39], &all[..39], "every line the band showed, oldest first");
        assert_eq!(doc.last().map(String::as_str), Some("> status"), "the fixed row stays below");
        assert_eq!(t.rows_above(), 30);
        assert_eq!(t.rows_below(), 0);
    }

    #[test]
    fn scrolling_the_app_back_up_reuses_the_rows_it_already_showed() {
        let mut term = Terminal::new(40, 10, 100);
        feed(&mut term, b"\x1b[?1049h");
        let all = lines(60);
        let mut t = Transcript::new(DEFAULT_LIMIT);
        for first in (0..=30).step_by(3) {
            frame(&mut term, &all, first, 10);
            t.observe(&term);
        }
        // The reader wheels the app back up 6 rows: nothing new is kept,
        // the band's place moves up.
        frame(&mut term, &all, 27, 10);
        t.observe(&term);
        frame(&mut term, &all, 24, 10);
        t.observe(&term);
        assert_eq!(t.rows_above(), 24);
        assert_eq!(t.rows_below(), 6, "the newer rows it showed are under the band");
        assert_eq!(t.len(), 39);
    }

    #[test]
    fn a_line_streamed_in_place_stays_current() {
        let mut term = Terminal::new(40, 10, 100);
        feed(&mut term, b"\x1b[?1049h");
        let mut all = lines(40);
        let mut t = Transcript::new(DEFAULT_LIMIT);
        for first in (0..=12).step_by(3) {
            frame(&mut term, &all, first, 10);
            t.observe(&term);
        }
        all[20] = "line 020 of the transcript, now longer".into();
        frame(&mut term, &all, 12, 10);
        t.observe(&term);
        let (doc, _) = t.document(&term);
        assert_eq!(text(doc[20]), all[20]);
    }

    #[test]
    fn a_new_screen_starts_the_transcript_over() {
        let mut term = Terminal::new(40, 10, 100);
        feed(&mut term, b"\x1b[?1049h");
        let all = lines(40);
        let mut t = Transcript::new(DEFAULT_LIMIT);
        for first in (0..=12).step_by(3) {
            frame(&mut term, &all, first, 10);
            t.observe(&term);
        }
        let other: Vec<String> = (0..40).map(|i| format!("help page {i}")).collect();
        frame(&mut term, &other, 0, 10);
        t.observe(&term);
        assert_eq!(t.rows_above(), 0);
        assert!(t.is_empty());
    }

    #[test]
    fn a_spinner_is_not_a_scroll() {
        let mut term = Terminal::new(40, 10, 100);
        feed(&mut term, b"\x1b[?1049h");
        let all = lines(40);
        let mut t = Transcript::new(DEFAULT_LIMIT);
        frame(&mut term, &all, 0, 10);
        t.observe(&term);
        for spin in ["|", "/", "-", "\\"] {
            feed(&mut term, format!("\x1b[10;1H\x1b[2K{spin} working").as_bytes());
            t.observe(&term);
        }
        assert_eq!(t.moves, 0);
        assert_eq!(t.rows_above(), 0);
    }

    #[test]
    fn the_limit_drops_the_oldest_rows() {
        let mut term = Terminal::new(40, 10, 100);
        feed(&mut term, b"\x1b[?1049h");
        let all = lines(200);
        let mut t = Transcript::new(50);
        for first in (0..=180).step_by(3) {
            frame(&mut term, &all, first, 10);
            t.observe(&term);
        }
        assert!(t.len() <= 50);
        let (doc, _) = t.document(&term);
        assert_eq!(text(doc[0]), all[t.dropped as usize]);
    }

    #[test]
    fn the_paint_ends_with_the_screen() {
        let mut term = Terminal::new(40, 10, 100);
        feed(&mut term, b"\x1b[?1049h");
        let all = lines(60);
        let mut t = Transcript::new(DEFAULT_LIMIT);
        for first in (0..=30).step_by(3) {
            frame(&mut term, &all, first, 10);
            t.observe(&term);
        }
        let (bytes, rows, top) = t.paint(&term);
        assert_eq!(rows, 40);
        assert_eq!(top, 30);
        // A fresh terminal of the screen's grid, fed the paint, shows the
        // app's screen; its scrollback holds the 30 rows above.
        let mut phone = Terminal::new(40, 10, 1000);
        feed(&mut phone, &bytes);
        let screen: Vec<String> = phone.screen_rows().iter().map(text).collect();
        let app: Vec<String> = term.screen_rows().iter().map(text).collect();
        assert_eq!(screen, app);
        let history: Vec<String> = phone.history.iter().map(text).collect();
        assert_eq!(&history[..], &all[..30]);
    }

    #[test]
    fn move_between_finds_the_shift_and_band() {
        let prev: Vec<u64> = (0..10).chain([99]).collect();
        let cur: Vec<u64> = (3..13).chain([99]).collect();
        let m = Move::between(&prev, &cur, 12).expect("moved");
        assert_eq!(m.rows, -3);
        assert_eq!(m.band, 0..10);
        let m = Move::between(&cur, &prev, 12).expect("moved");
        assert_eq!(m.rows, 3);
        assert_eq!(m.band, 0..10);
    }
}
