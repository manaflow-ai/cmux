//! Workspace auto-naming's bookkeeping (hq#1957), moved from the Swift
//! `WorkspaceAutoNamer` and `WorkspaceAutoNameHold`.
//!
//! [`Namer`]: variant B (`persist`) writes a focused chat's generated title to
//! the daemon through Rename Workspace. The app reads its models and the rule
//! (`WorkspaceAutoName`) and hands each workspace's candidate here; this keeps
//! at most one live submission per workspace, numbers the attempts so a late
//! callback never clears a newer one, and advances a workspace's retry mark
//! when a deferred send finds its candidate stale, which wakes that workspace
//! alone.
//!
//! [`Hold`]: the last name each front tab gave its workspace's sidebar row, so
//! the row keeps it while that tab's name is briefly unknown (a relaunch, a
//! watch reconnect), and the launch names of workspaces their launcher named
//! after an agent.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

/// A workspace on a machine: the key of its submission and retry mark.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Slot {
    pub machine_id: String,
    pub workspace_id: String,
}

/// The acpmux session an agent chat tab shows (`AgentSessionRef`): equal only
/// when every field is.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentSession {
    pub host: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
}

/// A workspace's identity and name state as read now: what a live submission
/// must still match to stay live.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    pub machine_id: String,
    pub workspace_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub daemon_generation: Option<String>,
    pub name_revision: u64,
}

impl Target {
    fn slot(&self) -> Slot {
        Slot { machine_id: self.machine_id.clone(), workspace_id: self.workspace_id.clone() }
    }
}

/// One rename the rule asks for, and the submission it becomes when queued.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rename {
    pub machine_id: String,
    pub workspace_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub daemon_generation: Option<String>,
    pub name_revision: u64,
    pub front_tab_id: String,
    pub front_agent_session: AgentSession,
    pub name: String,
}

impl Rename {
    fn slot(&self) -> Slot {
        Slot { machine_id: self.machine_id.clone(), workspace_id: self.workspace_id.clone() }
    }

    /// Whether this submission still belongs to `target`: the same workspace on
    /// the same daemon run at the same name revision.
    fn matches_target(&self, target: &Target) -> bool {
        self.machine_id == target.machine_id
            && self.workspace_id == target.workspace_id
            && self.daemon_generation == target.daemon_generation
            && self.name_revision == target.name_revision
    }

    /// Whether `current` (the rename the rule asks for in this workspace now)
    /// still asks for this one: same daemon run, revision, focused chat and name.
    fn still_current(&self, current: Option<&Rename>) -> bool {
        current.is_some_and(|current| {
            current.daemon_generation == self.daemon_generation
                && current.name_revision == self.name_revision
                && current.front_tab_id == self.front_tab_id
                && current.front_agent_session == self.front_agent_session
                && current.name == self.name
        })
    }
}

/// A workspace's one current submission and the attempt that owns it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Live {
    pub submission: Rename,
    pub attempt: u64,
}

/// A retry mark on the wire.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Mark {
    #[serde(flatten)]
    slot: Slot,
    revision: u64,
}

/// The namer's state on the wire: lists, since a JSON object keys by string.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct NamerWire {
    #[serde(default)]
    submitted: Vec<Live>,
    #[serde(default)]
    next_attempt_id: u64,
    #[serde(default)]
    shown: Vec<Slot>,
    #[serde(default)]
    retries: Vec<Mark>,
}

/// `WorkspaceAutoNamer`'s state: the app holds it between calls.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "NamerWire", into = "NamerWire")]
pub struct Namer {
    /// Each listed workspace's one current submission.
    pub submitted: BTreeMap<Slot, Live>,
    pub next_attempt_id: u64,
    /// The workspaces listed last.
    pub shown: BTreeSet<Slot>,
    /// Each workspace's retry mark: advanced only when a deferred send finds
    /// its candidate stale.
    pub retries: BTreeMap<Slot, u64>,
}

impl From<NamerWire> for Namer {
    fn from(wire: NamerWire) -> Self {
        Namer {
            submitted: wire
                .submitted
                .into_iter()
                .map(|live| (live.submission.slot(), live))
                .collect(),
            next_attempt_id: wire.next_attempt_id,
            shown: wire.shown.into_iter().collect(),
            retries: wire.retries.into_iter().map(|mark| (mark.slot, mark.revision)).collect(),
        }
    }
}

impl From<Namer> for NamerWire {
    fn from(namer: Namer) -> Self {
        NamerWire {
            submitted: namer.submitted.into_values().collect(),
            next_attempt_id: namer.next_attempt_id,
            shown: namer.shown.into_iter().collect(),
            retries: namer
                .retries
                .into_iter()
                .map(|(slot, revision)| Mark { slot, revision })
                .collect(),
        }
    }
}

