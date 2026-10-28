//! Part of `Hub`; see `hub/mod.rs`. How many of a session's sub-sessions run a turn at once
//! (Leo 2026-10-21: "increase or decrease subagent amounts ad hoc ... even per workspace").
//!
//! - A family prompt (`subsessions::PROVENANCE_KIND`: a start's first prompt, a `send_message`)
//!   starts a sub-session's turn only while its parent has a free run slot: fewer than the
//!   parent's `maxRunning` children hold one. Otherwise it waits in the child's own durable
//!   queue (`queue.rs`), so it survives a restart, and starts when a slot frees, a limit
//!   changes or the settings file changes. The person's own prompts and a chat started from a
//!   suggested task (`offered`) never wait for a slot and hold none.
//! - A slot is taken together with the turn lock, under this index's lock, so concurrent
//!   starts never pass the limit, and is held until the turn lock is released (the turn ended,
//!   or it never started).
//! - Lowering the limit stops nothing: running turns keep their slots and new ones wait.
//!   Raising it starts waiting ones at once.
//! - `maxRunning` resolves like the other limits (`Hub::subsession_effective`): the session's
//!   own override, an ancestor's, its workspace's (the person's, kept in
//!   [`WORKSPACES_FILE`] in the acpmux home), the settings (`agents.subsessions.maxRunning`),
//!   the catalog default.
//!
//! The index is a leaf lock, like the open-children index (`subsessions.rs`).

use super::*;
use std::collections::{BTreeMap, BTreeSet};

/// The workspaces' `maxRunning`, by cmux workspace id, in the acpmux home.
pub const WORKSPACES_FILE: &str = "subsession-workspaces.json";

/// Which children hold a run slot or wait for one, per parent; the workspace limits; and the
/// signal a waiting turn looks again on.
#[derive(Default)]
pub struct Runs {
    state: StdMutex<RunState>,
    /// Fired when a slot frees or a limit may have changed.
    changed: Notify,
    /// Loaded from [`WORKSPACES_FILE`] at first use.
    workspaces: StdMutex<Option<BTreeMap<String, u32>>>,
}

#[derive(Default)]
struct RunState {
    running: HashMap<String, BTreeSet<String>>,
    /// Each child counted once per wait in progress (a turn and a queued start may both wait).
    waiting: HashMap<String, HashMap<String, u32>>,
}

impl Runs {
    fn lock(&self) -> std::sync::MutexGuard<'_, RunState> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Children of `parent` holding a run slot now.
    pub fn running(&self, parent: &str) -> u32 {
        self.lock().running.get(parent).map_or(0, |s| s.len() as u32)
    }

    /// Children of `parent` waiting for a run slot now.
    pub fn waiting(&self, parent: &str) -> u32 {
        self.lock().waiting.get(parent).map_or(0, |s| s.len() as u32)
    }

    /// Whether `child` of `parent` waits for a run slot now.
    pub fn waits(&self, parent: &str, child: &str) -> bool {
        self.lock().waiting.get(parent).is_some_and(|s| s.contains_key(child))
    }

    /// Wakes every turn waiting for a slot, to look again.
    pub fn wake(&self) {
        self.changed.notify_waiters();
    }

    /// Takes a slot of `parent` for `child` under `max`; false when all are taken.
    fn take(&self, parent: &str, child: &str, max: u32) -> bool {
        let mut s = self.lock();
        let set = s.running.entry(parent.to_owned()).or_default();
        // A turn holds one slot; a second turn of the same child cannot run meanwhile (the turn
        // lock), so a held slot is never counted twice.
        if !set.contains(child) && set.len() as u32 >= max {
            if set.is_empty() {
                s.running.remove(parent);
            }
            return false;
        }
        set.insert(child.to_owned());
        true
    }

    fn release(&self, parent: &str, child: &str) {
        {
            let mut s = self.lock();
            if let Some(set) = s.running.get_mut(parent) {
                set.remove(child);
                if set.is_empty() {
                    s.running.remove(parent);
                }
            }
        }
        self.wake();
    }

