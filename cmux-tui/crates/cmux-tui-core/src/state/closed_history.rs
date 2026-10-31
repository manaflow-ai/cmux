//! `closed.reopen`: recreate a recently closed group (`closed-history-v2`,
//! plans/cmux-next/reopen-closed.md) from its record: every member, or the
//! chosen ones, in their stored order.
//!
//! Without a `closed` id the request takes the newest group of its `window`
//! (Cmd-Shift-T), else the newest group no live window owns. A tab reopens
//! in its pane at its old index when that pane is live, else in the
//! focused pane of its workspace, else in the session's focused pane; a
//! terminal that still runs gets a new view, any other terminal starts in
//! its recorded directory. A screen reopens in its workspace (a new
//! workspace when that is gone); a workspace reopens as a new workspace.
//! The restored members leave the history in the commit that stores the
//! request's result, so a retry with the same key replays it.

use crate::Actor;
use crate::mux::tab_groups::{group_members, pane_by_public_id};
use crate::mux::tab_strip::StripRequest;
use crate::mux::*;
use crate::state::closed_history_query::{
    closed_page, closed_record, keep_members, newest_for_window, public_item, remove_closed,
    remove_other_closes,
};
use crate::state::commit::{StateEffects, state_not_found};
use crate::state::conversation_tabs::ConversationTabTarget;
use crate::state::conversation_tabs_store::ConversationTabRecord;
use crate::state::prelude::*;
use crate::state::remote_terminal_tabs_store::RemoteTerminalRecord;
use crate::state::store::{StateChanges, StateCommit, state_delete, state_upsert};
use crate::user_settings::NewWorkspacePlacement;
use cmux_json::JsonSet as _;

const OPERATION: &str = "closed.reopen";

/// What a `closed.reopen` request names.
#[derive(Default)]
pub(crate) struct ReopenRequest {
    /// The group; None: the newest group in `window`'s scope.
    pub(crate) closed: Option<String>,
    /// The caller's window record id (`install/window`).
    pub(crate) window: Option<String>,
    /// Member indexes to restore; None: every member.
    pub(crate) members: Option<Vec<usize>>,
    /// A `tab_` id: reopen the member of the newest group that holds this
    /// tab, under the same id (a `cmux://tab/` link,
    /// plans/cmux-next/durable-links-DESIGN.md). Excludes `closed` and
    /// `members`.
    pub(crate) tab: Option<String>,
    /// A `ws_` id: reopen the newest closed workspace member that had this
    /// id (a `cmux://workspace/` link to a closed workspace). It reopens as
    /// a new workspace, like any reopened workspace. Excludes `closed`,
    /// `members` and `tab`.
    pub(crate) workspace: Option<String>,
    /// A `pane_` id: where a reopened tab goes when its own pane and
    /// workspace are gone, instead of the session's focused pane.
    pub(crate) fallback_pane: Option<String>,
}

impl ReopenRequest {
    /// The idempotency fingerprint. A request that names only `closed`
    /// keeps the v1 fingerprint, so a retry across an upgrade replays.
    fn fingerprint(&self) -> Value {
        let mut fingerprint = serde_json::json!({"operation": OPERATION, "closed": self.closed});
        if let Some(window) = &self.window {
            fingerprint.set("window", serde_json::json!(window));
        }
        if let Some(members) = &self.members {
            fingerprint.set("members", serde_json::json!(members));
        }
        if let Some(tab) = &self.tab {
            fingerprint.set("tab", serde_json::json!(tab));
        }
        if let Some(workspace) = &self.workspace {
            fingerprint.set("workspace", serde_json::json!(workspace));
        }
        if let Some(pane) = &self.fallback_pane {
            fingerprint.set("fallback_pane", serde_json::json!(pane));
        }
        fingerprint
    }
}

/// What a reopen created, in public ids.
#[derive(Default)]
pub(super) struct Reopened {
    pub(super) workspaces: Vec<String>,
    pub(super) screens: Vec<String>,
    pub(super) tabs: Vec<String>,
    /// (closed workspace key, reopened workspace key) per reopened workspace.
    pub(super) placements: Vec<(String, String)>,
    /// A closed tab's id to the id it reopened as.
    pub(super) reopened_as: std::collections::HashMap<String, String>,
    /// A closed pane's id to the pane split off its neighbor again; the
    /// group's kept tabs of that pane follow it there.
    panes: std::collections::HashMap<String, super::closed_pane_split::SplitPane>,
    /// The request's `fallback_pane`, live: where a tab whose pane and
    /// workspace are gone reopens.
    fallback_pane: Option<PaneId>,
}

impl Reopened {
    pub(super) fn note_workspace(&mut self, workspace: String) {
        if !self.workspaces.contains(&workspace) {
            self.workspaces.push(workspace);
        }
    }

    /// Note `tab`, reopened from the closed tab `record`.
    pub(super) fn note_tab(&mut self, record: &Value, tab: String) {
        if let Some(closed) = record["tab_id"].as_str() {
            self.reopened_as.insert(closed.to_string(), tab.clone());
        }
        self.tabs.push(tab);
    }
}

/// Split `members` into the ones to restore and the ones to keep.
pub(super) fn choose(
    members: Vec<Value>,
    chosen: Option<&[usize]>,
) -> anyhow::Result<(Vec<Value>, Vec<Value>)> {
    let Some(chosen) = chosen else { return Ok((members, Vec::new())) };
    if let Some(bad) = chosen.iter().find(|index| **index >= members.len()) {
        anyhow::bail!(
            "bad request: member {bad} is out of range (the group has {})",
            members.len()
        );
    }
    let (restore, keep): (Vec<_>, Vec<_>) =
        members.into_iter().enumerate().partition(|(index, _)| chosen.contains(index));
    Ok((restore.into_iter().map(|(_, m)| m).collect(), keep.into_iter().map(|(_, m)| m).collect()))
}

