//! JSON views of the mux tree for the control protocol: panes (tabs, groups,
//! columns, docks), workspaces and screen groups, unread counts, short ids,
//! tree entities and tree deltas.

use super::home;
use super::pane_tab_group_json;
use super::raw_tab;
use super::screen_json;
use super::workspace_groups_json;
use crate::SurfaceKind;
use crate::panic_free::JsonFields;
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
use cmux_tui_util::short_id::short_id_without_set;
use serde_json::Value;
use serde_json::json;
use std::collections::HashMap;

/// The short IDs of the tree: each ID's own value when that does not depend on the other IDs
/// ([`short_id_without_set`], every ID a session allocates), else the whole session's assignment,
/// made once and only then. A delta's entity (one screen, pane or tab) then costs what it shows,
/// never the whole session (#32408).
pub(super) struct ShortIds<'a> {
    state: &'a State,
    assigned: std::cell::OnceCell<HashMap<u64, String>>,
}

impl<'a> ShortIds<'a> {
    pub(super) fn of(state: &'a State) -> Self {
        Self { state, assigned: std::cell::OnceCell::new() }
    }

    /// The short ID of `id`; empty for an ID the tree does not hold (as before).
    pub(super) fn get(&self, id: u64) -> String {
        short_id_without_set(id).unwrap_or_else(|| {
            self.assigned
                .get_or_init(|| tree_short_ids(self.state))
                .get(&id)
                .cloned()
                .unwrap_or_default()
        })
    }
}

#[cfg(test)]
thread_local! {
    /// Panes serialized on this thread (`pane_json`): a unit test reads how much of the tree one
    /// change builds (#32408).
    static PANES_BUILT: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// Panes serialized on this thread so far.
#[cfg(test)]
pub(crate) fn panes_built_for_test() -> u64 {
    PANES_BUILT.with(std::cell::Cell::get)
}

#[cfg(test)]
thread_local! {
    /// Test seam: runs once on this thread between an entity's build and the whole tree's build in
    /// `tree_entity_json`'s check, as a terminal's reader could run there on another thread.
    static ENTITY_CHECK_HOOK: std::cell::RefCell<Option<Box<dyn FnOnce()>>> =
        const { std::cell::RefCell::new(None) };
}

/// Runs `hook` once, the next time `tree_entity_json` on this thread has built an entity and has not
/// built the whole tree yet.
#[cfg(test)]
pub(crate) fn set_entity_check_hook_for_test(hook: impl FnOnce() + 'static) {
    ENTITY_CHECK_HOOK.with(|slot| *slot.borrow_mut() = Some(Box::new(hook)));
}

pub(super) fn pane_json(
    state: &State,
    id: PaneId,
    short_ids: &ShortIds<'_>,
    notifications: &TreeDecorations,
) -> Value {
    #[cfg(test)]
    PANES_BUILT.with(|built| built.set(built.get() + 1));
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
        "short_id": short_ids.get(id),
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
            // The page a pinned browser tab was pinned on (Back to Pinned Page).
            let pinned_url = state
                .resource_indexes
                .tab_ids
                .get(sid)
                .filter(|_| pinned)
                .and_then(|tab| notifications.presentation.pinned_urls.get(tab.as_str()));
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
            let relaunch = kept.map(|kept| {
                crate::state::kept_tab_store::relaunch_json(kept.cwd.as_deref(), kept.on_show)
            });
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
                "pinned_url": pinned_url,
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
                "short_id": short_ids.get(*sid),
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
                // OSC 7501: the status the tab shows (TUI tab indicator).
                "program_status": surface
                    .and_then(|surface| surface.shown_program_status())
                    .map(|status| status.wire()),
                // Why a dead terminal ended (R41, terminal-state-v1).
                "end": end,
            });
            raw_tab::merge_surface_fields(&mut tab, surface, frontend_browser, conversation);
            // `app-screens-v1`: the app (and route) an app tab shows.
            if let Some(app) =
                content_resource_id.and_then(|id| notifications.presentation.app_tabs.get(id))
            {
                tab.insert("app", app.wire());
            }
            let remote = content_resource_id.and_then(|id| notifications.presentation.remote_terminals.get(id));
            super::remote_terminal_tabs_wire::apply(&mut tab, remote);
            tab
        }).collect::<Vec<_>>(),
    })
}

