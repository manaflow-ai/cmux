//! The phone's view: the host's logical lines (soft-wrapped rows joined)
//! re-wrapped at the phone's columns, written as VT bytes for a terminal of
//! the phone's grid, and kept up to date by repainting only from the first
//! row that changed.

use std::cmp::Ordering;
use std::collections::HashMap;

use crate::relayout;
use crate::style::{Color, FAINT, Style};
use crate::terminal::{Cell, Row, SPACER_HEAD, Terminal, WIDE, WIDE_TAIL};

/// One row of the phone's view.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProjectedRow {
    /// Glyph cells only (a wide glyph is one cell of width 2).
    pub cells: Vec<Cell>,
    /// The row's logical line goes on in the next row.
    pub wrapped: bool,
}

impl ProjectedRow {
    pub fn width(&self) -> usize {
        self.cells.iter().map(|c| c.width()).sum()
    }
}

/// A logical line re-wrapped: its rows, and where the host cursor lands.
pub struct Wrapped {
    pub rows: Vec<ProjectedRow>,
    /// (row in `rows`, column) of the cursor, when it is in this line.
    pub cursor: Option<(usize, usize)>,
    /// The line has no glyph and no cursor.
    pub empty: bool,
}

/// Re-wraps one logical line (host rows, the last one not wrapped, or the
/// screen's last) at `cols`. `cursor`: (host row index in `rows`, column).
pub fn wrap_line(
    term: &Terminal,
    rows: &[&Row],
    host_cols: usize,
    cols: usize,
    cursor: Option<(usize, usize)>,
    compact: bool,
) -> Wrapped {
    let cols = cols.max(2);
    if compact && let Some(laid) = relayout::layout(term, rows, host_cols, cols, cursor) {
        return laid;
    }
    let cursor_cell = cursor.map(|(k, x)| k * host_cols + x);
    let Units { mut units, spacer_heads, padded } = line_units(term, rows, host_cols, compact);
    let cursor_spacers = cursor_cell.map_or(0, |c| spacer_heads.partition_point(|&at| at < c));
    let cut = compact && compact_anchored(term, rows, host_cols, cols, &mut units);
    let cursor_offset = cursor_cell.map(|c| c - cursor_spacers);
    let mut out = vec![ProjectedRow::default()];
    let mut col = 0;
    let mut cursor_at = None;
    let place = |out: &mut Vec<ProjectedRow>, col: &mut usize, width: usize| -> (usize, usize) {
        if *col + width > cols {
            if let Some(row) = out.last_mut() {
                row.wrapped = true;
            }
            out.push(ProjectedRow::default());
            *col = 0;
        }
        (out.len() - 1, *col)
    };
    let mut end_offset = 0;
    for (offset, cell) in &units {
        let width = cell.width();
        if let Some(target) = cursor_offset
            && cursor_at.is_none()
            && *offset >= target
        {
            // The cursor is on this glyph (or on the empty cells before it).
            cursor_at =
                Some(place(&mut out, &mut col, 1.max(if *offset == target { width } else { 1 })));
        }
        let (row, _) = place(&mut out, &mut col, width);
        if let Some(out_row) = out.get_mut(row) {
            out_row.cells.push(*cell);
        }
        col += width;
        end_offset = offset + width;
    }
    if cut && cursor_offset.is_some() && cursor_at.is_none() {
        // Past a row cut at the phone's edge: the cursor stays on it.
        cursor_at = Some((out.len() - 1, col.min(cols - 1)));
    }
    if let (Some(target), None) = (cursor_offset, cursor_at) {
        // Past the line's end: the blank cells up to the cursor count.
        let blanks = target.saturating_sub(end_offset);
        if compact && padded && col + blanks >= cols {
            // Compact, in the padding it dropped (an app mid-way through
            // printing a right-aligned row, a network read cut it there):
            // the cursor waits at the line's last row's end. The padding
            // goes on no new row: a row added at the screen's bottom
            // scrolls the phone, and no later frame can take it back.
            cursor_at = Some((out.len() - 1, col.min(cols - 1)));
        } else if col + blanks < cols {
            // On the line's last row.
            cursor_at = Some((out.len() - 1, col + blanks));
        } else {
            // Past the phone's edge (a prompt's cursor far right on the
            // host, or right after a line that fills the phone's row): the
            // line goes on in blank cells through the cursor's own, so its
            // rows wrap by the phone's autowrap and the cursor sits at the
            // host's column of the logical line, not clamped to the edge.
            for _ in 0..=blanks {
                cursor_at = Some(place(&mut out, &mut col, 1));
                if let Some(row) = out.last_mut() {
                    row.cells.push(Cell::blank(0));
                }
                col += 1;
            }
        }
    }
    let empty = units.is_empty() && cursor_at.is_none();
    Wrapped { rows: out, cursor: cursor_at, empty }
}

/// A logical line's glyphs for the cell-by-cell wrap: each with its offset
/// in the host line, its trailing blanks trimmed.
struct Units {
    units: Vec<(usize, Cell)>,
    /// Host offsets of the line's spacer heads, ascending. A spacer head (the
    /// host's empty last cell before a wide glyph that wrapped) is the host's
    /// own artifact: offsets after it do not count it.
    spacer_heads: Vec<usize>,
    /// Compact: the line's end was written padding (see below), dropped.
    padded: bool,
}

fn line_units(term: &Terminal, rows: &[&Row], host_cols: usize, compact: bool) -> Units {
    let mut units: Vec<(usize, Cell)> = Vec::new();
    let mut spacer_heads = Vec::new();
    for (k, row) in rows.iter().enumerate() {
        for (x, cell) in row.cells.iter().enumerate() {
            let at = k * host_cols + x;
            if cell.kind == SPACER_HEAD {
                spacer_heads.push(at);
                continue;
            }
            if cell.kind == WIDE_TAIL {
                continue;
            }
            units.push((at - spacer_heads.len(), *cell));
        }
    }
    // Trailing blanks that draw nothing go (the host row's empty end). Laid
    // out as the host's lines exactly, only cells never written go, as
    // Ghostty's own reflow trims them: a space the program printed is a
    // cell of the line (a right-aligned row's padding, a line ending in a
    // space), and its rows wrap on the phone as on a resized Mac.
    // Compact also drops written spaces that pad the line (a run of them,
    // or one reaching the host's edge: an app filling its row or centering
    // a title), not the one space a line ends in before the edge: the
    // program drawn at the phone's width wraps that one too.
    let edge = rows
        .last()
        .and_then(|row| row.cells.get(host_cols.saturating_sub(1)))
        .is_some_and(|c| c.ch == u32::from(b' '));
    let run = units
        .iter()
        .rev()
        .skip_while(|(_, c)| c.ch == 0)
        .take_while(|(_, c)| c.ch == u32::from(b' '))
        .take(2)
        .count();
    let padded = edge || run >= 2;
    while let Some((_, cell)) = units.last() {
        let style = term.styles.get(cell.style);
        let trimmed = if compact {
            (cell.ch == 0 || (padded && cell.is_empty_or_space()))
                && style.is_invisible_when_blank()
        } else {
            cell.ch == 0 && cell.kind != WIDE && style.bg == Color::Default
        };
        if trimmed {
            units.pop();
        } else {
            break;
        }
    }
    Units { units, spacer_heads, padded }
}