    fn mark(&self, parent: &str, child: &str) {
        *self
            .lock()
            .waiting
            .entry(parent.to_owned())
            .or_default()
            .entry(child.to_owned())
            .or_default() += 1;
    }

    fn unmark(&self, parent: &str, child: &str) {
        let mut s = self.lock();
        if let Some(map) = s.waiting.get_mut(parent) {
            if let Some(n) = map.get_mut(child) {
                *n = n.saturating_sub(1);
                if *n == 0 {
                    map.remove(child);
                }
            }
            if map.is_empty() {
                s.waiting.remove(parent);
            }
        }
    }

    /// The workspace's own `maxRunning`, if the person set one.
    pub fn workspace_limit(&self, workspace: &str) -> Option<u32> {
        let mut w = self.workspaces.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        w.get_or_insert_with(load_workspaces).get(workspace).copied()
    }

    /// Sets (`Some`) or clears (`None`) the workspace's `maxRunning` and saves the file.
    fn set_workspace_limit(&self, workspace: &str, max: Option<u32>) -> anyhow::Result<()> {
        {
            // Written under the lock, so two sets reach the file in the order they were made.
            let mut w = self.workspaces.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let map = w.get_or_insert_with(load_workspaces);
            match max {
                Some(n) => map.insert(workspace.to_owned(), n),
                None => map.remove(workspace),
            };
            let bytes = serde_json::to_vec_pretty(&*map)?;
            let path = crate::config::home().join(WORKSPACES_FILE);
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir)?;
            }
            crate::config::write_atomic(&path, &bytes)?;
        }
        self.wake();
        Ok(())
    }
}

/// The workspace limits on disk; none when the file is missing or unreadable (logged).
fn load_workspaces() -> BTreeMap<String, u32> {
    let path = crate::config::home().join(WORKSPACES_FILE);
    match std::fs::read(&path) {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|e| {
            tracing::warn!("{}: not read: {e}", path.display());
            BTreeMap::new()
        }),
        Err(_) => BTreeMap::new(),
    }
}

/// A run slot a family turn of a sub-session holds; dropped (the turn ended, or never
/// started) it frees the slot and wakes the waiting turns.
pub(super) struct RunSlot {
    runs: Arc<Runs>,
    parent: String,
    child: String,
}

impl Drop for RunSlot {
    fn drop(&mut self) {
        self.runs.release(&self.parent, &self.child);
    }
}

/// A sub-session counted as waiting for a slot while this lives.
pub(super) struct WaitMark {
    runs: Arc<Runs>,
    parent: String,
    child: String,
}

impl Drop for WaitMark {
    fn drop(&mut self) {
        self.runs.unmark(&self.parent, &self.child);
    }
}

/// The turn lock, with the run slot a family turn of a sub-session holds (`queue.rs`): both are
/// released together.
pub(super) struct TurnGuard<'a> {
    // Fields drop in order: the slot frees while the turn lock is still held, so the same
    // child's next turn (which takes the lock first) never finds its old slot still counted.
    _slot: Option<RunSlot>,
    _lock: tokio::sync::MutexGuard<'a, ()>,
}

impl<'a> TurnGuard<'a> {
    pub(super) fn new(lock: tokio::sync::MutexGuard<'a, ()>, slot: Option<RunSlot>) -> Self {
        Self { _slot: slot, _lock: lock }
    }
}

