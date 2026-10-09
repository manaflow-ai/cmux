//! JSON views of the mux tree for the control protocol: panes (tabs, groups,
//! columns, docks), workspaces and screen groups, unread counts, short ids,
//! tree entities and tree deltas.

use super::home;
use super::pane_tab_group_json;
use super::raw_tab;
use super::screen_json;
use super::workspace_groups_json;
use crate::SurfaceKind;
use crate::resource::ContentPublicId;

use crate::Mux;
use crate::PaneId;
use crate::ScreenId;
use crate::SurfaceId;
use crate::TreeDecorations;
use crate::TreeDelta;
use crate::TreeDeltaKind;
use crate::assign_short_ids;
use crate::model::State;
use crate::model::Workspace;
use serde_json::Value;
use serde_json::json;
use std::collections::HashMap;

pub(super) fn pane_json(
    state: &State,
    id: PaneId,
    short_ids: &HashMap<u64, String>,
    notifications: &TreeDecorations,
) -> Value {
    let Some(pane) = state.panes.get(&id) else {
        return json!({ "id": id, "dead": true });
    };
    let tab_groups = crate::mux::pane_tab_groups(state, &notifications.presentation, id);
    let group_of = |surface: &SurfaceId| {
        tab_groups.iter().find(|run| run.members.contains(surface)).map(|run| run.group.id.as_str())
    };
    json!({
        "id": id,
        "resource_id": state.resource_indexes.pane_ids.get(&id),
        "short_id": short_ids.get(&id).cloned().unwrap_or_default(),
        "name": pane.name,
        "active_tab": pane.active_tab,
        "focused_at": pane.focused_at,
        "tab_groups": tab_groups.iter().map(|run| pane_tab_group_json(run, None)).collect::<Vec<_>>(),
        "tabs": pane.tabs.iter().map(|sid| {
            let surface = state.surfaces.get(sid);
            let terminal_identity = surface.and_then(|surface| surface.terminal_host_identity());
            let terminal_resource_id = surface
                .and_then(|surface| surface.resource_identity())
                .and_then(|identity| match &identity.content_id {
                    ContentPublicId::Terminal(id) => Some(id),
                    ContentPublicId::Browser(_) => None,
                });
            // A kept-layout tab (`end-terminals-keep-layout-v1`) has no
            // runtime surface after a restart; its identity is the index's.
            let tab_resource_id = surface
                .and_then(|surface| surface.resource_identity())
                .map(|identity| &identity.tab_id)
                .or_else(|| state.resource_indexes.tab_ids.get(sid));
            // A restored tab with no runtime surface (an ended terminal after
            // a restart) keeps its content id in the index, like its tab id.
            let content_resource_id = surface
                .and_then(|surface| surface.resource_identity())
                .map(|identity| identity.content_id.as_str())
                .or_else(|| state.resource_indexes.content_ids.get(sid).map(|content| content.as_str()));
            let directory = notifications.directories.get(sid);
            let frontend_browser = surface
                .and_then(|surface| surface.resource_identity())
                .and_then(|identity| match &identity.content_id {
                    ContentPublicId::Browser(id) => {
                        notifications.presentation.frontend_browsers.get(id.as_str())
                    }
                    ContentPublicId::Terminal(_) => None,
                });
            let conversation = content_resource_id
                .and_then(|id| notifications.presentation.conversation_tabs.get(id));
            let pinned = state.resource_indexes.tab_ids.get(sid).is_some_and(|tab| {
                notifications.presentation.pinned_tabs.contains(tab.as_str())
            });
            // `end-terminals-keep-layout-v1`: a kept tab whose terminal has
            // ended, to restart a shell in. After a restart it has no surface,
            // so its name and last title come from the record; a live
            // terminal's own title always wins.
            let kept = state
                .resource_indexes
                .tab_ids
                .get(sid)
                .filter(|_| surface.is_none_or(|surface| surface.is_dead()))
                .and_then(|tab| notifications.presentation.kept_tabs.get(tab.as_str()));
            let relaunch = kept.map(|kept| json!({"cwd": kept.cwd}));
            // R41: a terminal tab with no runtime surface is dead only when
            // its terminal really ended; a host still being adopted, or one
            // this build cannot adopt, keeps running its shell.
            let content_terminal = state.resource_indexes.content_ids.get(sid).and_then(|content| {
                match content {
                    ContentPublicId::Terminal(id) => Some(id.as_str()),
                    ContentPublicId::Browser(_) => None,
                }
            });
            let pending_terminal = surface
                .is_none()
                .then(|| content_terminal.and_then(|id| notifications.pending_terminals.get(id)))
                .flatten();
            let is_terminal_tab = surface.map_or(content_terminal.is_some(), |surface| {
                surface.kind() == SurfaceKind::Pty
            });
            let dead = surface.map(|s| s.is_dead()).unwrap_or(pending_terminal.is_none());
            let terminal_state = match (pending_terminal, is_terminal_tab) {
                (Some(pending), _) => Some(pending.state()),
                (None, false) => None,
                (None, true) if dead => Some("exited"),
                (None, true) => Some(
                    match surface.and_then(|surface| surface.terminal_host_connection_state()) {
                        Some(crate::surface::TerminalHostConnectionState::Reconnecting) => "reconnecting",
                        Some(crate::surface::TerminalHostConnectionState::Failed) => "failed",
                        _ => "running",
                    },
                ),
            };
            let host_record_version = match pending_terminal {
                Some(crate::mux::PendingTerminal::Unadoptable { record_version }) => *record_version,
                _ => None,
            };
            // Why a dead terminal ended: its runtime's end, else the durable
            // receipt of a terminal that has no runtime here.
            let end = if !dead || !is_terminal_tab {
                None
            } else {
                surface
                    .and_then(|surface| surface.terminal_end())
                    .map(|end| end.wire_json())
                    .or_else(|| content_terminal.and_then(|id| notifications.terminal_ends.get(id).cloned()))
                    .map(|end| notifications.with_loss_cause(content_terminal, end))
            };
            let mut tab = json!({
                "surface": sid,
                "tab_resource_id": tab_resource_id,
                "terminal_state": terminal_state,
                "host_record_version": host_record_version,
                "group": group_of(sid),
                "pinned": pinned,
                "relaunch": relaunch,
                "cwd": directory.and_then(|directory| directory.cwd.as_deref()),
                "git_branch": directory.and_then(|directory| directory.git_branch.as_deref()),
                "git_detached": directory.is_some_and(|directory| directory.git_detached),
                "content_resource_id": content_resource_id,
                "terminal_id": terminal_identity.as_ref().map(|identity| &identity.terminal_id),
                "terminal_resource_id": terminal_resource_id,
                "terminal_incarnation": terminal_identity
                    .as_ref()
                    .map(|identity| &identity.incarnation),
                "short_id": short_ids.get(sid).cloned().unwrap_or_default(),
                "supports_clear_history_key_fallback": surface
                    .is_some_and(|surface| surface.supports_clear_history_key_fallback()),
                "notification": notifications.get(sid).copied().map(|n| {
                    json!({
                        "notification": n.notification,
                        "unread": n.unread,
                        "level": n.level.as_str(),
                        "source": n.source.as_str(),
                    })
                }),
                "name": surface
                    .and_then(|s| s.name())
                    .or_else(|| kept.and_then(|k| k.name.clone())),
                "title": surface
                    .map(|s| s.title())
                    .filter(|title| !title.is_empty())
                    .or_else(|| kept.and_then(|k| k.title.clone()))
                    .unwrap_or_default(),
                "size": surface.map(|s| {
                    let (c, r) = s.size();
                    json!({"cols": c, "rows": r})
                }),
                "dead": dead,
                // Why a dead terminal ended (R41, terminal-state-v1).
                "end": end,
            });
            raw_tab::merge_surface_fields(&mut tab, surface, frontend_browser, conversation);
            // `app-screens-v1`: the app (and route) an app tab shows.
            if let Some(app) =
                content_resource_id.and_then(|id| notifications.presentation.app_tabs.get(id))
            {
                tab["app"] = app.wire();
            }
            let remote = content_resource_id.and_then(|id| notifications.presentation.remote_terminals.get(id));
            super::remote_terminal_tabs_wire::apply(&mut tab, remote);
            tab
        }).collect::<Vec<_>>(),
    })
}

