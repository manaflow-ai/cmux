//! Tab and tab-group command handlers: select, move, pin, rename, close
//! tabs and surfaces, tab groups (create, update, add, remove, ungroup,
//! close, move, save, reopen), and new browser/conversation/frontend tabs.
//! Each function is one `Command` arm of `handle_command_with_cancellation`.

use super::batch_close_terminals_json;

use super::MutationRequest;
use super::PaneRef;
use super::SplitRespawnRequest;
use super::TabRef;
use super::close_tabs_command;
use super::column_anchor;
use super::conversation_tabs_wire;
use super::frontend_browser_history;
use super::frontend_shell;
use super::get_surface;
use super::optional_surface_size;
use super::pane_tab_group_json;
use super::placed_terminal_result;
use super::placement_spawn_options;
use super::resolve_tab_refs;
use super::split_tab;
use super::surface_has_view_placement;
use super::tab_column;
use super::tab_drag_outcome_json;
use super::tab_group_outcome_json;
use super::validate_client_transaction;
use crate::Actor;
use crate::Mux;
use crate::PaneId;
use crate::ScreenId;
use crate::SplitId;
use crate::SurfaceId;
use crate::WorkspaceId;
use serde_json::Value;
use serde_json::json;
use std::collections::BTreeMap;
use std::sync::Arc;

#[allow(clippy::too_many_arguments)]
pub(super) fn new_tab(
    mux: &Arc<Mux>,
    client: u64,
    actor: Actor,
    pane: Option<PaneId>,
    cwd: Option<String>,
    env: Option<BTreeMap<String, String>>,
    cols: Option<u16>,
    rows: Option<u16>,
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
        mux.new_tab_with_options_as(&actor, pane, spawn, optional_surface_size(cols, rows))?;
    placed_terminal_result(mux, &surface, keep)
}

pub(super) fn new_conversation_tab(
    mux: &Arc<Mux>,
    client: u64,
    params: conversation_tabs_wire::NewConversationTabParams,
) -> anyhow::Result<Value> {
    conversation_tabs_wire::create(mux, client, params)
}

pub(super) fn bind_conversation_tab_session(
    mux: &Arc<Mux>,
    actor: Actor,
    params: conversation_tabs_wire::BindSessionParams,
) -> anyhow::Result<Value> {
    conversation_tabs_wire::bind(mux, &actor, params)
}

pub(super) fn new_frontend_browser_tab(
    mux: &Arc<Mux>,
    client: u64,
    params: frontend_browser_history::NewTabParams,
) -> anyhow::Result<Value> {
    frontend_browser_history::create(mux, client, params)
}

pub(super) fn update_frontend_browser_tab(
    mux: &Arc<Mux>,
    actor: Actor,
    params: frontend_browser_history::UpdateTabParams,
) -> anyhow::Result<Value> {
    frontend_browser_history::update(mux, &actor, params)
}

pub(super) fn new_browser_tab(
    mux: &Arc<Mux>,
    actor: Actor,
    url: String,
    pane: Option<PaneId>,
    cols: Option<u16>,
    rows: Option<u16>,
) -> anyhow::Result<Value> {
    let surface = mux.new_browser_tab_as(&actor, url, pane, optional_surface_size(cols, rows))?;
    Ok(json!({ "surface": surface.id }))
}