/// One reopen at a time per daemon, from resolving the group to the commit
/// that removes the restored members: two presses (or two clients) never
/// restore the same group or member twice.
pub(super) static REOPEN: std::sync::Mutex<()> = std::sync::Mutex::new(());

thread_local! {
    /// The surfaces reopens create while [`recording_created`] runs.
    static CREATED: std::cell::RefCell<Option<Vec<SurfaceId>>> =
        const { std::cell::RefCell::new(None) };
}

/// Run `body`, and answer with every surface a reopen created during it
/// (tabs and the starter tab of a workspace made for them), the moment it
/// was created: also the ones a later step of the same reopen failed on, so
/// a caller that undoes a failed reopen closes all of them.
pub(super) fn recording_created<T>(body: impl FnOnce() -> T) -> (T, Vec<SurfaceId>) {
    let outer = CREATED.with(|created| created.replace(Some(Vec::new())));
    let result = body();
    let created = CREATED.with(|created| created.replace(outer)).unwrap_or_default();
    // A recording around this one sees these too.
    CREATED.with(|outer| {
        if let Some(outer) = outer.borrow_mut().as_mut() {
            outer.extend_from_slice(&created);
        }
    });
    (result, created)
}

/// Note `surface` as created by a reopen (see [`recording_created`]).
pub(super) fn note_created(surface: SurfaceId) {
    CREATED.with(|created| {
        if let Some(created) = created.borrow_mut().as_mut() {
            created.push(surface);
        }
    });
}

/// The commit side of a reopen: re-read the group in the transaction, drop
/// the restored members (by value: members of one group differ at least in
/// their place), and give the request's result and the public change.
fn commit_reopen(
    transaction: &rusqlite::Transaction<'_>,
    closed_id: &str,
    restored: &[Value],
    reopened: &Reopened,
    active_workspace: Option<&str>,
) -> anyhow::Result<StateChanges> {
    let record = closed_record(transaction, closed_id)?
        .ok_or_else(|| state_not_found("closed", closed_id))?;
    let mut keep = record["members"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|member| !restored.contains(member))
        .cloned()
        .collect::<Vec<_>>();
    super::closed_pane_split::follow_split_panes(&mut keep, &reopened.panes);
    super::closed_pane_split::retarget_members(&mut keep, &reopened.panes);
    super::closed_pane_split::retarget_split_neighbors(transaction, closed_id, &reopened.panes)?;
    let remaining = keep.len();
    let kind = record["kind"].as_str().unwrap_or_default().to_string();
    // A deleted space (SPACE-DELETE-CLOSES-ITS-WORKSPACES) comes back first,
    // so its reopened workspaces get their pins and groups back.
    let room = record.get("room").filter(|room| room.is_object()).cloned();
    // A deleted personal workspace group (Ungroup, Delete Group) has no
    // member: its reopen forms the group again around its open workspaces.
    let group = record.get("group").filter(|group| group.is_object()).cloned();
    // A closed window (`window` group) reopens no workspace: the app shows
    // that window again, with the workspaces it kept.
    let window = (kind == "window").then(|| record["window_record"].clone());
    // An ungrouped tab or screen group has no member: its reopen formed it
    // again.
    let tab_group = ["tab_group", "screen_group"]
        .iter()
        .any(|field| record.get(*field).is_some_and(Value::is_object));
    // A page reopened is open again: every other close of it leaves with this one, so none
    // takes its Recently Closed row or reopens it a second time (Leo 2026-10-14).
    let page = if tab_group { None } else { closed_page(&public_item(&record)).map(str::to_owned) };
    let mut others = Vec::new();
    let change = if keep.is_empty() {
        remove_closed(transaction, closed_id)?;
        if let Some(page) = &page {
            others = remove_other_closes(transaction, page)?;
        }
        state_delete("closed", closed_id)
    } else {
        state_upsert("closed", closed_id, keep_members(transaction, closed_id, record, keep)?)
    };
    // A deleted space that had no workspace, or a deleted group, reopens
    // no workspace: the result names the session's active one, which stays
    // shown.
    let workspace = reopened
        .workspaces
        .first()
        .cloned()
        .or_else(|| {
            active_workspace
                .filter(|_| room.is_some() || group.is_some() || window.is_some() || tab_group)
                .map(str::to_string)
        })
        .context("reopened item has no workspace")?;
    let mut changes = vec![change];
    changes.extend(others);
    let room_restored = match &room {
        Some(room) => {
            let local = crate::state::values::local_registry_id(transaction)?;
            crate::workspace_registry::personal_mutations::room_archive::restore_room(
                transaction,
                room,
                &local,
                &reopened.placements,
            )?
        }
        None => false,
    };
    for (closed_key, reopened_key) in &reopened.placements {
        changes.extend(restore_placement(transaction, closed_key, reopened_key)?);
    }
    let group_restored = match &group {
        Some(group) => {
            let local = crate::state::values::local_registry_id(transaction)?;
            crate::workspace_registry::personal_mutations::group_archive::restore_group(
                transaction,
                group,
                &local,
                &reopened.placements,
            )?
        }
        None => false,
    };
    if group_restored && !room_restored {
        changes.extend(crate::state::personal::all_groups(transaction)?);
        changes.extend(crate::state::personal::all_placements(transaction)?);
    }
    if room_restored {
        changes.extend(crate::state::personal::all_rooms(transaction)?);
        changes.extend(crate::state::personal::all_groups(transaction)?);
        changes.extend(crate::state::personal::all_placements(transaction)?);
    }
    // sidebar-doc-v1: the restored rows move their items back to their old
    // place in the document (it listed the reopened workspace where it was
    // created, last).
    super::sidebar_doc_sync::sync_from_legacy(transaction)?;
    Ok(StateChanges::new(
        serde_json::json!({
            "closed_id": closed_id,
            "kind": kind,
            "workspace_id": workspace,
            "workspace_ids": reopened.workspaces,
            "screen_ids": reopened.screens,
            "tab_ids": reopened.tabs,
            "remaining": remaining,
            "window": window,
        }),
        changes,
    ))
}