pub(crate) fn workspaces_json(state: &State, notifications: &TreeDecorations) -> Value {
    let short_ids = tree_short_ids(state);
    json!({
        "workspace_revision": state.workspace_revision,
        "pane_revision": state.pane_revision,
        "groups": workspace_groups_json(&notifications.presentation),
        "workspaces": state.workspaces.iter().enumerate().map(|(index, workspace)| {
            workspace_json(state, workspace, index, &short_ids, notifications)
        }).collect::<Vec<_>>(),
    })
}

fn tree_short_ids(state: &State) -> HashMap<u64, String> {
    let ids = state
        .workspaces
        .iter()
        .flat_map(|ws| {
            let mut ids = vec![ws.id];
            for screen in &ws.screens {
                ids.push(screen.id);
                screen.root.pane_ids(&mut ids);
            }
            ids
        })
        .chain(state.surfaces.keys().copied());
    assign_short_ids(ids)
}

fn workspace_json(
    state: &State,
    workspace: &Workspace,
    index: usize,
    short_ids: &HashMap<u64, String>,
    notifications: &TreeDecorations,
) -> Value {
    let presentation = notifications.presentation.workspace(&workspace.key);
    let screen_groups =
        crate::mux::workspace_screen_groups(workspace, &notifications.presentation.screens);
    let group_of = |screen: ScreenId| {
        screen_groups
            .iter()
            .find(|run| run.members.contains(&screen))
            .map(|run| run.group.id.as_str())
    };
    json!({
        "id": workspace.id,
        "resource_id": workspace.public_id,
        "key": workspace.key,
        "short_id": short_ids.get(&workspace.id).cloned().unwrap_or_default(),
        "name": workspace.name,
        "group": presentation.and_then(|presentation| presentation.group.as_deref()),
        "color": presentation.and_then(|presentation| presentation.color.as_deref()),
        "icon": presentation.and_then(|presentation| presentation.icon.as_deref()),
        "title": presentation.and_then(|presentation| presentation.title.as_deref()),
        "pinned": presentation.is_some_and(|presentation| presentation.pinned),
        "marked_unread": presentation.is_some_and(|presentation| presentation.marked_unread),
        "kind": home::raw_workspace_kind(&notifications.presentation, &workspace.key),
        "app": home::raw_workspace_app(&notifications.presentation, &workspace.key),
        "unread_count": workspace_unread_count(state, workspace, notifications),
        "active": index == state.active_workspace,
        "screens": workspace.screens.iter().enumerate().map(|(screen_index, screen)| {
            screen_json(
                state,
                screen,
                screen_index == workspace.active_screen,
                group_of(screen.id),
                short_ids,
                notifications,
            )
        }).collect::<Vec<_>>(),
        "screen_groups": screen_groups.iter().map(screen_group_run_json).collect::<Vec<_>>(),
    })
}