/// Where each host cell `(row in rows, column)` of `cells` lands on the
/// phone, as `wrap_line(.., Some(cell), ..).cursor` would give it, from one
/// pass over the line (a long line has as many cells as glyphs: one
/// `wrap_line` per cell is quadratic).
pub fn wrap_line_cells(
    term: &Terminal,
    rows: &[&Row],
    host_cols: usize,
    cols: usize,
    compact: bool,
    cells: &[(usize, usize)],
) -> Vec<Option<(usize, usize)>> {
    let cols = cols.max(2);
    let Units { mut units, spacer_heads, padded } = line_units(term, rows, host_cols, compact);
    let cut = compact && compact_anchored(term, rows, host_cols, cols, &mut units);
    let mut targets: Vec<(usize, usize)> = cells
        .iter()
        .enumerate()
        .map(|(i, &(k, x))| {
            let c = k * host_cols + x;
            (c - spacer_heads.partition_point(|&at| at < c), i)
        })
        .collect();
    targets.sort_unstable();
    let mut out = vec![None; cells.len()];
    let mut next = 0;
    let (mut row, mut col) = (0usize, 0usize);
    let mut end_offset = 0;
    for (offset, cell) in &units {
        let width = cell.width();
        while let Some(&(target, i)) = targets.get(next)
            && *offset >= target
        {
            let w = 1.max(if *offset == target { width } else { 1 });
            if let Some(slot) = out.get_mut(i) {
                *slot = Some(if col + w > cols { (row + 1, 0) } else { (row, col) });
            }
            next += 1;
        }
        if col + width > cols {
            row += 1;
            col = 0;
        }
        col += width;
        end_offset = offset + width;
    }
    // Past the line's end, by `wrap_line`'s rules: a row cut at the phone's
    // edge, or compact padding it dropped, keeps the cell at the last row's
    // end; else the blank cells up to the cell count, the line going on in
    // blank cells past the phone's edge.
    for &(target, i) in targets.get(next..).unwrap_or_default() {
        let blanks = target.saturating_sub(end_offset);
        let at = if cut || (compact && padded && col + blanks >= cols) {
            (row, col.min(cols - 1))
        } else if col + blanks < cols {
            (row, col + blanks)
        } else {
            let (mut r, mut c, mut at) = (row, col, (row, col));
            for _ in 0..=blanks {
                if c + 1 > cols {
                    r += 1;
                    c = 0;
                }
                at = (r, c);
                c += 1;
            }
            at
        };
        // `i` indexes `cells`, and `out` has one slot per cell.
        if let Some(slot) = out.get_mut(i) {
            *slot = Some(at);
        }
    }
    out
}

/// Horizontal rules a program pads a frame with (`─` in `╭────╮`). Box
/// drawing only: ASCII runs (`===`, `---`) can be content.
fn is_rule(ch: u32) -> bool {
    matches!(char::from_u32(ch), Some('─' | '━' | '═' | '┄' | '┅' | '┈' | '┉' | '╌' | '╍'))
}

/// A frame's right edge (`│`, `╮`, `╯` and their kin).
fn is_right_edge(ch: u32) -> bool {
    matches!(
        char::from_u32(ch),
        Some(
            '│' | '┃'
                | '║'
                | '╮'
                | '╯'
                | '┐'
                | '┘'
                | '╗'
                | '╝'
                | '┤'
                | '┫'
                | '╣'
                | '┓'
                | '┛'
                | '╢'
                | '╡'
        )
    )
}

/// A blank cell (never written, or a space).
fn is_blank(cell: Cell) -> bool {
    cell.ch == 0 || cell.ch == u32::from(b' ')
}

/// Runs shorter than this are word spacing, not padding, and stay.
const MIN_PAD_RUN: usize = 3;

/// A program lays some rows out by the host's width: a right prompt or
/// status at the last column, a header box whose border is padded to the
/// edge (Claude Code's welcome box, Codex's header). Re-wrapped, such a row
/// breaks in two and its right part lands on the left. Laid out at the
/// phone's width instead, as the program would draw it for that width:
/// the row's padding (runs of blanks, or of one rule glyph such as `─`)
/// shrinks until the row fits, so left content stays left and right
/// content ends at the phone's edge.
///
/// A title centered on the host is centered on the phone ([`recenter`]).
///
/// Only a single hard host row (not soft-wrapped) that is wider than the
/// phone, ends within two cells of the host's edge or at a frame's right edge,
/// and has enough padding: prose and column output (`ls`) have short runs
/// and wrap as before. Each run keeps at least two cells (one for a rule).
fn compact_anchored(
    term: &Terminal,
    rows: &[&Row],
    host_cols: usize,
    cols: usize,
    units: &mut Vec<(usize, Cell)>,
) -> bool {
    let [row] = rows else { return false };
    if row.wrapped {
        return false;
    }
    let Some(&(last_offset, last)) = units.last() else { return false };
    let end = last_offset + last.width();
    if is_blank(last) {
        return false;
    }
    let by_edge = end + 3 >= host_cols;
    let anchored = by_edge || is_right_edge(last.ch);
    // The host's right margin stays (Claude Code's status ends a cell short
    // of the edge, as it does at any width).
    let margin = if by_edge { host_cols.saturating_sub(end) } else { 0 };
    if end + margin <= cols {
        return false;
    }
    if !anchored {
        if key_hints_cut(term, cols, units) {
            return true;
        }
        recenter(host_cols, cols, end, units);
        return false;
    }
    let need = end + margin - cols;
    // Runs: (first unit index, length, cells it keeps at least).
    let mut runs: Vec<(usize, usize, usize)> = Vec::new();
    let mut i = 0;
    while let Some(&(_, cell)) = units.get(i) {
        let blank = is_blank(cell);
        if cell.width() != 1 || !(blank || is_rule(cell.ch)) {
            i += 1;
            continue;
        }
        let mut j = i + 1;
        while let Some(&(_, next)) = units.get(j) {
            let same = next.width() == 1
                && next.style == cell.style
                && if blank { is_blank(next) } else { next.ch == cell.ch };
            if !same {
                break;
            }
            j += 1;
        }
        if j - i >= MIN_PAD_RUN {
            runs.push((i, j - i, if blank { 2 } else { 1 }));
        }
        i = j;
    }
    let spare: usize = runs.iter().map(|&(_, len, keep)| len - keep).sum();
    if spare < need {
        right_part_on_its_own_row(&runs, cols, margin, units);
        return false;
    }
    // The rightmost run shrinks first, down to what it keeps, then the one
    // before it: the padding before a right part or a frame's edge goes,
    // and the spacing inside the content (`model:     gpt`) stays as long
    // as it can.
    let mut cut = vec![0usize; runs.len()];
    let mut left = need;
    for (k, &(_, len, keep)) in runs.iter().enumerate().rev() {
        if left == 0 {
            break;
        }
        let n = (len - keep).min(left);
        if let Some(c) = cut.get_mut(k) {
            *c = n;
        }
        left -= n;
    }
    let mut drop = vec![false; units.len()];
    for (&(start, len, _), &n) in runs.iter().zip(&cut) {
        // A run keeps its first cells; the cut comes off its end.
        for d in drop.iter_mut().skip(start + len - n).take(n) {
            *d = true;
        }
    }
    let mut k = 0;
    units.retain(|_| {
        k += 1;
        !drop.get(k - 1).copied().unwrap_or(false)
    });
    false
}

