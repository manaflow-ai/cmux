//! A peer link's side of `_acpmux/session_patch` (`server/session_patch.rs`, version 2).
//!
//! The link asks for patches in its `initialize` (`sessionChangedDelta: 2`). A peer that knows
//! version 2 then sends each chat's row whole once, as `session_changed` with a `rowSeq`, and
//! each change after it as a patch of the row before. This keeps the last row of each chat the
//! link heard whole or patched, makes every patch a whole row again, and hands the hub that row
//! as the `session_changed` it always read: nothing past the read loop knows patches exist.
//!
//! A patch that does not apply to what is held (its `baseRowSeq` is not the held row's, or the
//! row was let go here) is dropped with the row, and the link asks the peer for the row whole
//! (`_acpmux/session_resync`); the patches that come before it are dropped too, since the whole
//! row is newer than each. A peer before version 2 reads `2` as not asking and sends whole rows
//! with no `rowSeq`: they pass as they are and nothing is held.
//!
//! Why: the link got every change of every chat it attached whole, 37 to 77 KB a row with the
//! time breakdown and the tools, on every record of a running turn: 142 KiB a turn on a desktop
//! pair, idle or under duress (transport pair matrix, long cell, 2026-11-24).
//!
//! Bounded: at most [`MAX_ROWS`] chats' rows and [`MAX_BYTES`] of them (each counted as the
//! frame that made it, and each patch's frame added), past which the oldest are let go.

use crate::rpc::method;
use serde_json::Value;
use std::collections::{HashMap, HashSet, VecDeque};

/// What the link asks for in `initialize` `_meta.acpmux.sessionChangedDelta`.
pub(crate) const VERSION: u64 = crate::server::session_patch::VERSION;

/// The most chats whose row one link holds: the peer keeps as many (`session_patch::MAX_ROWS`).
pub(crate) const MAX_ROWS: usize = crate::server::session_patch::MAX_ROWS;

/// The most bytes of rows one link holds.
pub(crate) const MAX_BYTES: usize = 32 << 20;

#[derive(Debug)]
struct Held {
    /// When it was held whole, in [`HeldRows::order`].
    stamp: u64,
    row_seq: u64,
    row: Value,
    bytes: usize,
}

/// One link's rows, from its open to its end: the peer forgets what it sent at each `initialize`.
#[derive(Debug, Default)]
pub(crate) struct HeldRows {
    rows: HashMap<String, Held>,
    /// Oldest first, each with its stamp: an entry whose row was held again since (another
    /// stamp) or let go is stale and skipped.
    order: VecDeque<(String, u64)>,
    stamps: u64,
    bytes: usize,
    /// The chats the link asked the peer to resend whole: asked once until it comes.
    resyncing: HashSet<String>,
}

/// What one notice is once read.
#[derive(Debug, PartialEq)]
pub(crate) enum Read {
    /// Pass it on as it came.
    Pass,
    /// A patch made whole: it is now a `session_changed` with the row in `session`.
    Changed,
    /// Drop it. `Some(id)`: ask the peer for that chat's row whole.
    Drop(Option<String>),
}

impl HeldRows {
    /// Reads one notice `m` with `p` (its params), `bytes` its frame's length. A patch that
    /// applies becomes the `session_changed` it stands for, in `p`.
    pub(crate) fn read(&mut self, m: &str, p: &mut Value, bytes: usize) -> Read {
        if m == method::MUX_SESSION_CHANGED {
            self.whole(p, bytes);
            return Read::Pass;
        }
        if m != method::MUX_SESSION_PATCH {
            return Read::Pass;
        }
        let Some(id) = p.get("sessionId").and_then(Value::as_str).map(str::to_owned) else {
            return Read::Drop(None);
        };
        let base = p.get("baseRowSeq").and_then(Value::as_u64);
        let row_seq = p.get("rowSeq").and_then(Value::as_u64);
        let patch = p.as_object_mut().and_then(|o| o.remove("patch"));
        let applied = match (self.rows.get_mut(&id), base, row_seq, patch) {
            (Some(held), Some(base), Some(row_seq), Some(patch)) if held.row_seq == base => {
                crate::server::session_patch::apply(&mut held.row, &patch).then(|| {
                    held.row_seq = row_seq;
                    held.bytes += bytes;
                    held.row.clone()
                })
            }
            _ => None,
        };
        let Some(row) = applied else {
            self.let_go(&id);
            // Asked once; the whole row it brings is newer than every patch until then.
            return Read::Drop(self.resyncing.insert(id.clone()).then_some(id));
        };
        self.bytes += bytes;
        if let Some(o) = p.as_object_mut() {
            o.remove("baseRowSeq");
            o.insert("session".into(), row);
        }
        self.trim(&id);
        Read::Changed
    }

    /// A whole row: held when it has a `rowSeq` (the peer sends patches of it next).
    fn whole(&mut self, p: &Value, bytes: usize) {
        let Some(id) = p.get("sessionId").and_then(Value::as_str) else { return };
        if p.get("kind").and_then(Value::as_str) == Some("purged") {
            self.let_go(id);
            self.resyncing.remove(id);
            return;
        }
        let (Some(row_seq), Some(row)) =
            (p.get("rowSeq").and_then(Value::as_u64), p.get("session").filter(|s| s.is_object()))
        else {
            return;
        };
        self.let_go(id);
        self.resyncing.remove(id);
        self.stamps += 1;
        let stamp = self.stamps;
        self.rows.insert(id.to_owned(), Held { stamp, row_seq, row: row.clone(), bytes });
        self.order.push_back((id.to_owned(), stamp));
        self.bytes += bytes;
        self.trim(id);
    }

    fn let_go(&mut self, id: &str) {
        if let Some(gone) = self.rows.remove(id) {
            self.bytes -= gone.bytes;
        }
    }

    /// Lets the oldest rows go past the bounds, `keep` last.
    fn trim(&mut self, keep: &str) {
        while self.rows.len() > MAX_ROWS || self.bytes > MAX_BYTES {
            let Some((oldest, stamp)) = self.order.pop_front() else { break };
            if self.rows.get(&oldest).is_none_or(|held| held.stamp != stamp) {
                continue;
            }
            if oldest == keep && self.rows.len() > 1 {
                self.order.push_back((oldest, stamp));
                continue;
            }
            self.let_go(&oldest);
        }
        // Rows held again or let go leave stale entries; keep the queue near the rows' count.
        if self.order.len() > 2 * MAX_ROWS {
            let rows = &self.rows;
            self.order.retain(|(id, stamp)| rows.get(id).is_some_and(|held| held.stamp == *stamp));
        }
    }

    #[cfg(test)]
    pub(crate) fn held(&self, id: &str) -> Option<(u64, &Value)> {
        self.rows.get(id).map(|h| (h.row_seq, &h.row))
    }

    #[cfg(test)]
    pub(crate) fn bytes(&self) -> usize {
        self.bytes
    }
}

#[cfg(test)]
#[path = "peer_row_patch_tests.rs"]
mod tests;
