//! A chat's latest subagents for its summary (`recentSubagents`, `subagentsSeen`): the sidebar lists
//! them under the chat's row, the way the Claude desktop app's Code tab nests a chat's tasks under it
//! (Leo, 2026-11-19: "for claude there's the font and the nested sessions and whatever"). Part of
//! [`SubagentTree`]; bounded at [`RECENT_SUBAGENTS`] whatever the chat starts.

use super::SubagentTree;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The most subagents a summary lists (`recentSubagents`); `subagentsSeen` counts all.
pub const RECENT_SUBAGENTS: usize = 8;

/// One listed subagent as the tree keeps it: its parent subagent and its last state.
/// Saved with the tree in a host checkpoint (#47558), so a resumed host keeps the list.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub(super) struct RecentEntry {
    id: String,
    parent: Option<String>,
    state: &'static str,
}

/// A checkpoint's [`RecentEntry`]: its state read back onto the four a list says.
#[derive(Deserialize)]
struct RecentEntryWire {
    id: String,
    parent: Option<String>,
    state: String,
}

// By hand, not derived: serde reads a `&'static str` field as borrowed and would ask `'de: 'static`.
impl<'de> Deserialize<'de> for RecentEntry {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        RecentEntryWire::deserialize(deserializer).map(Self::from)
    }
}

impl From<RecentEntryWire> for RecentEntry {
    fn from(wire: RecentEntryWire) -> Self {
        let state = match wire.state.as_str() {
            "running" => "running",
            "done" => "done",
            "failed" => "failed",
            _ => "stopped",
        };
        RecentEntry { id: wire.id, parent: wire.parent, state }
    }
}

/// One of a chat's latest subagents as its summary lists it (`recentSubagents[]`).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecentSubagent {
    pub id: String,
    /// The subagent that started it; null for one the chat itself started.
    pub parent: Option<String>,
    /// Its name, else its task, masked and cut as `subagentNames` are; null when it gave neither.
    pub title: Option<String>,
    /// `running`, `done`, `failed` or `stopped`: cancelled or disconnected, or one that runs no
    /// more though its harness never said it ended (a foreground one of a turn that ended, every
    /// one of a harness that is gone).
    pub state: &'static str,
}

/// A subagent event's state as a list says it; None for an event without one.
fn listed_state(event: &Value) -> Option<&'static str> {
    match event.get("state").and_then(Value::as_str)? {
        "running" => Some("running"),
        "completed" => Some("done"),
        "failed" => Some("failed"),
        "cancelled" | "disconnected" => Some("stopped"),
        _ => None,
    }
}

/// A name or task as a list shows it: its secrets masked before the cut, one line, and cut as
/// `subagentNames` labels are (`note_running`); None when nothing is left.
fn listed_title(text: &str) -> Option<String> {
    let line = crate::secret_scan::mask(text).split_whitespace().collect::<Vec<_>>().join(" ");
    (!line.is_empty()).then(|| super::truncate_label(&line))
}

impl SubagentTree {
    /// Follows the listed subagents through one update's events, live or replayed (a replay
    /// rebuilds the list after a daemon restart): a new one joins at the end, a known one takes its
    /// new state. Past [`RECENT_SUBAGENTS`] the oldest that ended leaves, else the oldest. A live
    /// change bumps `recent_revision`.
    pub(super) fn note_recent(&mut self, events: &[Value], live: bool) {
        let mut changed = false;
        for event in events {
            let (Some(id), Some(state)) =
                (event.get("id").and_then(Value::as_str), listed_state(event))
            else {
                continue;
            };
            let parent = self.parents.get(id).cloned().flatten();
            if let Some(entry) = self.recent.iter_mut().find(|e| e.id == id) {
                if entry.state != state || entry.parent != parent {
                    (entry.state, entry.parent) = (state, parent);
                    changed = true;
                }
                continue;
            }
            self.recent.push_back(RecentEntry { id: id.to_owned(), parent, state });
            changed = true;
            if self.recent.len() > RECENT_SUBAGENTS {
                let at = self.recent.iter().position(|e| e.state != "running").unwrap_or(0);
                self.recent.remove(at);
            }
        }
        if changed && live {
            self.recent_revision = self.recent_revision.wrapping_add(1);
        }
    }

    /// Takes in the list `log` (a tree rebuilt from the chat's log) holds: each one this tree does
    /// not list joins, oldest first, under the same bound; a listed one keeps this tree's state,
    /// which a live update may have changed after the log was read.
    pub(super) fn adopt_recent(&mut self, log: std::collections::VecDeque<RecentEntry>) {
        for entry in log {
            if self.recent.iter().any(|e| e.id == entry.id) {
                continue;
            }
            self.recent.push_back(entry);
            if self.recent.len() > RECENT_SUBAGENTS {
                let at = self.recent.iter().position(|e| e.state != "running").unwrap_or(0);
                self.recent.remove(at);
            }
        }
    }

    /// The listed subagents, oldest first, for the summary. One the list says runs but that runs
    /// no more (`running_now` with `turn_runs`) reads `stopped`.
    pub fn recent(&self, turn_runs: bool) -> Vec<RecentSubagent> {
        let running: std::collections::HashSet<&str> =
            self.running_now(turn_runs).into_iter().map(|(id, _)| id).collect();
        self.recent
            .iter()
            .map(|e| RecentSubagent {
                id: e.id.clone(),
                parent: e.parent.clone(),
                title: [
                    self.names.get(&e.id).map(String::as_str),
                    self.previews.get(&e.id).and_then(|p| p.task.as_deref()),
                ]
                .into_iter()
                .flatten()
                .find_map(listed_title),
                state: if e.state == "running" && !running.contains(e.id.as_str()) {
                    "stopped"
                } else {
                    e.state
                },
            })
            .collect()
    }

    /// Every subagent the chat started, listed or not (`subagentsSeen`).
    pub fn seen(&self) -> usize {
        self.parents.len()
    }

    /// Bumped on each change of the list a live update made: the tap tells watchers when it moved.
    pub fn recent_revision(&self) -> u64 {
        self.recent_revision
    }
}

#[cfg(test)]
#[path = "subagents_recent_tests.rs"]
mod tests;
