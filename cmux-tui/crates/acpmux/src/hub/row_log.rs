//! Part of `Hub`; see `hub/mod.rs`. The session list as a row log with a cursor
//! (cmuxterm-hq `docs/design/acpmux-session-list-row-log.md`). Leo, 2026-11-12: "it's
//! unacceptable to be having so many of these connectivity issues".
//!
//! Every change a watcher hears of as `_acpmux/session_changed` takes the next list position
//! (`listSeq`), stamped and broadcast under one lock, so positions go out in their order. The log
//! keeps each row's last position and the rows that went (to a bound), never a row's bytes: a
//! follow builds the rows it names when it is read, so it is as current as a whole list.
//!
//! A client keeps the highest `listSeq` it applied. A watch with `afterSeq` (and the daemon run's
//! `listEpoch`) is answered with the rows changed and removed since, not the list: its cost is the
//! changes, whatever the list's size. A cursor from another run, or older than the oldest removal
//! the log still holds, is answered `reset` and the client reads the list's first page again.

use super::*;
use std::collections::{BTreeMap, HashMap};

/// The `initialize` capability of a daemon that stamps `listSeq` and answers `afterSeq`.
pub const CAPABILITY: &str = "session-list-follow-v1";

/// Removals the log holds before the oldest is dropped (and the cursors before it reset).
const GONE_MOST: usize = 50_000;

/// A list row: one of this daemon's sessions, or a peer's (its peer, and the peer's own id).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(crate) enum RowKey {
    Own(String),
    Peer { peer: String, mux: String },
}

/// Each row's last position and the rows that went since the floor.
#[derive(Default)]
pub(crate) struct RowLog {
    head: u64,
    at: HashMap<RowKey, u64>,
    live: BTreeMap<u64, RowKey>,
    gone: BTreeMap<u64, RowKey>,
    /// The newest removal dropped: a cursor below it may have missed one.
    floor: u64,
}

/// What changed after a cursor, in position order: each row's key, whether it went, and its
/// position.
pub(crate) struct Since {
    pub(crate) head: u64,
    pub(crate) rows: Vec<(u64, RowKey, bool)>,
}

impl RowLog {
    /// `key` changed (or went, `gone`): its next position.
    pub(crate) fn stamp(&mut self, key: RowKey, gone: bool) -> u64 {
        self.head += 1;
        let seq = self.head;
        if let Some(old) = self.at.insert(key.clone(), seq) {
            self.live.remove(&old);
            self.gone.remove(&old);
        }
        if gone {
            self.gone.insert(seq, key);
            while self.gone.len() > GONE_MOST {
                let Some((dropped, key)) = self.gone.pop_first() else { break };
                self.at.remove(&key);
                self.floor = dropped;
            }
        } else {
            self.live.insert(seq, key);
        }
        seq
    }

    /// A change that may reach rows it does not name (a parent's tags fold its children): no
    /// cursor before it can be followed, so each reads the list again (`reset`).
    pub(crate) fn floor_all(&mut self) {
        self.floor = self.floor.max(self.head);
    }

    pub(crate) fn head(&self) -> u64 {
        self.head
    }

    /// The rows changed after `after`; None when the log cannot say (a cursor below the floor,
    /// or past the head: one from another run).
    pub(crate) fn since(&self, after: u64) -> Option<Since> {
        if after < self.floor || after > self.head {
            return None;
        }
        let from = after.saturating_add(1);
        let live = self.live.range(from..).map(|(seq, key)| (*seq, key.clone(), false));
        let gone = self.gone.range(from..).map(|(seq, key)| (*seq, key.clone(), true));
        let mut rows: Vec<_> = live.chain(gone).collect();
        rows.sort_unstable_by_key(|(seq, _, _)| *seq);
        Some(Since { head: self.head, rows })
    }

    /// How many rows and removals it holds.
    #[cfg(test)]
    pub(crate) fn len(&self) -> (usize, usize) {
        (self.live.len(), self.gone.len())
    }
}

/// The row `ev` changes in a watcher's list, and whether it goes: exactly the events
/// `server::deliver` sends a `session_changed` for.
pub(super) fn row_change(ev: &HubEvent) -> Option<(RowKey, bool)> {
    let rec = &ev.record;
    if rec.kind == PEER_LAGGED {
        return None;
    }
    if let Some(remote) = &ev.remote {
        if rec.dir != "peer" || rec.kind == PEER_PERMISSION_PENDING {
            return None;
        }
        let key = RowKey::Peer { peer: remote.peer.clone(), mux: ev.session_id.clone() };
        return Some((key, rec.kind == "purged"));
    }
    let own = || RowKey::Own(ev.session_id.clone());
    if rec.dir == super::cold_archive::COLD_CHANGED {
        return Some((own(), false));
    }
    if rec.dir == "mux" && rec.kind == "purged" {
        // `replaced`: the same chat came back under this id; its row stays.
        let replaced = rec.msg.get("replaced") == Some(&Value::Bool(true));
        return Some((own(), !replaced));
    }
    if rec.dir != "mux" && rec.kind != "available_commands_update" {
        return None;
    }
    crate::server::session_change_kind(&rec.kind).map(|_| (own(), false))
}

