//! `notification-ledger-delta-v1`: `list-notifications` with `since` answers
//! only the rows that changed since the reply a client holds, so a client
//! applies one changed row in O(changed) rather than reading the whole ledger
//! (up to 256 rows) on every notification (ask-1105ee4cc6).
//!
//! The log diffs each answer's rows against the previous answer's, not the
//! ledger's mutations: a row also shows state the ledger does not hold (its
//! terminal's placement, the acknowledgement, the question its agent waits
//! on), and every such change reaches the next answer without a hook in each
//! writer. The diff is O(rows) in the daemon, off every client's main thread.

use std::collections::{BTreeSet, HashMap, VecDeque};

use serde_json::{Value, json};

use super::Mux;

/// `since` on `list-notifications` and `version` on its reply.
pub const NOTIFICATION_LEDGER_DELTA_CAPABILITY: &str = "notification-ledger-delta-v1";

/// Versions the log keeps; a `since` older than these gets the whole ledger.
const LOGGED_VERSIONS: usize = 64;

/// One version's change: ids whose row is new or changed, ids that left.
struct Change {
    version: u64,
    upserted: Vec<String>,
    removed: Vec<String>,
}

/// The rows of the last answer and the changes of the last `LOGGED_VERSIONS` versions.
pub(crate) struct NotificationListLog {
    /// This daemon run's name in `version`, so a token from another run reads as too old.
    epoch: String,
    version: u64,
    /// The last answer's rows, newest first, and each id's index there.
    rows: Vec<Value>,
    index: HashMap<String, usize>,
    changes: VecDeque<Change>,
}

impl Default for NotificationListLog {
    fn default() -> Self {
        let epoch = crate::workspace_registry::new_uuid_v4().chars().take(8).collect();
        Self {
            epoch,
            version: 0,
            rows: Vec::new(),
            index: HashMap::new(),
            changes: VecDeque::new(),
        }
    }
}

fn row_id(row: &Value) -> Option<&str> {
    row.get("id").and_then(Value::as_str)
}

impl NotificationListLog {
    /// The opaque version token of the rows recorded last.
    pub(crate) fn token(&self) -> String {
        format!("{}.{}", self.epoch, self.version)
    }

    /// Records `rows` (the whole ledger, newest first) as the current answer;
    /// a new version when any row differs from the last answer's.
    pub(crate) fn record(&mut self, rows: Vec<Value>) {
        let index: HashMap<String, usize> = rows
            .iter()
            .enumerate()
            .filter_map(|(i, row)| row_id(row).map(|id| (id.to_string(), i)))
            .collect();
        let upserted: Vec<String> = rows
            .iter()
            .filter_map(|row| {
                let id = row_id(row)?;
                let same = self.index.get(id).is_some_and(|&old| self.rows[old] == *row);
                (!same).then(|| id.to_string())
            })
            .collect();
        let removed: Vec<String> =
            self.index.keys().filter(|id| !index.contains_key(*id)).cloned().collect();
        self.rows = rows;
        self.index = index;
        if upserted.is_empty() && removed.is_empty() {
            return;
        }
        self.version += 1;
        self.changes.push_back(Change { version: self.version, upserted, removed });
        while self.changes.len() > LOGGED_VERSIONS {
            self.changes.pop_front();
        }
    }

    /// The whole answer: every row and its version.
    pub(crate) fn whole(&self) -> Value {
        json!({ "notifications": self.rows, "version": self.token() })
    }

    /// The rows changed since `since` (newest first) and the ids that left;
    /// None when `since` is not a version this log reaches back to (another
    /// daemon run's, newer than this one's, or older than the log keeps).
    pub(crate) fn since(&self, since: &str) -> Option<(Vec<Value>, Vec<String>)> {
        let (epoch, version) = since.rsplit_once('.')?;
        let version: u64 = version.parse().ok()?;
        if epoch != self.epoch || version > self.version {
            return None;
        }
        if version == self.version {
            return Some((Vec::new(), Vec::new()));
        }
        // The log reaches `version` when it holds every change after it.
        if self.changes.front().is_none_or(|first| first.version > version + 1) {
            return None;
        }
        let mut upserted = BTreeSet::new();
        let mut removed = BTreeSet::new();
        for change in self.changes.iter().filter(|change| change.version > version) {
            for id in &change.upserted {
                removed.remove(id);
                upserted.insert(id.clone());
            }
            for id in &change.removed {
                upserted.remove(id);
                removed.insert(id.clone());
            }
        }
        let mut indices: Vec<usize> =
            upserted.iter().filter_map(|id| self.index.get(id).copied()).collect();
        indices.sort_unstable();
        let rows = indices.into_iter().map(|i| self.rows[i].clone()).collect();
        Some((rows, removed.into_iter().collect()))
    }

    /// The reply to `list-notifications` with `since` after recording `rows`:
    /// `{notifications, version}` whole, or `{delta: true, notifications,
    /// removed, version}` with only the rows changed since it.
    pub(crate) fn answer(&mut self, rows: Vec<Value>, since: Option<&str>) -> Value {
        self.record(rows);
        match since.and_then(|since| self.since(since)) {
            Some((rows, removed)) => json!({
                "delta": true,
                "notifications": rows,
                "removed": removed,
                "version": self.token(),
            }),
            None => self.whole(),
        }
    }
}

impl Mux {
    /// `list-notifications` over the whole ledger with its version: `rows`
    /// builds every row, newest first, under the log's lock, so two answers
    /// never record out of order.
    pub(crate) fn notification_list_answer(
        &self,
        since: Option<&str>,
        rows: impl FnOnce() -> anyhow::Result<Vec<Value>>,
    ) -> anyhow::Result<Value> {
        let mut log = self.notification_list_log.lock().unwrap_or_else(|e| e.into_inner());
        let rows = rows()?;
        Ok(log.answer(rows, since))
    }
}

#[cfg(test)]
#[path = "notification_list_log_tests.rs"]
mod tests;
