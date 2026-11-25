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
//! An end acpmux writes after the fact says so, and says when the subagent really ended, so a
//! client draws it where it ended and never as news of the moment it was written (Leo,
//! 2026-11-22, after a relaunch wrote 105 such ends into his coordinator's current turn, a
//! tooltip reading "Disconnected · 0s": "and more bullshit somehow happened here"). Each carries
//! `recovered: true`, `endedAt` (epoch ms: the notification that ended it, else its last own
//! event) and `startedAt` (its first event of the run, when the log has it). One whose
//! notification was heard ends with that status (`completed`, mostly), on every rule, a harness
//! exit and a sweep included: it finished, it was not lost. A subagent below another one
//! (Claude's nested agents, `spawn_depth` 2) is never in Claude's list of background tasks,
//! which holds only the top-level ones, so the list never ends it (`task_gone`).
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
    /// When it really ended (epoch ms): its notification, else its last own event.
    pub ended_at: Option<u64>,
    /// When its run started (epoch ms), when known.
    pub started_at: Option<u64>,
}

/// What a harness exit left of a subagent whose end the log never got.
#[derive(Debug, Clone, Copy, serde::Serialize)]
pub(super) struct Orphan {
    state: &'static str,
    ended_at: Option<u64>,
    started_at: Option<u64>,
}

/// An `Orphan` as a checkpoint holds it: its end state by name, read back as the same static
/// state it was written from.
#[derive(serde::Deserialize)]
struct StoredOrphan {
    state: String,
    ended_at: Option<u64>,
    started_at: Option<u64>,
}

impl<'de> serde::Deserialize<'de> for Orphan {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let o = StoredOrphan::deserialize(d)?;
        Ok(Orphan { state: stored_state(&o.state), ended_at: o.ended_at, started_at: o.started_at })
    }
}

/// What the tree keeps for expiry. It rides in the adoption checkpoint with the tree
/// (`hub/hosts/checkpoint.rs`), so a resumed log read keeps its orphans and event times.
#[derive(Debug, Default, Clone, serde::Serialize, serde::Deserialize)]
pub(super) struct Expiry {
    /// When the update being read happened (epoch ms; 0 when unknown).
    clock: u64,
    /// Each running subagent's last event time, and its run's first.
    last_event: HashMap<String, u64>,
    first_event: HashMap<String, u64>,
    /// Each subagent by its agent id (Claude's task id), and each one's agent id.
    by_agent: HashMap<String, String>,
    agent_of: HashMap<String, String>,
    /// The end Claude's notification gave a running subagent and when it came, by its id, kept
    /// until it leaves or its task starts again (a SendMessage resume).
    #[serde(with = "heard_end_serde")]
    heard_end: HashMap<String, (&'static str, u64)>,
    /// Subagents a harness exit ended in a log read, with no end record of theirs after it.
    orphans: HashMap<String, Orphan>,
    /// When the aged-out check last ran.
    last_sweep: u64,
}

/// An end state read back from a checkpoint as the same static state `end_state` (or a harness
/// exit's `disconnected`) gave it.
fn stored_state(state: &str) -> &'static str {
    match state {
        "failed" => "failed",
        "cancelled" => "cancelled",
        "disconnected" => "disconnected",
        _ => "completed",
    }
}

/// `Expiry::heard_end` in a checkpoint: each end state by name and when it came, read back as
/// the same static state `end_state` gives.
mod heard_end_serde {
    use std::collections::HashMap;

    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<S: Serializer>(
        map: &HashMap<String, (&'static str, u64)>,
        s: S,
    ) -> Result<S::Ok, S::Error> {
        map.serialize(s)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        d: D,
    ) -> Result<HashMap<String, (&'static str, u64)>, D::Error> {
        let named = HashMap::<String, (String, u64)>::deserialize(d)?;
        Ok(named
            .into_iter()
            .map(|(id, (state, at))| (id, (super::stored_state(&state), at)))
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
                self.expiry.first_event.entry(id.to_owned()).or_insert(at);
            }
        } else {
            self.expiry.last_event.remove(id);
            self.expiry.first_event.remove(id);
            self.expiry.heard_end.remove(id);
        }
    }

    /// The end `id` gets from a rule (`reason`): the status its notification gave, at that
    /// notification's time, else `disconnected` at its last event.
    fn expiry_end(&self, id: &str, reason: &'static str) -> Ended {
        let heard = self.expiry.heard_end.get(id);
        Ended {
            id: id.to_owned(),
            state: heard.map(|(state, _)| *state).unwrap_or("disconnected"),
            reason,
            ended_at: heard
                .map(|(_, at)| *at)
                .filter(|at| *at > 0)
                .or_else(|| self.expiry.last_event.get(id).copied()),
            started_at: self.expiry.first_event.get(id).copied(),
        }
    }

