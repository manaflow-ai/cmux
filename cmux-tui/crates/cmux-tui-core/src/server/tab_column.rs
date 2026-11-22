//! `move-tab-to-column`: drop a tab between strip columns, or into a new
//! column pinned to an edge in the same commit (`edge-docks-v1`). With
//! `respawn` (`tab-column-respawn-v1`) a pane's only tab moves and leaves a
//! fresh tab of the given kind in its pane, so docking a screen's only tab
//! keeps a column to scroll.

/// `move-tab-to-column` `respawn`.
pub const TAB_COLUMN_RESPAWN_CAPABILITY: &str = "tab-column-respawn-v1";

/// `move-tab-to-column` `pane_id`: the caller mints the new column's pane id, so a client that
/// shows the column before the reply (the lone chat docking left) sees the daemon's pane replace
/// its provisional one by id, as `split-client-keys-v1` does for `split`.
pub const TAB_COLUMN_CLIENT_PANE_CAPABILITY: &str = "tab-column-client-pane-v1";

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
    /// `tab-split-keep-focus-v1`: the focused pane stays focused.
    #[serde(default)]
    keep_focus: bool,
    /// `tab-column-client-pane-v1`: the new column's pane's public id, `pane_` and 32 hex digits.
    #[serde(default)]
    pane_id: Option<String>,
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
        keep_focus,
        pane_id,
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
    let pane_id = pane_id
        .map(|requested| {
            crate::resource::PanePublicId::parse(requested.clone())
                .map_err(|_| anyhow::anyhow!("bad request: pane_id {requested:?} is not a pane id"))
        })
        .transpose()?;
    anyhow::ensure!(
        !(keep_focus && respawn.is_some()),
        "bad request: keep_focus does not apply with respawn"
    );
    get_surface(mux, surface)?;
    let anchor = column_anchor(mux, pane, screen)?;
    let actor = origin_gate::connection_actor(mux, client);
    let destination = crate::mux::ColumnMove { pane: anchor, after_column, width, dock };
    let outcome = match respawn {
        None => mux.move_tab_to_column_keyed_as(
            &actor,
            surface,
            destination,
            pane_id,
            keep_focus,
            transaction,
        )?,
        Some(respawn) => {
            let respawn = respawn.into_respawn(frontend_shell(mux, client))?;
            mux.move_tab_to_column_respawning_keyed_as(
                &actor,
                surface,
                destination,
                respawn,
                pane_id,
                transaction,
            )?
        }
    };
    Ok(tab_drag_outcome_json(&outcome))
}
