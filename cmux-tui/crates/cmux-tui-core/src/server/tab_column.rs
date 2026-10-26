//! `move-tab-to-column`: drop a tab between strip columns, or into a new
//! column pinned to an edge in the same commit (`edge-docks-v1`). With
//! `respawn` (`tab-column-respawn-v1`) a pane's only tab moves and leaves a
//! fresh tab of the given kind in its pane, so docking a screen's only tab
//! keeps a column to scroll.

/// `move-tab-to-column` `respawn`.
pub const TAB_COLUMN_RESPAWN_CAPABILITY: &str = "tab-column-respawn-v1";

use super::tabs_wire::MoveTabToColumnParams;
use super::*;

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
        keep_focus,
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
    anyhow::ensure!(
        !(keep_focus && respawn.is_some()),
        "bad request: keep_focus does not apply with respawn"
    );
    get_surface(mux, surface)?;
    let anchor = column_anchor(mux, pane, screen)?;
    let actor = origin_gate::connection_actor(mux, client);
    let outcome = match respawn {
        None => mux.move_tab_to_column_as(
            &actor,
            surface,
            anchor,
            after_column,
            width,
            dock,
            keep_focus,
            transaction,
        )?,
        Some(respawn) => {
            let respawn = respawn.into_respawn(frontend_shell(mux, client))?;
            let destination = crate::mux::ColumnMove { pane: anchor, after_column, width, dock };
            mux.move_tab_to_column_respawning_as(
                &actor,
                surface,
                destination,
                respawn,
                transaction,
            )?
        }
    };
    Ok(tab_drag_outcome_json(&outcome))
}