    /// `id` is the agent Claude names `agent` (its task id).
    pub(super) fn expiry_agent(&mut self, id: &str, agent: &str) {
        self.expiry.by_agent.insert(agent.to_owned(), id.to_owned());
        self.expiry.agent_of.insert(id.to_owned(), agent.to_owned());
    }

    /// Claude's `task_notification` for task `agent` said `status`: kept for the running subagent
    /// it is, so its end says how it ended even when the bridge could not tell (the module doc).
    /// One a harness exit left an orphan is told too: Claude, resumed after the exit, often goes
    /// on to finish the agent and says so, and the orphan then ends as it said, when it said.
    pub fn note_task_ended(&mut self, agent: &str, status: &str) {
        let Some(id) = self.expiry.by_agent.get(agent) else { return };
        let at = self.expiry.clock;
        if let Some(orphan) = self.expiry.orphans.get_mut(id) {
            orphan.state = end_state(status);
            orphan.ended_at = Some(at).filter(|at| *at > 0).or(orphan.ended_at);
        } else if self.running.iter().any(|(r, _)| r == id) {
            self.expiry.heard_end.insert(id.clone(), (end_state(status), at));
        }
    }

    /// Claude's `task_started` for task `agent`: it runs again (a SendMessage resume), so an
    /// earlier notification no longer says how it ends. An orphan that starts again and is never
    /// heard of after is lost then, not at its last event before the exit.
    pub fn note_task_started(&mut self, agent: &str) {
        let Some(id) = self.expiry.by_agent.get(agent) else { return };
        self.expiry.heard_end.remove(id);
        let at = self.expiry.clock;
        if let Some(orphan) = self.expiry.orphans.get_mut(id) {
            orphan.state = "disconnected";
            orphan.ended_at = Some(at).filter(|at| *at > 0).or(orphan.ended_at);
        }
    }

    /// Claude's whole list of live background tasks (their task ids) at `now`: every running
    /// top-level background subagent whose agent id is known, missing from it, and quiet for
    /// [`TASK_GONE_GRACE_MS`] ends (`task_gone`). One below another subagent is background work
    /// for acpmux but never in Claude's list (the module doc).
    pub fn reconcile_tasks(&self, live: &HashSet<&str>, now: u64) -> Vec<Ended> {
        self.running
            .iter()
            .filter(|(id, _)| self.background.contains(id))
            .filter(|(id, _)| self.parents.get(id).is_none_or(Option::is_none))
            .filter(|(id, _)| {
                self.expiry.agent_of.get(id).is_some_and(|agent| !live.contains(agent.as_str()))
            })
            .filter(|(id, _)| {
                self.expiry
                    .last_event
                    .get(id)
                    .is_none_or(|at| now.saturating_sub(*at) >= TASK_GONE_GRACE_MS)
            })
            .map(|(id, _)| self.expiry_end(id, "task_gone"))
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
                ended.push(id.clone());
            }
        }
        ended.iter().map(|id| self.expiry_end(id, "aged_out")).collect()
    }

    /// The subagents a harness exit ended while the log was read whose end the log never got
    /// (`harness_exit`), taken once.
    pub fn take_orphans(&mut self) -> Vec<Ended> {
        let mut orphans: Vec<(String, Orphan)> = self.expiry.orphans.drain().collect();
        orphans.sort_by(|a, b| a.0.cmp(&b.0));
        orphans
            .into_iter()
            .map(|(id, o)| Ended {
                id,
                state: o.state,
                reason: "harness_exit",
                ended_at: o.ended_at,
                started_at: o.started_at,
            })
            .collect()
    }

    /// A harness exit ends what ran: remembered as orphans until an end record of theirs follows,
    /// each with the end it really had (its notification's, else lost at its last event).
    pub(super) fn expiry_harness_exit(&mut self) {
        let running: Vec<String> = self.running.iter().map(|(id, _)| id.clone()).collect();
        for id in running {
            let end = self.expiry_end(&id, "harness_exit");
            self.expiry.last_event.remove(&id);
            self.expiry.first_event.remove(&id);
            self.expiry.heard_end.remove(&id);
            self.expiry.orphans.insert(
                id,
                Orphan { state: end.state, ended_at: end.ended_at, started_at: end.started_at },
            );
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
        for (id, at) in log.first_event {
            if !known.contains(&id) {
                self.expiry.first_event.entry(id).or_insert(at);
            }
        }
        for (id, state) in log.heard_end {
            if !known.contains(&id) {
                self.expiry.heard_end.entry(id).or_insert(state);
            }
        }
        self.expiry.orphans.extend(log.orphans.into_iter().filter(|(id, _)| !known.contains(id)));
    }
}

#[cfg(test)]
#[path = "subagent_expiry_tests.rs"]
mod tests;
