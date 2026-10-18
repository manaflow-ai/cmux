//! Stash (`stash-v1`, bead cx-rws36): a native OneTab. Storage and the
//! public shape live in [`super::stash_store`].
//!
//! - `stash.create {tabs}` closes those browser tabs as one stash; any tab
//!   that is not a web page (terminal, conversation, remote terminal) or is
//!   incognito refuses the whole request. `stash.create {workspace}` stashes
//!   the workspace's unpinned web pages and reports the other tabs as
//!   `skipped` (they stay open). The close is one batch close commit whose
//!   group goes to the stash instead of the closed history; a workspace it
//!   empties closes as any last-tab close does.
//! - Members are named by their stable `id` (from `stash.list`); an id the
//!   stash no longer holds is `resource.not_found` and nothing changes.
//! - `stash.restore {stash, members?, target?, pane?}` reopens members like
//!   Reopen Closed (`here`, the default: their pane at their index when it
//!   is live, else `pane` (the pane the user acted from), else their
//!   workspace's focused pane, else the session's), or all in one new
//!   workspace named after the stash (`new_workspace`). Restored members
//!   leave the stash in the commit that stores the result.
//! - `stash.delete {stash, members?}` drops members or the whole stash.
//! - Only http(s) web pages are stashed, never app tabs.
//! - `stash.import {source, groups, engine?}` stores OneTab groups; only
//!   http(s) pages are kept. Pages without an engine reopen as
//!   daemon-rendered browsers, so the app passes its engine.

use std::collections::HashSet;

use rusqlite::OptionalExtension;
use serde_json::json;
use sha2::{Digest, Sha256};

use crate::Actor;
use crate::mux::tab_groups::pane_by_public_id;
use crate::mux::*;
use crate::state::closed_history::{REOPEN, Reopened};
use crate::state::closed_history_store::queue_change;
use crate::state::commit::{StateEffects, state_not_found};
use crate::state::prelude::*;
use crate::state::stash_store::{self as store, Refusal};
use crate::state::store::{StateChanges, StateCommit};

/// Where `stash.restore` puts the pages.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum RestoreTarget {
    Here,
    NewWorkspace,
}

impl RestoreTarget {
    pub(crate) fn parse(value: Option<&str>) -> Self {
        if value == Some("new_workspace") { Self::NewWorkspace } else { Self::Here }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Here => "here",
            Self::NewWorkspace => "new_workspace",
        }
    }
}

/// What `stash.create` names.
pub(crate) enum StashSource {
    Tabs(Vec<String>),
    Workspace(String),
}

/// One OneTab group of `stash.import`.
pub(crate) struct ImportGroup {
    pub(crate) name: Option<String>,
    pub(crate) created_ms: Option<u64>,
    /// (url, title)
    pub(crate) tabs: Vec<(String, Option<String>)>,
}

fn refusal(tab: &str, why: &Refusal) -> anyhow::Error {
    match why {
        Refusal::Private => anyhow::anyhow!(
            "bad request: tab {tab} cannot be stashed: it is incognito or no longer open"
        ),
        Refusal::NotPage => {
            anyhow::anyhow!("bad request: tab {tab} cannot be stashed: only web pages can")
        }
    }
}

