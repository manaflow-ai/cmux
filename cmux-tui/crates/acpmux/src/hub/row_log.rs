//! Part of `Hub`; see `hub/mod.rs`. The session list as a row log with a cursor
//! (cmuxterm-hq `docs/design/acpmux-session-list-row-log.md`). Leo, 2026-11-12: "it's
//! unacceptable to be having so many of these connectivity issues".
//!
//! Every change a watcher hears of as `_acpmux/session_changed` takes the next list position
//! (`listSeq`), stamped and broadcast under one lock, so positions go out in their order. The log
//! keeps each row's last position and the rows that went (to a bound), never a row's bytes: a
//! follow builds the rows it names when it is read, so it is as current as a whole list.
//!
//! A row change no record carries (a streamed chunk's preview, an attach) is stamped and told, as
//! `session_changed` of kind `row`, before a list position is read next; a record that reaches
//! other rows (a parent's tags fold its children) stamps and tells each of them too. So a cursor a
//! client took from any notice is past no change it was not sent (#42091). A change no record
//! carries that may reach any row (new usage thresholds) is a barrier: no cursor before it is
//! followed.
//!
//! A client keeps the highest `listSeq` it applied. A watch with `afterSeq` (and the daemon run's
//! `listEpoch`) is answered with the rows changed and removed since, not the list: its cost is the
//! changes, whatever the list's size. A cursor from another run, or older than the oldest removal
//! the log still holds, is answered `reset` and the client reads the list's first page again.

use super::*;
use std::collections::{BTreeMap, HashMap, HashSet};

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
    /// The newest removal dropped, or the last barrier: a cursor below it may have missed a change.
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
                // Never lower: a barrier may have raised it past the removal dropped.
                self.floor = self.floor.max(dropped);
            }
        } else {
            self.live.insert(seq, key);
        }
        seq
    }

    /// A change that may reach any row and names none (`Events::changed`): it takes a position of
    /// its own, and no cursor before it can be followed, so each reads the list again (`reset`).
    /// The reset's own `listSeq` is this position or later, which the log follows. A floor at the
    /// head without a position of its own let a client whose cursor was the head follow past it
    /// (#42091 F1).
    pub(crate) fn barrier(&mut self) {
        self.head += 1;
        self.floor = self.head;
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

/// The event that tells the watchers this daemon's row `session` changed with no record of its own
/// (`Events::tell_row`): `server::deliver` sends it as `session_changed` of kind `row`.
pub(super) fn row_event(session: &str) -> HubEvent {
    HubEvent {
        session_id: session.to_owned(),
        record: Arc::new(EventRecord {
            seq: 0,
            at: now_ms(),
            dir: super::cold_archive::COLD_CHANGED.into(),
            kind: "row".into(),
            msg: json!({}),
            host_seq: None,
        }),
        remote: None,
        update_line: Default::default(),
        row: Default::default(),
        list_seq: 0,
    }
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
    /// Notes the rows a record of `session` reaches besides its own
    /// (`list_guard::reaches_other_rows`): its parent's (a new child's count) and those of every
    /// session below it (a child folds under its parent, `Hub::spawned_by`; the lineage root walk
    /// goes through it). Each is stamped and told before the next list position is read
    /// ([`Self::tell_reached`]), after the record's own position. Before, such a record set a
    /// floor at its own position, and a client that applied its notice followed past the rows it
    /// changed and never named (#42091 F1, F2). Cheap here (an append holds its chat's lock): the
    /// walk is the list read's.
    pub(super) fn note_rows_reading(&self, session: &Session) {
        let parent = session.read_meta(|m| super::views::activity_parent_id(m).map(str::to_owned));
        self.events.reaches(&session.id, parent.filter(|parent| *parent != session.id));
    }

    /// Stamps and tells the rows the noted records reached ([`Self::note_rows_reading`]), then
    /// the rows changed with no notice: one walk of the sessions for all of them.
    fn tell_reached(&self) {
        let noted = self.events.take_reaching();
        if !noted.is_empty() {
            let mut children: HashMap<String, Vec<String>> = HashMap::new();
            for s in self.session_handles() {
                let parent =
                    s.read_meta(|m| super::views::activity_parent_id(m).map(str::to_owned));
                if let Some(parent) = parent.filter(|parent| *parent != s.id) {
                    children.entry(parent).or_default().push(s.id.clone());
                }
            }
            let mut seen = HashSet::new();
            for (id, parent) in noted {
                let mut below = vec![id.clone()];
                seen.insert(id);
                if let Some(parent) = parent
                    && seen.insert(parent.clone())
                {
                    self.events.tell_row(&parent);
                }
                while let Some(next) = below.pop() {
                    for child in children.get(&next).into_iter().flatten() {
                        if seen.insert(child.clone()) {
                            self.events.tell_row(child);
                            below.push(child.clone());
                        }
                    }
                }
            }
        }
    }

    /// A session came (made, forked, moved here): every closed row is built again, and its row and
    /// the rows that read it are told before the next list read: a child that came before its
    /// parent folds under it now.
    pub(super) fn session_came(&self, session: &Session) {
        self.events.all_rows_stale();
        self.events.row_changed(session);
        self.note_rows_reading(session);
    }

    /// The newest list position and this run's epoch.
    pub(crate) fn list_cursor(&self) -> (u64, &str) {
        self.tell_reached();
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
        self.tell_reached();
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
                    if tools { self.session_summary(&s) } else { self.session_list_summary(&s) }
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
                    held.map(|r| {
                        let summary = super::peers::listed_remote_row(&r, &states);
                        if tools { summary } else { super::views::without_summary_tools(summary) }
                    })
                }
            };
            let (text, removal) = match row {
                Some(row) => (row.to_string(), None),
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
