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
    /// Each machine listed, by its hub `daemonId` (its node key: what the hub carrier dials and
    /// what its Noise handshake proves), to its host. Kept whole by each read (`mine_by_key`),
    /// an ssh peer's machine too: the carrier is that machine's route when its ssh is down.
    /// Only the hub carrier reads it; the app's workspace targets leave ssh peers out
    /// (`mesh_book_route_machines`).
    #[cfg(feature = "hub-carrier")]
    machines: BTreeMap<String, String>,
}

/// Whether `book` lists daemon `d` as one of this person's other machines (`mine`).
fn is_mine(
    d: &crate::mesh::BookDaemon,
    own_user: &str,
    own_daemon: Option<&str>,
    skip: &dyn Fn(&str) -> bool,
) -> bool {
    !(own_user.is_empty()
        || d.user != own_user
        || d.host.is_empty()
        || own_daemon == Some(d.daemon_id.as_str())
        || super::mesh_rows::is_own_host(&d.host)
        || skip(&d.host))
}

/// The machines of `book` [`mine`] lists, by hub `daemonId`, to their host. A machine with no
/// `daemonId` is left out: nothing can dial it.
#[cfg(feature = "hub-carrier")]
pub(crate) fn mine_by_key(
    book: &AddressBook,
    own_user: &str,
    own_daemon: Option<&str>,
    skip: &dyn Fn(&str) -> bool,
) -> BTreeMap<String, String> {
    book.daemons
        .iter()
        .filter(|d| !d.daemon_id.is_empty() && is_mine(d, own_user, own_daemon, skip))
        .take(MAX_BOOK_ROWS)
        .map(|d| (d.daemon_id.clone(), d.host.clone()))
        .collect()
}

/// What a hub row is built from beside its key: `row_of` reads a session through this alone, and
/// `Bare` keeps it, so a field a row reads is a field whose change builds the row again.
#[derive(PartialEq, Eq, Clone, Copy)]
struct Fields<'a> {
    name: &'a str,
    harness: &'a str,
    state: &'a str,
    cwd: Option<&'a str>,
    title: Option<&'a str>,
    title_source: Option<&'a str>,
    name_given: Option<bool>,
    model: Option<&'a str>,
    agent_session_id: Option<&'a str>,
    host_build: Option<&'a str>,
    handle: Option<&'a str>,
}

impl<'a> Fields<'a> {
    fn of(s: &'a BookSession) -> Self {
        Self {
            name: &s.name,
            harness: &s.harness,
            state: &s.state,
            cwd: s.cwd.as_deref().filter(|c| !c.is_empty()),
            title: s.title.as_deref().filter(|t| !t.is_empty()),
            title_source: s.title_source.as_deref().filter(|t| !t.is_empty()),
            name_given: s.name_given,
            model: s.model.as_deref().filter(|m| !m.is_empty()),
            agent_session_id: s.agent_session_id.as_deref().filter(|a| !a.is_empty()),
            host_build: s.host_build.as_deref().filter(|b| !b.is_empty()),
            // Only a given handle: a derived one is every reader's to derive, and an invalid one
            // is no handle at all (`session_handle::valid`).
            handle: s.handle.as_deref().filter(|h| crate::session_handle::valid(h)),
        }
    }
}

/// The fields a hub row was built from (`Fields`), owned, and the last read that listed it. A
/// heartbeat that changes nothing is told by these, not by building each row again: at 2,048
/// rows that build took 2.65 ms a read, and the next allocation, whoever made it, paid another
/// 100 us for its frees (`list_tee/gates.rs`, `hub_row_drain_steps`, 2026-11-14).
struct Bare {
    name: String,
    harness: String,
    state: String,
    cwd: Option<String>,
    title: Option<String>,
    title_source: Option<String>,
    name_given: Option<bool>,
    model: Option<String>,
    agent_session_id: Option<String>,
    host_build: Option<String>,
    handle: Option<String>,
    read: u64,
}

impl Bare {
    fn of(fields: &Fields<'_>, read: u64) -> Self {
        let own = |s: Option<&str>| s.map(str::to_owned);
        Self {
            name: fields.name.into(),
            harness: fields.harness.into(),
            state: fields.state.into(),
            cwd: own(fields.cwd),
            title: own(fields.title),
            title_source: own(fields.title_source),
            name_given: fields.name_given,
            model: own(fields.model),
            agent_session_id: own(fields.agent_session_id),
            host_build: own(fields.host_build),
            handle: own(fields.handle),
            read,
        }
    }

