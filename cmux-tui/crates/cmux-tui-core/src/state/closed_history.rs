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
use crate::mux::tab_groups::pane_by_public_id;
use crate::mux::tab_strip::StripRequest;
use crate::mux::*;
use crate::state::closed_history_query::{
    closed_record, keep_members, newest_for_window, remove_closed,
};
use crate::state::commit::{StateEffects, state_not_found};
use crate::state::conversation_tabs::ConversationTabTarget;
use crate::state::conversation_tabs_store::ConversationTabRecord;
use crate::state::prelude::*;
use crate::state::store::{StateChanges, StateCommit, state_delete, state_upsert};
use crate::user_settings::NewWorkspacePlacement;

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
}

impl ReopenRequest {
    /// The idempotency fingerprint. A request that names only `closed`
    /// keeps the v1 fingerprint, so a retry across an upgrade replays.
    fn fingerprint(&self) -> Value {
        let mut fingerprint = serde_json::json!({"operation": OPERATION, "closed": self.closed});
        if let Some(window) = &self.window {
            fingerprint["window"] = serde_json::json!(window);
        }
        if let Some(members) = &self.members {
            fingerprint["members"] = serde_json::json!(members);
        }
        fingerprint
    }
}

/// What a reopen created, in public ids.
#[derive(Default)]
struct Reopened {
    workspaces: Vec<String>,
    screens: Vec<String>,
    tabs: Vec<String>,
    /// (closed workspace key, reopened workspace key) per reopened workspace.
    placements: Vec<(String, String)>,
}

impl Reopened {
    fn note_workspace(&mut self, workspace: String) {
        if !self.workspaces.contains(&workspace) {
            self.workspaces.push(workspace);
        }
    }
}

/// Split `members` into the ones to restore and the ones to keep.
fn choose(
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
static REOPEN: std::sync::Mutex<()> = std::sync::Mutex::new(());

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
    let keep = record["members"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|member| !restored.contains(member))
        .cloned()
        .collect::<Vec<_>>();
    let remaining = keep.len();
    let kind = record["kind"].as_str().unwrap_or_default().to_string();
    // A deleted space (SPACE-DELETE-CLOSES-ITS-WORKSPACES) comes back first,
    // so its reopened workspaces get their pins and groups back.
    let room = record.get("room").filter(|room| room.is_object()).cloned();
    // A deleted personal workspace group (Ungroup, Delete Group) has no
    // member: its reopen forms the group again around its open workspaces.
    let group = record.get("group").filter(|group| group.is_object()).cloned();
    let change = if keep.is_empty() {
        remove_closed(transaction, closed_id)?;
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
            active_workspace.filter(|_| room.is_some() || group.is_some()).map(str::to_string)
        })
        .context("reopened item has no workspace")?;
    let mut changes = vec![change];
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
    Ok(StateChanges::new(
        serde_json::json!({
            "closed_id": closed_id,
            "kind": kind,
            "workspace_id": workspace,
            "workspace_ids": reopened.workspaces,
            "screen_ids": reopened.screens,
            "tab_ids": reopened.tabs,
            "remaining": remaining,
        }),
        changes,
    ))
}

