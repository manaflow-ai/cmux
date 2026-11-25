//! When a subagent stops counting as running even though its harness never said it ended.
//!
//! Leo, 2026-11-22, on the composer hat's pill reading "^ 99+" in his coordinator chat: "this can
//! probably afford to show more than 99 numbers. and have better animations for transitioning
//! between numbers and digit lengths. i hope we also have sophisticated expiry for these." The
//! pill counts what runs: a client folds each subagent's newest `_meta.acpmux.subagents` record
//! (`state: "running"` counts). A subagent whose end never reached the log read "running" forever:
//! in his coordinator 117 of 198 "running" ones were dead, some ten days old.
//!
//! An item leaves the count in one of three ways, each its own notion:
//!
//! - **Acknowledged**: its end was delivered. The parent agent got its result (Claude's
//!   `task_notification`, which `claude_stdio` turns into the subagent's end), or the person
//!   stopped it. Before, a notification whose Agent call the bridge no longer knew (its in-memory
//!   maps start empty after a restart, and a resumed agent's notification names another call)
//!   ended nothing; the hub now keeps the status it heard by the agent's id
//!   ([`SubagentTree::note_task_ended`]) and ends the subagent with it once Claude's task list
//!   drops it.
//! - **Aged out**: it is provably gone, or it said nothing for too long. Each rule writes an end
//!   record (`subagent_state_update`) into the chat's log, so every client and every later read
//!   of the log agrees, with `reason` saying which rule ended it:
//!   - `task_gone`: Claude Code's own list of its live background tasks
//!     (`system/background_tasks_changed`, the whole list each time) no longer has the agent's
//!     id, and nothing was heard of it for [`TASK_GONE_GRACE_MS`]. It ends with the status its
//!     notification gave when one was heard, else `disconnected`.
//!   - `harness_exit`: the harness process ended, and the background subagents with it. Every
//!     one that ran then ends `disconnected`, not only those acpmux can resume; a chat whose log
//!     already lost them that way (before this rule) gets their ends when a daemon next rebuilds
//!     its subagents from the log ([`SubagentTree::take_orphans`]).
//!   - `aged_out`: no event of it for [`AGE_OUT_MS`], whatever the harness (Codex has no task
//!     list). Checked at most every [`SWEEP_EVERY_MS`] per chat, as its updates arrive and when a
//!     daemon rebuilds its subagents. A later event of a subagent that was in fact alive makes it
//!     running again, as any event does.
//! - **Seen**: what ended lingers in the hat as a finished line only for time the person could see
//!   the hat (`webviews/.../subagents/trayLinger.ts`, three minutes, never right after a look).
//!   That is the client's: the daemon only makes sure the end exists.
//!
//! Cost: one map entry per running subagent (its last event time), one per agent id, and the
//! statuses heard for running ones; a task list is checked against the running ones only.

use super::SubagentTree;
use std::collections::{HashMap, HashSet};

/// How long a background subagent missing from Claude's task list may stay running after its last
/// event: an agent that just started, or whose end is on its way, is not yet in (or already out of)
/// the list it is read against.
pub const TASK_GONE_GRACE_MS: u64 = 30_000;
/// A running subagent that said nothing for this long ages out: six hours. A background helper's
/// progress arrives with each of its tool calls, so hours of silence is one that is gone.
pub const AGE_OUT_MS: u64 = 6 * 60 * 60 * 1000;
/// The aged-out check runs at most this often per chat.
pub const SWEEP_EVERY_MS: u64 = 60_000;

/// One subagent to end: its id, the state it ends in and why (`reason`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ended {
    pub id: String,
    pub state: &'static str,
    pub reason: &'static str,
}

/// What the tree keeps for expiry. It rides in the adoption checkpoint with the tree
/// (`hub/hosts/checkpoint.rs`), so a resumed log read keeps its orphans and event times.
#[derive(Debug, Default, Clone, serde::Serialize, serde::Deserialize)]
pub(super) struct Expiry {
    /// When the update being read happened (epoch ms; 0 when unknown).
    clock: u64,
    /// Each running subagent's last event time.
    last_event: HashMap<String, u64>,
    /// Each subagent by its agent id (Claude's task id), and each one's agent id.
    by_agent: HashMap<String, String>,
    agent_of: HashMap<String, String>,
    /// The end Claude's notification gave a running subagent, by its id, kept until it leaves.
    #[serde(with = "heard_end_serde")]
    heard_end: HashMap<String, &'static str>,
    /// Subagents a harness exit ended in a log read, with no end record of theirs after it.
    orphans: HashSet<String>,
    /// When the aged-out check last ran.
    last_sweep: u64,
}

/// `Expiry::heard_end` in a checkpoint: each end state by name, read back as the same static
/// state `end_state` gives.
mod heard_end_serde {
    use std::collections::HashMap;

    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<S: Serializer>(
        map: &HashMap<String, &'static str>,
        s: S,
    ) -> Result<S::Ok, S::Error> {
        map.serialize(s)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        d: D,
    ) -> Result<HashMap<String, &'static str>, D::Error> {
        let named = HashMap::<String, String>::deserialize(d)?;
        Ok(named
            .into_iter()
            .map(|(id, state)| {
                let state = match state.as_str() {
                    "failed" => "failed",
                    "cancelled" => "cancelled",
                    _ => "completed",
                };
                (id, state)
            })
            .collect())
    }
}

