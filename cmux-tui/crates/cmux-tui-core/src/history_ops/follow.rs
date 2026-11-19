//! `history.entries.list` follow: a reader that holds an answer asks for
//! what changed since, not the whole window again.
//!
//! An open History page re-read its whole first window (1,000 entries,
//! ~220 KB) on every `history-changed`, about 4 a second on a busy Mac,
//! for a change of one or two rows (cmuxterm-hq
//! `docs/handbook/whole-list-reread-on-delta.md`). Each answer now carries
//! a `follow` cursor: the daemon run's epoch and the answer's number. A list
//! that passes the cursor back with the same query is answered with only the
//! entries that changed or came (`entries`, each with its index in the new
//! window, `delta.at`) and the ids that left (`delta.removed`). The reader
//! drops the removed and changed ids from what it holds and inserts each
//! entry at its index, in order; the window comes out as a whole answer
//! would be.
//!
//! The daemon keeps each answered window's ids and a hash of each entry's
//! wire JSON, never the entries, for the last `KEPT` answers. A cursor from
//! another daemon run, one no longer kept, another query, or a change too big
//! to be worth a delta is answered with the whole window and a new cursor,
//! as a reader without a cursor is. The merged list is still built per read
//! (its sources keep no change log); what the cursor saves is the wire, the
//! relay and the page's decode and redraw of every unchanged row.

use std::collections::hash_map::DefaultHasher;
use std::collections::{HashMap, HashSet, VecDeque};
use std::hash::{Hash, Hasher};
use std::sync::{Mutex, PoisonError};

use serde_json::{Map, Value, json};

/// Windows kept for a cursor: one per open reader and query, with room to
/// spare (a page's query changes as it is typed into).
const KEPT: usize = 16;

/// The answers this daemon run gave, by cursor.
pub(crate) struct Follows {
    epoch: String,
    state: Mutex<FollowState>,
}

#[derive(Default)]
struct FollowState {
    next: u64,
    windows: VecDeque<Window>,
}

struct Window {
    number: u64,
    query: u64,
    ids: Vec<String>,
    prints: HashMap<String, u64>,
}

/// What a list answers: every entry, or a delta over the cursor's window.
pub(super) struct Answer {
    pub(super) entries: Vec<Value>,
    pub(super) follow: String,
    pub(super) delta: Option<Value>,
}

impl Default for Follows {
    fn default() -> Self {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| since.as_nanos());
        Self {
            epoch: format!("{:x}{:x}", nanos, std::process::id()),
            state: Mutex::new(FollowState::default()),
        }
    }
}

impl Follows {
    /// Answers `rows` (the whole window of `fields`' query, in order) for a
    /// reader that sent `after`: a delta over the window it holds when the
    /// cursor names one of this query, else every row.
    pub(super) fn answer(
        &self,
        fields: &Map<String, Value>,
        after: Option<&str>,
        rows: Vec<Value>,
    ) -> Answer {
        let query = query_key(fields);
        let ids: Vec<String> = rows.iter().map(|row| id_of(row).to_owned()).collect();
        let prints: HashMap<String, u64> =
            rows.iter().map(|row| (id_of(row).to_owned(), print(row))).collect();
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let held = after
            .and_then(|cursor| self.number_of(cursor))
            .and_then(|number| state.windows.iter().find(|window| window.number == number))
            .filter(|window| window.query == query);
        let delta = held.and_then(|window| delta(window, &ids, &prints));
        state.next += 1;
        let number = state.next;
        state.windows.push_back(Window { number, query, ids, prints });
        while state.windows.len() > KEPT {
            state.windows.pop_front();
        }
        drop(state);
        let follow = format!("{}.{number}", self.epoch);
        match delta {
            None => Answer { entries: rows, follow, delta: None },
            Some((changed, removed)) => {
                let at: Vec<usize> = changed.clone();
                let mut rows = rows.into_iter().map(Some).collect::<Vec<_>>();
                let entries = changed.iter().filter_map(|index| rows[*index].take()).collect();
                Answer { entries, follow, delta: Some(json!({"removed": removed, "at": at})) }
            }
        }
    }

    /// The answer number of a cursor of this daemon run.
    fn number_of(&self, cursor: &str) -> Option<u64> {
        let (epoch, number) = cursor.rsplit_once('.')?;
        if epoch != self.epoch {
            return None;
        }
        number.parse().ok()
    }
}

/// The new window's changed indices (each entry that came or whose wire JSON
/// differs) and the held ids that left, when applying them to the held window
/// gives the new one and the change is under half the window; else none (the
/// reader gets every entry).
fn delta(
    held: &Window,
    ids: &[String],
    prints: &HashMap<String, u64>,
) -> Option<(Vec<usize>, Vec<String>)> {
    let changed: Vec<usize> = ids
        .iter()
        .enumerate()
        .filter(|(_, id)| held.prints.get(*id) != prints.get(*id))
        .map(|(index, _)| index)
        .collect();
    let removed: Vec<String> =
        held.ids.iter().filter(|id| !prints.contains_key(*id)).cloned().collect();
    if (changed.len() + removed.len()) * 2 > ids.len().max(1) {
        return None;
    }
    // The rows kept as they were must keep their order: the reader only
    // drops and inserts. The list's order (at_ms, then id) keeps them so;
    // this proves it for each answer.
    let touched: HashSet<&str> = changed.iter().map(|index| ids[*index].as_str()).collect();
    let kept_before =
        held.ids.iter().filter(|id| prints.contains_key(*id) && !touched.contains(id.as_str()));
    let kept_after = ids.iter().filter(|id| !touched.contains(id.as_str()));
    if !kept_before.eq(kept_after) {
        return None;
    }
    Some((changed, removed))
}

fn id_of(row: &Value) -> &str {
    row.get("id").and_then(Value::as_str).unwrap_or("")
}

fn print(row: &Value) -> u64 {
    let mut hasher = DefaultHasher::new();
    row.to_string().hash(&mut hasher);
    hasher.finish()
}

/// The query a cursor belongs to: every field but the cursor itself.
fn query_key(fields: &Map<String, Value>) -> u64 {
    let mut hasher = DefaultHasher::new();
    for (key, value) in fields {
        if key != "follow" {
            key.hash(&mut hasher);
            value.to_string().hash(&mut hasher);
        }
    }
    hasher.finish()
}

#[cfg(test)]
#[path = "follow_tests.rs"]
mod tests;
