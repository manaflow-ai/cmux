//! Part of `Hub`; see `hub/mod.rs`. The rows peers list (`Hub::remote_sessions`), with their
//! `(mux.parent, mux.handle)` tags indexed by every write, so an approval card names a peer's
//! child by reading only the rows of that pair (`permissions/display.rs`), never all of them.
//! Reads go through `Deref`; every write goes through the methods here, which keep the index.

use super::*;

#[derive(Default)]
pub(crate) struct RemoteRows {
    rows: HashMap<String, RemoteSession>,
    by_pair: HashMap<(String, String), std::collections::BTreeSet<String>>,
}

impl std::ops::Deref for RemoteRows {
    type Target = HashMap<String, RemoteSession>;
    fn deref(&self) -> &Self::Target {
        &self.rows
    }
}

impl RemoteRows {
    pub(crate) fn insert(&mut self, key: String, row: RemoteSession) {
        self.remove(&key);
        if let Some(pair) = pair_of(&row.summary) {
            self.by_pair.entry(pair).or_default().insert(key.clone());
        }
        self.rows.insert(key, row);
    }

    pub(crate) fn remove(&mut self, key: &str) -> Option<RemoteSession> {
        let row = self.rows.remove(key)?;
        if let Some(pair) = pair_of(&row.summary)
            && let Some(keys) = self.by_pair.get_mut(&pair)
        {
            keys.remove(key);
            if keys.is_empty() {
                self.by_pair.remove(&pair);
            }
        }
        Some(row)
    }

    pub(crate) fn retain(&mut self, mut keep: impl FnMut(&String, &RemoteSession) -> bool) {
        let gone: Vec<String> =
            self.rows.iter().filter(|(k, r)| !keep(k, r)).map(|(k, _)| k.clone()).collect();
        for key in gone {
            self.remove(&key);
        }
    }

    /// Marks `peer`'s rows stale (`peer_cache::mark_stale`): the summaries that changed. Each row
    /// is taken out and put back through `insert`, so the index follows whatever the mark touched.
    /// There is no other way to change a row in place.
    pub(crate) fn mark_peer_stale(&mut self, peer: &str, last_seen: Option<u64>) -> Vec<Value> {
        let keys: Vec<String> =
            self.rows.iter().filter(|(_, r)| r.peer == peer).map(|(k, _)| k.clone()).collect();
        let mut changed = Vec::new();
        for key in keys {
            let Some(mut row) = self.remove(&key) else { continue };
            if super::peer_cache::mark_stale(&mut row.summary, last_seen) {
                changed.push(row.summary.clone());
            }
            self.insert(key, row);
        }
        changed
    }

    /// The rows tagged with `pair`.
    pub(crate) fn with_pair(
        &self,
        pair: &(String, String),
    ) -> impl Iterator<Item = &RemoteSession> {
        self.by_pair.get(pair).into_iter().flatten().filter_map(|key| self.rows.get(key))
    }

    /// How many pairs the index holds.
    #[cfg(test)]
    pub(crate) fn pairs(&self) -> usize {
        self.by_pair.len()
    }
}

/// A row's `(mux.parent, mux.handle)` tags, as its summary lists them.
fn pair_of(summary: &Value) -> Option<(String, String)> {
    let tags = summary.get("tags")?;
    let tag = |key: &str| {
        tags.get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(str::to_owned)
    };
    Some((tag("mux.parent")?, tag("mux.handle")?))
}
