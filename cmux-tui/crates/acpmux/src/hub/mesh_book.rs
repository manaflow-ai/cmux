//! Part of `Hub`; see `hub/mod.rs`. The same person's other machines that reach this daemon
//! through the mesh hub, and their sessions, from the hub's address book (`GET /v1/mesh/sessions`,
//! read after each heartbeat the hub takes, `server/mesh_relay.rs`). Their rows join the session
//! list, `watch`, `resolve` and `peers` as an ssh peer's do, marked `via: "hub"`, so the app lists a
//! joined machine's chats and opens one; the open reads it through the hub (`server/mesh_read.rs`).
//! They are kept apart from the ssh peers' rows (`remote_sessions`): a send or read that names one
//! is still the hub's to route (`Hub::mesh_may_route`), and an ssh peer's host is never listed twice.

use super::*;
use crate::mesh::{AddressBook, BookSession};
use std::collections::BTreeMap;

/// The most hub rows kept: a person's machines list far fewer, and the list stays bounded.
const MAX_BOOK_ROWS: usize = 2048;

#[derive(Default)]
pub(crate) struct MeshBook {
    /// `HOST/ID` to the hub's fields of it (`row_of`) and its row.
    rows: BTreeMap<String, (Value, Arc<RemoteSession>)>,
    /// Each machine listed, with its newest heartbeat (ms since the epoch).
    hosts: BTreeMap<String, u64>,
}

/// The machines and sessions of `book` this daemon lists: those of the same person (`own_user`)
/// on another daemon (not `own_daemon`), another host than this one, and not a host `skip` names
/// (an ssh peer, whose own rows list it).
pub(crate) fn mine(
    book: AddressBook,
    own_user: &str,
    own_daemon: Option<&str>,
    skip: &dyn Fn(&str) -> bool,
) -> (BTreeMap<String, u64>, Vec<BookSession>) {
    let mut hosts = BTreeMap::new();
    let mut daemons = std::collections::HashSet::new();
    for d in book.daemons {
        if own_user.is_empty()
            || d.user != own_user
            || d.host.is_empty()
            || own_daemon == Some(d.daemon_id.as_str())
            || super::mesh_rows::is_own_host(&d.host)
            || skip(&d.host)
        {
            continue;
        }
        let seen = hosts.entry(d.host.clone()).or_insert(0);
        *seen = (*seen).max(d.last_seen_at);
        daemons.insert(d.daemon_id);
    }
    let sessions = book
        .sessions
        .into_iter()
        .filter(|s| daemons.contains(&s.daemon_id) && hosts.contains_key(&s.host))
        .filter(|s| !s.session_id.is_empty() && !s.session_id.contains('/'))
        .take(MAX_BOOK_ROWS)
        .collect();
    (hosts, sessions)
}

/// A hub session's row before `remote_summary` names it for its host. `updatedAt` is when this
/// daemon first saw it as it is now, so a heartbeat that changes nothing changes no row.
fn row_of(s: &BookSession) -> Value {
    json!({
        "sessionId": s.session_id,
        "name": s.name,
        "harness": s.harness,
        "status": s.state,
        "via": "hub",
        "stale": false,
    })
}

impl Hub {
    /// Read the address book's rows of this person's other machines into the list
    /// (`mesh_book::mine`).
    pub(crate) fn apply_mesh_book(
        &self,
        book: AddressBook,
        own_user: &str,
        own_daemon: Option<&str>,
    ) {
        let ssh: std::collections::HashSet<String> =
            self.peers.lock().unwrap_or_else(|e| e.into_inner()).keys().cloned().collect();
        let (hosts, sessions) = mine(book, own_user, own_daemon, &|host| ssh.contains(host));
        self.set_mesh_book(hosts, sessions);
    }

    /// Replace the hub rows: watching clients hear each one that appeared, changed or left, and
    /// the shared list is rebuilt once (`list_guard.rs`). Empty when the relay stops.
    pub(crate) fn set_mesh_book(&self, hosts: BTreeMap<String, u64>, sessions: Vec<BookSession>) {
        let now = now_ms();
        let (gone, changed, moved) = {
            let mut book = self.mesh_book.lock().unwrap_or_else(|e| e.into_inner());
            let mut rows = BTreeMap::new();
            let mut changed = Vec::new();
            for s in &sessions {
                let key = format!("{}/{}", s.host, s.session_id);
                let bare = row_of(s);
                let old = book.rows.get(&key).filter(|(was, _)| *was == bare);
                let row = match old {
                    Some((_, old)) => old.clone(),
                    None => {
                        let mut fields = bare.clone();
                        fields.set("updatedAt", json!(now));
                        let summary = Self::remote_summary(&s.host, fields);
                        changed.push((s.host.clone(), summary.clone()));
                        Arc::new(RemoteSession {
                            peer: s.host.clone(),
                            summary,
                            receipt: SessionReceipt::new(&s.host, &s.session_id, None, 0),
                        })
                    }
                };
                rows.insert(key, (bare, row));
            }
            let gone: Vec<(String, Value)> = book
                .rows
                .iter()
                .filter(|(key, _)| !rows.contains_key(*key))
                .map(|(_, (_, r))| (r.peer.clone(), r.summary.clone()))
                .collect();
            let moved = book.hosts != hosts;
            book.rows = rows;
            book.hosts = hosts;
            (gone, changed, moved)
        };
        if !gone.is_empty() || !changed.is_empty() || moved {
            self.remote_sessions.lock().unwrap_or_else(|e| e.into_inner()).writes += 1;
        }
        for (peer, summary) in gone {
            self.announce_remote(&peer, summary, "purged");
        }
        for (peer, summary) in changed {
            self.announce_remote(&peer, summary, "status");
        }
    }

    /// The hub rows `keep` takes, cloning no other.
    pub(super) fn mesh_book_rows(
        &self,
        keep: impl Fn(&RemoteSession) -> bool,
    ) -> Vec<Arc<RemoteSession>> {
        let book = self.mesh_book.lock().unwrap_or_else(|e| e.into_inner());
        book.rows.values().map(|(_, r)| r).filter(|r| keep(r)).cloned().collect()
    }

    /// The machines the hub lists for this person, as `peers` lists an ssh peer: connected, with
    /// their session count and newest heartbeat.
    pub(super) fn mesh_book_hosts(&self) -> Vec<Value> {
        let book = self.mesh_book.lock().unwrap_or_else(|e| e.into_inner());
        book.hosts
            .iter()
            .map(|(host, seen)| {
                let count = book.rows.values().filter(|(_, r)| &r.peer == host).count();
                json!({
                    "name": host,
                    "connected": true,
                    "state": "connected",
                    "via": "hub",
                    "lastSeen": seen,
                    "sessions": count,
                })
            })
            .collect()
    }

    /// The machine whose hub row has session id `id`, when one only has it: the app opens a
    /// listed chat by its bare id.
    pub(crate) fn mesh_book_host(&self, id: &str) -> Option<String> {
        let book = self.mesh_book.lock().unwrap_or_else(|e| e.into_inner());
        let mut hosts = book
            .rows
            .values()
            .map(|(_, r)| r)
            .filter(|r| r.receipt.mux_session_id == id)
            .map(|r| &r.peer);
        let host = hosts.next()?.clone();
        hosts.next().is_none().then_some(host)
    }
}

#[cfg(test)]
#[path = "mesh_book_tests.rs"]
mod tests;
