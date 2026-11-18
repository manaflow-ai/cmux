//! The TUI's session rows with a version: every write gives the list a new one, so what is built
//! from the rows (the sidebar's grouped list, `render/sidebar.rs`) is built again only after the
//! rows changed, not on every frame. A row set, inserted or removed is also logged, so a reader
//! can follow one changed row instead of reading every row again.

use serde_json::Value;
use std::collections::VecDeque;
use std::ops::{Deref, DerefMut, Index, IndexMut};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_VERSION: AtomicU64 = AtomicU64::new(1);

fn next_version() -> u64 {
    NEXT_VERSION.fetch_add(1, Ordering::Relaxed)
}

/// Changes a reader can follow past: more than this many and it reads the rows again.
const LOGGED: usize = 256;

/// One logged write, by row index at the time it was made.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Change {
    Set(usize),
    Insert(usize),
    Remove(usize),
}

/// The session rows, newest first. Reads go through `Deref`. `push`, `insert`, `remove` and a
/// row borrowed through `IndexMut` are logged; any other mutable borrow (a sort, a retain, a
/// whole new list) clears the log. Every write takes a new version, and a version is never
/// reused, even by a list that replaces this one.
#[derive(Debug, Clone)]
pub struct Sessions {
    rows: Vec<Value>,
    version: u64,
    /// The version before the oldest logged change.
    base: u64,
    log: VecDeque<(u64, Change)>,
}

impl Sessions {
    /// Changes whenever the rows may have changed; equal versions mean equal rows.
    pub fn version(&self) -> u64 {
        self.version
    }

    /// The writes since `version`, oldest first, when they are all logged.
    pub(crate) fn changes_since(&self, version: u64) -> Option<impl Iterator<Item = Change> + '_> {
        let skip = if version == self.base {
            0
        } else {
            self.log.iter().position(|(v, _)| *v == version)? + 1
        };
        Some(self.log.iter().skip(skip).map(|(_, c)| *c))
    }

    fn record(&mut self, change: Change) {
        self.version = next_version();
        if self.log.len() == LOGGED
            && let Some((dropped, _)) = self.log.pop_front()
        {
            self.base = dropped;
        }
        self.log.push_back((self.version, change));
    }

    pub fn push(&mut self, row: Value) {
        self.rows.push(row);
        self.record(Change::Insert(self.rows.len() - 1));
    }

    pub fn insert(&mut self, at: usize, row: Value) {
        self.rows.insert(at, row);
        self.record(Change::Insert(at));
    }

    pub fn remove(&mut self, at: usize) -> Value {
        let row = self.rows.remove(at);
        self.record(Change::Remove(at));
        row
    }
}

impl Default for Sessions {
    fn default() -> Self {
        Vec::new().into()
    }
}

impl From<Vec<Value>> for Sessions {
    fn from(rows: Vec<Value>) -> Self {
        let version = next_version();
        Sessions { rows, version, base: version, log: VecDeque::new() }
    }
}

impl Deref for Sessions {
    type Target = Vec<Value>;
    fn deref(&self) -> &Vec<Value> {
        &self.rows
    }
}

impl DerefMut for Sessions {
    fn deref_mut(&mut self) -> &mut Vec<Value> {
        self.version = next_version();
        self.base = self.version;
        self.log.clear();
        &mut self.rows
    }
}

impl Index<usize> for Sessions {
    type Output = Value;
    fn index(&self, at: usize) -> &Value {
        &self.rows[at]
    }
}

impl IndexMut<usize> for Sessions {
    fn index_mut(&mut self, at: usize) -> &mut Value {
        self.record(Change::Set(at));
        &mut self.rows[at]
    }
}

impl<'a> IntoIterator for &'a Sessions {
    type Item = &'a Value;
    type IntoIter = std::slice::Iter<'a, Value>;
    fn into_iter(self) -> Self::IntoIter {
        self.rows.iter()
    }
}

impl PartialEq<Vec<Value>> for Sessions {
    fn eq(&self, other: &Vec<Value>) -> bool {
        self.rows == *other
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn every_write_takes_a_new_version_and_reads_keep_it() {
        let mut s: Sessions = vec![json!({"sessionId": "a"})].into();
        let v = s.version();
        assert_eq!(s.len(), 1);
        assert!(s.iter().any(|r| r["sessionId"] == "a"));
        assert_eq!(s[0]["sessionId"], "a");
        assert_eq!(s.version(), v, "a read changed the version");
        s[0]["status"] = json!("running");
        assert_ne!(s.version(), v, "a field write kept the version");
        let v = s.version();
        s.push(json!({"sessionId": "b"}));
        assert_ne!(s.version(), v, "a push kept the version");
        let replaced: Sessions = vec![json!({"sessionId": "a"})].into();
        assert_ne!(replaced.version(), s.version(), "a new list reused a version");
    }

    #[test]
    fn logged_writes_are_followed_and_others_are_not() {
        let mut s: Sessions = vec![json!(1), json!(2), json!(3)].into();
        let start = s.version();
        s[1] = json!(20);
        let row = s.remove(2);
        s.insert(0, row);
        s.push(json!(4));
        let changes: Vec<Change> = s.changes_since(start).unwrap().collect();
        assert_eq!(
            changes,
            [Change::Set(1), Change::Remove(2), Change::Insert(0), Change::Insert(3)]
        );
        let mid = s.version();
        assert_eq!(s.changes_since(mid).unwrap().count(), 0);
        s.sort_by_key(|v| v.as_u64());
        assert!(s.changes_since(mid).is_none(), "a sort was followed as logged writes");
        let after_sort = s.version();
        for i in 0..LOGGED + 1 {
            s.push(json!(i));
        }
        assert!(s.changes_since(after_sort).is_none(), "a dropped change was followed");
    }
}
