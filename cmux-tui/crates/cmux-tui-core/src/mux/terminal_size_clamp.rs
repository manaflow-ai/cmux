//! The one size rule for terminal requests.

use crate::sizing_policy::TerminalGridSize;

/// The one size rule for every terminal request: the sizing engine's
/// minimum (2 x 1), the largest side, and the host's cell-area limit (rows
/// give way, so the width a person sees is kept). Local and hosted
/// terminals then accept the same sizes.
pub(crate) fn clamp_terminal_size(cols: u16, rows: u16) -> (u16, u16) {
    use crate::terminal_host_runtime::{TERMINAL_CELL_AREA_MAX, TERMINAL_DIMENSION_MAX};
    let grid = TerminalGridSize::new(cols, rows).clamped();
    let cols = grid.cols.min(TERMINAL_DIMENSION_MAX);
    let rows = grid.rows.min(TERMINAL_DIMENSION_MAX);
    let area_rows = u16::try_from(TERMINAL_CELL_AREA_MAX / u64::from(cols)).unwrap_or(u16::MAX);
    (cols, rows.min(area_rows))
}
