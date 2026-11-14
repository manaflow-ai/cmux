//! The remote tokens each `ssh://` peer read over ssh (`peer_tokens.rs`), kept on disk
//! (`peer-tokens.json` in the acpmux home), so a restarted daemon's first connect presents them
//! instead of logging in once more to read them: that read is a whole ssh login (about 10 round
//! trips), and a direct path (WireGuard, the cmux link) waits on it before it dials. They are
//! read again when they stop working, as in memory (`peer_tokens.rs` lists when).
//!
//! An entry is the peer's name and the URL it was read over: a peer whose URL changed reads
//! again, and never presents another machine's tokens.
//!
//! Format (mode 0600, replaced through a temp file and a rename; it holds credentials, the same
//! ones `config.json` holds for a peer configured with them):
//! `{"version":1,"peers":{"<name>":{"url":"ssh://...","token":"...","peerToken":"..."}}}`.
//! A memory store keeps none.

use crate::peer_last_good::{read_json, write_json};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};

/// A runtime-only writer identity. A replacement gets a fresh identity even
/// when its name, URL and currently kept tokens are all unchanged.
pub(crate) struct Generation {
    active: Arc<AtomicU64>,
    id: u64,
}

impl Generation {
    /// Called in peer registration order. No file I/O or shared writer lock.
    pub(crate) fn activate(&self) {
        self.active.store(self.id, Ordering::Release);
    }

    fn is_current(&self) -> bool {
        self.active.load(Ordering::Acquire) == self.id
    }
}

/// The file name in the acpmux home.
pub const FILE_NAME: &str = "peer-tokens.json";
const VERSION: u32 = 1;

/// The dashboard token and the peer token.
pub type Tokens = (String, Option<String>);

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    url: String,
    token: String,
    peer_token: String,
}

#[derive(Default, Serialize, Deserialize)]
struct File {
    version: u32,
    #[serde(default)]
    peers: BTreeMap<String, Entry>,
}

/// The file, loaded once and written on each change. Shared by every peer of one hub
/// (`LastGood::tokens`).
#[derive(Default)]
pub struct KeptTokens {
    path: Option<PathBuf>,
    peers: Mutex<BTreeMap<String, Entry>>,
    // Binding takes this lock only to find the shared generation gate.
    owners: Mutex<BTreeMap<String, (String, Weak<AtomicU64>)>>,
}

impl std::fmt::Debug for KeptTokens {
    // Names only: the tokens never reach a log.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
        f.debug_struct("KeptTokens")
            .field("path", &self.path)
            .field("peers", &peers.keys().collect::<Vec<_>>())
            .finish()
    }
}

impl KeptTokens {
    /// Read `<home>/peer-tokens.json` (none, unreadable or another version: empty). `None`
    /// keeps everything in memory only.
    pub fn open(home: Option<&Path>) -> Self {
        let path = home.map(|home| home.join(FILE_NAME));
        let peers = path
            .as_deref()
            .and_then(read_json::<File>)
            .filter(|file| file.version == VERSION)
            .map(|file| file.peers)
            .unwrap_or_default();
        Self { path, peers: Mutex::new(peers), owners: Mutex::default() }
    }

    pub(crate) fn bind(&self, name: &str, url: &str) -> (Generation, Option<Tokens>) {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let active = {
            let mut owners = self.owners.lock().unwrap_or_else(|e| e.into_inner());
            let active = owners
                .get(name)
                .and_then(|(_, owner)| owner.upgrade())
                .unwrap_or_else(|| Arc::new(AtomicU64::new(0)));
            owners.insert(name.to_owned(), (url.to_owned(), Arc::downgrade(&active)));
            active
        };
        let generation = Generation { active, id: NEXT.fetch_add(1, Ordering::Relaxed) };
        (generation, self.get(name, url))
    }

    pub(crate) fn release(&self, name: &str, generation: Generation) {
        let mut owners = self.owners.lock().unwrap_or_else(|e| e.into_inner());
        let same = owners
            .get(name)
            .is_some_and(|(_, owner)| owner.ptr_eq(&Arc::downgrade(&generation.active)));
        // Drop while serialized with bind and other releases: two simultaneous
        // final drops must not both observe another owner and leave a dead slot.
        drop(generation);
        if same && owners.get(name).is_some_and(|(_, owner)| owner.strong_count() == 0) {
            owners.remove(name);
        }
    }

    /// The tokens `name` read over `url`; none when it read them over another URL.
    pub fn get(&self, name: &str, url: &str) -> Option<Tokens> {
        let peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
        let entry = peers.get(name).filter(|entry| entry.url == url)?;
        Some((entry.token.clone(), Some(entry.peer_token.clone())))
    }

    /// Keep what `name` read over `url`; only a read with a peer token is kept
    /// (`peer_tokens.rs`). Written only when it changed.
    pub(crate) fn keep_current(
        &self,
        name: &str,
        url: &str,
        generation: &Generation,
        tokens: &Tokens,
    ) {
        let Some(peer_token) = &tokens.1 else { return };
        let entry =
            Entry { url: url.to_owned(), token: tokens.0.clone(), peer_token: peer_token.clone() };
        let mut peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
        if !generation.is_current() || peers.get(name) == Some(&entry) {
            return;
        }
        peers.insert(name.to_owned(), entry);
        // Written under the lock: two peers' writes never share the temp file.
        self.save(name, &peers);
    }

    /// Forget what `name` read over `url`: the remote no longer takes it, or it restarts. An
    /// entry another URL wrote (a replacement of the peer pointed elsewhere) stays.
    pub(crate) fn forget_current(&self, name: &str, url: &str, generation: &Generation) {
        let mut peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
        if generation.is_current() && peers.get(name).is_some_and(|entry| entry.url == url) {
            peers.remove(name);
            self.save(name, &peers);
        }
    }

    /// Drop every entry whose peer name and URL are not among `configured`, the peers this
    /// run starts with, and rewrite the file without them: a removed peer's credentials do not
    /// outlive it past the next start.
    pub fn retain<'a>(&self, configured: impl IntoIterator<Item = (&'a str, &'a str)>) {
        let configured: std::collections::BTreeSet<_> = configured.into_iter().collect();
        let mut owners = self.owners.lock().unwrap_or_else(|e| e.into_inner());
        owners.retain(|name, (url, owner)| {
            let keep = configured.contains(&(name.as_str(), url.as_str()));
            if !keep && let Some(active) = owner.upgrade() {
                active.store(0, Ordering::Release);
            }
            keep
        });
        let mut peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
        let before = peers.len();
        peers.retain(|name, entry| configured.contains(&(name.as_str(), entry.url.as_str())));
        if peers.len() != before {
            self.save("(removed peers)", &peers);
        }
    }

    #[cfg(test)]
    fn keep(&self, name: &str, url: &str, tokens: &Tokens) {
        let (generation, _) = self.bind(name, url);
        generation.activate();
        self.keep_current(name, url, &generation, tokens);
        self.release(name, generation);
    }

    #[cfg(test)]
    fn forget(&self, name: &str, url: &str) {
        let (generation, _) = self.bind(name, url);
        generation.activate();
        self.forget_current(name, url, &generation);
        self.release(name, generation);
    }

    fn save(&self, name: &str, peers: &BTreeMap<String, Entry>) {
        let Some(path) = &self.path else { return };
        let file = File { version: VERSION, peers: peers.clone() };
        if let Err(e) = write_json(path, &file) {
            tracing::warn!(peer = %name, "could not save the peer's remote tokens: {e}");
        }
    }
}

#[cfg(test)]
mod tests;