/// The state a Claude task status ends a subagent in.
fn end_state(status: &str) -> &'static str {
    match status {
        "failed" => "failed",
        "stopped" | "killed" | "paused" => "cancelled",
        _ => "completed",
    }
}

impl SubagentTree {
    /// The time of the updates that follow (epoch ms): a live one's arrival, a logged one's stamp.
    pub fn set_clock(&mut self, at: u64) {
        self.expiry.clock = at;
    }

    /// One event of `id`: running, it is seen now; ended, it leaves expiry's tables. Any event
    /// is its own record after a harness exit, so it is no orphan.
    pub(super) fn expiry_event(&mut self, id: &str, running: bool) {
        self.expiry.orphans.remove(id);
        if running {
            let at = self.expiry.clock;
            if at > 0 {
                self.expiry.last_event.insert(id.to_owned(), at);
            }
        } else {
            self.expiry.last_event.remove(id);
            self.expiry.heard_end.remove(id);
        }
    }

    /// `id` is the agent Claude names `agent` (its task id).
    pub(super) fn expiry_agent(&mut self, id: &str, agent: &str) {
        self.expiry.by_agent.insert(agent.to_owned(), id.to_owned());
        self.expiry.agent_of.insert(id.to_owned(), agent.to_owned());
    }

    /// Claude's `task_notification` for task `agent` said `status`: kept for the running subagent
    /// it is, so its end says how it ended even when the bridge could not tell (the module doc).
    pub fn note_task_ended(&mut self, agent: &str, status: &str) {
        let Some(id) = self.expiry.by_agent.get(agent) else { return };
        if self.running.iter().any(|(r, _)| r == id) {
            self.expiry.heard_end.insert(id.clone(), end_state(status));
        }
    }

    /// Claude's whole list of live background tasks (their task ids) at `now`: every running
    /// background subagent whose agent id is known, missing from it, and quiet for
    /// [`TASK_GONE_GRACE_MS`] ends (`task_gone`).
    pub fn reconcile_tasks(&self, live: &HashSet<&str>, now: u64) -> Vec<Ended> {
        self.running
            .iter()
            .filter(|(id, _)| self.background.contains(id))
            .filter(|(id, _)| {
                self.expiry.agent_of.get(id).is_some_and(|agent| !live.contains(agent.as_str()))
            })
            .filter(|(id, _)| {
                self.expiry
                    .last_event
                    .get(id)
                    .is_none_or(|at| now.saturating_sub(*at) >= TASK_GONE_GRACE_MS)
            })
            .map(|(id, _)| Ended {
                id: id.clone(),
                state: self.expiry.heard_end.get(id).copied().unwrap_or("disconnected"),
                reason: "task_gone",
            })
            .collect()
    }

    /// The running subagents quiet for [`AGE_OUT_MS`] at `now` (`aged_out`); none when the check
    /// ran less than [`SWEEP_EVERY_MS`] ago, unless `force`. One with no event time yet is
    /// counted from now.
    pub fn sweep_aged(&mut self, now: u64, force: bool) -> Vec<Ended> {
        if now == 0 || (!force && now.saturating_sub(self.expiry.last_sweep) < SWEEP_EVERY_MS) {
            return Vec::new();
        }
        self.expiry.last_sweep = now;
        let mut ended = Vec::new();
        for (id, _) in &self.running {
            let at = *self.expiry.last_event.entry(id.clone()).or_insert(now);
            if now.saturating_sub(at) >= AGE_OUT_MS {
                ended.push(Ended { id: id.clone(), state: "disconnected", reason: "aged_out" });
            }
        }
        ended
    }

    /// The subagents a harness exit ended while the log was read whose end the log never got
    /// (`harness_exit`), taken once.
    pub fn take_orphans(&mut self) -> Vec<Ended> {
        let mut ids: Vec<String> = self.expiry.orphans.drain().collect();
        ids.sort();
        ids.into_iter()
            .map(|id| Ended { id, state: "disconnected", reason: "harness_exit" })
            .collect()
    }

    /// A harness exit ends what ran: remembered as orphans until an end record of theirs follows.
    pub(super) fn expiry_harness_exit(&mut self) {
        for (id, _) in &self.running {
            self.expiry.last_event.remove(id);
            self.expiry.heard_end.remove(id);
            self.expiry.orphans.insert(id.clone());
        }
    }

    /// Takes what a tree rebuilt from the log knows. `known` are the ids this tree knew before:
    /// their state is this tree's.
    pub(super) fn adopt_expiry(&mut self, log: Expiry, known: &HashSet<String>) {
        for (agent, id) in log.by_agent {
            self.expiry.by_agent.entry(agent).or_insert(id);
        }
        for (id, agent) in log.agent_of {
            self.expiry.agent_of.entry(id).or_insert(agent);
        }
        for (id, at) in log.last_event {
            if !known.contains(&id) {
                self.expiry.last_event.entry(id).or_insert(at);
            }
        }
        for (id, state) in log.heard_end {
            if !known.contains(&id) {
                self.expiry.heard_end.entry(id).or_insert(state);
            }
        }
        self.expiry.orphans.extend(log.orphans.into_iter().filter(|id| !known.contains(id)));
    }
}

#[cfg(test)]
#[path = "subagent_expiry_tests.rs"]
mod tests;
