//! `move-tab-to-column`: drop a tab between strip columns, or into a new
//! column pinned to an edge in the same commit (`edge-docks-v1`).

use super::*;

/// `move-tab-to-column`: a new column holding the tab, after `after_column`
/// (default: right of the anchor's column). `sticky` pins the new column;
/// the column that held that edge scrolls again.
#[derive(Deserialize)]
pub(super) struct MoveTabToColumnParams {
    surface: SurfaceId,
    #[serde(default)]
    pane: Option<PaneId>,
    #[serde(default)]
    screen: Option<ScreenId>,
    #[serde(default)]
    after_column: Option<SplitId>,
    #[serde(default)]
    width: Option<f32>,
    #[serde(default)]
    sticky: Option<crate::model::ColumnSticky>,
    #[serde(default)]
    transaction: Option<String>,
}

pub(super) fn move_tab_to_column(
    mux: &Arc<Mux>,
    params: MoveTabToColumnParams,
) -> anyhow::Result<Value> {
    let MoveTabToColumnParams { surface, pane, screen, after_column, width, sticky, transaction } =
        params;
    validate_client_transaction(transaction.as_deref())?;
    get_surface(mux, surface)?;
    let anchor = column_anchor(mux, pane, screen)?;
    let outcome =
        mux.move_tab_to_column(surface, anchor, after_column, width, sticky, transaction)?;
    Ok(tab_drag_outcome_json(&outcome))
}