/// Whether closed workspace `closed_key` still has its personal row in this
/// session, the place [`restore_placement`] gives back on reopen.
fn place_kept(connection: &rusqlite::Connection, closed_key: &str) -> anyhow::Result<bool> {
    use rusqlite::{OptionalExtension, params};
    let local = crate::state::values::local_registry_id(connection)?;
    Ok(connection
        .query_row(
            "SELECT 1 FROM personal_workspaces WHERE session_id = ?1 AND workspace_key = ?2",
            params![local, closed_key],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

/// Give the reopened workspace the closed one's personal row: its group,
/// its place in the personal sidebar order and its theme
/// (LAST-TAB-CLOSES-WORKSPACE rule 3). Nothing when that row is gone.
pub(super) fn restore_placement(
    transaction: &rusqlite::Transaction<'_>,
    closed_key: &str,
    reopened_key: &str,
) -> anyhow::Result<Vec<Value>> {
    use crate::state::personal_state_store::{placement_id, placement_snapshot};
    use rusqlite::params;
    let local = crate::state::values::local_registry_id(transaction)?;
    if !place_kept(transaction, closed_key)? {
        return Ok(Vec::new());
    }
    transaction.execute(
        "DELETE FROM personal_workspaces WHERE session_id = ?1 AND workspace_key = ?2",
        params![local, reopened_key],
    )?;
    transaction.execute(
        "UPDATE personal_workspaces SET workspace_key = ?3 WHERE session_id = ?1 AND workspace_key = ?2",
        params![local, closed_key, reopened_key],
    )?;
    crate::workspace_registry::personal_store::bump_personal_revision(transaction)?;
    let placement = placement_snapshot(transaction, &local, reopened_key)?;
    Ok(vec![
        state_delete("workspace_placement", &placement_id(&local, closed_key)),
        state_upsert("workspace_placement", &placement_id(&local, reopened_key), placement),
    ])
}

impl Mux {
    pub(crate) fn state_reopen_closed(
        self: &Arc<Self>,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        request: &ReopenRequest,
    ) -> anyhow::Result<StateCommit> {
        let _serial = REOPEN.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let fingerprint = request.fingerprint();
        if let Some(replay) = self.workspace_registry.lock().unwrap().replay_resource_patch(
            mutation,
            OPERATION,
            &fingerprint,
        )? {
            return Ok(replay.into());
        }
        let by_tab = match &request.tab {
            Some(tab) => {
                if request.closed.is_some() || request.members.is_some() {
                    anyhow::bail!("bad request: tab excludes closed and members");
                }
                let live = self.with_state(|state| {
                    state.resource_indexes.tab_ids.values().any(|id| id.as_str() == tab)
                });
                let found = if live {
                    None
                } else {
                    self.read_registry_state(|connection| {
                        crate::state::closed_history_query::group_member_holding_tab(
                            connection, tab,
                        )
                    })?
                };
                Some(found.ok_or_else(|| state_not_found("tab", tab))?)
            }
            None => None,
        };
        let by_tab = match &request.workspace {
            Some(workspace) => {
                if request.closed.is_some() || request.members.is_some() || by_tab.is_some() {
                    anyhow::bail!("bad request: workspace excludes closed, members and tab");
                }
                let live = self.with_state(|state| {
                    state.workspaces.iter().any(|open| open.public_id.as_str() == workspace)
                });
                let found = if live {
                    None
                } else {
                    self.read_registry_state(|connection| {
                        crate::state::closed_history_query::group_member_holding_workspace(
                            connection, workspace,
                        )
                    })?
                };
                Some(found.ok_or_else(|| state_not_found("workspace", workspace))?)
            }
            None => by_tab,
        };
        let closed_id = match (&by_tab, &request.closed) {
            (Some((closed, _)), _) => closed.clone(),
            (None, Some(closed)) => closed.clone(),
            (None, None) => self
                .read_registry_state(|connection| {
                    newest_for_window(connection, request.window.as_deref())
                })?
                .ok_or_else(|| state_not_found("closed", "newest"))?,
        };
        let record = self
            .read_registry_state(|connection| closed_record(connection, &closed_id))?
            .ok_or_else(|| state_not_found("closed", &closed_id))?;
        let members = record["members"].as_array().cloned().unwrap_or_default();
        let chosen = match &by_tab {
            Some((_, member)) => Some(vec![*member]),
            None => request.members.clone(),
        };
        let (restore, _) = choose(members, chosen.as_deref())?;
        // A closed pane split off another pane of the same gesture comes back after it.
        let restore = super::closed_pane_split::neighbors_first(restore);
        let fallback_pane = request
            .fallback_pane
            .as_deref()
            .and_then(|pane| self.with_state(|state| pane_by_public_id(state, pane)));
        let mut reopened = Reopened { fallback_pane, ..Reopened::default() };
        for member in &restore {
            self.reopen_member(&mutation.actor, &closed_id, member, &mut reopened)?;
        }
        // An ungrouped group (`tab_group`, no member) forms again whole. The
        // groups a close took (`tab_groups`; `tab_group` on a Close Group
        // recorded before cx-gzh.31) name their closed tabs: each forms
        // again around those this reopen brought back.
        let closed = !restore.is_empty();
        let groups = record
            .get("tab_group")
            .filter(|group| group.is_object())
            .into_iter()
            .chain(record["tab_groups"].as_array().into_iter().flatten());
        for group in groups {
            let mut group = group.clone();
            if closed {
                let tabs = group["tab_ids"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|tab| reopened.reopened_as.get(tab.as_str()?).cloned())
                    .collect::<Vec<_>>();
                if tabs.is_empty() {
                    continue;
                }
                group.set("tab_ids", serde_json::json!(tabs));
            }
            self.reopen_tab_group(&mutation.actor, &group, closed, &mut reopened)?;
        }
        if let Some(group) = record.get("screen_group").filter(|group| group.is_object()) {
            self.reopen_screen_group(&mutation.actor, group, &mut reopened)?;
        }
        let active = self.with_state(|state| {
            state
                .workspaces
                .get(state.active_workspace)
                .map(|workspace| workspace.public_id.to_string())
        });
        let commit = self.commit_state(
            mutation,
            OPERATION,
            &fingerprint,
            expected_revision,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                commit_reopen(transaction, &closed_id, &restore, &reopened, active.as_deref())
            },
        )?;
        // Each reopened workspace keeps its agent-home folder (chat files), before its first chat.
        super::agent_home_moves::follow_reopen(&reopened.placements);
        Ok(commit)
    }

    fn reopen_member(
        self: &Arc<Self>,
        actor: &Actor,
        closed_id: &str,
        member: &Value,
        reopened: &mut Reopened,
    ) -> anyhow::Result<()> {
        match member["kind"].as_str() {
            Some("tab") => self.reopen_closed_tab(actor, member, reopened),
            Some("screen") => self.reopen_closed_screen(actor, member, reopened),
            Some("workspace") => self.reopen_closed_workspace(actor, member, reopened),
            other => {
                anyhow::bail!("closed item {closed_id} has a member of unknown kind {other:?}")
            }
        }
    }

    /// Form an ungrouped tab group again (`archive`, from
    /// `record_ungrouped_group`) with its id, name and color around
    /// those of its tabs still open, unpinned and in no other group, in one
    /// pane, in their order: its own pane when it holds any, else the pane
    /// of the first. A group formed since keeps its tabs.
    /// None still open forms nothing; a live group of that id (a retried
    /// reopen) is left as it is.
    ///
    /// `closed`: the archive is a closed group's (Close Group) and names the
    /// tabs this reopen brought back, which are already in `reopened`. A
    /// live group of that id (an earlier partial reopen formed it) takes
    /// them in.
    pub(super) fn reopen_tab_group(
        self: &Arc<Self>,
        actor: &Actor,
        archive: &Value,
        closed: bool,
        reopened: &mut Reopened,
    ) -> anyhow::Result<()> {
        let Some(id) = archive["id"].as_str().map(str::to_string) else { return Ok(()) };
        let presentation = self.presentation_snapshot();
        // A group row a close left behind (no strip edit pruned it yet)
        // holds no open tab: it is not live, and forms again.
        let live = self
            .with_state(|state| !group_members(state, &presentation.tab_groups, &id).is_empty());
        if !live || closed {
            let wanted = archive["tab_ids"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .filter(|tab| {
                    // A reopened tab keeps its id (durable-links-DESIGN.md), so the
                    // membership row its close left behind names this same group: only
                    // another group's row keeps it out.
                    !presentation.pinned_tabs.contains(*tab)
                        && presentation
                            .tab_groups
                            .members
                            .get(*tab)
                            .is_none_or(|group| group.as_str() == id)
                })
                .map(str::to_string)
                .collect::<Vec<_>>();
            let home = archive["pane_id"].as_str().map(str::to_string);
            let members = self.with_state(|state| {
                let open = wanted
                    .iter()
                    .filter_map(|tab| {
                        state
                            .resource_indexes
                            .tab_ids
                            .iter()
                            .find_map(|(surface, id)| (id.as_str() == tab).then_some(*surface))
                    })
                    .collect::<Vec<_>>();
                if live {
                    return open;
                }
                let pane = home
                    .as_deref()
                    .and_then(|pane| pane_by_public_id(state, pane))
                    .filter(|pane| {
                        open.iter().any(|surface| state.pane_of(*surface) == Some(*pane))
                    })
                    .or_else(|| open.first().and_then(|surface| state.pane_of(*surface)));
                open.into_iter()
                    .filter(|surface| pane.is_some() && state.pane_of(*surface) == pane)
                    .collect::<Vec<_>>()
            });
            if members.is_empty() {
                return Ok(());
            }
            if live {
                self.rejoin_closed_tab_group(actor, &id, members)?;
            } else {
                self.tab_group_create(
                    StripRequest::local(actor, "closed.reopen"),
                    move |_| Ok(members),
                    archive["name"].as_str().map(str::to_string),
                    archive["color"].as_str().map(str::to_string),
                    id.clone(),
                    archive["icon"].as_str().map(str::to_string),
                )?;
                if let Some(saved) = archive["saved_id"].as_str() {
                    self.relink_saved_tab_group(actor, &id, saved)?;
                }
            }
        }
        let outcome = self.tab_group_outcome(&id);
        if !closed {
            for surface in &outcome.members {
                reopened.tabs.push(self.public_tab_of(*surface)?);
            }
        }
        if let Some(pane) = outcome.pane {
            let (workspace, _) = self.public_screen_of_pane(pane)?;
            reopened.note_workspace(workspace);
        }
        Ok(())
    }

    /// Form an ungrouped screen group again (`archive`, from
    /// `record_ungrouped_group`) with its id, name and color around those of
    /// its screens still open, unpinned and in no other group, in their
    /// order, in the workspace of the first. A group formed since keeps its
    /// screens. None still open forms nothing; a live group of that id (a
    /// retried reopen) is left as it is.
    fn reopen_screen_group(
        self: &Arc<Self>,
        actor: &Actor,
        archive: &Value,
        reopened: &mut Reopened,
    ) -> anyhow::Result<()> {
        let Some(id) = archive["id"].as_str().map(str::to_string) else { return Ok(()) };
        let presentation = self.presentation_snapshot();
        if !presentation.screens.groups.contains_key(&id) {
            let wanted = archive["screen_ids"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .filter(|screen| {
                    !presentation.screens.is_pinned(screen)
                        && !presentation.screens.members.contains_key(*screen)
                })
                .filter_map(|screen| self.screen_id_of(screen))
                .collect::<Vec<_>>();
            let members = self.with_state(|state| {
                let workspace = |screen: ScreenId| {
                    state.workspaces.iter().position(|workspace| {
                        workspace.screens.iter().any(|candidate| candidate.id == screen)
                    })
                };
                let first = wanted.first().and_then(|screen| workspace(*screen));
                wanted
                    .iter()
                    .copied()
                    .filter(|screen| first.is_some() && workspace(*screen) == first)
                    .collect::<Vec<_>>()
            });
            if members.is_empty() {
                return Ok(());
            }
            self.create_screen_group_with_id(
                StripRequest::local_screens(actor, "closed.reopen"),
                &members,
                archive["name"].as_str().map(str::to_string),
                archive["color"].as_str().map(str::to_string),
                id.clone(),
            )?;
        }
        let outcome = self.screen_group_outcome_public(&id);
        let screens = self.with_state(|state| {
            let workspace = outcome
                .workspace
                .and_then(|workspace| state.workspace_index(workspace))
                .map(|index| &state.workspaces[index]);
            workspace.map(|workspace| {
                let screens = outcome
                    .members
                    .iter()
                    .filter_map(|member| {
                        workspace.screens.iter().find(|screen| screen.id == *member)
                    })
                    .map(|screen| screen.public_id.to_string())
                    .collect::<Vec<_>>();
                (workspace.public_id.to_string(), screens)
            })
        });
        if let Some((workspace, screens)) = screens {
            reopened.screens.extend(screens);
            reopened.note_workspace(workspace);
        }
        Ok(())
    }

    pub(super) fn public_tab_of(&self, surface: SurfaceId) -> anyhow::Result<String> {
        self.with_state(|state| {
            state.resource_indexes.tab_ids.get(&surface).map(|id| id.to_string())
        })
        .context("reopened tab has no public id")
    }

    pub(super) fn public_screen_of_pane(&self, pane: PaneId) -> anyhow::Result<(String, String)> {
        self.with_state(|state| {
            let (workspace, screen) = state.screen_of(pane)?;
            let workspace = &state.workspaces[workspace];
            Some((workspace.public_id.to_string(), workspace.screens[screen].public_id.to_string()))
        })
        .context("reopened pane has no screen")
    }

    /// Restore one tab record into `pane`. `reattach` lets a still-running
    /// terminal get a new view instead of a new process.
    pub(super) fn reopen_tab_record(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        tab: &Value,
        reattach: bool,
    ) -> anyhow::Result<SurfaceId> {
        // The tab comes back under its own id, so every link to it keeps
        // working (plans/cmux-next/durable-links-DESIGN.md). Each creation
        // attempt below gets the id; the first that commits keeps it.
        let retired = tab["tab_id"].as_str();
        let same_id = |create: &mut dyn FnMut() -> anyhow::Result<SurfaceId>| {
            tab_strip::reopen_identity::scoped(retired, create)
        };
        let surface = match tab["kind"].as_str() {
            Some("browser") if tab.get("conversation").is_some_and(|value| !value.is_null()) => {
                let record = ConversationTabRecord::from_wire(&tab["conversation"])
                    .context("the closed conversation tab has no valid record")?;
                same_id(&mut || {
                    let target = ConversationTabTarget::Pane(Some(pane));
                    Ok(self
                        .new_conversation_tab_as(actor, target, record.clone(), None, None, None)?
                        .surface
                        .id)
                })?
            }
            Some("browser") if tab.get("remote").is_some_and(|value| !value.is_null()) => {
                let record = RemoteTerminalRecord::from_wire(&tab["remote"])
                    .context("the closed remote-terminal tab has no valid record")?;
                same_id(&mut || {
                    Ok(self.new_remote_terminal_tab_as(actor, Some(pane), record.clone(), None)?.id)
                })?
            }
            Some("browser") => {
                let url = tab["url"].as_str().unwrap_or("about:blank").to_string();
                match tab["engine"].as_str() {
                    Some(engine) => {
                        let surface = same_id(&mut || {
                            Ok(self
                                .new_frontend_browser_tab_as(
                                    actor,
                                    Some(pane),
                                    crate::workspace_registry::FrontendBrowserRecord {
                                        engine: engine.to_string(),
                                        url: url.clone(),
                                        title: None,
                                        favicon_url: None,
                                        profile_id: tab["browser_profile_id"]
                                            .as_str()
                                            .map(str::to_string),
                                        // The app that shows the reopened tab claims it.
                                        owner: None,
                                    },
                                    None,
                                )?
                                .id)
                        })?;
                        // The page restores its back/forward entries and
                        // scroll from here, as at relaunch (cx-d0d.11).
                        if let Some(history) = tab["browser_history"].as_str()
                            && let Err(error) =
                                self.set_frontend_browser_history(surface, Some(history.into()))
                        {
                            eprintln!(
                                "cmux-tui: reopened browser tab lost its session history: {error}"
                            );
                        }
                        surface
                    }
                    None => same_id(&mut || {
                        Ok(self.new_browser_tab_as(actor, url.clone(), Some(pane), None)?.id)
                    })?,
                }
            }
            _ => {
                let running = reattach
                    .then(|| tab["terminal_id"].as_str())
                    .flatten()
                    .and_then(|terminal| self.resolve_running_terminal(terminal));
                match running.and_then(|resolution| {
                    same_id(&mut || {
                        self.project_terminal_into_pane(
                            actor,
                            &resolution.terminal.terminal_id,
                            pane,
                        )
                    })
                    .ok()
                }) {
                    Some(surface) => surface,
                    None => {
                        // ARCHIVE-1: the archived screen and the stopped
                        // program come back above the new shell.
                        let (spawn, _seed, size) = self.reopen_terminal_spawn(tab);
                        same_id(&mut || {
                            Ok(self
                                .new_tab_with_options_as(actor, Some(pane), spawn.clone(), size)?
                                .id)
                        })?
                    }
                }
            }
        };
        note_created(surface);
        self.restore_tab_details(actor, surface, tab)?;
        Ok(surface)
    }

    /// The recorded name and pin of a reopened tab.
    fn restore_tab_details(
        self: &Arc<Self>,
        actor: &Actor,
        surface: SurfaceId,
        tab: &Value,
    ) -> anyhow::Result<()> {
        if let Some(name) = tab["name"].as_str() {
            self.rename_surface_as(actor, surface, name.to_string());
        }
        if tab["pinned"].as_bool() == Some(true) {
            let selectors = crate::ResourceSelectors {
                tab: Some(self.public_tab_of(surface)?),
                ..Self::ordinary_resource_selectors()
            };
            self.state_pin_tab(StripRequest::local(actor, "tab.pin"), selectors, true)?;
        }
        Ok(())
    }

    pub(super) fn reopen_closed_tab(
        self: &Arc<Self>,
        actor: &Actor,
        record: &Value,
        reopened: &mut Reopened,
    ) -> anyhow::Result<()> {
        let tab = &record["screens"][0]["tabs"][0];
        let closed_pane = record["pane_id"].as_str();
        // The tab's own pane: live, or split off its neighbor again by an
        // earlier reopen, while still in the tab's workspace. With it gone,
        // the neighbor it was split off takes the tab first, then splits
        // again (cx-gzh.32).
        let (home, neighbor) = self.with_state(|state| {
            (
                super::closed_pane_split::home_pane(state, record, &reopened.panes),
                super::closed_pane_split::split_neighbor(state, record, &reopened.panes),
            )
        });
        let fallback = reopened.fallback_pane;
        let pane = self.with_state(|state| {
            home.or(neighbor)
                .or_else(|| {
                    let workspace = record["workspace_id"].as_str()?;
                    let workspace = state
                        .workspaces
                        .iter()
                        .find(|candidate| candidate.public_id.as_str() == workspace)?;
                    workspace.active_screen_ref().map(|screen| screen.active_pane)
                })
                // A link's caller names where new items open (Home: the pane
                // right of Home), checked live: it may have closed since.
                .or_else(|| fallback.filter(|pane| state.panes.contains_key(pane)))
                .or_else(|| state.active_pane())
        });
        // Back in its own pane, the tab is created at its recorded index in
        // one change (one `tab-added` there; cx-d1xb8), not at the end and
        // then moved, which a client animates across the strip. A pinned tab
        // takes the place its pin gives it.
        let index = recorded_index(record)
            .filter(|_| pane.is_some() && pane == home && tab["pinned"].as_bool() != Some(true));
        let surface = match pane {
            Some(pane) => match index {
                Some(index) => tab_strip::tab_slot::scoped(pane, index, || {
                    self.reopen_tab_record(actor, pane, tab, true)
                })?,
                None => self.reopen_tab_record(actor, pane, tab, true)?,
            },
            // No workspace at all: the tab gets a workspace of its own.
            None => {
                let first = self.new_workspace_as(actor, None, None)?.id;
                note_created(first);
                let pane = self
                    .with_state(|state| state.pane_of(first))
                    .context("new workspace has no pane")?;
                self.reopen_tab_record(actor, pane, tab, true)?
            }
        };
        // With its neighbor gone too (two sibling panes of one Close Other Panes), a closed
        // pane still comes back as a pane of its own: split off the pane its first tab landed
        // in, in its workspace, rather than joining that pane's tabs.
        let landed_home = || {
            self.with_state(|state| {
                let landed = state.pane_of(surface)?;
                let (workspace, _) = state.screen_of(landed)?;
                (record["split"].is_object()
                    && record["workspace_id"].as_str()
                        == Some(state.workspaces.get(workspace)?.public_id.as_str()))
                .then_some(landed)
            })
        };
        let split_from = match (home, neighbor) {
            (None, Some(neighbor)) => Some(neighbor),
            (None, None) => landed_home(),
            _ => None,
        };
        let home = match split_from {
            Some(neighbor) => {
                let pane = self.split_closed_pane_again(actor, surface, neighbor, &record["split"]);
                let split = pane.and_then(|pane| {
                    self.with_state(|state| super::closed_pane_split::SplitPane::of(state, pane))
                });
                if let (Some(closed), Some(split)) = (closed_pane, split) {
                    reopened.panes.insert(closed.to_string(), split);
                }
                pane
            }
            None => home,
        };
        self.restore_tab_index(actor, surface, home, record, tab);
        let pane =
            self.with_state(|state| state.pane_of(surface)).context("reopened tab has no pane")?;
        let (workspace, screen) = self.public_screen_of_pane(pane)?;
        reopened.note_workspace(workspace);
        reopened.screens.push(screen);
        // The member names the tab (its record does too since cx-gzh.31).
        reopened.note_tab(record, self.public_tab_of(surface)?);
        Ok(())
    }

    /// Put a tab that reopened in its own pane (`home`) back at its recorded
    /// index (clamped) when its creation did not already place it there. A
    /// creation in `home` takes the scoped index, so this is a no-op (no move,
    /// no event) unless the tab was created elsewhere: split off its neighbor
    /// again (cx-gzh.32), or by a creation path that ignores the scope. Such
    /// a tab is the LAST tab of its pane, so `move_tab`'s insertion index
    /// equals the recorded index (it only subtracts one for an index past
    /// the old position). A pinned tab keeps the place its pin gave it.
    fn restore_tab_index(
        self: &Arc<Self>,
        actor: &Actor,
        surface: SurfaceId,
        home: Option<PaneId>,
        record: &Value,
        tab: &Value,
    ) {
        if tab["pinned"].as_bool() == Some(true) {
            return;
        }
        let Some(index) = recorded_index(record) else {
            return;
        };
        let original =
            home.filter(|pane| self.with_state(|state| state.pane_of(surface)) == Some(*pane));
        if let Some(pane) = original {
            self.move_tab_as(actor, surface, pane, index);
        }
    }

    /// Fill a fresh screen whose first terminal tab `first` already exists.
    /// The first terminal record reuses it (it started in that record's
    /// directory); every other record becomes a new tab, in the splits the
    /// screen had when its record has them, else in order in one pane.
    /// Answers the pane the screen focuses.
    fn fill_screen(
        self: &Arc<Self>,
        actor: &Actor,
        first: SurfaceId,
        screen: &Value,
        reopened: &mut Reopened,
    ) -> anyhow::Result<PaneId> {
        let pane =
            self.with_state(|state| state.pane_of(first)).context("new screen has no pane")?;
        let (workspace, screen_id) = self.public_screen_of_pane(pane)?;
        reopened.note_workspace(workspace);
        reopened.screens.push(screen_id);
        if let Some(name) = screen["name"].as_str()
            && let Some(slot) = self.with_state(|state| {
                state
                    .screen_of(pane)
                    .map(|(workspace, screen)| state.workspaces[workspace].screens[screen].id)
            })
        {
            self.rename_screen_as(actor, slot, name.to_string());
        }
        let tabs = screen["tabs"].as_array().cloned().unwrap_or_default();
        let reused = tabs.iter().position(|tab| tab["kind"] == "terminal");
        if let Some(reused) = reused {
            self.restore_tab_details(actor, first, &tabs[reused])?;
        }
        // A record with its layout comes back in its splits.
        if let Some(shape) = super::closed_screen_layout::Shape::of(screen) {
            let (made, focus) = self.rebuild_screen(actor, first, reused, screen, &shape)?;
            for (tab, surface) in made {
                reopened.note_tab(&tabs[tab], self.public_tab_of(surface)?);
            }
            if reused.is_none() {
                reopened.tabs.push(self.public_tab_of(first)?);
            }
            return Ok(focus.unwrap_or(pane));
        }
        for (index, tab) in tabs.iter().enumerate() {
            let surface = if Some(index) == reused {
                first
            } else {
                self.reopen_tab_record(actor, pane, tab, false)?
            };
            reopened.note_tab(tab, self.public_tab_of(surface)?);
        }
        if reused.is_none() {
            reopened.tabs.push(self.public_tab_of(first)?);
        }
        Ok(pane)
    }

    /// How the first terminal of a reopened screen starts: as its first
    /// terminal record (directory, environment, archived screen), which
    /// `fill_screen` then reuses.
    fn first_terminal_spawn(
        &self,
        screen: &Value,
    ) -> (TerminalSpawnOptions, Option<terminal_archive::SeedGuard<'_>>, Option<(u16, u16)>) {
        match screen["tabs"]
            .as_array()
            .and_then(|tabs| tabs.iter().find(|tab| tab["kind"] == "terminal"))
        {
            Some(tab) => {
                let (spawn, guard, size) = self.reopen_terminal_spawn(tab);
                (spawn, Some(guard), size)
            }
            None => (TerminalSpawnOptions::new(None, Vec::new()), None, None),
        }
    }

    fn reopen_closed_screen(
        self: &Arc<Self>,
        actor: &Actor,
        record: &Value,
        reopened: &mut Reopened,
    ) -> anyhow::Result<()> {
        let screen = &record["screens"][0];
        let workspace = record["workspace_id"].as_str().and_then(|workspace| {
            self.with_state(|state| {
                state
                    .workspaces
                    .iter()
                    .find(|candidate| candidate.public_id.as_str() == workspace)
                    .map(|candidate| candidate.id)
            })
        });
        let (spawn, _seed, size) = self.first_terminal_spawn(screen);
        let first = match workspace {
            Some(workspace) => {
                self.new_screen_named_as(actor, Some(workspace), None, spawn, size)?
            }
            None => self.new_workspace_with_spawn_as(actor, None, spawn, size)?,
        };
        let pane = self.fill_screen(actor, first.id, screen, reopened)?;
        // Back in its workspace, the screen takes its old place.
        let slot = self.with_state(|state| {
            let (workspace, index) = state.screen_of(pane)?;
            Some(state.workspaces[workspace].screens[index].id)
        });
        if workspace.is_some()
            && let (Some(slot), Some(index)) = (slot, recorded_index(record))
            && let Err(error) = self.move_screen_as(
                actor,
                slot,
                ScreenDestination::Workspace { workspace: None, index: Some(index) },
            )
        {
            eprintln!("cmux-tui: a reopened screen could not take its old place: {error:#}");
        }
        Ok(())
    }

    pub(super) fn reopen_closed_workspace(
        self: &Arc<Self>,
        actor: &Actor,
        record: &Value,
        reopened: &mut Reopened,
    ) -> anyhow::Result<()> {
        let screens = record["screens"].as_array().cloned().unwrap_or_default();
        let name = record["name"].as_str().map(str::to_string);
        let (spawn, _seed, size) = screens
            .first()
            .map_or((TerminalSpawnOptions::new(None, Vec::new()), None, None), |screen| {
                self.first_terminal_spawn(screen)
            });
        // A known place (the closed workspace's personal row was kept): created
        // last, so the row `restore_placement` drops in the reopen commit moves
        // no other row, and the closed row's place comes back. No known place:
        // where `workspaces.newPlacement` puts a new workspace (top by default).
        let known = match record["workspace_key"].as_str() {
            Some(closed_key) => {
                self.read_registry_state(|connection| place_kept(connection, closed_key))?
            }
            None => false,
        };
        let create = || self.new_workspace_with_spawn_as(actor, name, spawn, size);
        let first = if known { NewWorkspacePlacement::Bottom.scoped(create)? } else { create()? };
        let (workspace, key) = self
            .with_state(|state| {
                let (index, _) = state.screen_of(state.pane_of(first.id)?)?;
                Some((state.workspaces[index].id, state.workspaces[index].key.clone()))
            })
            .context("reopened workspace is missing")?;
        if let Some(closed_key) = record["workspace_key"].as_str() {
            reopened.placements.push((closed_key.to_string(), key));
        }
        let mut focus = Vec::with_capacity(screens.len());
        for (index, screen) in screens.iter().enumerate() {
            let surface = if index == 0 {
                first.clone()
            } else {
                let (spawn, _seed, size) = self.first_terminal_spawn(screen);
                self.new_screen_named_as(actor, Some(workspace), None, spawn, size)?
            };
            focus.push(self.fill_screen(actor, surface.id, screen, reopened)?);
        }
        // The screen that was shown is shown again, with its focused pane.
        if let Some(pane) = record["active_screen"]
            .as_u64()
            .and_then(|index| usize::try_from(index).ok())
            .and_then(|index| focus.get(index))
        {
            self.focus_pane_as(actor, *pane);
        }
        self.restore_workspace_presentation(actor, workspace, &record["presentation"]);
        if screens.is_empty() {
            let pane = self
                .with_state(|state| state.pane_of(first.id))
                .context("new workspace has no pane")?;
            let (workspace, screen) = self.public_screen_of_pane(pane)?;
            reopened.note_workspace(workspace);
            reopened.screens.push(screen);
            reopened.tabs.push(self.public_tab_of(first.id)?);
        }
        Ok(())
    }
}

impl Mux {
    /// Set the closed workspace's shared color, icon, custom title and pin
    /// (`presentation`, its record's) on the workspace that reopened it.
    /// Its group and sidebar place come back with its personal row.
    fn restore_workspace_presentation(
        &self,
        actor: &Actor,
        workspace: WorkspaceId,
        presentation: &Value,
    ) {
        if !presentation.is_object() {
            return;
        }
        let text = |field: &str| presentation[field].as_str().map(str::to_string);
        let update = crate::workspace_registry::WorkspacePresentationUpdate {
            color: text("color").map(Some),
            icon: text("icon").map(Some),
            title: text("title").map(Some),
            pinned: presentation["pinned"].as_bool().filter(|pinned| *pinned),
            ..Default::default()
        };
        if update == Default::default() {
            return;
        }
        let mutation = WorkspaceMutation::local("cmux-tui-closed-reopen", actor.clone());
        if let Err(error) =
            self.set_workspace_metadata(Some(workspace), None, update, None, None, &mutation)
        {
            eprintln!("cmux-tui: a reopened workspace lost its color, icon or title: {error:#}");
        }
    }
}

/// The strip index a closed tab member recorded in its pane.
fn recorded_index(record: &Value) -> Option<usize> {
    record["index"].as_u64().and_then(|index| usize::try_from(index).ok())
}
