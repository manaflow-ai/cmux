//! Sessions this daemon just created on another machine (`session/new` placed on a peer, a start
//! through the mesh hub). The creating daemon knows the host and the id the moment the create
//! answers, but the machine's own list or the hub's address book (30 s heartbeat) shows the
//! session later, and a `send` by name in that gap said "no session matches" for a session that
//! exists. A create is therefore recorded here at once: a peer's row goes into the peer rows
//! (the far daemon's own notice replaces it), and a hub-reached host's name resolves through
//! [`Hub::recent_create`] until the book lists it.

use super::*;

/// How long a created session's name resolves from the record alone. The far side's own list
/// or book row replaces it long before.
const KEEP: std::time::Duration = std::time::Duration::from_secs(600);
const MAX: usize = 256;

#[derive(Default)]
pub(crate) struct RecentCreates(std::sync::Mutex<Vec<Entry>>);

struct Entry {
    host: String,
    id: String,
    name: Option<String>,
    at: std::time::Instant,
}

impl RecentCreates {
    fn note(&self, host: &str, id: &str, name: Option<&str>) {
        let mut list = self.0.lock().unwrap_or_else(|e| e.into_inner());
        list.retain(|e| e.at.elapsed() < KEEP && e.id != id);
        if list.len() >= MAX {
            list.remove(0);
        }
        list.push(Entry {
            host: host.to_owned(),
            id: id.to_owned(),
            name: name.map(str::to_owned),
            at: std::time::Instant::now(),
        });
    }

    /// `(host, id)` when exactly one recent create answers to `key`: its id, its name, or either
    /// on its host (`HOST/NAME`).
    fn find(&self, key: &str) -> Option<(String, String)> {
        let list = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let mut hits = list.iter().filter(|e| e.at.elapsed() < KEEP).filter(|e| {
            let rest = key.strip_prefix(e.host.as_str()).and_then(|r| r.strip_prefix('/'));
            [Some(key), rest]
                .into_iter()
                .flatten()
                .any(|k| k == e.id || e.name.as_deref() == Some(k))
        });
        let first = hits.next()?;
        hits.next().is_none().then(|| (first.host.clone(), first.id.clone()))
    }
}

impl Hub {
    /// Records the session `id` (named `name`) just created on `host`. On a configured peer its
    /// row is added now, unless the peer's own notice already did, so every lookup by name
    /// (`send`, `last`, `wait`, `info`) finds it before the peer's list does.
    pub(crate) fn note_created_remote(&self, host: &str, id: &str, name: Option<&str>) {
        self.recent_creates.note(host, id, name);
        let Some(peer) = self.peer(host) else { return };
        if self.remote_sessions.read().find_mux(host, id).is_some() {
            return;
        }
        let mut session = json!({
            "sessionId": id,
            "status": "idle",
            "createdAt": crate::store::now_ms(),
            "updatedAt": crate::store::now_ms(),
        });
        if let (Some(name), Some(o)) = (name, session.as_object_mut()) {
            o.insert("name".into(), name.into());
        }
        self.apply_peer_notice_rows(
            host,
            peer.generation,
            crate::peer::PeerNotice::SessionChanged { session, kind: "created".into(), seq: 0 },
        );
    }

    /// The `(host, id)` a recently created remote session answers to: what a miss in the peer
    /// rows and the hub's book falls back to before it refuses a name.
    pub(crate) fn recent_create(&self, key: &str) -> Option<(String, String)> {
        self.recent_creates.find(key)
    }
}

#[cfg(test)]
#[path = "recent_creates_tests.rs"]
mod tests;