    fn fields(&self) -> Fields<'_> {
        Fields {
            name: &self.name,
            harness: &self.harness,
            state: &self.state,
            cwd: self.cwd.as_deref(),
            title: self.title.as_deref(),
            title_source: self.title_source.as_deref(),
            name_given: self.name_given,
            model: self.model.as_deref(),
            agent_session_id: self.agent_session_id.as_deref(),
            host_build: self.host_build.as_deref(),
            handle: self.handle.as_deref(),
        }
    }

    /// Whether `fields` build the row this was built from.
    fn builds(&self, fields: &Fields<'_>) -> bool {
        self.fields() == *fields
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
        if !is_mine(&d, own_user, own_daemon, skip) {
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

/// The keys every session row lists, from this machine or another: a hub row lists each one,
/// null when the hub does not say, so no reader drops or misfiles a chat for a missing key (Leo,
/// 2026-11-22: "my gui chats are not showing yet").
#[cfg(test)]
pub(crate) const ROW_KEYS: [&str; 11] = [
    "name",
    "nameGiven",
    "title",
    "titleSource",
    "cwd",
    "model",
    "harness",
    "agentSessionId",
    "hostBuild",
    "handle",
    "status",
];

/// A hub session's row before `remote_summary` names it for its host. `updatedAt` is when this
/// daemon first saw it as it is now, so a heartbeat that changes nothing changes no row.
fn row_of(session_id: &str, fields: &Fields<'_>) -> Value {
    let Fields {
        name,
        harness,
        state,
        cwd,
        title,
        title_source,
        name_given,
        model,
        agent_session_id,
        host_build,
        handle,
    } = *fields;
    json!({
        "sessionId": session_id,
        "name": name,
        // Unknown unless the hub says: the name came from its machine, given or derived there.
        "nameGiven": name_given,
        "title": title,
        "titleSource": title.and(title_source),
        "cwd": cwd,
        "model": model,
        "harness": harness,
        "agentSessionId": agent_session_id,
        "hostBuild": host_build,
        // Its given handle (`acpmux rename ... --handle`), which `resolve`, `send` and `locate`
        // match (`peer_row::Hot`) and `ls` shows; null for a derived one, which readers derive
        // from the id (`session_handle::display`, `session_handle::matches`).
        "handle": handle,
        "displayName": handle,
        "status": state,
        // A waiting session waits on its person: listed with the asks (`pendingOnly`).
        "pendingPermissions": u64::from(state == "waiting"),
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
        let ssh: std::collections::HashSet<String> = self.peers.load().keys().cloned().collect();
        let skip = |host: &str| ssh.contains(host);
        // Every one of this person's other machines keeps its carrier route, an ssh peer's too
        // (no skip): the carrier is how `remote.pipe` (`tools/carrier-pipe`, ssh's ProxyCommand)
        // reaches a machine when its ssh is the thing that is down. Skipping ssh peers here made
        // every fleet lane VM an ssh peer of the controller `machine.unknown` on the carrier
        // (2026-11-22). Only the session rows below leave ssh peers out, so none is listed twice.
        #[cfg(feature = "hub-carrier")]
        self.set_mesh_book_machines(mine_by_key(&book, own_user, own_daemon, &|_| false));
        let (hosts, sessions) = mine(book, own_user, own_daemon, &skip);
        self.set_mesh_book(hosts, sessions);
    }

    /// Replace the machines the book lists by `daemonId` (`mine_by_key`). Empty when the relay
    /// stops.
    #[cfg(feature = "hub-carrier")]
    pub fn set_mesh_book_machines(&self, machines: BTreeMap<String, String>) {
        self.mesh_book.lock().unwrap_or_else(|e| e.into_inner()).machines = machines;
    }

    /// The host of the machine whose hub `daemonId` is `key`, when the book lists it as one of
    /// this person's other machines.
    #[cfg(feature = "hub-carrier")]
    pub(crate) fn mesh_book_machine(&self, key: &str) -> Option<String> {
        self.mesh_book.lock().unwrap_or_else(|e| e.into_inner()).machines.get(key).cloned()
    }

    /// Each of this person's other machines the book lists: `(daemonId, host)`.
    #[cfg(feature = "hub-carrier")]
    pub(crate) fn mesh_book_machines(&self) -> Vec<(String, String)> {
        let book = self.mesh_book.lock().unwrap_or_else(|e| e.into_inner());
        book.machines.iter().map(|(key, host)| (key.clone(), host.clone())).collect()
    }

    /// The machines of [`Self::mesh_book_machines`] no ssh peer of this daemon already names:
    /// the app's workspace targets (`_acpmux/machine_routes`), where an ssh peer's machine is
    /// listed by its ssh row, not twice.
    #[cfg(feature = "hub-carrier")]
    pub(crate) fn mesh_book_route_machines(&self) -> Vec<(String, String)> {
        let ssh: std::collections::HashSet<String> = self.peers.load().keys().cloned().collect();
        let mut machines = self.mesh_book_machines();
        machines.retain(|(_, host)| !ssh.contains(host));
        machines
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
                let fields = Fields::of(s);
                if let Some((was, _)) = book.rows.get_mut(key.as_str())
                    && was.builds(&fields)
                {
                    was.read = read;
                    continue;
                }
                let bare = Bare::of(&fields, read);
                let mut fields = row_of(&s.session_id, &fields);
                fields.set("updatedAt", json!(now));
                let summary = Self::remote_summary(&s.host, fields);
                let row = PeerRow::new(&summary);
                changed.push((s.host.clone(), summary));
                let row = Arc::new(RemoteSession {
                    peer: s.host.clone(),
                    summary: row,
                    receipt: SessionReceipt::new(
                        &s.host,
                        &s.session_id,
                        s.agent_session_id.clone().filter(|a| !a.is_empty()),
                        0,
                    ),
                });
                book.rows.insert(key.clone(), (bare, row));
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
                self.peers.load().keys().cloned().collect();
            for host in left.iter().filter(|host| !ssh.contains(*host)) {
                self.events.origin_tee(host, OriginState::Removed, now);
            }
            for host in &came {
                self.events.origin_tee(host, OriginState::Connected, now);
            }
        }
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

    /// The session ids of machine `host`'s hub rows, read from its own range of the book: what
    /// the v2 list offers again when a slot of its index frees (`list_tee/refused.rs`).
    pub(super) fn mesh_book_ids(&self, host: &str) -> Vec<String> {
        let book = self.mesh_book.lock().unwrap_or_else(|e| e.into_inner());
        let start = format!("{host}/");
        book.rows
            .range::<str, _>((
                std::ops::Bound::Included(start.as_str()),
                std::ops::Bound::Unbounded,
            ))
            .take_while(|(key, _)| key.starts_with(&start))
            .filter(|(_, (_, r))| r.peer == host)
            .map(|(_, (_, r))| r.receipt.mux_session_id.clone())
            .collect()
    }

    /// The hub rows `keep` takes, cloning no other.
    pub(super) fn mesh_book_rows(
        &self,
        keep: impl Fn(&RemoteSession) -> bool,
    ) -> Vec<Arc<RemoteSession>> {
        let book = self.mesh_book.lock().unwrap_or_else(|e| e.into_inner());
        book.rows.values().map(|(_, r)| r).filter(|r| keep(r)).cloned().collect()
    }

    /// How many hub rows `keep` takes, counted under the book's lock with none cloned.
    pub(super) fn mesh_book_count(&self, keep: impl Fn(&RemoteSession) -> bool) -> usize {
        let book = self.mesh_book.lock().unwrap_or_else(|e| e.into_inner());
        book.rows.values().filter(|(_, r)| keep(r)).count()
    }

    /// The hub row listed under `key` (`HOST/ID`).
    pub(super) fn mesh_book_row(&self, key: &str) -> Option<Arc<RemoteSession>> {
        let book = self.mesh_book.lock().unwrap_or_else(|e| e.into_inner());
        book.rows.get(key).map(|(_, row)| row.clone())
    }

    /// The machines the hub lists for this person, as `peers` lists an ssh peer: connected, with
    /// their session count and newest heartbeat.
    /// With each one's last health reading through the hub and when it came (`hub_health.rs`),
    /// as a direct peer's row carries its link's (`health`, `healthAt`), so placement weighs it.
    pub(super) fn mesh_book_hosts(&self) -> Vec<Value> {
        let mut rows: Vec<Value> = {
            let book = self.mesh_book.lock().unwrap_or_else(|e| e.into_inner());
            // One walk of the rows for every host, not one per host.
            let mut counts: HashMap<&str, usize> = HashMap::new();
            for (_, row) in book.rows.values() {
                *counts.entry(row.peer.as_str()).or_default() += 1;
            }
            book.hosts
                .iter()
                .map(|(host, seen)| {
                    let count = counts.get(host.as_str()).copied().unwrap_or(0);
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
        };
        // Taken after the book's lock is let go: the two are never held together.
        let health = self.hub_health.lock().unwrap_or_else(|e| e.into_inner());
        for row in &mut rows {
            let Some(name) = row.get("name").and_then(Value::as_str).map(str::to_owned) else {
                continue;
            };
            let name = name.as_str();
            if let Some((at, reading)) = health.reading(name)
                && let Some(fields) = row.as_object_mut()
            {
                fields.insert("health".into(), reading);
                fields.insert("healthAt".into(), json!(at));
            }
            // Its newest read failed: placement passes it over (`placement/reach.rs`).
            if let Some(failed) = health.failed_at(name)
                && let Some(fields) = row.as_object_mut()
            {
                fields.insert("healthFailedAt".into(), json!(failed));
            }
        }
        rows
    }

    /// A session the hub lists on machine `host`, the one a machine read goes through: the hub
    /// takes a read only when it names one session (cmux-platform `Core.ts`, `mesh.invalid: a read
    /// names one session by sessionId or name`), and the far daemon answers a health read before
    /// it looks the session up (`mesh_read.rs` `HOST_HEALTH`). None when it lists none there.
    pub(crate) fn mesh_book_session_on(&self, host: &str) -> Option<String> {
        let book = self.mesh_book.lock().unwrap_or_else(|e| e.into_inner());
        let prefix = format!("{host}/");
        book.rows
            .range(prefix.clone()..)
            .take_while(|(key, _)| key.starts_with(&prefix))
            .map(|(_, (_, r))| r.receipt.mux_session_id.clone())
            .find(|id| !id.is_empty())
    }

    /// The session id of the one hub row `key` names: its bare id, `HOST/ID` or `HOST/name`.
    pub(crate) fn mesh_book_resolve(&self, key: &str) -> Option<String> {
        let book = self.mesh_book.lock().unwrap_or_else(|e| e.into_inner());
        let mut found = book.rows.iter().filter_map(|(qualified, (_, r))| {
            let id = r.receipt.mux_session_id.as_str();
            let name = r.summary.name();
            (key == id || key == qualified || name == Some(key) || names_by_handle(r, key))
                .then(|| id.to_owned())
        });
        let id = found.next()?;
        found.next().is_none().then_some(id)
    }

    /// The hub row `key` names by its handle, bare (`Mango`) or on its machine (`HOST/Mango`),
    /// as `(host, id)` when one row only does. The hub and the far daemon know a chat by its id
    /// and name, never its handle, so a send or read through the hub names it by id
    /// (`mesh_send.rs`, `mesh_read.rs`).
    pub(crate) fn mesh_book_handle(&self, key: &str) -> Option<(String, String)> {
        let book = self.mesh_book.lock().unwrap_or_else(|e| e.into_inner());
        let mut found = book
            .rows
            .values()
            .map(|(_, r)| r)
            .filter(|r| names_by_handle(r, key))
            .map(|r| (r.peer.clone(), r.receipt.mux_session_id.clone()));
        let Some(row) = found.next() else {
            drop(book);
            // Created through the hub seconds ago: the book lists it at the next heartbeat.
            return self.recent_create(key).filter(|(host, _)| self.peer(host).is_none());
        };
        found.next().is_none().then_some(row)
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

/// Whether `key` names hub row `r` by its handle (`session_handle::matches`: its given one, or
/// the one derived from its id), bare or as `HOST/HANDLE` with the row's machine.
fn names_by_handle(r: &RemoteSession, key: &str) -> bool {
    let id = r.receipt.mux_session_id.as_str();
    let handle = r.summary.handle();
    match key.strip_prefix(r.peer.as_str()).and_then(|rest| rest.strip_prefix('/')) {
        Some(rest) => crate::session_handle::matches(handle, id, rest),
        None => crate::session_handle::matches(handle, id, key),
    }
}

#[cfg(test)]
#[path = "mesh_book_tests.rs"]
mod tests;