/// A key-hint footer (faint text in columns: `⏎ send   ⇧⏎ newline   ⌃C quit`)
/// is cut at the phone's edge, as the app cuts it at a narrow width
/// (ratatui truncates a line to its area) instead of wrapping it.
fn key_hints_cut(term: &Terminal, cols: usize, units: &mut Vec<(usize, Cell)>) -> bool {
    let faint =
        units.iter().all(|&(_, c)| is_blank(c) || term.styles.get(c.style).flags & FAINT != 0);
    if !faint {
        return false;
    }
    let mut gaps = 0;
    let mut run = 0;
    let mut seen = false;
    for &(_, c) in units.iter() {
        if is_blank(c) {
            run += 1;
        } else {
            if seen && run >= MIN_PAD_RUN {
                gaps += 1;
            }
            seen = true;
            run = 0;
        }
    }
    if gaps < 2 {
        return false;
    }
    let mut used = 0;
    let keep = units
        .iter()
        .take_while(|&&(_, c)| {
            used += c.width();
            used <= cols
        })
        .count();
    units.truncate(keep);
    while units.last().is_some_and(|&(_, c)| is_blank(c)) {
        units.pop();
    }
    true
}

/// A row centered on the host (a title: as many blanks before it as after
/// it, give or take one) that fits the phone without its leading blanks is
/// centered on the phone instead of pushed past its edge.
fn recenter(host_cols: usize, cols: usize, end: usize, units: &mut Vec<(usize, Cell)>) {
    let lead = units.iter().take_while(|&&(_, c)| c.width() == 1 && is_blank(c)).count();
    if lead < MIN_PAD_RUN {
        return;
    }
    let rest = end - lead;
    if rest > cols || lead.abs_diff(host_cols.saturating_sub(end)) > 1 {
        return;
    }
    let keep = (cols - rest) / 2;
    units.drain(keep..lead);
}

/// A row whose left and right parts cannot share the phone's row (zsh's
/// right prompt beside a long left one, a frame row whose text is wider
/// than the phone): the gap before the right part is set so the right part
/// ends at the phone's edge, on the left part's last row when there is
/// room for both with two cells between them, else on the row after it.
/// The right part stays whole and right-aligned, never split by the wrap.
fn right_part_on_its_own_row(
    runs: &[(usize, usize, usize)],
    cols: usize,
    margin: usize,
    units: &mut Vec<(usize, Cell)>,
) {
    let Some(&(start, len, _)) = runs
        .iter()
        .rev()
        .find(|&&(start, _, _)| units.get(start).is_some_and(|&(_, cell)| is_blank(cell)))
    else {
        return;
    };
    let width = |part: &[(usize, Cell)]| part.iter().map(|(_, c)| c.width()).sum::<usize>();
    let left = width(units.get(..start).unwrap_or_default());
    let right = width(units.get(start + len..).unwrap_or_default());
    if right == 0 || right + margin > cols {
        return;
    }
    // The host's right margin stays past the right part.
    let right = right + margin;
    // Where the left part ends on its last phone row (0: it fills it).
    let rem = if left == 0 { 0 } else { (left - 1) % cols + 1 };
    let rem = if rem == cols { 0 } else { rem };
    let blanks =
        if rem + 2 + right <= cols { cols - rem - right } else { (cols - rem) + (cols - right) };
    // The run's own cells first (their offsets place the cursor), then
    // copies of its last cell when the gap must be longer than the run.
    let Some(&last) = units.get(start + len - 1) else { return };
    let keep = blanks.min(len);
    let extra = blanks - keep;
    let tail: Vec<(usize, Cell)> = units.drain(start + keep..).skip(len - keep).collect();
    units.extend(std::iter::repeat_n(last, extra));
    units.extend(tail);
}

/// Phone screens of scrollback a reset paints above the host's screen
/// (the reader's first flick up); older rows come on demand.
pub const TAIL_SCREENS: usize = 2;

/// Where a host cell lands once the host's lines are re-wrapped at `cols`:
/// the daemon's `terminal-find` gives a hit as rows from the bottom of the
/// host's rows (1: the screen's last row) and a host column, and a phone
/// re-wrapping the same lines needs its own row and column for it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Located {
    /// Rows from the bottom of the re-wrapped content (1: its last row).
    pub from_bottom: usize,
    /// The column on that row, in phone cells.
    pub column: usize,
}

/// The re-wrapped place of host row `host_from_bottom` (1 is the screen's
/// last row), host column `host_column`. None: the model holds fewer rows
/// than that (the hit is older than what the phone has replayed) or the
/// column is outside the host's grid.
pub fn locate(
    term: &Terminal,
    cols: usize,
    compact: bool,
    host_from_bottom: usize,
    host_column: usize,
) -> Option<Located> {
    let rows: Vec<&Row> = term.history.iter().chain(term.primary_rows().iter()).collect();
    if host_from_bottom == 0 || host_from_bottom > rows.len() || host_column >= term.cols {
        return None;
    }
    let at = rows.len() - host_from_bottom;
    let mut first = at;
    while first > 0 && joins_at(term, &rows, first - 1, compact) {
        first -= 1;
    }
    let mut last = at;
    while last + 1 < rows.len() && joins_at(term, &rows, last, compact) {
        last += 1;
    }
    let line = rows.get(first..=last)?;
    let wrapped = wrap_line(term, line, term.cols, cols, Some((at - first, host_column)), compact);
    let (row, column) = wrapped.cursor?;
    let mut from_bottom = wrapped.rows.len() - row;
    let mut start = last + 1;
    while start < rows.len() {
        let mut end = start;
        while end + 1 < rows.len() && joins_at(term, &rows, end, compact) {
            end += 1;
        }
        let below = rows.get(start..=end)?;
        from_bottom += wrap_line(term, below, term.cols, cols, None, compact).rows.len();
        start = end + 1;
    }
    Some(Located { from_bottom, column })
}

