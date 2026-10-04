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

use crate::mux::tab_groups::pane_by_public_id;
use crate::mux::tab_strip::StripRequest;
use crate::mux::*;
use crate::state::closed_history_query::{
    closed_record, keep_members, newest_for_window, remove_closed,
};
use crate::state::commit::{StateEffects, state_not_found};
use crate::state::prelude::*;
use crate::state::store::{StateChanges, StateCommit, state_delete, state_upsert};

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
    let change = if keep.is_empty() {
        remove_closed(transaction, closed_id)?;
        state_delete("closed", closed_id)
    } else {
        state_upsert("closed", closed_id, keep_members(transaction, closed_id, record, keep)?)
    };
    let workspace =
        reopened.workspaces.first().cloned().context("reopened item has no workspace")?;
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
        vec![change],
    ))
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
            self.reopen_member(&closed_id, member, &mut reopened)?;
        }
        self.commit_state(
            mutation,
            OPERATION,
            &fingerprint,
            expected_revision,
            StateEffects::EVENTS_ONLY,
            |transaction, _| commit_reopen(transaction, &closed_id, &restore, &reopened),
        )
    }

    fn reopen_member(
        self: &Arc<Self>,
        closed_id: &str,
        member: &Value,
        reopened: &mut Reopened,
    ) -> anyhow::Result<()> {
        match member["kind"].as_str() {
            Some("tab") => self.reopen_closed_tab(member, reopened),
            Some("screen") => self.reopen_closed_screen(member, reopened),
            Some("workspace") => self.reopen_closed_workspace(member, reopened),
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
        pane: PaneId,
        tab: &Value,
        reattach: bool,
    ) -> anyhow::Result<SurfaceId> {
        let surface = match tab["kind"].as_str() {
            Some("browser") => {
                let url = tab["url"].as_str().unwrap_or("about:blank").to_string();
                match tab["engine"].as_str() {
                    Some(engine) => {
                        self.new_frontend_browser_tab(
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
                    None => self.new_browser_tab(url, Some(pane), None)?.id,
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
                    self.project_terminal_into_pane(&resolution.terminal.terminal_id, pane).ok()
                }) {
                    Some(surface) => surface,
                    None => {
                        self.new_tab(Some(pane), tab["cwd"].as_str().map(str::to_string), None)?.id
                    }
                }
            }
        };
        self.restore_tab_details(surface, tab)?;
        Ok(surface)
    }

    /// The recorded name and pin of a reopened tab.
    fn restore_tab_details(
        self: &Arc<Self>,
        surface: SurfaceId,
        tab: &Value,
    ) -> anyhow::Result<()> {
        if let Some(name) = tab["name"].as_str() {
            self.rename_surface(surface, name.to_string());
        }
        if tab["pinned"].as_bool() == Some(true) {
            let selectors = crate::ResourceSelectors {
                tab: Some(self.public_tab_of(surface)?),
                ..Self::ordinary_resource_selectors()
            };
            self.state_pin_tab(StripRequest::local("tab.pin"), selectors, true)?;
        }
        Ok(())
    }

    fn reopen_closed_tab(
        self: &Arc<Self>,
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
            Some(pane) => self.reopen_tab_record(pane, tab, true)?,
            // No workspace at all: the tab gets a workspace of its own.
            None => {
                let first = self.new_workspace(None, None)?.id;
                let pane = self
                    .with_state(|state| state.pane_of(first))
                    .context("new workspace has no pane")?;
                self.reopen_tab_record(pane, tab, true)?
            }
        };
        self.restore_tab_index(surface, record, tab);
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
    fn restore_tab_index(self: &Arc<Self>, surface: SurfaceId, record: &Value, tab: &Value) {
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
            self.move_tab(surface, pane, index);
        }
    }

    /// Fill a fresh screen whose first terminal tab `first` already exists.
    /// The first terminal record reuses it (it started in that record's
    /// directory); every other record becomes a new tab in order.
    fn fill_screen(
        self: &Arc<Self>,
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
            self.rename_screen(slot, name.to_string());
        }
        let tabs = screen["tabs"].as_array().cloned().unwrap_or_default();
        let reused = tabs.iter().position(|tab| tab["kind"] == "terminal");
        for (index, tab) in tabs.iter().enumerate() {
            let surface = if Some(index) == reused {
                self.restore_tab_details(first, tab)?;
                first
            } else {
                self.reopen_tab_record(pane, tab, false)?
            };
            reopened.tabs.push(self.public_tab_of(surface)?);
        }
        if reused.is_none() {
            reopened.tabs.push(self.public_tab_of(first)?);
        }
        Ok(())
    }

    fn first_terminal_cwd(screen: &Value) -> Option<String> {
        screen["tabs"]
            .as_array()?
            .iter()
            .find(|tab| tab["kind"] == "terminal")
            .and_then(|tab| tab["cwd"].as_str())
            .map(str::to_string)
    }

    fn reopen_closed_screen(
        self: &Arc<Self>,
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
        let first = match workspace {
            Some(workspace) => {
                self.new_screen_with_cwd(Some(workspace), Self::first_terminal_cwd(screen), None)?
            }
            None => self.new_workspace(None, None)?,
        };
        self.fill_screen(first.id, screen, reopened)
    }

    fn reopen_closed_workspace(
        self: &Arc<Self>,
        record: &Value,
        reopened: &mut Reopened,
    ) -> anyhow::Result<()> {
        let screens = record["screens"].as_array().cloned().unwrap_or_default();
        let name = record["name"].as_str().map(str::to_string);
        let first = self.new_workspace(name, None)?;
        let workspace = self
            .with_state(|state| state.pane_of(first.id).and_then(|pane| state.screen_of(pane)))
            .map(|(workspace, _)| self.with_state(|state| state.workspaces[workspace].id))
            .context("reopened workspace is missing")?;
        for (index, screen) in screens.iter().enumerate() {
            let surface = if index == 0 {
                first.clone()
            } else {
                self.new_screen_with_cwd(Some(workspace), Self::first_terminal_cwd(screen), None)?
            };
            self.fill_screen(surface.id, screen, reopened)?;
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
