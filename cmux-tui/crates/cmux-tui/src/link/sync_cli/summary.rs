//! What a push answers: files written, unchanged and deleted, and what it left out.

use cmux_json::JsonSet as _;
use serde_json::json;

#[derive(Default)]
pub(in crate::link) struct Summary {
    pub(in crate::link) written: u64,
    pub(in crate::link) unchanged: u64,
    pub(in crate::link) deleted: u64,
    /// Files the machine changed since the last push, left as the machine has them.
    pub(in crate::link) kept: u64,
    /// Every path left out, named or not.
    pub(in crate::link) skipped: u64,
    pub(in crate::link) bytes: u64,
    /// The first [`super::skips::LISTED`] skipped paths, `[{path, kind, why}]`.
    pub(in crate::link) skipped_files: serde_json::Value,
    /// How many were skipped of each kind (`other`: counted, not named).
    pub(in crate::link) skipped_counts: serde_json::Value,
    /// The content-addressed store's part ([`super::store`]), when one was asked for.
    pub(in crate::link) store: Option<serde_json::Value>,
    /// Head links ([`super::push_head`]) the machine did not make, for nothing at their target
    /// yet: a head without them is not the folder's head.
    pub(in crate::link) head_links_short: u64,
}

impl Summary {
    pub(in crate::link) fn json(&self) -> serde_json::Value {
        let mut line = json!({
            "written": self.written,
            "unchanged": self.unchanged,
            "deleted": self.deleted,
            "kept": self.kept,
            "skipped": self.skipped,
            "bytes": self.bytes,
            "skipped_files": if self.skipped_files.is_null() { json!([]) } else { self.skipped_files.clone() },
            "skipped_counts": if self.skipped_counts.is_null() { json!({}) } else { self.skipped_counts.clone() },
        });
        if let Some(store) = &self.store {
            line.set("store", store.clone());
        }
        line
    }
}