/// The host cell under a phone cell: the inverse of [`locate`], for a tap or
/// a mouse click on the primary screen of an app that asked for the mouse
/// (Aziz, cmux#42219: "I found no mapping from phone positions back to host
/// cells"). `phone_from_bottom` counts the re-wrapped rows (1: the last),
/// `phone_column` the phone's cells. The answer is host rows from the bottom
/// (1: the screen's last row) and a host column. A phone cell past a row's
/// last glyph, or on padding the compact layout shrank, gives the host cell
/// of the nearest glyph before it on that row. None: the model holds fewer
/// rows than that. Within a line, cells are placed by the cell-by-cell wrap
/// (as [`locate`] places them); an inline app's paragraph that
/// [`relayout::layout`] re-flows by words maps by that wrap's rows too.
pub fn host_cell(
    term: &Terminal,
    cols: usize,
    compact: bool,
    phone_from_bottom: usize,
    phone_column: usize,
) -> Option<(usize, usize)> {
    let rows: Vec<&Row> = term.history.iter().chain(term.primary_rows().iter()).collect();
    if phone_from_bottom == 0 || rows.is_empty() {
        return None;
    }
    // Logical lines from the bottom, counting the phone rows each takes.
    let mut below = 0;
    let mut end = rows.len();
    while end > 0 {
        let mut first = end - 1;
        while first > 0 && joins_at(term, &rows, first - 1, compact) {
            first -= 1;
        }
        let line = rows.get(first..end)?;
        let wrapped = wrap_line(term, line, term.cols, cols, None, compact);
        let taken = wrapped.rows.len().max(1);
        if phone_from_bottom <= below + taken {
            let target_row = taken - (phone_from_bottom - below);
            // The last host cell of the line that lands at or before the
            // tapped cell on the tapped row.
            let mut best: Option<(usize, usize, usize)> = None;
            let mut first_on_row: Option<(usize, usize)> = None;
            let glyphs: Vec<(usize, usize)> = line
                .iter()
                .enumerate()
                .flat_map(|(k, row)| {
                    row.cells.iter().enumerate().filter_map(move |(x, &cell)| {
                        let skip =
                            cell.kind == WIDE_TAIL || cell.kind == SPACER_HEAD || cell.ch == 0;
                        (!skip).then_some((k, x))
                    })
                })
                .collect();
            let places = wrap_line_cells(term, line, term.cols, cols, compact, &glyphs);
            for (&(k, x), at) in glyphs.iter().zip(places) {
                let Some((r, c)) = at else { continue };
                if r != target_row {
                    continue;
                }
                if first_on_row.is_none() {
                    first_on_row = Some((k, x));
                }
                if c <= phone_column && best.is_none_or(|(_, _, bc)| c >= bc) {
                    best = Some((k, x, c));
                }
            }
            let (k, x) = best.map(|(k, x, _)| (k, x)).or(first_on_row).unwrap_or((0, 0));
            return Some((rows.len() - (first + k), x));
        }
        below += taken;
        end = first;
    }
    None
}

/// Host row `i`, the scrollback's rows then the screen's.
fn host_row(term: &Terminal, i: usize) -> Option<&Row> {
    let len = term.history.len();
    if i < len { term.history.get(i) } else { term.primary_rows().get(i - len) }
}

/// `next` goes on with the logical line `prev` is in: a soft wrap, or in
/// compact mode an inline app's word wrap ([`relayout::continues`]).
pub fn joins(term: &Terminal, prev: &Row, next: &Row, compact: bool) -> bool {
    prev.wrapped || (compact && relayout::continues(term, prev, next, term.cols))
}

/// Whether `rows[i]` joins `rows[i + 1]`; false when either is out of range.
fn joins_at(term: &Terminal, rows: &[&Row], i: usize, compact: bool) -> bool {
    match (rows.get(i), i.checked_add(1).and_then(|j| rows.get(j))) {
        (Some(prev), Some(next)) => joins(term, prev, next, compact),
        _ => false,
    }
}

/// The last row (an index in `term.history`) of the line starting at
/// `first`, once the line is whole in the scrollback. None: it may go on in
/// a row not in the scrollback yet.
fn settled_end(term: &Terminal, first: usize, compact: bool) -> Option<usize> {
    let mut last = first;
    loop {
        let row = term.history.get(last)?;
        match term.history.get(last + 1) {
            Some(next) if joins(term, row, next, compact) => last += 1,
            Some(_) => return Some(last),
            None => {
                let open = row.wrapped || (compact && relayout::may_continue(term, row, term.cols));
                return (!open).then_some(last);
            }
        }
    }
}

/// The start (an index in `term.history`) of the logical line holding
/// history row `index` (`history.len()`: the screen's first line).
pub fn line_start(term: &Terminal, index: usize, compact: bool) -> usize {
    let mut i = index.min(term.history.len());
    while i > 0
        && term.history.get(i - 1).is_some_and(|prev| {
            host_row(term, i).map_or(prev.wrapped, |next| joins(term, prev, next, compact))
        })
    {
        i -= 1;
    }
    i
}

/// Walks back from history index `end` (exclusive, at a line start) over
/// whole logical lines until they fill `want` rows at `cols`; their start.
pub fn rows_back(term: &Terminal, end: usize, cols: usize, want: usize, compact: bool) -> usize {
    let mut start = line_start(term, end, compact);
    let mut rows = 0;
    while start > 0 && rows < want {
        let first = line_start(term, start - 1, compact);
        let line: Vec<&Row> = term.history.iter().take(start).skip(first).collect();
        rows += wrap_line(term, &line, term.cols, cols, None, compact).rows.len();
        start = first;
    }
    start
}

/// The host's last lines laid out at some width, as a terminal of that
/// width holds them (Ghostty's reflow): which rows continue a soft wrap,
/// where the content ends, and the cursor's row.
struct Shape {
    /// Per row: it continues the row above it (a soft wrap).
    continues: Vec<bool>,
    /// Rows through the last line with something in it, or the cursor's.
    end: usize,
    cursor: usize,
    /// Rows above `continues` (at least: an older line takes one or more).
    above: usize,
}

impl Shape {
    /// The host's lines from `want` host rows above its screen on, at `cols`.
    fn of(term: &Terminal, cols: usize, compact: bool, want: usize) -> Option<Shape> {
        let history_len = term.history.len();
        let from = line_start(term, history_len.saturating_sub(want), compact);
        let (cursor_x, cursor_y) = term.primary_cursor();
        let rows: Vec<&Row> =
            term.history.iter().skip(from).chain(term.primary_rows().iter()).collect();
        let cursor_row = history_len - from + cursor_y;
        let mut continues = Vec::new();
        let mut keep = 0;
        let mut cursor = None;
        let mut start = 0;
        while start < rows.len() {
            let mut end = start;
            while end + 1 < rows.len() && joins_at(term, &rows, end, compact) {
                end += 1;
            }
            let in_line =
                (start..=end).contains(&cursor_row).then(|| (cursor_row - start, cursor_x));
            let line = rows.get(start..=end).unwrap_or_default();
            let wrapped = wrap_line(term, line, term.cols, cols, in_line, compact);
            if let Some((row, _)) = wrapped.cursor {
                cursor = Some(continues.len() + row);
            }
            continues.extend((0..wrapped.rows.len()).map(|k| k > 0));
            if !wrapped.empty {
                keep = continues.len();
            }
            start = end + 1;
        }
        let cursor = cursor?;
        Some(Shape { continues, end: keep.max(cursor + 1), cursor, above: from })
    }

