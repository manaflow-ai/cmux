//! Pane and layout command handlers: split and new panes or rows, close,
//! focus, neighbors, rename, zoom, swap, split ratios, viewport widths,
//! column docks, row heights, layout undo, and layout apply/export. Each
//! function is one `Command` arm of `handle_command_with_cancellation`.

use super::node_json;
use crate::model::State;

use super::LayoutRequest;
use super::frontend_shell;
use super::layout_request_to_spec;
use super::optional_surface_size;
use super::parse_direction;
use super::parse_split_dir;
use super::parse_zoom_mode;
use super::placed_terminal_result;
use super::placement_spawn_options;
use super::rows;
use super::split_kind;
use crate::Actor;
use crate::LayoutUndoResult;
use crate::Mux;
use crate::PaneId;
use crate::ScreenId;
use crate::SplitId;
use crate::WorkspaceId;
use serde_json::Value;
use serde_json::json;
use std::collections::BTreeMap;
use std::sync::Arc;

pub(super) fn export_layout(mux: &Arc<Mux>, screen: Option<ScreenId>) -> anyhow::Result<Value> {
    mux.with_state(|state| export_layout_json(state, screen))
}

pub(super) fn apply_layout(
    mux: &Arc<Mux>,
    actor: Actor,
    workspace: Option<WorkspaceId>,
    name: Option<String>,
    layout: LayoutRequest,
    cols: Option<u16>,
    rows: Option<u16>,
) -> anyhow::Result<Value> {
    let layout = layout_request_to_spec(layout)?;
    let applied =
        mux.apply_layout_as(&actor, workspace, name, &layout, optional_surface_size(cols, rows))?;
    Ok(json!({
        "screen": applied.screen,
        "panes": applied.panes.iter().map(|pane| {
            json!({ "pane": pane.pane, "surface": pane.surface })
        }).collect::<Vec<_>>(),
    }))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn new_pane(
    mux: &Arc<Mux>,
    client: u64,
    actor: Actor,
    pane: PaneId,
    cols: Option<u16>,
    rows: Option<u16>,
    cwd: Option<String>,
    env: Option<BTreeMap<String, String>>,
    keep: bool,
    terminal_id: Option<String>,
    shell_args: Option<Vec<String>>,
) -> anyhow::Result<Value> {
    let spawn = placement_spawn_options(
        cwd,
        env.as_ref(),
        terminal_id,
        shell_args,
        frontend_shell(mux, client),
    )?;
    let surface =
        mux.new_pane_with_options_as(&actor, pane, spawn, optional_surface_size(cols, rows))?;
    placed_terminal_result(mux, &surface, keep)
}

pub(super) fn new_pane_right(
    mux: &Arc<Mux>,
    client: u64,
    params: split_kind::NewPaneRightParams,
) -> anyhow::Result<Value> {
    split_kind::new_pane_right(mux, client, params)
}

pub(super) fn split(
    mux: &Arc<Mux>,
    client: u64,
    params: split_kind::SplitParams,
) -> anyhow::Result<Value> {
    split_kind::split(mux, client, params)
}

pub(super) fn set_ratio(
    mux: &Arc<Mux>,
    actor: Actor,
    pane: PaneId,
    dir: String,
    ratio: f32,
) -> anyhow::Result<Value> {
    let dir = parse_split_dir(&dir)?;
    mux.set_ratio_checked_as(&actor, pane, dir, ratio)?;
    Ok(json!({}))
}

pub(super) fn set_split_ratio(
    mux: &Arc<Mux>,
    client: u64,
    actor: Actor,
    split: SplitId,
    ratio: f32,
    transaction: Option<u64>,
) -> anyhow::Result<Value> {
    transaction.map_or_else(
        || mux.set_split_ratio_checked_as(&actor, split, ratio),
        |transaction| {
            mux.set_split_ratio_in_transaction_checked_as(&actor, split, ratio, client, transaction)
        },
    )?;
    Ok(json!({}))
}

pub(super) fn set_viewport_pane_width(
    mux: &Arc<Mux>,
    client: u64,
    actor: Actor,
    pane: PaneId,
    width: f32,
    transaction: Option<u64>,
) -> anyhow::Result<Value> {
    transaction.map_or_else(
        || mux.set_viewport_pane_width_checked_as(&actor, pane, width),
        |transaction| {
            mux.set_viewport_pane_width_in_transaction_checked_as(
                &actor,
                pane,
                width,
                client,
                transaction,
            )
        },
    )?;
    Ok(json!({}))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn set_column_dock(
    mux: &Arc<Mux>,
    client: u64,
    actor: Actor,
    pane: PaneId,
    dock: bool,
    edge: Option<String>,
    mode: Option<String>,
    role: Option<String>,
    permanent: Option<bool>,
    transaction: Option<u64>,
) -> anyhow::Result<Value> {
    let mut dock =
        crate::mux::parse_column_dock(dock, edge.as_deref(), mode.as_deref(), role.as_deref())?;
    // `permanent-dock-v1`: `permanent:true` marks the column; false or
    // omitted keeps the current value (a permanent column stays one).
    if let Some(flag) = dock.as_mut() {
        flag.permanent = permanent == Some(true);
    }
    let outcome = mux.set_column_dock_as(
        &actor,
        pane,
        dock,
        transaction.map(|transaction| (client, transaction)),
    )?;
    let mut data = json!({"column": outcome.column, "dock": outcome.dock});
    if let Some(transaction) = transaction {
        data["transaction"] = json!(transaction);
    }
    Ok(data)
}

pub(super) fn undo_layout(
    mux: &Arc<Mux>,
    actor: Actor,
    pane: PaneId,
    revision: Option<u64>,
    confirm_close: bool,
) -> anyhow::Result<Value> {
    match mux.undo_layout_as(&actor, pane, revision, confirm_close)? {
        LayoutUndoResult::Undone { screen, revision } => Ok(json!({
            "undone": true,
            "screen": screen,
            "revision": revision,
        })),
        LayoutUndoResult::ConfirmationRequired { screen, revision, closes_panes } => Ok(json!({
            "undone": false,
            "confirmation_required": true,
            "screen": screen,
            "revision": revision,
            "closes_panes": closes_panes,
        })),
    }
}

pub(super) fn pane_neighbor(mux: &Arc<Mux>, pane: PaneId, dir: String) -> anyhow::Result<Value> {
    let dir = parse_direction(&dir)?;
    let pane = mux.pane_neighbor(pane, dir)?;
    Ok(json!({ "pane": pane }))
}

pub(super) fn focus_direction(
    mux: &Arc<Mux>,
    actor: Actor,
    pane: Option<PaneId>,
    dir: String,
) -> anyhow::Result<Value> {
    let dir = parse_direction(&dir)?;
    let pane = mux.focus_direction_as(&actor, pane, dir)?;
    Ok(json!({ "pane": pane }))
}

pub(super) fn swap_pane(
    mux: &Arc<Mux>,
    actor: Actor,
    pane: PaneId,
    dir: Option<String>,
    target: Option<PaneId>,
) -> anyhow::Result<Value> {
    let target = match (dir, target) {
        (Some(_), Some(_)) => anyhow::bail!("use only one of dir or target"),
        (Some(dir), None) => {
            let dir = parse_direction(&dir)?;
            mux.pane_neighbor(pane, dir)?.ok_or_else(|| anyhow::anyhow!("no neighbor"))?
        }
        (None, Some(target)) => target,
        (None, None) => anyhow::bail!("one of dir or target is required"),
    };
    if !mux.swap_panes_as(&actor, pane, target) {
        anyhow::bail!("unknown pane/target");
    }
    Ok(json!({}))
}

pub(super) fn zoom_pane(
    mux: &Arc<Mux>,
    actor: Actor,
    pane: Option<PaneId>,
    mode: Option<String>,
) -> anyhow::Result<Value> {
    let mode = parse_zoom_mode(mode)?;
    let state = mux.zoom_pane_as(&actor, pane, mode)?;
    Ok(json!({
        "pane": state.pane,
        "zoomed": state.zoomed,
        "zoomed_pane": state.zoomed_pane,
    }))
}

pub(super) fn new_row(
    mux: &Arc<Mux>,
    client: u64,
    params: rows::NewRowParams,
) -> anyhow::Result<Value> {
    rows::new_row(mux, client, params)
}

pub(super) fn set_row_heights(
    mux: &Arc<Mux>,
    client: u64,
    params: rows::SetRowHeightsParams,
) -> anyhow::Result<Value> {
    rows::set_row_heights(mux, client, params)
}

pub(super) fn close_pane(
    mux: &Arc<Mux>,
    actor: Actor,
    pane: PaneId,
    end_terminals: bool,
) -> anyhow::Result<Value> {
    if end_terminals {
        mux.close_container_ending_terminals_as(&actor, crate::BatchCloseTarget::Pane(pane))?;
    } else if !mux.close_pane_as(&actor, pane)? {
        anyhow::bail!("unknown pane {pane}");
    }
    Ok(json!({}))
}

pub(super) fn rename_pane(
    mux: &Arc<Mux>,
    actor: Actor,
    pane: PaneId,
    name: String,
) -> anyhow::Result<Value> {
    if !mux.rename_pane_as(&actor, pane, name) {
        anyhow::bail!("unknown pane {pane}");
    }
    Ok(json!({}))
}

pub(super) fn focus_pane(mux: &Arc<Mux>, actor: Actor, pane: PaneId) -> anyhow::Result<Value> {
    if !mux.focus_pane_as(&actor, pane) {
        anyhow::bail!("unknown pane {pane}");
    }
    Ok(json!({}))
}

fn export_layout_json(state: &State, screen_id: Option<ScreenId>) -> anyhow::Result<Value> {
    let screen = match screen_id {
        Some(id) => state
            .workspaces
            .iter()
            .flat_map(|ws| ws.screens.iter())
            .find(|screen| screen.id == id)
            .ok_or_else(|| anyhow::anyhow!("unknown screen {id}"))?,
        None => state
            .workspaces
            .get(state.active_workspace)
            .and_then(|ws| ws.active_screen_ref())
            .ok_or_else(|| anyhow::anyhow!("no active screen"))?,
    };
    let mut pane_ids = Vec::new();
    screen.root.pane_ids(&mut pane_ids);
    let mut value = json!({
        "layout": node_json(&screen.root, screen.active_pane),
        "panes": pane_ids.iter().map(|pane_id| {
            let surfaces = state
                .panes
                .get(pane_id)
                .map(|pane| pane.tabs.clone())
                .unwrap_or_default();
            json!({ "pane": pane_id, "surfaces": surfaces })
        }).collect::<Vec<_>>(),
    });
    if !screen.viewport_splits.is_empty() {
        value["viewport_splits"] = json!(
            screen
                .viewport_splits
                .iter()
                .map(|(split, width)| json!({"split": split, "width": width}))
                .collect::<Vec<_>>()
        );
        if let Some(width) = screen.viewport_base_width {
            value["viewport_base_width"] = json!(width);
        }
    }
    Ok(value)
}
