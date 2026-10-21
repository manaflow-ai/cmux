//! `column-move-v1`: `move-column` moves the whole viewport column holding
//! a pane one place left or right (crate::mux::column_move).

use super::*;
use crate::mux::{ColumnMoveDirection, ColumnMoveError};

/// `move-column`: the column holding `pane` trades places with its
/// neighbor in `direction`.
#[derive(Deserialize)]
pub(super) struct MoveColumnParams {
    pane: PaneId,
    /// `left` or `right`; a string so a bad value answers
    /// `error_code:"invalid-argument"` instead of a decode error.
    direction: String,
}

pub(super) fn move_column(
    mux: &Arc<Mux>,
    client: u64,
    params: MoveColumnParams,
) -> anyhow::Result<Value> {
    let actor = origin_gate::connection_actor(mux, client);
    let direction = ColumnMoveDirection::parse(&params.direction)?;
    let outcome = mux.move_column_as(&actor, params.pane, direction)?;
    Ok(json!({
        "screen": outcome.screen,
        "column": outcome.column,
        "index": outcome.index,
        "changed": true,
    }))
}

/// `error_code` of a refused `move-column`.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<ColumnMoveError>().and_then(ColumnMoveError::code).map(str::to_string)
}