    /// Rows below the cursor's, with `pad` rows below the content.
    fn below_cursor(&self, pad: usize) -> usize {
        self.end + pad - self.cursor - 1
    }

    /// Soft-wrap continuations from the top of the active area (the last
    /// `rows` rows) down to the cursor's row.
    fn wraps_to_cursor(&self, pad: usize, rows: usize) -> usize {
        if self.below_cursor(pad) >= rows {
            return 0;
        }
        let top = (self.end + pad).saturating_sub(rows);
        self.continues.get(top..=self.cursor).map_or(0, |c| c.iter().filter(|&&w| w).count())
    }

    /// A change of rows only (PageList.resizeWithoutReflow): fewer rows trim
    /// blank ones from the bottom first; more rows pull scrollback down when
    /// the cursor is on the last row, else add blank rows at the bottom.
    fn rows_changed(&self, rows: usize, pad: usize, new_rows: usize) -> usize {
        match new_rows.cmp(&rows) {
            Ordering::Less => pad - pad.min(rows - new_rows),
            Ordering::Greater if self.below_cursor(pad) == 0 => {
                pad + new_rows.saturating_sub(self.above + self.end + pad)
            }
            Ordering::Greater => pad + (new_rows - rows),
            Ordering::Equal => pad,
        }
    }
}

/// A change of columns (PageList.resizeCols): the lines re-wrap, blank rows
/// at the bottom are dropped, the grid is filled to `rows`, and rows are
/// added so the cursor keeps the rows it had below it (less the rows its
/// own lines grew by above it).
fn reflowed(before: &Shape, pad: usize, after: &Shape, rows: usize) -> usize {
    let remaining = before.below_cursor(pad).min(rows.saturating_sub(1));
    let wrapped_before = before.wraps_to_cursor(pad, rows);
    let pad = rows.saturating_sub(after.above + after.end);
    let current = after.below_cursor(pad);
    if current >= rows {
        return pad;
    }
    let grew = after.wraps_to_cursor(pad, rows).saturating_sub(wrapped_before);
    pad + remaining.saturating_sub(grew).saturating_sub(current)
}

/// The blank rows a terminal keeps below the host's content after it is
/// resized from `old` (cols, rows, blank rows below the content) to `new`
/// (cols, rows), the way Ghostty resizes a grid: a phone that rotates
/// keeps the rows a Mac resized the same way would. None: no cursor on the
/// primary screen to lay out by.
pub fn rows_below_after_resize(
    term: &Terminal,
    compact: bool,
    old: (usize, usize, usize),
    new: (usize, usize),
) -> Option<usize> {
    let ((old_cols, old_rows, pad), (cols, rows)) = (old, new);
    let want = old_rows.max(rows) + 1;
    let before = Shape::of(term, old_cols, compact, want)?;
    if cols == old_cols {
        return Some(before.rows_changed(old_rows, pad, rows));
    }
    let after = Shape::of(term, cols, compact, want)?;
    Some(if cols < old_cols {
        // Rows first, then the columns (PageList.resize).
        let pad = before.rows_changed(old_rows, pad, rows);
        reflowed(&before, pad, &after, rows)
    } else {
        let pad = reflowed(&before, pad, &after, old_rows);
        after.rows_changed(old_rows, pad, rows)
    })
}

/// The blank rows the host's own grid has below its content.
pub fn host_rows_below(term: &Terminal) -> Option<usize> {
    let shape = Shape::of(term, term.cols, false, term.rows + 1)?;
    Some(shape.continues.len().saturating_sub(shape.end))
}

/// What a feed gives the phone's terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Paint {
    /// Bytes for the phone's terminal as it is.
    Update(Vec<u8>),
    /// The phone's terminal starts over (`ESC c`, sent by the caller), then these bytes.
    Reset(Vec<u8>),
}

/// The phone's view of the primary screen.
pub struct View {
    pub cols: usize,
    pub rows: usize,
    /// Projected rows of settled lines (whole in the scrollback), counted
    /// from the last reset.
    settled_end: u64,
    /// Host scrollback rows (absolute, counting dropped ones) settled so far.
    settled_host: u64,
    /// Rows written after the settled ones, as the phone's terminal has them.
    shown: Vec<ProjectedRow>,
    /// Where the phone's cursor is: (absolute row, column, pending wrap).
    phone_cursor: (u64, usize),
    phone_style: Option<Style>,
    phone_cursor_visible: bool,
    needs_reset: bool,
    /// The oldest host row (absolute) a reset must paint (rows the reader
    /// is on, or asked for by scrolling up); nil: only the tail window.
    pub keep_from: Option<u64>,
    /// [`Terminal::history_pushed`] at the last paint: a reset also paints
    /// every row pushed since, so a phone painted once per frame holds the
    /// rows a paint per chunk would have streamed to it.
    pub pushed_at_paint: Option<u64>,
    /// The first host row (absolute) the last reset painted: older rows are
    /// in the model, not on the phone, until [`View::load_older`].
    window_from: u64,
    /// Settled lines as a reset writes them at this view's width, by the
    /// host row they start at: a reset from older rows (the reader scrolling
    /// up) re-wraps only the rows it has not written before.
    line_cache: HashMap<u64, (Vec<u8>, u64)>,
    /// Bytes painted since creation (for benches).
    pub bytes_out: u64,
    pub resets: u64,
    /// Right-anchored rows wider than the phone are laid out at its width
    /// ([`compact_anchored`]). Set before the first paint.
    pub compact: bool,
    /// Blank rows the phone's grid has below its content (the last line
    /// with something in it, or the cursor's row), as of the last paint.
    pub rows_below: usize,
    /// The grid's rows as a resize leaves them ([`rows_below_after_resize`]):
    /// a reset keeps the blank rows below the content it had, and new output
    /// takes them before the grid grows. None: the host's screen decides.
    grid_below: Option<usize>,
    /// No paint yet: the grid's rows were set for this host state.
    fresh: bool,
    /// [`Terminal::screen_cleared`] when the grid's rows were set: a clear
    /// or a switch of screens since gives the rows back to the host's screen.
    cleared_at: Option<u64>,
}

impl View {
    pub fn new(cols: usize, rows: usize) -> View {
        View {
            cols: cols.max(2),
            rows: rows.max(1),
            settled_end: 0,
            settled_host: 0,
            shown: Vec::new(),
            phone_cursor: (0, 0),
            phone_style: None,
            phone_cursor_visible: true,
            needs_reset: true,
            keep_from: None,
            pushed_at_paint: None,
            window_from: 0,
            line_cache: HashMap::new(),
            bytes_out: 0,
            resets: 0,
            compact: true,
            rows_below: 0,
            grid_below: None,
            fresh: true,
            cleared_at: None,
        }
    }