pub(crate) fn workspaces_json(state: &State, notifications: &TreeDecorations) -> Value {
    let short_ids = ShortIds::of(state);
    json!({
        "workspace_revision": state.workspace_revision,
        "pane_revision": state.pane_revision,
        "groups": workspace_groups_json(&notifications.presentation),
        "workspaces": state.workspaces.iter().enumerate().map(|(index, workspace)| {
            workspace_json(state, workspace, index, &short_ids, notifications)
        }).collect::<Vec<_>>(),
    })
}

pub(super) fn tree_short_ids(state: &State) -> HashMap<u64, String> {
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
    short_ids: &ShortIds<'_>,
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
        "short_id": short_ids.get(workspace.id),
        "name": workspace.name,
        // `workspace-name-source-v1`: the revision is a decimal string, as on tabs.
        "name_source": workspace.name_source,
        "name_revision": workspace.name_revision.to_string(),
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

/// The workspace, index and screen of screen `id` as the tree lists it.
fn screen_in_tree(state: &State, id: u64) -> Option<(&Workspace, usize, &crate::model::Screen)> {
    let found =
        |workspace: &'_ Workspace| workspace.screens.iter().position(|screen| screen.id == id);
    if let Some(workspace) = state
        .resource_indexes
        .screen_workspace
        .get(&id)
        .and_then(|workspace| state.workspace_index(*workspace))
        .and_then(|index| state.workspaces.get(index))
        && let Some(index) = found(workspace)
    {
        return Some((workspace, index, &workspace.screens[index]));
    }
    state.workspaces.iter().find_map(|workspace| {
        found(workspace).map(|index| (workspace, index, &workspace.screens[index]))
    })
}

/// Whether a screen's layout places pane `pane` (the tree lists only those panes).
fn pane_in_tree(state: &State, pane: PaneId) -> Option<()> {
    let (workspace, screen) = state.screen_of(pane)?;
    state.workspaces.get(workspace)?.screens.get(screen)?.root.contains(pane).then_some(())
}

/// Screen `screen` (at `screen_index`) of `workspace` as `workspace_json` lists it.
fn workspace_screen_json(
    state: &State,
    workspace: &Workspace,
    screen_index: usize,
    screen: &crate::model::Screen,
    short_ids: &ShortIds<'_>,
    notifications: &TreeDecorations,
) -> Value {
    let screen_groups =
        crate::mux::workspace_screen_groups(workspace, &notifications.presentation.screens);
    let group = screen_groups
        .iter()
        .find(|run| run.members.contains(&screen.id))
        .map(|run| run.group.id.as_str());
    screen_json(
        state,
        screen,
        screen_index == workspace.active_screen,
        group,
        short_ids,
        notifications,
    )
}

fn screen_group_run_json(run: &crate::mux::WorkspaceScreenGroup) -> Value {
    json!({
        "id": run.group.id,
        "name": run.group.name,
        "color": run.group.color,
        "collapsed": run.group.collapsed,
        "saved_id": run.group.saved_id,
        "icon": run.group.icon,
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

/// `selection-changed` (`tree-selection-deltas-v1`): the whole selection of workspace `workspace`
/// (its active screen, each screen's active pane, each pane's active tab and focus stamp) and the
/// focused workspace, in O(that workspace). Nil when the workspace is gone.
pub(crate) fn selection_changed_json(state: &State, workspace: u64) -> Option<Value> {
    let index = state.workspace_index(workspace)?;
    let entry = state.workspaces.get(index)?;
    let screens = entry
        .screens
        .iter()
        .enumerate()
        .map(|(screen_index, screen)| {
            let panes = screen
                .root
                .pane_ids_vec()
                .into_iter()
                .filter_map(|id| state.panes.get(&id).map(|pane| (id, pane)))
                .map(|(id, pane)| {
                    json!({"id": id, "active_tab": pane.active_tab, "focused_at": pane.focused_at})
                })
                .collect::<Vec<_>>();
            json!({
                "id": screen.id,
                "active": screen_index == entry.active_screen,
                "active_pane": screen.active_pane,
                "panes": panes,
            })
        })
        .collect::<Vec<_>>();
    Some(json!({
        "event": "selection-changed",
        "workspace": workspace,
        "active": index == state.active_workspace,
        "active_workspace": state.workspaces.get(state.active_workspace).map(|active| active.id),
        "screens": screens,
    }))
}

/// `workspace-presentation-changed` (`tree-selection-deltas-v1`): workspace `workspace`'s entity as
/// `list-workspaces` has it, after a `workspace.update` of its title, color or icon. Nil when it is gone.
pub(crate) fn workspace_presentation_changed_json(
    state: &State,
    notifications: &TreeDecorations,
    workspace: u64,
) -> Option<Value> {
    let entity =
        tree_entity_json(state, notifications, TreeDeltaKind::WorkspaceChanged, workspace)?;
    Some(
        json!({"event": "workspace-presentation-changed", "workspace": workspace, "entity": entity}),
    )
}

pub(crate) fn tree_entity_json(
    state: &State,
    notifications: &TreeDecorations,
    kind: TreeDeltaKind,
    id: u64,
) -> Option<Value> {
    let entity = entity_json(state, notifications, kind, id);
    // Unit tests check every entity against the whole tree's value at that place (not counted as built).
    #[cfg(test)]
    check_entity_against_whole_tree(state, notifications, kind, id, &entity);
    entity
}

/// How many times the check reads an entity whose live fields keep moving before it gives up on
/// comparing it.
#[cfg(test)]
const ENTITY_CHECK_ATTEMPTS: usize = 16;

/// Unit tests: `entity` (built alone) equals the whole tree's value at its place. Both builders
/// read a terminal's live fields (title, size, connection state, end) without the state lock, and
/// its reader sets them on its own thread, so they are equal only when both builds saw the same
/// inputs: the entity is built again after the whole tree, and the two are compared only when the
/// inputs held still across the tree's build (the entity built before and after it agree). A title
/// set between the builds (#35765: a directory publication's tab delta, built on the terminal
/// publisher while the shell sets its title at a prompt) is read again, not reported as a
/// difference. Not counted as built.
#[cfg(test)]
fn check_entity_against_whole_tree(
    state: &State,
    notifications: &TreeDecorations,
    kind: TreeDeltaKind,
    id: u64,
    entity: &Option<Value>,
) {
    let built = panes_built_for_test();
    let mut before = entity.clone();
    for _ in 0..ENTITY_CHECK_ATTEMPTS {
        if let Some(hook) = ENTITY_CHECK_HOOK.with(|slot| slot.borrow_mut().take()) {
            hook();
        }
        let from_tree = entity_from_whole_tree(state, notifications, kind, id);
        let after = entity_json(state, notifications, kind, id);
        if after == before {
            PANES_BUILT.with(|cell| cell.set(built));
            assert_eq!(after, from_tree, "the {kind:?} entity of {id} differs from the tree's");
            return;
        }
        before = after;
    }
    // The live fields moved during every attempt: nothing to compare.
    PANES_BUILT.with(|cell| cell.set(built));
}

/// Only the entity itself: the one workspace, screen, pane or tab, never the whole tree (each
/// create's delta took the whole session's tree under the registry and state locks, #32408). The
/// value is the one `list-workspaces` holds at that place.
fn entity_json(
    state: &State,
    notifications: &TreeDecorations,
    kind: TreeDeltaKind,
    id: u64,
) -> Option<Value> {
    let short_ids = ShortIds::of(state);
    match kind {
        TreeDeltaKind::WorkspaceAdded
        | TreeDeltaKind::WorkspaceClosed
        | TreeDeltaKind::WorkspaceRenamed
        | TreeDeltaKind::WorkspaceMoved
        | TreeDeltaKind::WorkspaceChanged => {
            let index = state.workspace_index(id)?;
            let workspace = state.workspaces.get(index)?;
            Some(workspace_json(state, workspace, index, &short_ids, notifications))
        }
        TreeDeltaKind::ScreenAdded
        | TreeDeltaKind::ScreenClosed
        | TreeDeltaKind::ScreenRenamed
        | TreeDeltaKind::ScreenChanged => {
            let (workspace, screen_index, screen) = screen_in_tree(state, id)?;
            Some(workspace_screen_json(
                state,
                workspace,
                screen_index,
                screen,
                &short_ids,
                notifications,
            ))
        }
        TreeDeltaKind::PaneAdded | TreeDeltaKind::PaneClosed => {
            pane_in_tree(state, id)?;
            Some(pane_json(state, id, &short_ids, notifications))
        }
        TreeDeltaKind::TabAdded
        | TreeDeltaKind::TabClosed
        | TreeDeltaKind::TabRenamed
        | TreeDeltaKind::TabChanged => {
            let pane = state.pane_of(id)?;
            pane_in_tree(state, pane)?;
            let mut pane = pane_json(state, pane, &short_ids, notifications);
            let tabs = pane.get_mut("tabs")?.as_array_mut()?;
            let index = tabs
                .iter()
                .position(|tab| tab.get("surface").and_then(Value::as_u64) == Some(id))?;
            Some(tabs.swap_remove(index))
        }
    }
}

/// The entity at `kind`/`id` read from the whole tree: what [`entity_json`] must equal.
#[cfg(test)]
fn entity_from_whole_tree(
    state: &State,
    notifications: &TreeDecorations,
    kind: TreeDeltaKind,
    id: u64,
) -> Option<Value> {
    let tree = workspaces_json(state, notifications);
    let workspaces = tree.get("workspaces")?.as_array()?;
    let screens = || {
        workspaces.iter().flat_map(|workspace| {
            workspace.get("screens").and_then(Value::as_array).into_iter().flatten()
        })
    };
    let panes = || {
        screens()
            .flat_map(|screen| screen.get("panes").and_then(Value::as_array).into_iter().flatten())
    };
    match kind {
        TreeDeltaKind::WorkspaceAdded
        | TreeDeltaKind::WorkspaceClosed
        | TreeDeltaKind::WorkspaceRenamed
        | TreeDeltaKind::WorkspaceMoved
        | TreeDeltaKind::WorkspaceChanged => workspaces
            .iter()
            .find(|workspace| workspace.get("id").and_then(Value::as_u64) == Some(id))
            .cloned(),
        TreeDeltaKind::ScreenAdded
        | TreeDeltaKind::ScreenClosed
        | TreeDeltaKind::ScreenRenamed
        | TreeDeltaKind::ScreenChanged => {
            screens().find(|screen| screen.get("id").and_then(Value::as_u64) == Some(id)).cloned()
        }
        TreeDeltaKind::PaneAdded | TreeDeltaKind::PaneClosed => {
            panes().find(|pane| pane.get("id").and_then(Value::as_u64) == Some(id)).cloned()
        }
        TreeDeltaKind::TabAdded
        | TreeDeltaKind::TabClosed
        | TreeDeltaKind::TabRenamed
        | TreeDeltaKind::TabChanged => panes()
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
        value.insert("screen", json!(screen));
    }
    if let Some(pane) = delta.pane {
        value.insert("pane", json!(pane));
    }
    if let Some(surface) = delta.surface {
        value.insert("surface", json!(surface));
    }
    if let Some(index) = delta.index {
        value.insert("index", json!(index));
    }
    if let Some(transaction) = &delta.transaction {
        value.insert("transaction", json!(transaction.as_ref()));
    }
    if let Some(revision) = delta.workspace_revision {
        value.insert("workspace_revision", json!(revision));
        if let Ok(Some(event)) = mux.workspace_registry_event(revision) {
            value.insert("origin", json!(event.origin));
            value.insert("mutation_id", json!(event.mutation_id));
        }
        let (registry_id, generation) = mux.registry_identity();
        value.insert("registry_id", json!(registry_id));
        value.insert("generation", json!(generation));
    }
    value
}