/// A random id for this daemon run's list positions.
pub(super) fn new_epoch() -> String {
    uuid::Uuid::now_v7().simple().to_string()
}

/// A follow's reply: the rows changed after the cursor, built now, and the ids removed, in
/// position order and cut to `budget` bytes; `listSeq` is the position it covers to (the head, or
/// the last row it holds when cut, with `more`).
pub(crate) struct Follow {
    pub(crate) text: String,
}

impl Hub {
    /// The newest list position and this run's epoch.
    pub(crate) fn list_cursor(&self) -> (u64, &str) {
        (self.events.list_head(), self.events.list_epoch())
    }

    /// The reply to `_acpmux/watch {afterSeq: after}` of a list that holds this daemon's own rows
    /// only (`own_only`, a peer's link) or the peers' too, with tools when `tools`. None: `after`
    /// is not a cursor this log can follow (reset).
    pub(crate) fn list_follow(
        &self,
        after: u64,
        own_only: bool,
        tools: bool,
        budget: usize,
    ) -> Option<Follow> {
        let since = self.events.list_since(after)?;
        let mut sessions: Vec<String> = Vec::new();
        let mut removed: Vec<Value> = Vec::new();
        let (mut used, mut covered, mut more) = (64_usize, since.head, false);
        let remote = self.remote_sessions.snapshot();
        let states = if own_only { HashMap::new() } else { self.peer_link_states() };
        for (seq, key, gone) in since.rows {
            let row = match (&key, gone) {
                (RowKey::Peer { .. }, _) if own_only => continue,
                (_, true) => None,
                (RowKey::Own(id), false) => self.resolve(id).ok().map(|s| {
                    let row = if tools {
                        self.session_summary(&s)
                    } else {
                        self.session_list_summary(&s)
                    };
                    row.to_string()
                }),
                (RowKey::Peer { peer, mux }, false) => {
                    let held = remote.find_mux(peer, mux).map(|(_, r)| r.clone());
                    // A row of this person's other machines lives in the mesh book, not the
                    // peers' rows (`mesh_book.rs`), as a whole list reads it too.
                    let held = held.or_else(|| {
                        let mine =
                            |r: &RemoteSession| r.peer == *peer && r.receipt.mux_session_id == *mux;
                        self.mesh_book_rows(mine).into_iter().next()
                    });
                    // The row's own text, not parsed (`peer_row.rs`).
                    held.map(|r| super::peers::listed_remote_text(&r, &states, tools))
                }
            };
            let (text, removal) = match row {
                Some(row) => (row, None),
                None => {
                    let removal = match &key {
                        RowKey::Own(id) => json!({"sessionId": id}),
                        RowKey::Peer { peer, mux } => json!({"sessionId": mux, "peer": peer}),
                    };
                    (removal.to_string(), Some(removal))
                }
            };
            let next = used.saturating_add(text.len()).saturating_add(1);
            if next > budget && (!sessions.is_empty() || !removed.is_empty()) {
                more = true;
                break;
            }
            used = next;
            covered = seq;
            match removal {
                Some(removal) => removed.push(removal),
                None => sessions.push(text),
            }
        }
        if !more {
            covered = since.head;
        } else if own_only {
            // A peer's link reads one reply in its handshake (`peer.rs` `first_watch`): changes
            // past a page are read as the whole list, in its pages, as on a first link.
            return None;
        }
        let removed = Value::Array(removed).to_string();
        let epoch = Value::String(self.events.list_epoch().to_owned()).to_string();
        let text = format!(
            "{{\"follow\":true,\"listEpoch\":{epoch},\"listSeq\":{covered},\"more\":{more},\"gone\":{removed},\"sessions\":[{}]}}",
            sessions.join(",")
        );
        Some(Follow { text })
    }
}

impl Hub {
    /// Sends a mux record of `kind` for `chat`, as a change of its row does.
    #[cfg(test)]
    pub(crate) fn row_changed_for_test(&self, chat: &str, kind: &str) {
        let _ = self.events.send(HubEvent {
            session_id: chat.to_owned(),
            record: Arc::new(EventRecord {
                seq: 0,
                at: now_ms(),
                dir: "mux".into(),
                kind: kind.into(),
                msg: json!({}),
                host_seq: None,
            }),
            remote: None,
            update_line: Default::default(),
            row: Default::default(),
            list_seq: 0,
        });
    }
}

/// `text`, a list reply's JSON object, with the list position it is current to, and `reset` when
/// it answers a cursor the log could not follow.
pub(crate) fn with_cursor(text: &str, head: u64, epoch: &str, reset: bool) -> String {
    let epoch = Value::String(epoch.to_owned()).to_string();
    let rest = text.strip_prefix('{').unwrap_or(text);
    let comma = if rest.trim_start().starts_with('}') { "" } else { "," };
    let reset = if reset { ",\"reset\":true" } else { "" };
    format!("{{\"listEpoch\":{epoch},\"listSeq\":{head}{reset}{comma}{rest}")
}

#[cfg(test)]
#[path = "row_log_tests.rs"]
mod tests;