    /// The blank rows below the content the phone's grid starts with (a
    /// resize's, [`rows_below_after_resize`]). Set before the first paint.
    /// `cleared`: the host's [`Terminal::screen_cleared`] now (a view made
    /// on the alternate screen first paints after the switch back).
    pub fn set_rows_below(&mut self, rows: Option<usize>, cleared: u64) {
        self.grid_below = rows;
        self.cleared_at = Some(cleared);
    }

    pub fn request_reset(&mut self) {
        self.needs_reset = true;
    }

    /// Host scrollback rows older than what the phone's terminal holds.
    pub fn older_rows(&self, term: &Terminal) -> usize {
        (self.window_from.saturating_sub(term.history_dropped) as usize).min(term.history.len())
    }

    /// The phone's terminal takes `host_rows` more of the older scrollback
    /// (a reset painted at the next paint). False: it has all of it.
    pub fn load_older(&mut self, term: &Terminal, host_rows: usize) -> bool {
        let older = self.older_rows(term);
        if older == 0 {
            return false;
        }
        let from = line_start(term, older.saturating_sub(host_rows.max(1)), self.compact);
        self.keep_from = Some(term.history_dropped + from as u64);
        self.needs_reset = true;
        true
    }

    /// Where a reset starts painting (an index in `term.history`, at a
    /// logical line's start): the scrollback lines that fill
    /// [`TAIL_SCREENS`] of the phone's screens above the host's screen, or
    /// older ones kept by [`View::keep_from`]. A width change costs this
    /// window, not the whole scrollback.
    fn window_start(&self, term: &Terminal) -> usize {
        let mut tail =
            rows_back(term, term.history.len(), self.cols, TAIL_SCREENS * self.rows, self.compact);
        if let Some(at) = self.pushed_at_paint {
            // Rows pushed since the last paint (all of them past a clear,
            // which empties the history).
            let new = term.history_pushed.saturating_sub(at) as usize;
            let len = term.history.len();
            tail = tail.min(line_start(term, len - new.min(len), self.compact));
        }
        match self.keep_from {
            Some(keep) => {
                let keep = keep.saturating_sub(term.history_dropped) as usize;
                line_start(term, keep.min(tail), self.compact)
            }
            None => tail,
        }
    }

    /// Rows of the live part (the unsettled lines and the screen) shown.
    pub fn live_rows(&self) -> usize {
        self.shown.len()
    }

    fn shown_end(&self) -> u64 {
        self.settled_end + self.shown.len() as u64
    }

    /// The first absolute row on the phone's screen (rows above it are in its scrollback).
    fn top(&self) -> u64 {
        self.shown_end().saturating_sub(self.rows as u64)
    }

    /// Brings the phone's terminal to the host's primary screen now.
    pub fn paint(&mut self, term: &mut Terminal, passthrough: &[u8]) -> Option<Paint> {
        let paint = self.paint_now(term, passthrough);
        self.pushed_at_paint = Some(term.history_pushed);
        paint
    }