pub(super) fn move_tab_to_workspace(
    mux: &Arc<Mux>,
    actor: Actor,
    surface: SurfaceId,
    workspace: Option<WorkspaceId>,
    transaction: Option<String>,
) -> anyhow::Result<Value> {
    validate_client_transaction(transaction.as_deref())?;
    mux.move_tab_to_workspace_as(&actor, surface, workspace)?;
    mux.emit_tab_changed_for_transaction(surface, transaction.map(Arc::from));
    let (workspace, pane) = surface_placement(mux, surface);
    Ok(json!({"surface": surface, "workspace": workspace, "pane": pane, "undoable": false}))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn move_tab_to_split(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
    pane: PaneId,
    edge: String,
    ratio: Option<f32>,
    respawn: Option<SplitRespawnRequest>,
    transaction: Option<String>,
) -> anyhow::Result<Value> {
    validate_client_transaction(transaction.as_deref())?;
    get_surface(mux, surface)?;
    let edge = crate::TabDropEdge::parse(&edge)?;
    let outcome = split_tab(mux, client, surface, pane, edge, ratio, respawn, transaction)?;
    Ok(tab_drag_outcome_json(&outcome))
}

pub(super) fn move_tab_to_column(
    mux: &Arc<Mux>,
    client: u64,
    params: tab_column::MoveTabToColumnParams,
) -> anyhow::Result<Value> {
    tab_column::move_tab_to_column(mux, client, params)
}

pub(super) fn move_tab_to_new_workspace(
    mux: &Arc<Mux>,
    actor: Actor,
    surface: SurfaceId,
    group: Option<String>,
    index: Option<usize>,
    name: Option<String>,
    transaction: Option<String>,
) -> anyhow::Result<Value> {
    validate_client_transaction(transaction.as_deref())?;
    get_surface(mux, surface)?;
    let workspace =
        mux.move_tab_to_new_workspace_as(&actor, surface, group.clone(), index, name)?;
    mux.emit_tab_changed_for_transaction(surface, transaction.map(Arc::from));
    let (key, workspace_index) = mux
        .with_state(|state| {
            let index = state.workspace_index(workspace)?;
            Some((state.workspaces[index].key.clone(), index))
        })
        .ok_or_else(|| anyhow::anyhow!("new workspace disappeared"))?;
    let (_, pane) = surface_placement(mux, surface);
    Ok(json!({
        "surface": surface,
        "workspace": workspace,
        "key": key,
        "index": workspace_index,
        "group": group,
        "pane": pane,
        "undoable": false,
    }))
}

pub(super) fn move_tab(
    mux: &Arc<Mux>,
    actor: Actor,
    surface: SurfaceId,
    pane: PaneId,
    index: usize,
    transaction: Option<String>,
) -> anyhow::Result<Value> {
    validate_client_transaction(transaction.as_deref())?;
    let valid = mux.with_state(|state| {
        state.surfaces.contains_key(&surface)
            && state.panes.contains_key(&pane)
            && state.pane_of(surface).is_some()
    });
    if !valid {
        anyhow::bail!("unknown surface/pane");
    }
    let index = mux.pinned_tab_move_index(surface, pane, index);
    let (moved, undoable) = mux.move_tab_with_undo_as(&actor, surface, pane, index, transaction);
    Ok(json!({"moved": moved, "undoable": undoable}))
}

pub(super) fn list_tab_groups(mux: &Arc<Mux>) -> anyhow::Result<Value> {
    let presentation = mux.presentation_snapshot();
    let groups = mux.with_state(|state| {
        let mut groups = Vec::new();
        for pane in state.panes.keys() {
            for run in crate::mux::pane_tab_groups(state, &presentation, *pane) {
                groups.push(pane_tab_group_json(&run, Some(*pane)));
            }
        }
        groups
    });
    Ok(json!({ "groups": groups }))
}

pub(super) fn create_tab_group(
    mux: &Arc<Mux>,
    actor: Actor,
    surfaces: Vec<TabRef>,
    name: Option<String>,
    color: Option<String>,
    group: Option<String>,
    transaction: Option<String>,
) -> anyhow::Result<Value> {
    validate_client_transaction(transaction.as_deref())?;
    let surfaces = resolve_tab_refs(mux, &surfaces)?;
    let outcome =
        mux.create_tab_group_as(&actor, &surfaces, name, color, group, transaction.as_deref())?;
    Ok(tab_group_outcome_json(&outcome))
}

pub(super) fn update_tab_group(
    mux: &Arc<Mux>,
    actor: Actor,
    group: String,
    name: Option<String>,
    color: Option<String>,
    collapsed: Option<bool>,
) -> anyhow::Result<Value> {
    Ok(tab_group_outcome_json(&mux.update_tab_group_as(&actor, &group, name, color, collapsed)?))
}

pub(super) fn add_tabs_to_tab_group(
    mux: &Arc<Mux>,
    actor: Actor,
    group: String,
    surfaces: Vec<TabRef>,
    transaction: Option<String>,
) -> anyhow::Result<Value> {
    validate_client_transaction(transaction.as_deref())?;
    let surfaces = resolve_tab_refs(mux, &surfaces)?;
    let outcome =
        mux.add_tabs_to_tab_group_as(&actor, &group, &surfaces, transaction.as_deref())?;
    Ok(tab_group_outcome_json(&outcome))
}

pub(super) fn remove_tabs_from_tab_group(
    mux: &Arc<Mux>,
    actor: Actor,
    surfaces: Vec<TabRef>,
    transaction: Option<String>,
) -> anyhow::Result<Value> {
    validate_client_transaction(transaction.as_deref())?;
    let surfaces = resolve_tab_refs(mux, &surfaces)?;
    let groups = mux.remove_tabs_from_tab_group_as(&actor, &surfaces, transaction.as_deref())?;
    Ok(json!({ "surfaces": surfaces, "groups": groups }))
}

pub(super) fn move_tab_group(
    mux: &Arc<Mux>,
    actor: Actor,
    group: String,
    pane: Option<PaneRef>,
    index: Option<usize>,
    transaction: Option<String>,
) -> anyhow::Result<Value> {
    validate_client_transaction(transaction.as_deref())?;
    let pane = match pane {
        Some(pane) => resolve_pane_ref(mux, &pane)?,
        None => mux
            .with_state(|state| {
                let presentation = mux.presentation_snapshot();
                let record = presentation.tab_groups.groups.get(&group)?;
                state
                    .resource_indexes
                    .panes
                    .iter()
                    .find_map(|(id, slot)| (id.as_str() == record.pane_id).then_some(*slot))
            })
            .ok_or_else(|| anyhow::anyhow!("unknown tab group {group}"))?,
    };
    let outcome = mux.move_tab_group_as(
        &actor,
        &group,
        crate::TabGroupDestination::Strip { pane, index },
        transaction.as_deref(),
    )?;
    Ok(tab_group_outcome_json(&outcome))
}

pub(super) fn move_tab_group_to_split(
    mux: &Arc<Mux>,
    actor: Actor,
    group: String,
    pane: PaneRef,
    edge: String,
    ratio: Option<f32>,
    transaction: Option<String>,
) -> anyhow::Result<Value> {
    validate_client_transaction(transaction.as_deref())?;
    let pane = resolve_pane_ref(mux, &pane)?;
    if let Some(ratio) = ratio {
        anyhow::ensure!(
            ratio.is_finite() && (0.05..=0.95).contains(&ratio),
            "bad request: ratio must be between 0.05 and 0.95"
        );
    }
    let edge = crate::TabDropEdge::parse(&edge)?;
    let outcome = mux.move_tab_group_as(
        &actor,
        &group,
        crate::TabGroupDestination::Split { pane, edge, ratio },
        transaction.as_deref(),
    )?;
    Ok(tab_group_outcome_json(&outcome))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn move_tab_group_to_column(
    mux: &Arc<Mux>,
    actor: Actor,
    group: String,
    pane: Option<PaneRef>,
    screen: Option<ScreenId>,
    after_column: Option<SplitId>,
    width: Option<f32>,
    transaction: Option<String>,
) -> anyhow::Result<Value> {
    validate_client_transaction(transaction.as_deref())?;
    let pane = pane.map(|pane| resolve_pane_ref(mux, &pane)).transpose()?;
    let pane = column_anchor(mux, pane, screen)?;
    let outcome = mux.move_tab_group_as(
        &actor,
        &group,
        crate::TabGroupDestination::Column { pane, after_column, width },
        transaction.as_deref(),
    )?;
    Ok(tab_group_outcome_json(&outcome))
}

pub(super) fn move_tab_group_to_new_workspace(
    mux: &Arc<Mux>,
    actor: Actor,
    group: String,
    workspace_group: Option<String>,
    index: Option<usize>,
    transaction: Option<String>,
) -> anyhow::Result<Value> {
    validate_client_transaction(transaction.as_deref())?;
    let outcome = mux.move_tab_group_as(
        &actor,
        &group,
        crate::TabGroupDestination::NewWorkspace { group: workspace_group, index },
        transaction.as_deref(),
    )?;
    Ok(tab_group_outcome_json(&outcome))
}

pub(super) fn ungroup_tab_group(
    mux: &Arc<Mux>,
    actor: Actor,
    group: String,
) -> anyhow::Result<Value> {
    let members = mux.ungroup_tab_group_as(&actor, &group)?;
    Ok(json!({ "group": group, "surfaces": members }))
}

pub(super) fn close_tab_group(
    mux: &Arc<Mux>,
    actor: Actor,
    group: String,
    end_terminals: bool,
) -> anyhow::Result<Value> {
    if !end_terminals {
        let closed = mux.close_tab_group_as(&actor, &group)?;
        return Ok(json!({ "group": group, "closed": closed }));
    }
    let outcome = mux.close_container_ending_terminals_as(
        &actor,
        crate::BatchCloseTarget::TabGroup(group.clone()),
    )?;
    Ok(json!({
        "group": group,
        "closed": outcome.closed(),
        "terminals": batch_close_terminals_json(&outcome),
    }))
}

pub(super) fn list_saved_tab_groups(mux: &Arc<Mux>) -> anyhow::Result<Value> {
    Ok(json!({ "saved_groups": mux.saved_tab_groups() }))
}

pub(super) fn save_tab_group(mux: &Arc<Mux>, actor: Actor, group: String) -> anyhow::Result<Value> {
    let saved = mux.save_tab_group_as(&actor, &group)?;
    Ok(json!({ "group": group, "saved": saved }))
}

pub(super) fn unsave_tab_group(
    mux: &Arc<Mux>,
    actor: Actor,
    group: String,
) -> anyhow::Result<Value> {
    Ok(json!({ "group": group, "unsaved": mux.unsave_tab_group_as(&actor, &group)? }))
}

pub(super) fn delete_saved_tab_group(
    mux: &Arc<Mux>,
    actor: Actor,
    saved: String,
) -> anyhow::Result<Value> {
    Ok(json!({ "saved": saved, "deleted": mux.delete_saved_tab_group_as(&actor, &saved)? }))
}

pub(super) fn reopen_saved_tab_group(
    mux: &Arc<Mux>,
    actor: Actor,
    saved: String,
    pane: PaneRef,
    transaction: Option<String>,
) -> anyhow::Result<Value> {
    validate_client_transaction(transaction.as_deref())?;
    let pane = resolve_pane_ref(mux, &pane)?;
    let outcome = mux.reopen_saved_tab_group_as(&actor, &saved, pane, transaction.as_deref())?;
    Ok(tab_group_outcome_json(&outcome))
}

/// `ack-tab-notifications`. `refused` lists the tab's unread local feed
/// items that another owner holds (`feed-local-owner-v1`).
pub(super) fn ack_tab_notifications(mux: &Arc<Mux>, surface: SurfaceId) -> anyhow::Result<Value> {
    let ack = mux.acknowledge_tab_notifications(surface)?;
    Ok(json!({
        "surface": surface,
        "cleared": ack.cleared,
        "acknowledged": ack.acknowledged,
        "refused": crate::mux::feed_local::refused_json(&ack.refused),
    }))
}

pub(super) fn set_tab_pinned(
    mux: &Arc<Mux>,
    actor: Actor,
    surface: SurfaceId,
    pinned: bool,
) -> anyhow::Result<Value> {
    get_surface(mux, surface)?;
    let change = mux.set_tab_pinned_as(&actor, surface, pinned)?;
    Ok(json!({
        "surface": surface,
        "pinned": pinned,
        "index": change.index,
        "changed": change.changed,
    }))
}

pub(super) fn close_surface(
    mux: &Arc<Mux>,
    actor: Actor,
    surface: SurfaceId,
) -> anyhow::Result<Value> {
    // A kept-layout tab (`end-terminals-keep-layout-v1`) has no
    // runtime surface after a restart but is still a placed tab.
    if get_surface(mux, surface).is_err() && !surface_has_view_placement(mux, surface) {
        anyhow::bail!("unknown surface {surface}");
    }
    if !mux.close_surface_as(&actor, surface)? {
        anyhow::bail!("unknown surface {surface}");
    }
    Ok(json!({}))
}

pub(super) fn close_tabs(
    mux: &Arc<Mux>,
    client: u64,
    surfaces: Vec<TabRef>,
    end_terminals: bool,
    transaction: Option<String>,
    reason: Option<crate::mux::CloseReason>,
    mutation: MutationRequest,
) -> anyhow::Result<Value> {
    {
        close_tabs_command::run(
            mux,
            client,
            &surfaces,
            end_terminals,
            transaction,
            reason,
            &mutation,
        )
    }
    // With `end_terminals` the result shapes stay those of the plain
    // closes; the ended terminals show in the terminal and resource streams.
}

pub(super) fn rename_surface(
    mux: &Arc<Mux>,
    actor: Actor,
    surface: SurfaceId,
    name: String,
) -> anyhow::Result<Value> {
    if !mux.rename_surface_as(&actor, surface, name) {
        anyhow::bail!("unknown surface {surface}");
    }
    Ok(json!({}))
}

pub(super) fn select_tab(
    mux: &Arc<Mux>,
    actor: Actor,
    pane: Option<PaneId>,
    index: Option<usize>,
    delta: Option<isize>,
) -> anyhow::Result<Value> {
    mux.select_tab_as(&actor, pane, index, delta);
    Ok(json!({}))
}

fn resolve_pane_ref(mux: &Mux, reference: &PaneRef) -> anyhow::Result<PaneId> {
    match reference {
        PaneRef::Id(pane) => Ok(*pane),
        PaneRef::Public(id) => mux
            .with_state(|state| {
                state
                    .resource_indexes
                    .panes
                    .iter()
                    .find_map(|(pane, slot)| (pane.as_str() == id).then_some(*slot))
            })
            .ok_or_else(|| anyhow::anyhow!("unknown pane {id}")),
    }
}

pub(super) fn surface_placement(
    mux: &Mux,
    surface: SurfaceId,
) -> (Option<WorkspaceId>, Option<PaneId>) {
    mux.with_state(|state| {
        let pane = state.pane_of(surface);
        let workspace = pane
            .and_then(|pane| state.screen_of(pane))
            .map(|(workspace, _)| state.workspaces[workspace].id);
        (workspace, pane)
    })
}
