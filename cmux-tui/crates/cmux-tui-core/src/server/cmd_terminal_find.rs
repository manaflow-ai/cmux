//! `terminal-find`: one page of Cmd-F matches in a terminal's whole retained screen (the
//! scrollback and the active area), newest first, with the find bar's case, whole-word and
//! regex toggles (cmux-terminal-find has the matching).
//!
//! Rows are named by history marker (`history_marker`: the row's number counted from the first
//! row this terminal ever retained), so a page's cursor and its matches stay valid while old
//! rows are evicted at the top. The terminal's lock is held for one chunk of rows at a time,
//! never for the whole search: output keeps flowing while a long history is searched.

use super::get_surface;
use super::require_pty;
use crate::Mux;
use crate::SurfaceId;
use cmux_terminal_find::{
    Cell, CellRole, FindOptions, MATCH_CAP, Matcher, RowCells, ScreenMatch, scan_page,
};
use ghostty_vt::CellWidth;
use ghostty_vt::ScreenRowText;
use ghostty_vt::Terminal;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

/// Rows read under one hold of the terminal's lock.
const CHUNK_ROWS: u64 = 512;
/// Rows one page reads unless the caller asks for fewer: the first page answers in a few
/// milliseconds, and the bar asks for the next while the person reads the newest matches.
const DEFAULT_PAGE_ROWS: u64 = 8_192;

pub(super) struct FindRequest {
    pub query: String,
    pub options: FindOptions,
    /// The marker of the row the page ends above (exclusive); `None` starts at the bottom.
    pub before: Option<u64>,
    /// The marker epoch the cursor came from; a different one (a reflow renumbered the rows)
    /// restarts at the bottom and says so.
    pub epoch: Option<u64>,
    pub page_rows: Option<u64>,
    pub max_matches: Option<usize>,
}

pub(super) fn terminal_find(
    mux: &Arc<Mux>,
    surface: SurfaceId,
    request: FindRequest,
) -> anyhow::Result<Value> {
    let surface = get_surface(mux, surface)?;
    require_pty(&surface)?;
    find_page(&request, |read| surface.try_with_terminal(|term| read(term)))
}

/// One page of `request` over a terminal that `with_terminal` locks for one call of its
/// argument at a time.
fn find_page(
    request: &FindRequest,
    with_terminal: impl Fn(&mut dyn FnMut(&mut Terminal)) -> anyhow::Result<()>,
) -> anyhow::Result<Value> {
    let matcher = match Matcher::new(&request.query, request.options) {
        Ok(Some(matcher)) => matcher,
        Ok(None) => return Ok(json!({ "matches": [], "next_before": null, "complete": true })),
        Err(err) => {
            return Ok(json!({
                "matches": [],
                "next_before": null,
                "complete": true,
                "invalid_pattern": err.to_string(),
            }));
        }
    };
    let (mut epoch, mut bottom) = (0, 0);
    with_terminal(&mut |term| {
        epoch = term.history_marker_epoch();
        bottom = term.history_marker(screen_total(term));
    })?;
    let restarted = request.epoch.is_some_and(|asked| asked != epoch);
    let before = if restarted { bottom } else { request.before.unwrap_or(bottom).min(bottom) };
    let page_rows = request.page_rows.unwrap_or(DEFAULT_PAGE_ROWS).max(1);
    let max_matches = request.max_matches.unwrap_or(MATCH_CAP).clamp(1, MATCH_CAP);
    let mut failed = None;
    let page = scan_page(&matcher, before, page_rows, max_matches, CHUNK_ROWS, |start, end| {
        let mut rows = Vec::new();
        if let Err(err) = with_terminal(&mut |term| rows = read_rows(term, epoch, start, end)) {
            failed = Some(err);
        }
        rows
    });
    if let Some(err) = failed {
        return Err(err);
    }
    // Where each match sits from the bottom now, which a mirror with less history (the
    // Mac's and the phone's Ghostty) maps to its own rows.
    let (mut now_bottom, mut now_epoch, mut rows, mut cols) = (0, 0, 0, 0);
    with_terminal(&mut |term| {
        now_bottom = term.history_marker(screen_total(term));
        now_epoch = term.history_marker_epoch();
        rows = term.rows();
        cols = term.cols();
    })?;
    let matches =
        page.matches.iter().map(|found| match_json(found, now_bottom)).collect::<Vec<_>>();
    Ok(json!({
        "matches": matches,
        "next_before": page.next_before,
        "complete": page.next_before.is_none(),
        "epoch": epoch,
        "renumbered": now_epoch != epoch,
        "restarted": restarted,
        "interrupted": page.interrupted,
        "scanned_rows": page.scanned_rows,
        "bottom": now_bottom,
        "rows": rows,
        "cols": cols,
    }))
}

/// Rows `start..end` (markers) top to bottom; fewer when the oldest were evicted, none when the
/// epoch changed.
fn read_rows(term: &Terminal, epoch: u64, start: u64, end: u64) -> Vec<RowCells> {
    if term.history_marker_epoch() != epoch {
        return Vec::new();
    }
    let base = term.history_marker(0);
    let total = screen_total(term);
    let first = start.max(base) - base;
    let last = end.saturating_sub(base).min(total);
    (first..last).map_while(|row| term.screen_row_text(row)).map(row_cells).collect()
}

/// Every retained row: the scrollback and the active area.
fn screen_total(term: &Terminal) -> u64 {
    term.scrollback_rows() as u64 + u64::from(term.rows())
}

fn row_cells(row: ScreenRowText) -> RowCells {
    RowCells {
        cells: row
            .cells
            .into_iter()
            .map(|cell| Cell {
                text: cell.text,
                role: match cell.width {
                    CellWidth::Narrow => CellRole::Narrow,
                    CellWidth::Wide => CellRole::Wide,
                    CellWidth::SpacerTail => CellRole::SpacerTail,
                    CellWidth::SpacerHead => CellRole::SpacerHead,
                },
            })
            .collect(),
        wraps: row.wraps,
    }
}

fn match_json(found: &ScreenMatch, bottom: u64) -> Value {
    json!({
        "start": { "marker": found.start.row, "column": found.start.column },
        "end": { "marker": found.end.row, "column": found.end.column },
        // 1 is the bottom row.
        "rows_from_bottom": bottom.saturating_sub(found.start.row),
        "snippet": found.snippet,
        "snippet_start": found.snippet_start,
        "snippet_len": found.snippet_len,
    })
}

#[cfg(test)]
#[path = "cmd_terminal_find_tests.rs"]
mod tests;