impl Namer {
    /// Records the listed workspaces (`list`): one no longer listed keeps no
    /// submission or retry mark.
    pub fn list(&mut self, listed: &[Slot]) {
        self.shown = listed.iter().cloned().collect();
        let shown = &self.shown;
        self.submitted.retain(|slot, _| shown.contains(slot));
        self.retries.retain(|slot, _| shown.contains(slot));
    }

    /// The rename to queue for `target`'s workspace (`plan`), given
    /// `candidate`, the one the rule asks for now (nil when the rule, the
    /// setting or the front tab asks for none). A submission for another
    /// daemon run or revision is dropped first; a candidate already live is
    /// not asked for again. Starts the workspace's retry mark.
    pub fn plan(&mut self, target: &Target, candidate: Option<Rename>) -> Option<Rename> {
        let slot = target.slot();
        self.retries.entry(slot.clone()).or_insert(0);
        if self.submitted.get(&slot).is_some_and(|live| !live.submission.matches_target(target)) {
            self.submitted.remove(&slot);
        }
        let candidate = candidate?;
        if let Some(live) = self.submitted.get(&slot) {
            if live.submission == candidate {
                return None;
            }
            self.submitted.remove(&slot);
        }
        Some(candidate)
    }

    /// Queues `candidate` once (`apply`): the attempt that now owns it, or nil
    /// when it is already live or `current` (the rename the rule asks for in
    /// its workspace now, nil when its workspace has no key) no longer asks
    /// for it. The app then schedules the rename and, when the queue refuses
    /// it, calls [`Namer::release`].
    pub fn apply(&mut self, candidate: &Rename, current: Option<&Rename>) -> Option<u64> {
        let slot = candidate.slot();
        if self.submitted.get(&slot).is_some_and(|live| live.submission == *candidate)
            || !self.shown.contains(&slot)
            || !candidate.still_current(current)
        {
            return None;
        }
        let attempt = self.next_attempt_id;
        self.next_attempt_id = self.next_attempt_id.wrapping_add(1);
        self.submitted.insert(slot, Live { submission: candidate.clone(), attempt });
        Some(attempt)
    }

    /// Whether `attempt` may send now, read immediately before the daemon
    /// request (`maySend`). A stale candidate releases its submission and
    /// advances the workspace's retry mark, so its observation plans again.
    pub fn may_send(&mut self, slot: &Slot, attempt: u64, current: Option<&Rename>) -> bool {
        let Some(live) = self.submitted.get(slot) else { return false };
        if live.attempt != attempt {
            return false;
        }
        if self.shown.contains(slot) && live.submission.still_current(current) {
            return true;
        }
        self.submitted.remove(slot);
        let revision = self.retries.entry(slot.clone()).or_insert(0);
        *revision = revision.wrapping_add(1);
        false
    }

    /// The queue refused `attempt`, or the daemon failed it after it was
    /// accepted (`acceptedSendFailed`): releases only that exact attempt, with
    /// no retry, so a failure waits for a real change.
    pub fn release(&mut self, slot: &Slot, attempt: u64) {
        if self.submitted.get(slot).is_some_and(|live| live.attempt == attempt) {
            self.submitted.remove(slot);
        }
    }
}

/// `WorkspaceAutoNameHold`'s state: the app holds one.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Hold {
    /// By workspace id, then by namer: the name it gave last.
    #[serde(default)]
    pub held: BTreeMap<String, BTreeMap<String, String>>,
    /// By workspace id: the launch name and chat of a workspace its launcher
    /// named after that chat's agent (`session` NUL `name`).
    #[serde(default)]
    pub launcher_named: BTreeMap<String, String>,
}

impl Hold {
    /// The name a row shows: `label` when its namer gives one (held from now
    /// on), else the name the same namer gave last, else nil.
    pub fn settle(&mut self, workspace: &str, namer: &str, label: Option<&str>) -> Option<String> {
        let Some(label) = label else {
            return self.held.get(workspace).and_then(|names| names.get(namer)).cloned();
        };
        self.held
            .entry(workspace.to_owned())
            .or_default()
            .insert(namer.to_owned(), label.to_owned());
        Some(label.to_owned())
    }

    /// Whether `workspace`, named `name`, is launcher-named after the agent of
    /// `session`: `matches` (its name is one the agent has had) now, or it
    /// matched before under the same name and chat. Remembers a match.
    pub fn launcher_named(
        &mut self,
        workspace: &str,
        name: &str,
        session: &str,
        matches: bool,
    ) -> bool {
        let key = format!("{session}\u{0}{name}");
        if matches {
            self.launcher_named.insert(workspace.to_owned(), key);
            return true;
        }
        self.launcher_named.get(workspace) == Some(&key)
    }

    /// The user named `workspace`: nothing held for it outlives that name.
    pub fn forget(&mut self, workspace: &str) {
        self.held.remove(workspace);
    }
}

#[cfg(test)]
#[path = "auto_namer_tests.rs"]
mod tests;