    fn paint_now(&mut self, term: &mut Terminal, passthrough: &[u8]) -> Option<Paint> {
        if term.reset_needed {
            // The scrollback was cleared or the host resized: rows are not
            // the ones cached under their numbers.
            term.reset_needed = false;
            self.needs_reset = true;
            self.line_cache.clear();
            if !self.fresh {
                // A full reset or a host resize: its screen decides again.
                self.grid_below = None;
            }
        }
        self.fresh = false;
        if self.cleared_at.is_some_and(|at| at != term.screen_cleared) {
            self.grid_below = None;
        }
        if self.settled_host < term.history_dropped {
            // An unsettled line longer than the scrollback lost its start.
            self.needs_reset = true;
        }
        let reset = self.needs_reset;
        if reset {
            self.needs_reset = false;
            self.settled_end = 0;
            self.settled_host = term.history_dropped + self.window_start(term) as u64;
            self.window_from = self.settled_host;
            self.shown.clear();
            self.phone_cursor = (0, 0);
            self.phone_style = None;
            self.phone_cursor_visible = true;
            self.resets += 1;
        }
        let mut out = Vec::new();
        if reset {
            term.write_modes(&mut out);
        }
        out.extend_from_slice(passthrough);
        // 1. Lines that are now whole in the scrollback settle.
        let base = term.history_dropped;
        let history_len = term.history.len();
        let mut first = (self.settled_host - base) as usize;
        let mut newly: Vec<ProjectedRow> = Vec::new();
        if reset {
            // Settled lines, each as it was written before at this width.
            self.line_cache.retain(|start, _| *start >= base);
            self.phone_style = Some(Style::default());
            let cols = self.cols;
            let compact = self.compact;
            let mut count = 0;
            while let Some(last) = settled_end(term, first, compact) {
                let (bytes, rows) =
                    self.line_cache.entry(base + first as u64).or_insert_with(|| {
                        let rows: Vec<&Row> =
                            term.history.iter().take(last + 1).skip(first).collect();
                        encode_line(term, &rows, cols, compact)
                    });
                out.extend_from_slice(bytes);
                count += *rows;
                first = last + 1;
            }
            self.settled_end = count;
            self.phone_cursor = (count, 0);
        }
        // Otherwise they settle as rows the phone's terminal already has.
        while !reset && first < history_len {
            let Some(last) = settled_end(term, first, self.compact) else { break };
            let rows: Vec<&Row> = term.history.iter().take(last + 1).skip(first).collect();
            newly.extend(wrap_line(term, &rows, term.cols, self.cols, None, self.compact).rows);
            first = last + 1;
        }
        let settled_rows = newly.len();
        // 2. The live lines: the unsettled scrollback tail and the screen.
        let (cursor_x, cursor_y) = term.primary_cursor();
        let screen = term.primary_rows();
        let live_rows: Vec<&Row> = term.history.iter().skip(first).chain(screen.iter()).collect();
        let cursor_row = live_rows.len() - screen.len() + cursor_y;
        let mut live: Vec<ProjectedRow> = Vec::new();
        let mut cursor: Option<(usize, usize)> = None;
        // Rows of the live part up to its last line with something in it.
        let mut keep = 0;
        let mut start = 0;
        while start < live_rows.len() {
            let mut end = start;
            while end + 1 < live_rows.len() && joins_at(term, &live_rows, end, self.compact) {
                end += 1;
            }
            let in_line =
                (start..=end).contains(&cursor_row).then(|| (cursor_row - start, cursor_x));
            let line = live_rows.get(start..=end).unwrap_or_default();
            let wrapped = wrap_line(term, line, term.cols, self.cols, in_line, self.compact);
            if let Some((row, col)) = wrapped.cursor {
                cursor = Some((live.len() + row, col));
            }
            live.extend(wrapped.rows);
            if !wrapped.empty {
                keep = live.len();
            }
            start = end + 1;
        }
        let cursor_end = cursor.map_or(0, |(row, _)| row + 1);
        // The host's screen is a screen: at least the phone's rows of it, so a
        // cleared screen keeps its prompt at the top as on the host.
        let screen_floor = self.rows.min(live.len());
        let content_end = keep.max(cursor_end);
        let mut live_len = match self.grid_below {
            // A reset keeps the grid's blank rows; output takes them first.
            Some(below) if reset => content_end + below,
            Some(_) => content_end,
            None => content_end.max(screen_floor),
        };
        // The phone's terminal never takes rows back: what it shows stays as long.
        let shown_end = self.shown_end();
        let new_settled_end = self.settled_end + settled_rows as u64;
        let min_len = shown_end.saturating_sub(new_settled_end) as usize;
        if !reset && live_len < min_len {
            live_len = min_len;
        }
        live.resize(live_len, ProjectedRow::default());
        self.rows_below = live_len - content_end;
        if self.grid_below.is_some() {
            self.grid_below = Some(self.rows_below);
        }
        // 3. Rows from the old settled end: the newly settled ones, then the live ones.
        let mut tail = newly;
        tail.extend(live.iter().cloned());
        let from = self.settled_end;
        let mut first_changed: Option<(u64, usize)> = None;
        for (i, row) in tail.iter().enumerate() {
            match self.shown.get(i) {
                Some(old) if old == row => {}
                Some(old) => {
                    let common =
                        old.cells.iter().zip(&row.cells).take_while(|(a, b)| a == b).count();
                    first_changed = Some((from + i as u64, common));
                    break;
                }
                None => {
                    first_changed = Some((from + i as u64, 0));
                    break;
                }
            }
        }
        if first_changed.is_none() && self.shown.len() > tail.len() {
            first_changed = Some((from + tail.len() as u64, 0));
        }
        if let Some((row, _)) = first_changed
            && row < self.top()
            && !reset
        {
            // A change in rows the phone's terminal scrolled away: start over.
            self.needs_reset = true;
            term.reset_needed = false;
            return self.paint_now(term, passthrough);
        }
        let old_shown_end = shown_end;
        if let Some((row, 0)) = first_changed {
            // A new row of a soft-wrapped line: write it by the phone's own
            // autowrap, from the previous row's last glyph, so its wrap flag
            // (copy, its own reflow) is the host's.
            let i = (row - from) as usize;
            // (Only when that row is still on the phone's screen.)
            if i > 0
                && i <= self.shown.len()
                && row > self.top()
                && let Some(previous) = tail.get(i - 1)
                && previous.wrapped
                && previous.width() + 1 >= self.cols
                && !previous.cells.is_empty()
                && tail.get(i).is_some_and(|r| !r.cells.is_empty())
            {
                first_changed = Some((row - 1, previous.cells.len() - 1));
            }
        }
        if let Some((row, common)) = first_changed {
            // Only the wrap flag changed: the last glyph again, so the next
            // row comes by the phone's autowrap (wrapped), or after its own
            // line break (a full row no longer wrapped: the phone's cursor
            // cannot sit past its last column).
            let i = (row - from) as usize;
            if let Some(new_row) = tail.get(i)
                && common >= new_row.cells.len()
                && (new_row.wrapped || new_row.width() >= self.cols)
                && !new_row.cells.is_empty()
            {
                first_changed = Some((row, new_row.cells.len() - 1));
            }
        }
        if let Some((row, common)) = first_changed {
            let i = (row - from) as usize;
            let old_row = self.shown.get(i);
            let mut common = common;
            let mut unit_col: usize =
                tail.get(i).map_or(0, |r| r.cells.iter().take(common).map(|c| c.width()).sum());
            // Blank cells up to where the phone's cursor already is (the
            // space after a prompt) need not be written: an echo is the key.
            if let (Some(new_row), true) =
                (tail.get(i), old_row.is_none_or(|r| r.cells.len() <= common))
            {
                while self.phone_cursor == (row, self.phone_cursor.1)
                    && unit_col < self.phone_cursor.1
                    && new_row
                        .cells
                        .get(common)
                        .is_some_and(|c| c.is_empty_or_space() && c.style == 0 && c.kind != WIDE)
                {
                    common += 1;
                    unit_col += 1;
                }
            }
            let rows_below_drawn = self
                .shown
                .get(i + 1..)
                .is_some_and(|rows| rows.iter().any(|r| !r.cells.is_empty()));
            let had_after = old_row.is_some_and(|r| r.cells.len() > common) || rows_below_drawn;
            let erase_rows_below = rows_below_drawn;
            // The phone's terminal rows: old ones in place; new ones are added at the bottom.
            self.move_to(&mut out, row, unit_col, old_shown_end);
            if had_after {
                if self.phone_style != Some(Style::default()) {
                    Style::default().write_sgr(&mut out);
                    self.phone_style = Some(Style::default());
                }
                out.extend_from_slice(if erase_rows_below { b"\x1b[J" } else { b"\x1b[K" });
            }
            let mut abs = row;
            let mut col = unit_col;
            // Blank rows the phone's screen already has (erased above) are
            // not written; rows past its bottom are, so it scrolls.
            let physical_end = old_shown_end.max(self.rows as u64);
            let new_end = from + tail.len() as u64;
            // `i` is a row of `tail` (the loop above stops inside it), so
            // `tail.len() - 1 - i` cannot underflow and `i + last` is in range.
            debug_assert!(i < tail.len(), "paint row {i} past the tail ({})", tail.len());
            let last = if new_end > physical_end {
                tail.len() - 1 - i
            } else {
                tail.get(i..).and_then(|t| t.iter().rposition(|r| !r.cells.is_empty())).unwrap_or(0)
            };
            for (k, projected) in tail.get(i..=i + last).unwrap_or_default().iter().enumerate() {
                let skip = if k == 0 { common.min(projected.cells.len()) } else { 0 };
                if k > 0 {
                    // A soft wrap is the phone's own autowrap (a wrapped row
                    // is full, or one short of a wide glyph that follows).
                    if !tail.get(i + k - 1).is_some_and(|r| r.wrapped) {
                        // A line feed that scrolls fills the new row with the
                        // current background (BCE): the default one, as the
                        // host's own empty rows have.
                        if let Some(style) = self.phone_style.filter(|s| s.bg != Color::Default) {
                            self.phone_style = Some(plain_keeping_link(&mut out, style));
                        }
                        out.extend_from_slice(b"\r\n");
                    }
                    abs += 1;
                    col = 0;
                }
                for cell in projected.cells.iter().skip(skip) {
                    let style = term.styles.get(cell.style);
                    if self.phone_style != Some(style) {
                        write_style(term, &mut out, self.phone_style, style);
                        self.phone_style = Some(style);
                    }
                    if cell.ch == 0 {
                        out.push(b' ');
                    } else {
                        term.write_cell(*cell, &mut out);
                    }
                    col += cell.width();
                }
                if k > 0 && tail.get(i + k - 1).is_some_and(|r| r.wrapped) {
                    let entered = projected.cells.first().map(|c| term.styles.get(c.style));
                    if let Some(style) = self.phone_style
                        && end_after_autowrap(projected, entered, self.cols)
                    {
                        self.phone_style = Some(plain_keeping_link(&mut out, style));
                        out.extend_from_slice(b"\x1b[K");
                    }
                }
            }
            // A soft wrap left pending lands on the next row when written.
            self.phone_cursor = (abs, col);
        }
        self.settled_end = new_settled_end;
        self.settled_host = base + first as u64;
        self.shown = live;
        // 4. The cursor.
        let visible_row = cursor
            .map(|(row, col)| (self.settled_end + row as u64, col))
            .filter(|(row, _)| *row >= self.top());
        let want_visible = term.cursor_visible && visible_row.is_some();
        if let Some((row, col)) = visible_row {
            let shown_end = self.shown_end();
            let col = col.min(self.cols - 1);
            let (at_row, at_col) = self.phone_cursor;
            let row_width = row
                .checked_sub(self.settled_end)
                .and_then(|i| self.shown.get(i as usize))
                .map_or(0, ProjectedRow::width);
            if at_row == row
                && col > at_col
                && at_col >= row_width
                && col - at_col <= 8
                && self
                    .phone_style
                    .is_some_and(|style| style.is_invisible_when_blank() && style.link == 0)
            {
                // Past the row's end, as the host's own echo of a space does.
                // (Not in a link: a space written in one is a linked cell,
                // and the host's blanks there are not.)
                out.extend(std::iter::repeat_n(b' ', col - at_col));
                self.phone_cursor = (row, col);
            } else if at_row == row && at_col == col + 1 && at_col < self.cols {
                // One cell back (onto a blank just written past the line's
                // end, the cursor's own): a backspace, not a CUP.
                out.push(0x08);
                self.phone_cursor = (row, col);
            } else if self.phone_cursor != (row, col) {
                self.move_to(&mut out, row, col, shown_end);
            }
        }
        if want_visible != self.phone_cursor_visible {
            out.extend_from_slice(if want_visible { b"\x1b[?25h" } else { b"\x1b[?25l" });
            self.phone_cursor_visible = want_visible;
        }
        // The program's own style again, for anything the phone draws itself.
        if reset {
            self.bytes_out += out.len() as u64;
            return Some(Paint::Reset(out));
        }
        if out.is_empty() {
            return None;
        }
        self.bytes_out += out.len() as u64;
        Some(Paint::Update(out))
    }

