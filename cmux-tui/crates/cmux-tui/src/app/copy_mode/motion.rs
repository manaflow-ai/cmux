//! Copy-mode word motions (vim `w`/`b`/`e` and their WORD forms) over the
//! screen as one stream of cells. A hard line end separates words; a soft
//! wrap does not, so a word that wraps is one word.

use super::engine::{CopyPoint, CopyView};
use super::grid::TerminalGrid;

/// How many rows one word motion may cross before it stops where it is, so
/// a motion over a long run of blank rows stays bounded.
const WORD_MOTION_ROWS: u64 = 512;

/// The class of a cell: 0 blank, 1 word characters, 2 punctuation. A WORD
/// motion (`big`) treats every non-blank cell as one class.
fn class(grid: &mut TerminalGrid<'_>, point: CopyPoint, big: bool) -> u8 {
    match grid.first_char(point) {
        None => 0,
        Some(c) if c.is_whitespace() => 0,
        Some(_) if big => 1,
        Some(c) if c.is_alphanumeric() || c == '_' => 1,
        Some(_) => 2,
    }
}

/// The next cell, and whether a hard line end lies between the two.
fn forward(grid: &mut TerminalGrid<'_>, point: CopyPoint) -> Option<(CopyPoint, bool)> {
    if let Some(col) = grid.next_col(point) {
        return Some((CopyPoint { col, ..point }, false));
    }
    let row = point.row.checked_add(1).filter(|row| *row < grid.total_rows())?;
    let hard = !grid.wraps(point.row);
    Some((CopyPoint { row, col: 0 }, hard))
}

/// The previous cell, and whether a hard line end lies between the two.
fn backward(grid: &mut TerminalGrid<'_>, point: CopyPoint) -> Option<(CopyPoint, bool)> {
    if let Some(col) = grid.prev_col(point) {
        return Some((CopyPoint { col, ..point }, false));
    }
    let row = point.row.checked_sub(1)?;
    let hard = !grid.wraps(row);
    let col = grid.lead_col(row, grid.last_col());
    Some((CopyPoint { row, col }, hard))
}

fn within(origin: CopyPoint, point: CopyPoint) -> bool {
    origin.row.abs_diff(point.row) <= WORD_MOTION_ROWS
}

/// `w`: the start of the next word.
pub(crate) fn word_next(grid: &mut TerminalGrid<'_>, origin: CopyPoint, big: bool) -> CopyPoint {
    let start_class = class(grid, origin, big);
    let mut cur = origin;
    if start_class != 0 {
        loop {
            let Some((next, hard)) = forward(grid, cur) else { return origin };
            cur = next;
            if hard || class(grid, cur, big) != start_class {
                break;
            }
        }
    }
    while class(grid, cur, big) == 0 {
        match forward(grid, cur) {
            Some((next, _)) if within(origin, next) => cur = next,
            _ => return cur,
        }
    }
    cur
}

/// `e`: the end of the current or next word.
pub(crate) fn word_end(grid: &mut TerminalGrid<'_>, origin: CopyPoint, big: bool) -> CopyPoint {
    let Some((mut cur, _)) = forward(grid, origin) else { return origin };
    while class(grid, cur, big) == 0 {
        match forward(grid, cur) {
            Some((next, _)) if within(origin, next) => cur = next,
            _ => return origin,
        }
    }
    let word_class = class(grid, cur, big);
    while let Some((next, hard)) = forward(grid, cur) {
        if hard || class(grid, next, big) != word_class {
            break;
        }
        cur = next;
    }
    cur
}

/// `b`: the start of the current or previous word.
pub(crate) fn word_prev(grid: &mut TerminalGrid<'_>, origin: CopyPoint, big: bool) -> CopyPoint {
    let Some((mut cur, _)) = backward(grid, origin) else { return origin };
    while class(grid, cur, big) == 0 {
        match backward(grid, cur) {
            Some((next, _)) if within(origin, next) => cur = next,
            _ => return origin,
        }
    }
    let word_class = class(grid, cur, big);
    while let Some((prev, hard)) = backward(grid, cur) {
        if hard || class(grid, prev, big) != word_class {
            break;
        }
        cur = prev;
    }
    cur
}

/// `G`: the last row holding text, searched up from the bottom of history
/// through at most one view; the bottom row when the whole range is blank.
pub(crate) fn last_text_row(grid: &mut TerminalGrid<'_>, view: CopyView) -> u64 {
    let last = grid.total_rows() - 1;
    let floor = last.saturating_sub(u64::from(view.height.max(1)));
    (floor..=last)
        .rev()
        .find(|&row| {
            let col = grid.last_non_blank(row);
            !grid.is_blank(CopyPoint { row, col })
        })
        .unwrap_or(last)
}
