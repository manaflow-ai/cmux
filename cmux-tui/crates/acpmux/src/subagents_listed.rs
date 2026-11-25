//! Every subagent a chat started, for the Background tasks panel (`_acpmux/subagents`,
//! `hub/subagent_list.rs`). Part of [`SubagentTree`].
//!
//! The panel used to find a chat's subagents in the rows its page holds, and a page holds only
//! the chat's newest records (webviews `direct/heldRecords.ts`, 2,000 to 4,000): a coordinator
//! that started its helpers hours and millions of records ago had none of them in its page, so
//! the panel said "Nothing runs in the background" while a hundred ran (Leo, 2026-11-24: "this
//! bugged? or had an ultra slow load"). The tree already sees every subagent event, live and
//! replayed, so it keeps each one's last state here and the panel reads the list in one call,
//! whatever its page holds.
//!
//! One small entry per subagent the tree already maps in `parents`; the list a call returns is
//! every running one and the latest `ended` ended ones, so a chat of 4,000 subagents answers in a
//! few kilobytes.

use super::SubagentTree;
use super::recent::{listed_state, listed_title};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};

/// The ended subagents a list returns when the caller names no bound.
pub const LISTED_ENDED_DEFAULT: usize = 100;
/// The most ended subagents one list returns.
pub const LISTED_ENDED_MAX: usize = 500;

/// One subagent's last state as the tree keeps it.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub(super) struct Listed {
    /// `running`, `done`, `failed` or `stopped` (`listed_state`).
    state: String,
    /// The tree's `listed_seq` at its last state change: the ended ones list latest first.
    seq: u64,
    /// When it was first seen running and when it ended, epoch ms, from live updates only (a
    /// replayed one's clock is the replay's, not the subagent's).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    started_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    ended_at: Option<u64>,
    /// `workflow` for a Claude workflow; none for an agent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    kind: Option<String>,
    /// The tool call that started it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    tool_call_id: Option<String>,
}

/// One subagent as the list says it (`_acpmux/subagents` `running[]`, `ended[]`).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ListedSubagent {
    pub id: String,
    /// The subagent that started it; null for one the chat itself started.
    pub parent: Option<String>,
    /// Its name, else its task, masked and cut as the summary's labels are.
    pub title: Option<String>,
    /// `running`, `done`, `failed` or `stopped`.
    pub state: &'static str,
    /// It outlives the turn that started it.
    pub background: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<u64>,
}

/// What `_acpmux/subagents` answers: every running subagent, oldest first; the latest ended
/// ones, latest first; and how many the chat started in all.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubagentListing {
    pub running: Vec<ListedSubagent>,
    pub ended: Vec<ListedSubagent>,
    /// Ended subagents past the bound, not listed.
    pub ended_omitted: usize,
    pub seen: usize,
}

fn as_static(state: &str) -> &'static str {
    match state {
        "running" => "running",
        "done" => "done",
        "failed" => "failed",
        _ => "stopped",
    }
}

impl SubagentTree {
    /// Follows every subagent through one update's events, live or replayed: its state, its kind
    /// and the call that started it; and, live, when it started and ended.
    pub(super) fn note_listed(&mut self, events: &[Value], live: bool) {
        let now = live.then(crate::store::now_ms);
        for event in events {
            let (Some(id), Some(state)) =
                (event.get("id").and_then(Value::as_str), listed_state(event))
            else {
                continue;
            };
            let text = |key: &str| event.get(key).and_then(Value::as_str).map(str::to_owned);
            let entry = self.listed.entry(id.to_owned()).or_default();
            if entry.state != state {
                self.listed_seq += 1;
                entry.seq = self.listed_seq;
                entry.state = state.to_owned();
                if state == "running" {
                    entry.ended_at = None;
                    entry.started_at = entry.started_at.or(now);
                } else {
                    entry.ended_at = now.or(entry.ended_at);
                }
            }
            if let Some(kind) = text("kind") {
                entry.kind = Some(kind);
            }
            if let Some(call) = text("toolCallId") {
                entry.tool_call_id = Some(call);
            }
        }
    }

    /// Takes in what a tree rebuilt from the chat's log lists: a subagent this tree knew before
    /// (`known`) keeps its own entry, since a live update may have changed it after the read.
    pub(super) fn adopt_listed(&mut self, log: HashMap<String, Listed>, known: &HashSet<String>) {
        for (id, mut entry) in log {
            if known.contains(&id) && self.listed.contains_key(&id) {
                continue;
            }
            self.listed_seq += 1;
            entry.seq = self.listed_seq;
            self.listed.insert(id, entry);
        }
    }

    /// The list `_acpmux/subagents` answers. Running is what `running_now` says (`turn_runs`
    /// as the summary's): one the list says runs but that runs no more reads `stopped`, and one
    /// running that the list never saw (a resumed host) is listed too. At most `ended` ended
    /// ones, latest first.
    pub fn listing(&self, turn_runs: bool, ended: usize) -> SubagentListing {
        let running_now = self.running_now(turn_runs);
        let running_ids: HashSet<&str> = running_now.iter().map(|(id, _)| *id).collect();
        let item = |id: &str, entry: Option<&Listed>, state: &'static str| ListedSubagent {
            id: id.to_owned(),
            parent: self.parents.get(id).cloned().flatten(),
            title: [
                self.names.get(id).map(String::as_str),
                self.previews.get(id).and_then(|p| p.task.as_deref()),
            ]
            .into_iter()
            .flatten()
            .find_map(listed_title),
            state,
            background: self.was_background.contains(id),
            kind: entry.and_then(|e| e.kind.clone()),
            tool_call_id: entry.and_then(|e| e.tool_call_id.clone()),
            started_at: entry.and_then(|e| e.started_at),
            ended_at: entry.and_then(|e| e.ended_at),
        };
        let running =
            running_now.iter().map(|(id, _)| item(id, self.listed.get(*id), "running")).collect();
        let mut done: Vec<(&String, &Listed)> =
            self.listed.iter().filter(|(id, _)| !running_ids.contains(id.as_str())).collect();
        done.sort_by_key(|a| std::cmp::Reverse(a.1.seq));
        let ended_omitted = done.len().saturating_sub(ended);
        let ended = done
            .into_iter()
            .take(ended)
            .map(|(id, entry)| {
                let state = match as_static(&entry.state) {
                    // It says it runs, but the tree's running list no longer holds it: its turn
                    // ended or its harness went, as the summary's list reads it.
                    "running" => "stopped",
                    other => other,
                };
                item(id, Some(entry), state)
            })
            .collect();
        SubagentListing { running, ended, ended_omitted, seen: self.parents.len() }
    }
}

#[cfg(test)]
#[path = "subagents_listed_tests.rs"]
mod tests;