fn screen_group_run_json(run: &crate::mux::WorkspaceScreenGroup) -> Value {
    json!({
        "id": run.group.id,
        "name": run.group.name,
        "color": run.group.color,
        "collapsed": run.group.collapsed,
        "saved_id": run.group.saved_id,
        "start": run.start,
        "count": run.members.len(),
        "screens": run.members,
    })
}

/// Tabs in a workspace whose content has an unread notification marker.
fn workspace_unread_count(
    state: &State,
    workspace: &Workspace,
    notifications: &TreeDecorations,
) -> usize {
    workspace
        .screens
        .iter()
        .flat_map(|screen| screen.root.pane_ids_vec())
        .filter_map(|pane| state.panes.get(&pane))
        .flat_map(|pane| pane.tabs.iter())
        .filter(|surface| notifications.get(surface).is_some_and(|marker| marker.unread))
        .count()
}

pub(crate) fn tree_entity_json(
    state: &State,
    notifications: &TreeDecorations,
    kind: TreeDeltaKind,
    id: u64,
) -> Option<Value> {
    if matches!(
        kind,
        TreeDeltaKind::WorkspaceAdded
            | TreeDeltaKind::WorkspaceClosed
            | TreeDeltaKind::WorkspaceRenamed
            | TreeDeltaKind::WorkspaceMoved
            | TreeDeltaKind::WorkspaceChanged
    ) {
        let short_ids = tree_short_ids(state);
        let index = state.workspace_index(id)?;
        let workspace = state.workspaces.get(index)?;
        return Some(workspace_json(state, workspace, index, &short_ids, notifications));
    }
    let tree = workspaces_json(state, notifications);
    let workspaces = tree.get("workspaces")?.as_array()?;
    match kind {
        TreeDeltaKind::WorkspaceAdded
        | TreeDeltaKind::WorkspaceClosed
        | TreeDeltaKind::WorkspaceRenamed
        | TreeDeltaKind::WorkspaceMoved
        | TreeDeltaKind::WorkspaceChanged => unreachable!("workspace deltas returned above"),
        TreeDeltaKind::ScreenAdded
        | TreeDeltaKind::ScreenClosed
        | TreeDeltaKind::ScreenRenamed
        | TreeDeltaKind::ScreenChanged => workspaces
            .iter()
            .flat_map(|workspace| {
                workspace.get("screens").and_then(Value::as_array).into_iter().flatten()
            })
            .find(|screen| screen.get("id").and_then(Value::as_u64) == Some(id))
            .cloned(),
        TreeDeltaKind::PaneAdded | TreeDeltaKind::PaneClosed => workspaces
            .iter()
            .flat_map(|workspace| {
                workspace.get("screens").and_then(Value::as_array).into_iter().flatten()
            })
            .flat_map(|screen| screen.get("panes").and_then(Value::as_array).into_iter().flatten())
            .find(|pane| pane.get("id").and_then(Value::as_u64) == Some(id))
            .cloned(),
        TreeDeltaKind::TabAdded
        | TreeDeltaKind::TabClosed
        | TreeDeltaKind::TabRenamed
        | TreeDeltaKind::TabChanged => workspaces
            .iter()
            .flat_map(|workspace| {
                workspace.get("screens").and_then(Value::as_array).into_iter().flatten()
            })
            .flat_map(|screen| screen.get("panes").and_then(Value::as_array).into_iter().flatten())
            .flat_map(|pane| pane.get("tabs").and_then(Value::as_array).into_iter().flatten())
            .find(|tab| tab.get("surface").and_then(Value::as_u64) == Some(id))
            .cloned(),
    }
}

pub(super) fn tree_delta_json(delta: &TreeDelta, mux: &Mux) -> Value {
    let mut value = json!({
        "event": delta.kind.as_str(),
        "workspace": delta.workspace,
        "entity": delta.entity,
    });
    if let Some(screen) = delta.screen {
        value["screen"] = json!(screen);
    }
    if let Some(pane) = delta.pane {
        value["pane"] = json!(pane);
    }
    if let Some(surface) = delta.surface {
        value["surface"] = json!(surface);
    }
    if let Some(index) = delta.index {
        value["index"] = json!(index);
    }
    if let Some(transaction) = &delta.transaction {
        value["transaction"] = json!(transaction.as_ref());
    }
    if let Some(revision) = delta.workspace_revision {
        value["workspace_revision"] = json!(revision);
        if let Ok(Some(event)) = mux.workspace_registry_event(revision) {
            value["origin"] = json!(event.origin);
            value["mutation_id"] = json!(event.mutation_id);
        }
        let (registry_id, generation) = mux.registry_identity();
        value["registry_id"] = json!(registry_id);
        value["generation"] = json!(generation);
    }
    value
}
