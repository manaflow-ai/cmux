//! Render a libghostty-vt `Terminal` viewport as a vec of text rows.

use libghostty_vt::Terminal;
use libghostty_vt::render::{CellIterator, RenderState, RowIterator};

/// Dump every row of the active viewport as a String (graphemes concatenated).
/// Trailing whitespace per row is trimmed; cells with no graphemes render as a
/// single space so column positions stay roughly aligned.
pub fn dump_rows(terminal: &Terminal<'_, '_>) -> anyhow::Result<Vec<String>> {
    let mut render_state = RenderState::new()?;
    let snapshot = render_state.update(terminal)?;

    let mut row_iter = RowIterator::new()?;
    let mut row_iteration = row_iter.update(&snapshot)?;

    let mut out = Vec::new();
    while row_iteration.next().is_some() {
        let mut cell_iter = CellIterator::new()?;
        let mut cell_iteration = cell_iter.update(&row_iteration)?;

        let mut row = String::new();
        while cell_iteration.next().is_some() {
            let graphemes = cell_iteration.graphemes()?;
            if graphemes.is_empty() {
                row.push(' ');
            } else {
                for ch in graphemes {
                    if ch != '\0' {
                        row.push(ch);
                    }
                }
            }
        }
        out.push(row.trim_end().to_string());
    }
    Ok(out)
}