    /// Moves the phone's cursor to absolute row `row`, column `col`, given
    /// the rows its terminal holds (`end`). A row past the end is reached
    /// with line feeds, which scroll the phone's terminal as the host's would.
    fn move_to(&mut self, out: &mut Vec<u8>, row: u64, col: usize, end: u64) {
        let col = col.min(self.cols - 1);
        if self.phone_cursor == (row, col) && col < self.cols {
            return;
        }
        let top = end.saturating_sub(self.rows as u64);
        let last = end.max(1) - 1;
        if row <= last.max(top) && row >= top {
            let screen_row = row - top;
            out.extend_from_slice(format!("\x1b[{};{}H", screen_row + 1, col + 1).as_bytes());
        } else {
            // Below the rows written so far: to the last one, then down.
            let from = if end == 0 { 0 } else { last };
            let screen_row = from - top;
            out.extend_from_slice(format!("\x1b[{};1H", screen_row + 1).as_bytes());
            if let Some(style) = self.phone_style.filter(|s| s.bg != Color::Default) {
                // Rows a line feed scrolls in take the current background.
                self.phone_style = Some(plain_keeping_link(out, style));
            }
            for _ in from..row {
                out.extend_from_slice(b"\n");
            }
            if col > 0 {
                out.extend_from_slice(format!("\x1b[{}G", col + 1).as_bytes());
            } else {
                out.push(b'\r');
            }
        }
        self.phone_cursor = (row, col);
    }
}

/// A settled line as a reset writes it: from the default style, back to
/// it, then a line break. Its bytes and its rows at `cols`.
fn encode_line(term: &Terminal, rows: &[&Row], cols: usize, compact: bool) -> (Vec<u8>, u64) {
    let wrapped = wrap_line(term, rows, term.cols, cols, None, compact);
    let mut out = Vec::new();
    let mut style = Style::default();
    let mut previous_wrapped = false;
    for row in &wrapped.rows {
        // A line's rows follow by the phone's own autowrap.
        let entered = row.cells.first().map(|c| term.styles.get(c.style));
        for cell in &row.cells {
            let next = term.styles.get(cell.style);
            if next != style {
                write_style(term, &mut out, Some(style), next);
                style = next;
            }
            if cell.ch == 0 {
                out.push(b' ');
            } else {
                term.write_cell(*cell, &mut out);
            }
        }
        if previous_wrapped && end_after_autowrap(row, entered, cols) {
            style = plain_keeping_link(&mut out, style);
            out.extend_from_slice(b"\x1b[K");
        }
        previous_wrapped = row.wrapped;
    }
    if style != Style::default() {
        write_style(term, &mut out, Some(style), Style::default());
    }
    out.extend_from_slice(b"\r\n");
    (out, wrapped.rows.len() as u64)
}

/// Whether the rest of `row` must be erased in the default style once its
/// cells are written: the last row of a line, not full, entered by the
/// phone's autowrap in `entered` (its first glyph's style) with a
/// background. An autowrap that scrolls fills the new row with that
/// background (BCE), where the host has none past the line's end.
fn end_after_autowrap(row: &ProjectedRow, entered: Option<Style>, cols: usize) -> bool {
    !row.wrapped && row.width() < cols && entered.is_some_and(|s| s.bg != Color::Default)
}

/// Writes the default SGR, keeping the open link (an SGR reset does not
/// close one); the style the phone's terminal then has.
fn plain_keeping_link(out: &mut Vec<u8>, style: Style) -> Style {
    let plain = Style { link: style.link, ..Style::default() };
    plain.write_sgr(out);
    plain
}

pub(crate) fn write_style(
    term: &Terminal,
    out: &mut Vec<u8>,
    previous: Option<Style>,
    style: Style,
) {
    if previous.map(|p| p.link) != Some(style.link) {
        if style.link == 0 {
            out.extend_from_slice(b"\x1b]8;;\x1b\\");
        } else {
            out.extend_from_slice(b"\x1b]8;");
            out.extend_from_slice(term.links.get(style.link).as_bytes());
            out.extend_from_slice(b"\x1b\\");
        }
    }
    let without_link = Style { link: 0, ..style };
    if previous.map(|p| Style { link: 0, ..p }) != Some(without_link) {
        without_link.write_sgr(out);
    }
}

#[cfg(test)]
#[path = "project_tests.rs"]
mod tests;