impl Hub {
    /// The parent whose slot a turn of `session` with `provenance` needs, with its limit;
    /// `None` when it needs none (not a family prompt, not a sub-session, an offered chat, or
    /// a parent this daemon no longer has).
    fn run_gate(&self, session: &Session, provenance: Option<&Value>) -> Option<(String, u32)> {
        let family = super::subsession_guard::is_family_prompt(provenance)
            || super::subsession_guard::is_family_retry(provenance);
        if !family {
            return None;
        }
        let link = session.meta().subsession.filter(|l| !l.offered)?;
        let parent = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&link.started_by)
            .cloned()?;
        let max = self.subsession_effective(&parent.meta()).max_running;
        Some((link.started_by, max))
    }

    /// A run slot for a turn of `session`: `Ok(None)` when it needs none, `Err(parent)` when
    /// the parent's slots are all taken.
    pub(super) fn take_run_slot(
        &self,
        session: &Session,
        provenance: Option<&Value>,
    ) -> Result<Option<RunSlot>, String> {
        let Some((parent, max)) = self.run_gate(session, provenance) else {
            return Ok(None);
        };
        if !self.subsession_runs.take(&parent, &session.id, max) {
            return Err(parent);
        }
        Ok(Some(RunSlot { runs: self.subsession_runs.clone(), parent, child: session.id.clone() }))
    }

    /// Counts `session` as waiting for a slot of `parent` until the mark is dropped.
    pub(super) fn mark_waiting_for_slot(&self, parent: &str, session: &Session) -> WaitMark {
        self.subsession_runs.mark(parent, &session.id);
        WaitMark {
            runs: self.subsession_runs.clone(),
            parent: parent.to_owned(),
            child: session.id.clone(),
        }
    }

    /// A future that is ready once a slot frees or a limit may have changed; enable it before
    /// looking at the slots, so a change in between is not missed.
    pub(super) fn run_slots_changed(&self) -> tokio::sync::futures::Notified<'_> {
        self.subsession_runs.changed.notified()
    }

    /// Takes every family prompt (`subsessions::PROVENANCE_KIND`) and every retry a sub-session
    /// asked for (`is_family_retry`) out of `session`'s queue, its `queue_removed` naming
    /// `reason`: a stopped or closed sub-session starts no turn later.
    pub(super) fn withdraw_family_prompts(&self, session: &Arc<Session>, reason: &str) {
        let ids: Vec<String> = session
            .queue
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .filter(|q| {
                let p = q.run.provenance.as_ref();
                super::subsession_guard::is_family_prompt(p)
                    || super::subsession_guard::is_family_retry(p)
            })
            .map(|q| q.prompt_id.clone())
            .collect();
        for id in ids {
            self.remove_queued_because(session, &id, Some(reason));
        }
    }

    /// Whether `session` (a sub-session) waits for a run slot of its parent now.
    pub(super) fn waits_for_slot(&self, m: &SessionMeta) -> bool {
        m.subsession.as_ref().is_some_and(|l| self.subsession_runs.waits(&l.started_by, &m.id))
    }

    /// `_acpmux/subsession/limits {workspaceId, maxRunning?}`, the person's: sets (a number) or
    /// clears (null) the workspace's `maxRunning`; left out, only reads it.
    pub fn set_workspace_run_limit(
        &self,
        workspace: &str,
        max_running: Option<Option<u32>>,
    ) -> Result<Value, RpcError> {
        // Kept as sessions keep theirs (`session_env::workspace_id`).
        let workspace = workspace.to_ascii_lowercase();
        if !crate::session_env::is_workspace_id(&workspace) {
            return Err(RpcError::invalid_params("workspaceId must be a workspace id (a UUID)"));
        }
        let workspace = workspace.as_str();
        let ceiling = super::subsessions::catalog().max_running.max;
        if let Some(Some(n)) = max_running
            && (n == 0 || n > ceiling)
        {
            return Err(super::subsessions::refused(
                "subsessions.limit_out_of_range",
                format!("maxRunning must be from 1 to {ceiling}"),
                json!({"max": ceiling}),
            ));
        }
        if let Some(max) = max_running {
            self.subsession_runs
                .set_workspace_limit(workspace, max)
                .map_err(|e| RpcError::internal(format!("workspace limit not saved: {e:#}")))?;
        }
        Ok(json!({
            "workspaceId": workspace,
            "maxRunning": self.subsession_runs.workspace_limit(workspace),
        }))
    }
}
