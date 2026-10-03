//! `rows-v1` commands (plans/cmux-next/rows.md): `new-row` opens a row
//! below a pane's row, `set-row-heights` resizes every row of a column. The
//! read shape is `Screen.columns[].rows` (screen_json.rs).

use super::*;

/// `new-row`: one new terminal in a new pane, in a new row of
/// `height_permille` below the row of `pane`.
#[derive(Deserialize)]
pub(super) struct NewRowParams {
    pane: PaneId,
    height_permille: u64,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    env: Option<BTreeMap<String, String>>,
    #[serde(default)]
    keep: bool,
    #[serde(default)]
    terminal_id: Option<String>,
    #[serde(default)]
    shell_args: Option<Vec<String>>,
    /// Echoed in the result and in the `screen-changed` delta.
    #[serde(default)]
    transaction: Option<String>,
}

pub(super) fn new_row(mux: &Arc<Mux>, params: NewRowParams) -> anyhow::Result<Value> {
    let NewRowParams {
        pane,
        height_permille,
        cols,
        rows,
        cwd,
        env,
        keep,
        terminal_id,
        shell_args,
        transaction,
    } = params;
    validate_client_transaction(transaction.as_deref())?;
    let spawn = placement_spawn_options(cwd, env.as_ref(), terminal_id, shell_args)?;
    let size = optional_surface_size(cols, rows);
    let surface =
        mux.new_row_with_options(pane, height_permille, spawn, size, transaction.clone())?;
    let mut result = placed_terminal_result(mux, &surface, keep)?;
    result["pane"] = json!(mux.with_state(|state| state.pane_of(surface.id)));
    if let Some(transaction) = transaction {
        result["transaction"] = json!(transaction);
    }
    Ok(result)
}

#[derive(Deserialize)]
pub(super) struct RowHeight {
    row: SplitId,
    height: u64,
}

/// `set-row-heights`: every row of `column` at once.
#[derive(Deserialize)]
pub(super) struct SetRowHeightsParams {
    column: SplitId,
    heights: Vec<RowHeight>,
    #[serde(default)]
    fit: bool,
    #[serde(default)]
    transaction: Option<u64>,
}

pub(super) fn set_row_heights(
    mux: &Arc<Mux>,
    client: u64,
    params: SetRowHeightsParams,
) -> anyhow::Result<Value> {
    let SetRowHeightsParams { column, heights, fit, transaction } = params;
    let heights = heights.iter().map(|entry| (entry.row, entry.height)).collect::<Vec<_>>();
    let scoped = transaction.map(|transaction| (client, transaction));
    let outcome = mux.set_row_heights(column, &heights, fit, scoped)?;
    let mut data =
        json!({"screen": outcome.screen, "column": outcome.column, "changed": outcome.changed});
    if let Some(transaction) = transaction {
        data["transaction"] = json!(transaction);
    }
    Ok(data)
}

/// `error_code` of a rejected row command.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<crate::mux::RowsError>().and_then(|error| error.code()).map(str::to_string)
}