/// Give the reopened workspace the closed one's personal row: its group,
/// its place in the personal sidebar order and its theme
/// (LAST-TAB-CLOSES-WORKSPACE rule 3). Nothing when that row is gone.
fn restore_placement(
    transaction: &rusqlite::Transaction<'_>,
    closed_key: &str,
    reopened_key: &str,
) -> anyhow::Result<Vec<Value>> {
    use crate::state::personal_state_store::{placement_id, placement_snapshot};
    use rusqlite::{OptionalExtension, params};
    let local = crate::state::values::local_registry_id(transaction)?;
    let kept = transaction
        .query_row(
            "SELECT 1 FROM personal_workspaces WHERE session_id = ?1 AND workspace_key = ?2",
            params![local, closed_key],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if !kept {
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
        let closed_id = match &request.closed {
            Some(closed) => closed.clone(),
            None => self
                .read_registry_state(|connection| {
                    newest_for_window(connection, request.window.as_deref())
                })?
                .ok_or_else(|| state_not_found("closed", "newest"))?,
        };
        let record = self
            .read_registry_state(|connection| closed_record(connection, &closed_id))?
            .ok_or_else(|| state_not_found("closed", &closed_id))?;
        let members = record["members"].as_array().cloned().unwrap_or_default();
        let (restore, _) = choose(members, request.members.as_deref())?;
        let mut reopened = Reopened::default();
        for member in &restore {
            self.reopen_member(&mutation.actor, &closed_id, member, &mut reopened)?;
        }
        let active = self.with_state(|state| {
            state
                .workspaces
                .get(state.active_workspace)
                .map(|workspace| workspace.public_id.to_string())
        });
        self.commit_state(
            mutation,
            OPERATION,
            &fingerprint,
            expected_revision,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                commit_reopen(transaction, &closed_id, &restore, &reopened, active.as_deref())
            },
        )
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

    fn public_tab_of(&self, surface: SurfaceId) -> anyhow::Result<String> {
        self.with_state(|state| {
            state.resource_indexes.tab_ids.get(&surface).map(|id| id.to_string())
        })
        .context("reopened tab has no public id")
    }

    fn public_screen_of_pane(&self, pane: PaneId) -> anyhow::Result<(String, String)> {
        self.with_state(|state| {
            let (workspace, screen) = state.screen_of(pane)?;
            let workspace = &state.workspaces[workspace];
            Some((workspace.public_id.to_string(), workspace.screens[screen].public_id.to_string()))
        })
        .context("reopened pane has no screen")
    }

    /// Restore one tab record into `pane`. `reattach` lets a still-running
    /// terminal get a new view instead of a new process.
    fn reopen_tab_record(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        tab: &Value,
        reattach: bool,
    ) -> anyhow::Result<SurfaceId> {
        let surface = match tab["kind"].as_str() {
            Some("browser") if tab.get("conversation").is_some_and(|value| !value.is_null()) => {
                let record = ConversationTabRecord::from_wire(&tab["conversation"])
                    .context("the closed conversation tab has no valid record")?;
                let target = ConversationTabTarget::Pane(Some(pane));
                self.new_conversation_tab_as(actor, target, record, None, None)?.surface.id
            }
            Some("browser") => {
                let url = tab["url"].as_str().unwrap_or("about:blank").to_string();
                match tab["engine"].as_str() {
                    Some(engine) => {
                        self.new_frontend_browser_tab_as(
                            actor,
                            Some(pane),
                            crate::workspace_registry::FrontendBrowserRecord {
                                engine: engine.to_string(),
                                url,
                                title: None,
                                favicon_url: None,
                                profile_id: tab["browser_profile_id"].as_str().map(str::to_string),
                                // The app that shows the reopened tab claims it.
                                owner: None,
                            },
                            None,
                        )?
                        .id
                    }
                    None => self.new_browser_tab_as(actor, url, Some(pane), None)?.id,
                }
            }
            _ => {
                let running = reattach
                    .then(|| tab["terminal_id"].as_str())
                    .flatten()
                    .and_then(|terminal| self.resolve_terminal(terminal).ok().flatten())
                    .filter(|resolution| {
                        resolution.terminal.lifecycle == TerminalLifecycle::Running
                    });
                match running.and_then(|resolution| {
                    self.project_terminal_into_pane(actor, &resolution.terminal.terminal_id, pane)
                        .ok()
                }) {
                    Some(surface) => surface,
                    None => {
                        // ARCHIVE-1: the archived screen and the stopped
                        // program come back above the new shell.
                        let (spawn, _seed) = self.reopen_terminal_spawn(tab);
                        self.new_tab_with_options_as(actor, Some(pane), spawn, None)?.id
                    }
                }
            }
        };
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

    fn reopen_closed_tab(
        self: &Arc<Self>,
        actor: &Actor,
        record: &Value,
        reopened: &mut Reopened,
    ) -> anyhow::Result<()> {
        let tab = &record["screens"][0]["tabs"][0];
        let pane = self.with_state(|state| {
            record["pane_id"]
                .as_str()
                .and_then(|pane| pane_by_public_id(state, pane))
                .or_else(|| {
                    let workspace = record["workspace_id"].as_str()?;
                    let workspace = state
                        .workspaces
                        .iter()
                        .find(|candidate| candidate.public_id.as_str() == workspace)?;
                    workspace.active_screen_ref().map(|screen| screen.active_pane)
                })
                .or_else(|| state.active_pane())
        });
        let surface = match pane {
            Some(pane) => self.reopen_tab_record(actor, pane, tab, true)?,
            // No workspace at all: the tab gets a workspace of its own.
            None => {
                let first = self.new_workspace_as(actor, None, None)?.id;
                let pane = self
                    .with_state(|state| state.pane_of(first))
                    .context("new workspace has no pane")?;
                self.reopen_tab_record(actor, pane, tab, true)?
            }
        };
        self.restore_tab_index(actor, surface, record, tab);
        let pane =
            self.with_state(|state| state.pane_of(surface)).context("reopened tab has no pane")?;
        let (workspace, screen) = self.public_screen_of_pane(pane)?;
        reopened.note_workspace(workspace);
        reopened.screens.push(screen);
        reopened.tabs.push(self.public_tab_of(surface)?);
        Ok(())
    }

    /// Put a tab that reopened in its own pane back at its recorded index
    /// (clamped). A pinned tab keeps the place its pin gave it. A reopened
    /// tab is always the LAST tab of its pane (new tabs and reattached
    /// views append), so `move_tab`'s insertion index equals the recorded
    /// index (it only subtracts one for an index past the old position).
    fn restore_tab_index(
        self: &Arc<Self>,
        actor: &Actor,
        surface: SurfaceId,
        record: &Value,
        tab: &Value,
    ) {
        if tab["pinned"].as_bool() == Some(true) {
            return;
        }
        let Some(index) = record["index"].as_u64().and_then(|index| usize::try_from(index).ok())
        else {
            return;
        };
        let original = self.with_state(|state| {
            let pane =
                record["pane_id"].as_str().and_then(|pane| pane_by_public_id(state, pane))?;
            (state.pane_of(surface) == Some(pane)).then_some(pane)
        });
        if let Some(pane) = original {
            self.move_tab_as(actor, surface, pane, index);
        }
    }

    /// Fill a fresh screen whose first terminal tab `first` already exists.
    /// The first terminal record reuses it (it started in that record's
    /// directory); every other record becomes a new tab in order.
    fn fill_screen(
        self: &Arc<Self>,
        actor: &Actor,
        first: SurfaceId,
        screen: &Value,
        reopened: &mut Reopened,
    ) -> anyhow::Result<()> {
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
        for (index, tab) in tabs.iter().enumerate() {
            let surface = if Some(index) == reused {
                self.restore_tab_details(actor, first, tab)?;
                first
            } else {
                self.reopen_tab_record(actor, pane, tab, false)?
            };
            reopened.tabs.push(self.public_tab_of(surface)?);
        }
        if reused.is_none() {
            reopened.tabs.push(self.public_tab_of(first)?);
        }
        Ok(())
    }

    /// How the first terminal of a reopened screen starts: as its first
    /// terminal record (directory, environment, archived screen), which
    /// `fill_screen` then reuses.
    fn first_terminal_spawn(
        &self,
        screen: &Value,
    ) -> (TerminalSpawnOptions, Option<terminal_archive::SeedGuard<'_>>) {
        match screen["tabs"]
            .as_array()
            .and_then(|tabs| tabs.iter().find(|tab| tab["kind"] == "terminal"))
        {
            Some(tab) => {
                let (spawn, guard) = self.reopen_terminal_spawn(tab);
                (spawn, Some(guard))
            }
            None => (TerminalSpawnOptions::new(None, Vec::new()), None),
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
        let (spawn, _seed) = self.first_terminal_spawn(screen);
        let first = match workspace {
            Some(workspace) => {
                self.new_screen_named_as(actor, Some(workspace), None, spawn, None)?
            }
            None => self.new_workspace_with_spawn_as(actor, None, spawn, None)?,
        };
        self.fill_screen(actor, first.id, screen, reopened)
    }

    fn reopen_closed_workspace(
        self: &Arc<Self>,
        actor: &Actor,
        record: &Value,
        reopened: &mut Reopened,
    ) -> anyhow::Result<()> {
        let screens = record["screens"].as_array().cloned().unwrap_or_default();
        let name = record["name"].as_str().map(str::to_string);
        let (spawn, _seed) =
            screens.first().map_or((TerminalSpawnOptions::new(None, Vec::new()), None), |screen| {
                self.first_terminal_spawn(screen)
            });
        // Created last, so the row `restore_placement` drops in the reopen
        // commit moves no other row; the closed row's place comes back.
        let first = NewWorkspacePlacement::Bottom
            .scoped(|| self.new_workspace_with_spawn_as(actor, name, spawn, None))?;
        let (workspace, key) = self
            .with_state(|state| {
                let (index, _) = state.screen_of(state.pane_of(first.id)?)?;
                Some((state.workspaces[index].id, state.workspaces[index].key.clone()))
            })
            .context("reopened workspace is missing")?;
        if let Some(closed_key) = record["workspace_key"].as_str() {
            reopened.placements.push((closed_key.to_string(), key));
        }
        for (index, screen) in screens.iter().enumerate() {
            let surface = if index == 0 {
                first.clone()
            } else {
                let (spawn, _seed) = self.first_terminal_spawn(screen);
                self.new_screen_named_as(actor, Some(workspace), None, spawn, None)?
            };
            self.fill_screen(actor, surface.id, screen, reopened)?;
        }
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
