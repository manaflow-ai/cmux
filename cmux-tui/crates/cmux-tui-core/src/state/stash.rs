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
//! - Only http(s) web pages are stashed, never app tabs, except by
//!   `stash.create {workspaces}` (`stash-workspaces-v1`,
//!   [`super::stash_workspaces`]): whole workspaces, terminals included,
//!   one `kind: "workspace"` member each, reopened as their own workspaces.
//! - `stash.import {source, groups, engine?}` stores OneTab groups; only
//!   http(s) pages are kept. Pages without an engine reopen as
//!   daemon-rendered browsers, so the app passes its engine.

use std::collections::{HashMap, HashSet};

use rusqlite::OptionalExtension;
use serde_json::json;
use sha2::{Digest, Sha256};

use crate::Actor;
use crate::mux::tab_groups::pane_by_public_id;
use crate::mux::*;
use crate::panic_free::JsonFields;
use crate::state::closed_history::{REOPEN, Reopened, note_created, recording_created};
use crate::state::closed_history_store::{member_tab, queue_change};
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
    /// Whole workspaces (`stash-workspaces-v1`), and the stash's name.
    Workspaces {
        workspaces: Vec<String>,
        name: Option<String>,
    },
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
    #[track_caller]
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
            StashSource::Workspaces { workspaces, name } => {
                return self.state_stash_workspaces(mutation, workspaces, name.as_deref());
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
        // Home's pinned page (`pinned-dock-v1`): a Workspace-form stash skips
        // it as it skips pinned tabs; a Tabs-form stash that names it is
        // refused by the close.
        let dock_pinned = self.with_state(|state| {
            pinned_dock_tabs(state)
                .iter()
                .filter_map(|surface| state.resource_indexes.tab_ids.get(surface))
                .map(ToString::to_string)
                .collect::<HashSet<_>>()
        });
        let (tabs, skipped, name) = self.read_registry_state(|connection| {
            let (candidates, workspace) = match source {
                StashSource::Tabs(tabs) => (tabs.clone(), None),
                StashSource::Workspaces { .. } => {
                    anyhow::bail!("bad request: whole workspaces stash on their own path")
                }
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
                    Ok(member)
                        if workspace_form(source)
                            && (member_pinned(&member) || dock_pinned.contains(&tab)) =>
                    {
                        skipped.push(tab);
                    }
                    Ok(member) => {
                        if first_workspace.is_none() {
                            first_workspace =
                                member.field("workspace_id").as_str().map(str::to_string);
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
        // The stashed tabs close as a tab close does: the pinned tab stays.
        let outcome = self.close_tabs_for_room_delete(
            surfaces,
            OPERATION,
            crate::resource::ResourceOperation::TabClose,
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

    #[track_caller]
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
            record.field("members").as_array().cloned().unwrap_or_default(),
            members,
        )?;
        if let Some(pane) = pane
            && self.with_state(|state| pane_by_public_id(state, pane)).is_none()
        {
            return Err(state_not_found("pane", pane));
        }
        let restored_ids = restore.iter().map(|member| member["id"].clone()).collect::<Vec<_>>();
        let mut reopened = Reopened::default();
        // All or nothing: when a member cannot reopen, or the commit fails,
        // every surface this call created closes again and every member
        // stays. Surfaces are recorded as they are created, so one a later
        // step of its reopen failed on closes too.
        // Whole workspaces (`stash-workspaces-v1`) reopen as their own
        // workspaces for either target; the pages follow the target.
        let pages = restore
            .iter()
            .filter(|member| !super::stash_workspaces::is_workspace(member))
            .cloned()
            .collect::<Vec<_>>();
        let (committed, created) = recording_created(|| {
            self.restore_stashed_workspaces(&mutation.actor, &record, &restore, &mut reopened)
                .and_then(|()| match target {
                    RestoreTarget::Here => pages.iter().try_for_each(|member| {
                        self.restore_member_here(&mutation.actor, member, pane, &mut reopened)
                    }),
                    RestoreTarget::NewWorkspace if pages.is_empty() && !restore.is_empty() => {
                        Ok(())
                    }
                    RestoreTarget::NewWorkspace => {
                        self.restore_in_new_workspace(mutation, &record, &pages, &mut reopened)
                    }
                })
                .and_then(|()| {
                    self.commit_restore(
                        mutation,
                        OPERATION,
                        &fingerprint,
                        stash_id,
                        &restored_ids,
                        reopened,
                    )
                })
        });
        if committed.is_err() {
            self.roll_back_restore(mutation, &created);
        }
        committed
    }

    /// The commit of a restore: `restored_ids` leave the stash, and each
    /// reopened whole workspace takes its stashed row (group, sidebar place,
    /// theme) and its agent-home folder.
    #[track_caller]
    fn commit_restore(
        &self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        stash_id: &str,
        restored_ids: &[Value],
        reopened: Reopened,
    ) -> anyhow::Result<StateCommit> {
        let placements = reopened.placements.clone();
        let commit = self.commit_state(
            mutation,
            operation,
            fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                let record = store::stash_record(transaction, stash_id)?
                    .ok_or_else(|| state_not_found("stash", stash_id))?;
                let keep = record
                    .field("members")
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|member| !restored_ids.contains(&member["id"]))
                    .cloned()
                    .collect::<Vec<_>>();
                let (change, remaining) =
                    store::keep_stash_members(transaction, stash_id, record, keep)?;
                let mut changes = vec![change];
                for (stashed_key, reopened_key) in &placements {
                    changes.extend(super::closed_history::restore_placement(
                        transaction,
                        stashed_key,
                        reopened_key,
                    )?);
                }
                Ok(StateChanges::new(
                    json!({
                        "stash_id": stash_id,
                        "workspace_id": reopened.workspaces.first(),
                        "workspace_ids": reopened.workspaces,
                        "screen_ids": reopened.screens,
                        "tab_ids": reopened.tabs,
                        "remaining": remaining,
                    }),
                    changes,
                ))
            },
        )?;
        if !commit.replayed {
            super::agent_home_moves::follow_reopen(&placements);
        }
        Ok(commit)
    }

    /// Close what a failed restore created (`created`, the ones still open)
    /// as a session end, never recorded in Recently Closed, under a key of
    /// its own. A surface another client closes meanwhile is left out of a
    /// second try; a close that still fails is logged, and the restore's own
    /// error is what the caller sees.
    #[track_caller]
    fn roll_back_restore(self: &Arc<Self>, mutation: &WorkspaceMutation, created: &[SurfaceId]) {
        let mut last_error = None;
        for _ in 0..2 {
            let open = self.with_state(|state| {
                created
                    .iter()
                    .copied()
                    .filter(|surface| state.pane_of(*surface).is_some())
                    .collect::<Vec<_>>()
            });
            if open.is_empty() {
                return;
            }
            let closed = WorkspaceMutation::new(
                format!("stash-restore-rollback-{}", crate::workspace_registry::new_uuid_v4()),
                mutation.origin.clone(),
                mutation.actor.clone(),
            )
            .and_then(|close| {
                self.close_tabs_for(open, true, Some(CloseReason::SessionEnd), &close)
            });
            match closed {
                Ok(_) => return,
                Err(error) => last_error = Some(error),
            }
        }
        if let Some(error) = last_error {
            eprintln!(
                "cmux-tui: stash.restore could not close the pages of a failed restore: {error:#}"
            );
        }
    }

    /// Restore one member `here`. With no pane named, as closed history
    /// reopens a tab. With `pane` (the one the user acted from): back in its
    /// own pane while that is still in its workspace and screen, else at the
    /// end of `pane`, and nowhere else. When both are gone by the time the
    /// member reopens, it is refused (`resource.not_found`) and stays in the
    /// stash; it never opens in the active pane instead.
    #[track_caller]
    pub(super) fn restore_member_here(
        self: &Arc<Self>,
        actor: &Actor,
        member: &Value,
        pane: Option<&str>,
        reopened: &mut Reopened,
    ) -> anyhow::Result<()> {
        let Some(pane) = pane else { return self.reopen_closed_tab(actor, member, reopened) };
        let tab = member_tab(member);
        let (target, own) = self
            .with_state(|state| {
                super::closed_pane_split::home_pane(state, member, &HashMap::new())
                    .map(|own| (own, true))
                    .or_else(|| pane_by_public_id(state, pane).map(|named| (named, false)))
            })
            .ok_or_else(|| state_not_found("pane", pane))?;
        // Back in its own pane, at its recorded index (a pinned tab takes
        // the place its pin gives it); in the named pane, at the end.
        let index = member["index"]
            .as_u64()
            .and_then(|index| usize::try_from(index).ok())
            .filter(|_| own && tab["pinned"].as_bool() != Some(true));
        let created = match index {
            Some(index) => tab_strip::tab_slot::scoped(target, index, || {
                self.reopen_tab_record(actor, target, tab, true)
            }),
            None => self.reopen_tab_record(actor, target, tab, true),
        };
        // An explicit pane that closed meanwhile fails the creation.
        let surface = created.map_err(|error| {
            if self.with_state(|state| state.panes.contains_key(&target)) {
                error
            } else {
                state_not_found("pane", pane)
            }
        })?;
        let (workspace, screen) = self.public_screen_of_pane(target)?;
        reopened.note_workspace(workspace);
        reopened.screens.push(screen);
        reopened.note_tab(member, self.public_tab_of(surface)?);
        Ok(())
    }

    /// One new workspace named after the stash holding `restore` in order.
    /// It starts with a shell (every new workspace does), which closes once
    /// the pages are in, unrecorded (`session_end`). The shell is recorded
    /// as created, so a failed restore closes it with the pages.
    #[track_caller]
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
        note_created(starter);
        let pane =
            self.with_state(|state| state.pane_of(starter)).context("new workspace has no pane")?;
        let (workspace, screen) = self.public_screen_of_pane(pane)?;
        reopened.note_workspace(workspace);
        reopened.screens.push(screen);
        for member in restore {
            let surface = self.reopen_tab_record(actor, pane, member_tab(member), false)?;
            reopened.tabs.push(self.public_tab_of(surface)?);
        }
        if !restore.is_empty() {
            // A key of its own for each attempt: a retry after a failed one
            // closes its own starter, never conflicting with the first's
            // receipt, and a replay of the restore never gets here.
            let starter_close = WorkspaceMutation::new(
                format!("stash-starter-{}", crate::workspace_registry::new_uuid_v4()),
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

    #[track_caller]
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
        // Workspace keys of the deleted whole workspaces: their agent-home
        // folders go, as a deleted closed workspace's do.
        let keys = std::sync::Mutex::new(Vec::new());
        let commit = self.commit_state(
            mutation,
            OPERATION,
            &fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                let record = store::stash_record(transaction, stash_id)?
                    .ok_or_else(|| state_not_found("stash", stash_id))?;
                let all = record.field("members").as_array().cloned().unwrap_or_default();
                let (removed, keep) = store::choose_members(all, members)?;
                *keys.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
                    super::agent_home_moves::member_keys(&removed);
                let (change, remaining) =
                    store::keep_stash_members(transaction, stash_id, record, keep)?;
                Ok(StateChanges::new(
                    json!({"stash_id": stash_id, "remaining": remaining}),
                    vec![change],
                ))
            },
        )?;
        let keys = keys.into_inner().unwrap_or_else(std::sync::PoisonError::into_inner);
        if !commit.replayed && !keys.is_empty() {
            let live = |key: &str| {
                self.with_state(|state| {
                    state.workspaces.iter().any(|workspace| workspace.key == key)
                })
            };
            super::agent_home_moves::retire(&keys, &live);
        }
        Ok(commit)
    }

    #[track_caller]
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
    member_tab(member).field("pinned").as_bool() == Some(true)
}
