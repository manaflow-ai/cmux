//! R3b of the resize audit (Swift `ColumnWidthLedger`): a create keeps every other column's width in
//! points. A screen records its columns' rest widths before the first create since its last check
//! ([`note_change`]) and compares them once the layout settled ([`take`]). The column that took a new
//! pane by a split is not compared; a change of the screen's width drops the record.

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// `ColumnWidthLedger.tolerance`: float noise below this is not a width change.
pub const TOLERANCE: f64 = 0.001;

/// `ColumnWidthLedger.Column`: one column at rest. `id` is `None` for a screen stored as one split tree.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LedgerColumn {
    #[serde(default)]
    pub id: Option<String>,
    pub panes: BTreeSet<String>,
    pub width: f64,
    /// Pinned to a viewport edge: a dock that comes or goes is not a create.
    #[serde(default)]
    pub docked: bool,
}

/// `ColumnWidthLedger.Record`: the screen's width and its columns before the first create.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LedgerRecord {
    pub viewport_width: f64,
    pub columns: Vec<LedgerColumn>,
}

/// `ColumnWidthLedger.Change`: a column a create resized (`"screen"` for a split tree's).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LedgerChange {
    pub column: String,
    pub before: f64,
    pub after: f64,
}

/// `noteChange(from:to:viewportWidth:)`: the record after the layout changed from `before` to `after`.
/// A create (a pane `before` did not have) is recorded; a move, close, width or dock change is not. A
/// second create before the check adds the columns the first one made.
pub fn note_change(
    record: Option<LedgerRecord>,
    before: &[LedgerColumn],
    after: &[LedgerColumn],
    viewport_width: f64,
) -> Option<LedgerRecord> {
    let panes: BTreeSet<&String> = before.iter().flat_map(|column| &column.panes).collect();
    let docks = |columns: &[LedgerColumn]| -> BTreeSet<Option<String>> {
        columns.iter().filter(|column| column.docked).map(|column| column.id.clone()).collect()
    };
    let creates = after.iter().any(|column| column.panes.iter().any(|pane| !panes.contains(pane)));
    if !(viewport_width > 0. && docks(before) == docks(after) && creates) {
        return record;
    }
    let Some(mut record) = record.filter(|record| record.viewport_width == viewport_width) else {
        return Some(LedgerRecord { viewport_width, columns: before.to_vec() });
    };
    let known: BTreeSet<String> = record.columns.iter().filter_map(|c| c.id.clone()).collect();
    record.columns.extend(
        before
            .iter()
            .filter(|column| column.id.as_ref().is_some_and(|id| !known.contains(id)))
            .cloned(),
    );
    Some(record)
}

/// `take(_:viewportWidth:)`: the recorded columns whose width differs in `current` (the record is
/// cleared). A column that is gone is not compared, nor one that took a new pane; a split tree's
/// column is the current column holding most of its panes.
pub fn take(
    record: Option<&LedgerRecord>,
    current: &[LedgerColumn],
    viewport_width: f64,
) -> Vec<LedgerChange> {
    let Some(record) = record else { return Vec::new() };
    if record.viewport_width != viewport_width {
        return Vec::new();
    }
    let recorded: BTreeSet<&String> = record.columns.iter().flat_map(|c| &c.panes).collect();
    record
        .columns
        .iter()
        .filter_map(|old| {
            let now = match &old.id {
                Some(id) => current.iter().find(|column| column.id.as_ref() == Some(id)),
                None => {
                    let shared =
                        |column: &LedgerColumn| column.panes.intersection(&old.panes).count();
                    current.iter().filter(|column| !column.panes.is_disjoint(&old.panes)).reduce(
                        |best, column| if shared(best) < shared(column) { column } else { best },
                    )
                }
            }?;
            let within = now.panes.iter().all(|pane| recorded.contains(pane));
            (within && (now.width - old.width).abs() > TOLERANCE).then(|| LedgerChange {
                column: old.id.clone().unwrap_or_else(|| "screen".to_string()),
                before: old.width,
                after: now.width,
            })
        })
        .collect()
}
