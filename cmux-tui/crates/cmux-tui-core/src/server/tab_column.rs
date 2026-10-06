//! `move-tab-to-column`: drop a tab between strip columns, or into a new
//! column pinned to an edge in the same commit (`edge-docks-v1`). With
//! `respawn` (`tab-column-respawn-v1`) a pane's only tab moves and leaves a
//! fresh tab of the given kind in its pane, so docking a screen's only tab
//! keeps a column to scroll.

/// `move-tab-to-column` `respawn`.
pub const TAB_COLUMN_RESPAWN_CAPABILITY: &str = "tab-column-respawn-v1";

use super::*;

/// `move-tab-to-column`: a new column holding the tab, after `after_column`
/// (default: right of the anchor's column). `dock` pins the new column;
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
    dock: Option<crate::model::ColumnDock>,
    /// The pre-R87 name of `dock`, refused so an older client's pin never
    /// silently becomes a plain column.
    #[serde(default)]
    sticky: Option<Value>,
    #[serde(default)]
    respawn: Option<SplitRespawnRequest>,
    #[serde(default)]
    transaction: Option<String>,
}

pub(super) fn move_tab_to_column(
    mux: &Arc<Mux>,
    client: u64,
    params: MoveTabToColumnParams,
) -> anyhow::Result<Value> {
    let MoveTabToColumnParams {
        surface,
        pane,
        screen,
        after_column,
        width,
        dock,
        sticky,
        respawn,
        transaction,
    } = params;
    if sticky.is_some() {
        return Err(crate::ColumnDockError::InvalidArgument {
            field: "sticky",
            value: "sticky".to_string(),
        }
        .into());
    }
    validate_client_transaction(transaction.as_deref())?;
    get_surface(mux, surface)?;
    let anchor = column_anchor(mux, pane, screen)?;
    let outcome = match respawn {
        None => mux.move_tab_to_column(surface, anchor, after_column, width, dock, transaction)?,
        Some(respawn) => {
            let respawn = respawn.into_respawn(frontend_shell(mux, client))?;
            let destination = crate::mux::ColumnMove { pane: anchor, after_column, width, dock };
            mux.move_tab_to_column_respawning(surface, destination, respawn, transaction)?
        }
    };
    Ok(tab_drag_outcome_json(&outcome))
}