impl Mux {
    pub(crate) fn state_stash_create(
        self: &Arc<Self>,
        mutation: &WorkspaceMutation,
        source: &StashSource,
    ) -> anyhow::Result<StateCommit> {
        const OPERATION: &str = "stash.create";
        let fingerprint = match source {
            StashSource::Tabs(tabs) => json!({"operation": OPERATION, "tabs": tabs}),
            StashSource::Workspace(workspace) => {
                json!({"operation": OPERATION, "workspace": workspace})
            }
        };
        if let Some(replay) = self
            .workspace_registry
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .replay_resource_patch(mutation, OPERATION, &fingerprint)?
        {
            return Ok(replay.into());
        }
        let (tabs, skipped, name) = self.read_registry_state(|connection| {
            let (candidates, workspace) = match source {
                StashSource::Tabs(tabs) => (tabs.clone(), None),
                StashSource::Workspace(workspace) => {
                    let live = connection
                        .query_row(
                            "SELECT 1 FROM resource_workspaces
                             WHERE public_id = ?1 AND deleted_revision IS NULL",
                            [workspace],
                            |_| Ok(()),
                        )
                        .optional()?;
                    if live.is_none() {
                        return Err(state_not_found("workspace", workspace));
                    }
                    if super::closed_history_store::is_ephemeral(connection, workspace)? {
                        anyhow::bail!("bad request: an incognito workspace cannot be stashed");
                    }
                    (store::workspace_tabs(connection, workspace)?, Some(workspace.clone()))
                }
            };
            let mut pages = Vec::new();
            let mut skipped = Vec::new();
            let mut first_workspace = workspace;
            // Each tab once, in the order named.
            let mut seen = HashSet::new();
            let candidates = candidates.into_iter().filter(|tab| seen.insert(tab.clone()));
            for tab in candidates {
                match store::stash_member(connection, &tab)? {
                    Ok(member) if workspace_form(source) && member_pinned(&member) => {
                        skipped.push(tab);
                    }
                    Ok(member) => {
                        if first_workspace.is_none() {
                            first_workspace = member["workspace_id"].as_str().map(str::to_string);
                        }
                        pages.push((tab, member));
                    }
                    Err(_) if workspace_form(source) => skipped.push(tab),
                    Err(why) => return Err(refusal(&tab, &why)),
                }
            }
            // Restore order: ascending position per pane (as closed history
            // records a close), so each tab goes back to its own index after
            // the lower ones are in place.
            pages.sort_by(|(_, left), (_, right)| {
                (left["pane_id"].as_str(), left["index"].as_i64())
                    .cmp(&(right["pane_id"].as_str(), right["index"].as_i64()))
            });
            let tabs = pages.into_iter().map(|(tab, _)| tab).collect::<Vec<_>>();
            let name = match &first_workspace {
                Some(workspace) => store::workspace_name(connection, workspace)?,
                None => None,
            };
            Ok((tabs, skipped, name))
        })?;
        anyhow::ensure!(!tabs.is_empty(), "bad request: no web page to stash");
        let surfaces = self.with_state(|state| {
            tabs.iter()
                .map(|tab| {
                    state
                        .resource_indexes
                        .tab_ids
                        .iter()
                        .find_map(|(surface, id)| (id.as_str() == tab.as_str()).then_some(*surface))
                        .ok_or_else(|| state_not_found("tab", tab))
                })
                .collect::<anyhow::Result<Vec<_>>>()
        })?;
        let stash_id = store::new_stash_id();
        let result = json!({"stash_id": stash_id, "tab_ids": tabs, "skipped": skipped});
        // Inside the close's transaction, before its rows are tombstoned:
        // the members are read from the live rows, the stash is stored, and
        // the closed history is told to record nothing for this close.
        let before_patch = |transaction: &rusqlite::Transaction<'_>| -> anyhow::Result<()> {
            let mut members = Vec::with_capacity(tabs.len());
            for tab in &tabs {
                members.push(
                    store::stash_member(transaction, tab)?.map_err(|why| refusal(tab, &why))?,
                );
            }
            let change =
                store::insert_stash(transaction, &stash_id, name.as_deref(), None, members)?;
            queue_change(transaction, &change)?;
            store::mark_capture(transaction, &tabs)
        };
        // The space-delete close carries a write before its patch; a stash
        // uses it for its own group (no space is involved).
        let outcome = self.close_tabs_for_room_delete(
            surfaces,
            OPERATION,
            &fingerprint,
            mutation,
            RoomClose { before_patch: &before_patch, result, bare: Vec::new() },
        )?;
        Ok(StateCommit {
            revision: outcome.resource_revision,
            result: outcome.result,
            replayed: outcome.replayed,
            personal_revision: None,
        })
    }

    pub(crate) fn state_stash_restore(
        self: &Arc<Self>,
        mutation: &WorkspaceMutation,
        stash_id: &str,
        members: Option<&[String]>,
        target: RestoreTarget,
        pane: Option<&str>,
    ) -> anyhow::Result<StateCommit> {
        const OPERATION: &str = "stash.restore";
        let _serial = REOPEN.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let fingerprint = json!({
            "operation": OPERATION, "stash": stash_id, "members": members,
            "target": target.as_str(), "pane": pane,
        });
        if let Some(replay) = self
            .workspace_registry
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .replay_resource_patch(mutation, OPERATION, &fingerprint)?
        {
            return Ok(replay.into());
        }
        let record = self
            .read_registry_state(|connection| store::stash_record(connection, stash_id))?
            .ok_or_else(|| state_not_found("stash", stash_id))?;
        let (restore, _) = store::choose_members(
            record["members"].as_array().cloned().unwrap_or_default(),
            members,
        )?;
        if let Some(pane) = pane
            && self.with_state(|state| pane_by_public_id(state, pane)).is_none()
        {
            return Err(state_not_found("pane", pane));
        }
        let restored_ids = restore.iter().map(|member| member["id"].clone()).collect::<Vec<_>>();
        let mut reopened = Reopened::default();
        match target {
            RestoreTarget::Here => {
                for member in &restore {
                    self.restore_member_here(&mutation.actor, member, pane, &mut reopened)?;
                }
            }
            RestoreTarget::NewWorkspace => {
                self.restore_in_new_workspace(mutation, &record, &restore, &mut reopened)?;
            }
        }
        self.commit_state(
            mutation,
            OPERATION,
            &fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                let record = store::stash_record(transaction, stash_id)?
                    .ok_or_else(|| state_not_found("stash", stash_id))?;
                let keep = record["members"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|member| !restored_ids.contains(&member["id"]))
                    .cloned()
                    .collect::<Vec<_>>();
                let (change, remaining) =
                    store::keep_stash_members(transaction, stash_id, record, keep)?;
                Ok(StateChanges::new(
                    json!({
                        "stash_id": stash_id,
                        "workspace_id": reopened.workspaces.first(),
                        "workspace_ids": reopened.workspaces,
                        "screen_ids": reopened.screens,
                        "tab_ids": reopened.tabs,
                        "remaining": remaining,
                    }),
                    vec![change],
                ))
            },
        )
    }

    /// Restore one member `here`: in its own pane while that is live, else
    /// in `pane` (at its end) when the user acted from one.
    pub(super) fn restore_member_here(
        self: &Arc<Self>,
        actor: &Actor,
        member: &Value,
        pane: Option<&str>,
        reopened: &mut Reopened,
    ) -> anyhow::Result<()> {
        let member = self.placed_in(member, pane);
        self.reopen_closed_tab(actor, &member, reopened)
    }

    /// `member` as `here` restores it: in its own pane while that is live,
    /// else in `pane` (at its end) when the user acted from one.
    fn placed_in(&self, member: &Value, pane: Option<&str>) -> Value {
        let Some(pane) = pane else { return member.clone() };
        let own_pane_live = self.with_state(|state| {
            member["pane_id"].as_str().and_then(|own| pane_by_public_id(state, own)).is_some()
        });
        if own_pane_live {
            return member.clone();
        }
        // A reopen takes a member's pane only while it sits in the member's
        // workspace and screen, so the member names the target pane's.
        let place = self.with_state(|state| {
            let (workspace, screen) = state.screen_of(pane_by_public_id(state, pane)?)?;
            let workspace = &state.workspaces[workspace];
            Some((workspace.public_id.to_string(), workspace.screens[screen].public_id.to_string()))
        });
        let mut placed = member.clone();
        placed["pane_id"] = json!(pane);
        placed["workspace_id"] = json!(place.as_ref().map(|(workspace, _)| workspace));
        placed["screen_id"] = json!(place.as_ref().map(|(_, screen)| screen));
        placed["index"] = Value::Null;
        if let Some(object) = placed.as_object_mut() {
            object.remove("split");
        }
        placed
    }

    /// One new workspace named after the stash holding `restore` in order.
    /// It starts with a shell (every new workspace does), which closes once
    /// the pages are in, unrecorded (`session_end`).
    ///
    /// Known limitation: the starter close commits under a key derived from
    /// the request's, before the restore's own commit. A retry after a
    /// failure between the two creates another workspace whose starter close
    /// conflicts with the first one's receipt.
    fn restore_in_new_workspace(
        self: &Arc<Self>,
        mutation: &WorkspaceMutation,
        record: &Value,
        restore: &[Value],
        reopened: &mut Reopened,
    ) -> anyhow::Result<()> {
        let actor = &mutation.actor;
        let name = record["name"].as_str().map(str::to_string);
        let starter = self.new_workspace_as(actor, name, None)?.id;
        let pane =
            self.with_state(|state| state.pane_of(starter)).context("new workspace has no pane")?;
        let (workspace, screen) = self.public_screen_of_pane(pane)?;
        reopened.note_workspace(workspace);
        reopened.screens.push(screen);
        for member in restore {
            let surface =
                self.reopen_tab_record(actor, pane, &member["screens"][0]["tabs"][0], false)?;
            reopened.tabs.push(self.public_tab_of(surface)?);
        }
        if !restore.is_empty() {
            // A key of its own, derived from the request's, so the close
            // never collides with the restore's receipt.
            let derived = Sha256::digest(format!("stash.restore.starter\u{0}{}", mutation.id));
            let starter_close = WorkspaceMutation::new(
                format!("stash-starter-{derived:x}"),
                mutation.origin.clone(),
                mutation.actor.clone(),
            )?;
            self.close_tabs_for(
                vec![starter],
                true,
                Some(CloseReason::SessionEnd),
                &starter_close,
            )?;
        }
        Ok(())
    }

    pub(crate) fn state_stash_delete(
        &self,
        mutation: &WorkspaceMutation,
        stash_id: &str,
        members: Option<&[String]>,
    ) -> anyhow::Result<StateCommit> {
        const OPERATION: &str = "stash.delete";
        // Never while a restore of the same stash is between its read and
        // its commit.
        let _serial = REOPEN.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let fingerprint = json!({"operation": OPERATION, "stash": stash_id, "members": members});
        self.commit_state(
            mutation,
            OPERATION,
            &fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                let record = store::stash_record(transaction, stash_id)?
                    .ok_or_else(|| state_not_found("stash", stash_id))?;
                let all = record["members"].as_array().cloned().unwrap_or_default();
                let (_, keep) = store::choose_members(all, members)?;
                let (change, remaining) =
                    store::keep_stash_members(transaction, stash_id, record, keep)?;
                Ok(StateChanges::new(
                    json!({"stash_id": stash_id, "remaining": remaining}),
                    vec![change],
                ))
            },
        )
    }

    pub(crate) fn state_stash_import(
        &self,
        mutation: &WorkspaceMutation,
        source: &str,
        engine: Option<&str>,
        groups: &[ImportGroup],
    ) -> anyhow::Result<StateCommit> {
        const OPERATION: &str = "stash.import";
        let mut hasher = Sha256::new();
        for group in groups {
            let parts = [group.name.clone().unwrap_or_default(), format!("{:?}", group.created_ms)];
            for part in parts.iter().map(String::as_str).chain(
                group
                    .tabs
                    .iter()
                    .flat_map(|(url, title)| [url.as_str(), title.as_deref().unwrap_or("")]),
            ) {
                hasher.update(part.len().to_le_bytes());
                hasher.update(part.as_bytes());
            }
            hasher.update(b"\x00group");
        }
        let fingerprint = json!({
            "operation": OPERATION, "source": source, "engine": engine,
            "groups": format!("{:x}", hasher.finalize()),
        });
        // A group's own time, never later than now (a future or
        // out-of-range time is now).
        let now = crate::workspace_registry::unix_epoch_ms()?;
        self.commit_state(
            mutation,
            OPERATION,
            &fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                let mut ids = Vec::new();
                let mut changes = Vec::new();
                let mut skipped = 0_usize;
                let mut imported = 0_usize;
                for group in groups {
                    let mut seen = HashSet::new();
                    let members = group
                        .tabs
                        .iter()
                        // Only web pages, each once per group (members
                        // are told apart by value).
                        .filter(|(url, _)| {
                            let keep = store::is_web_url(url) && seen.insert(url.clone());
                            if !keep {
                                skipped += 1;
                            }
                            keep
                        })
                        .map(|(url, title)| store::imported_member(url, title.as_deref(), engine))
                        .collect::<Vec<_>>();
                    if members.is_empty() {
                        continue;
                    }
                    imported += members.len();
                    let id = store::new_stash_id();
                    changes.push(store::insert_stash(
                        transaction,
                        &id,
                        group.name.as_deref(),
                        Some(group.created_ms.map_or(now, |created| created.min(now))),
                        members,
                    )?);
                    ids.push(id);
                }
                Ok(StateChanges::new(
                    json!({"stash_ids": ids, "imported_tabs": imported, "skipped_tabs": skipped}),
                    changes,
                ))
            },
        )
    }
}

fn workspace_form(source: &StashSource) -> bool {
    matches!(source, StashSource::Workspace(_))
}

fn member_pinned(member: &Value) -> bool {
    member["screens"][0]["tabs"][0]["pinned"].as_bool() == Some(true)
}
