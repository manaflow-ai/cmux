//! Part of `Hub`; see `hub/mod.rs`. The same person's other machines that reach this daemon
//! through the mesh hub, and their sessions, from the hub's address book (`GET /v1/mesh/sessions`,
//! read after each heartbeat the hub takes, `server/mesh_relay.rs`). Their rows join the session
//! list, `watch`, `resolve` and `peers` as an ssh peer's do, marked `via: "hub"`, so the app lists a
//! joined machine's chats and opens one; the open reads it through the hub (`server/mesh_read.rs`).
//! They are kept apart from the ssh peers' rows (`remote_sessions`): a send or read that names one
//! is still the hub's to route (`Hub::mesh_may_route`), and an ssh peer's host is never listed twice.

use super::*;
use crate::mesh::{AddressBook, BookSession};
use acpmux_book::index::OriginState;
use std::collections::BTreeMap;

/// The most hub rows kept: a person's machines list far fewer, and the list stays bounded.
const MAX_BOOK_ROWS: usize = 2048;

#[derive(Default)]
pub(crate) struct MeshBook {
    /// `HOST/ID` to the hub's fields of it (`row_of`) and its row.
    rows: BTreeMap<String, (Bare, Arc<RemoteSession>)>,
    /// Each machine listed, with its newest heartbeat (ms since the epoch).
    hosts: BTreeMap<String, u64>,
    /// The book reads so far: a row no read lists now has an older one (`Bare::read`).
    reads: u64,
}

/// The fields a hub row is built from beside its key (`row_of`), and the last read that listed
/// it. A heartbeat that changes nothing is told by these, not by building each row again: at
/// 2,048 rows that build took 2.65 ms a read, and the next allocation, whoever made it, paid
/// another 100 us for its frees (`list_tee/gates.rs`, `hub_row_drain_steps`, 2026-11-14).
struct Bare {
    name: String,
    harness: String,
    state: String,
    read: u64,
}

impl Bare {
    fn of(s: &BookSession, read: u64) -> Self {
        Self { name: s.name.clone(), harness: s.harness.clone(), state: s.state.clone(), read }
    }

    /// Whether `s` builds the row this was built from.
    fn builds(&self, s: &BookSession) -> bool {
        self.name == s.name && self.harness == s.harness && self.state == s.state
    }
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
        // A waiting session waits on its person: listed with the asks (`pendingOnly`).
        "pendingPermissions": u64::from(s.state == "waiting"),
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
        let (gone, changed, moved, came, left) = {
            let mut book = self.mesh_book.lock().unwrap_or_else(|e| e.into_inner());
            book.reads = book.reads.wrapping_add(1);
            let read = book.reads;
            let mut changed = Vec::new();
            // A row the book lists as it was keeps its entry and its key: an unchanged read
            // allocates and frees nothing per row.
            let mut key = String::new();
            for s in &sessions {
                key.clear();
                key.push_str(&s.host);
                key.push('/');
                key.push_str(&s.session_id);
                if let Some((was, _)) = book.rows.get_mut(key.as_str())
                    && was.builds(s)
                {
                    was.read = read;
                    continue;
                }
                let mut fields = row_of(s);
                fields.set("updatedAt", json!(now));
                let summary = Self::remote_summary(&s.host, fields);
                let row = PeerRow::new(&summary);
                changed.push((s.host.clone(), summary));
                let row = Arc::new(RemoteSession {
                    peer: s.host.clone(),
                    summary: row,
                    receipt: SessionReceipt::new(&s.host, &s.session_id, None, 0),
                });
                book.rows.insert(key.clone(), (Bare::of(s, read), row));
            }
            let mut gone: Vec<(String, Value)> = Vec::new();
            book.rows.retain(|_, (bare, r)| {
                let listed = bare.read == read;
                if !listed {
                    gone.push((r.peer.clone(), r.summary.value()));
                }
                listed
            });
            // A heartbeat's time alone changes no row: only a machine coming or going does.
            let moved = !book.hosts.keys().eq(hosts.keys());
            let (came, left) = if moved {
                let came: Vec<String> =
                    hosts.keys().filter(|h| !book.hosts.contains_key(*h)).cloned().collect();
                let left: Vec<String> =
                    book.hosts.keys().filter(|h| !hosts.contains_key(*h)).cloned().collect();
                (came, left)
            } else {
                Default::default()
            };
            book.hosts = hosts;
            (gone, changed, moved, came, left)
        };
        if !gone.is_empty() || !changed.is_empty() || moved {
            self.remote_sessions.write().writes += 1;
        }
        for (peer, summary) in gone {
            self.announce_remote(&peer, summary, "purged");
        }
        for (peer, summary) in changed {
            self.announce_remote(&peer, summary, "status");
        }
        // Each machine is an origin of the v2 list, as an ssh peer is (`list_tee.rs`): connected
        // while the book lists it, removed with its rows when it leaves. A machine that left
        // because it is an ssh peer now keeps its one origin, which the peer's link states.
        if !came.is_empty() || !left.is_empty() {
            let ssh: std::collections::HashSet<String> =
                self.peers.lock().unwrap_or_else(|e| e.into_inner()).keys().cloned().collect();
            for host in left.iter().filter(|host| !ssh.contains(*host)) {
                self.events.origin_tee(host, OriginState::Removed, now);
            }
            for host in &came {
                self.events.origin_tee(host, OriginState::Connected, now);
            }
        }
    }

    /// The hub row of machine `host`'s session `id`: one lookup, its `Arc` cloned.
    pub(super) fn mesh_book_row(&self, host: &str, id: &str) -> Option<Arc<RemoteSession>> {
        let key = format!("{host}/{id}");
        let book = self.mesh_book.lock().unwrap_or_else(|e| e.into_inner());
        book.rows.get(&key).map(|(_, r)| r.clone())
    }

    /// The machines the book lists and the `(host, id)` of each of its rows, copied under its
    /// lock: what the v2 list's reconcile compares its rows to (`list_tee.rs`).
    pub(super) fn mesh_book_keys(&self) -> (Vec<String>, Vec<(String, String)>) {
        let book = self.mesh_book.lock().unwrap_or_else(|e| e.into_inner());
        let hosts = book.hosts.keys().cloned().collect();
        let keys = book
            .rows
            .values()
            .map(|(_, r)| (r.peer.clone(), r.receipt.mux_session_id.clone()))
            .collect();
        (hosts, keys)
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

    /// The session id of the one hub row `key` names: its bare id, `HOST/ID` or `HOST/name`.
    pub(crate) fn mesh_book_resolve(&self, key: &str) -> Option<String> {
        let book = self.mesh_book.lock().unwrap_or_else(|e| e.into_inner());
        let mut found = book.rows.iter().filter_map(|(qualified, (_, r))| {
            let id = r.receipt.mux_session_id.as_str();
            let name = r.summary.name();
            (key == id || key == qualified || name == Some(key)).then(|| id.to_owned())
        });
        let id = found.next()?;
        found.next().is_none().then_some(id)
    }

    /// Whether the hub lists machine `host` for this person.
    pub(crate) fn mesh_book_has_host(&self, host: &str) -> bool {
        self.mesh_book.lock().unwrap_or_else(|e| e.into_inner()).hosts.contains_key(host)
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
