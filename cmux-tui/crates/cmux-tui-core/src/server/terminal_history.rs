//! `terminal-history` and `terminal-read-range` (raw v12 forms of the
//! `terminal.history` and `terminal.read_range` ops in
//! `.cmux-scratch/nx-worker/cli-requests/terminal-snapshot-history.md`).
//!
//! Rows are addressed by host row markers (see ghostty-vt
//! `terminal_history.rs`): a marker stays on its row while output scrolls,
//! and reads of rows that left scrollback answer `range_evicted`. Markers
//! belong to a `marker_epoch`; a reflow starts a new epoch.

use std::sync::Arc;

use base64::Engine as _;
use serde::Deserialize;
use serde_json::{Value, json};

use super::{get_surface, require_pty};
use crate::{Mux, SurfaceId};

/// Default and maximum page bytes of one `terminal-history` reply.
pub const TERMINAL_HISTORY_DEFAULT_BYTES: usize = 1 << 20;
pub const TERMINAL_HISTORY_MAX_BYTES: usize = 8 << 20;

#[derive(Debug, Deserialize)]
pub(crate) struct TerminalHistoryParams {
    surface: SurfaceId,
    /// Marker of the newest row the caller already has; absent: the top of
    /// the active area.
    #[serde(default)]
    before: Option<u64>,
    #[serde(default)]
    marker_epoch: Option<u64>,
    #[serde(default)]
    max_bytes: Option<usize>,
}

/// One end of a `terminal-read-range` range.
#[derive(Debug, Deserialize)]
pub(crate) struct RowMarkerPoint {
    row_marker: u64,
    col: u16,
}

#[derive(Debug, Deserialize)]
pub(crate) struct TerminalReadRangeParams {
    surface: SurfaceId,
    from: RowMarkerPoint,
    to: RowMarkerPoint,
    /// `text` (default) or `vt`.
    #[serde(default)]
    format: Option<String>,
    #[serde(default)]
    marker_epoch: Option<u64>,
    /// Largest `text` in bytes (default 1 MiB, at most 8 MiB); a longer
    /// range is cut at a character boundary and answers `truncated: true`.
    #[serde(default)]
    max_bytes: Option<usize>,
}

/// Cut `text` to at most `max_bytes` at a character boundary.
fn truncate_text(mut text: String, max_bytes: usize) -> (String, bool) {
    if text.len() <= max_bytes {
        return (text, false);
    }
    let mut end = max_bytes;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text.truncate(end);
    (text, true)
}

fn marker_error(error: ghostty_vt::MarkerError) -> anyhow::Error {
    match error {
        ghostty_vt::MarkerError::RangeEvicted => anyhow::anyhow!("range_evicted"),
        ghostty_vt::MarkerError::Invalid => anyhow::anyhow!("invalid: range is outside the screen"),
        ghostty_vt::MarkerError::Vt(error) => anyhow::anyhow!("terminal snapshot failed: {error}"),
    }
}

pub(crate) fn history(mux: &Arc<Mux>, params: TerminalHistoryParams) -> anyhow::Result<Value> {
    let surface = get_surface(mux, params.surface)?;
    require_pty(&surface)?;
    let max_bytes = params.max_bytes.unwrap_or(TERMINAL_HISTORY_DEFAULT_BYTES);
    anyhow::ensure!(
        (1..=TERMINAL_HISTORY_MAX_BYTES).contains(&max_bytes),
        "invalid: max_bytes must be 1..={TERMINAL_HISTORY_MAX_BYTES}"
    );
    let pages = surface
        .history_pages(params.marker_epoch, params.before, max_bytes)
        .map_err(marker_error)?;
    let engine = &base64::engine::general_purpose::STANDARD;
    Ok(json!({
        "surface": params.surface,
        "marker_epoch": pages.marker_epoch,
        "snapshot_version": ghostty_vt::snapshot_version(),
        "pages": pages.pages.iter().map(|page| json!({
            "marker": page.marker,
            "rows": page.rows,
            "data": engine.encode(&page.record),
        })).collect::<Vec<_>>(),
        "next_before": pages.next_before,
        "done": pages.done,
    }))
}

pub(crate) fn read_range(mux: &Arc<Mux>, params: TerminalReadRangeParams) -> anyhow::Result<Value> {
    let surface = get_surface(mux, params.surface)?;
    require_pty(&surface)?;
    let max_bytes = params.max_bytes.unwrap_or(TERMINAL_HISTORY_DEFAULT_BYTES);
    anyhow::ensure!(
        (1..=TERMINAL_HISTORY_MAX_BYTES).contains(&max_bytes),
        "invalid: max_bytes must be 1..={TERMINAL_HISTORY_MAX_BYTES}"
    );
    let vt = match params.format.as_deref().unwrap_or("text") {
        "text" => false,
        "vt" => true,
        other => anyhow::bail!("invalid: format must be text or vt, got {other:?}"),
    };
    let text = surface
        .read_marker_range(
            params.marker_epoch,
            (params.from.row_marker, params.from.col),
            (params.to.row_marker, params.to.col),
            vt,
        )
        .map_err(marker_error)?;
    let (text, truncated) = truncate_text(text, max_bytes);
    Ok(json!({"surface": params.surface, "text": text, "truncated": truncated}))
}

#[cfg(test)]
mod tests {
    use super::truncate_text;

    #[test]
    fn read_range_text_is_cut_at_a_character_boundary() {
        assert_eq!(truncate_text("abc".into(), 8), ("abc".to_string(), false));
        assert_eq!(truncate_text("abcdef".into(), 4), ("abcd".to_string(), true));
        // "é" is two bytes: a cut inside it backs off to the boundary.
        assert_eq!(truncate_text("aé".into(), 2), ("a".to_string(), true));
    }
}
