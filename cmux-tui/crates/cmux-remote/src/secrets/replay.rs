//! Replay protection that outlives the daemon: an item is taken only within
//! [`WINDOW_SECS`] of the time sealed into it, and every nonce taken in that
//! window is kept, on disk too, until the window has passed. A live entry is
//! never dropped: when the window is full, a request is refused (retryably)
//! instead.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// How far an item's sealed time may be from the daemon's clock, either way.
pub const WINDOW_SECS: u64 = 300;
/// The most nonces one window holds.
pub const MAX_LIVE: usize = 4_096;
/// The taken nonces, under the daemon's state folder.
const FILE: &str = "secrets-v1/taken-nonces.json";

/// Why an item can't be taken. Each is a fixed wire code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// Sealed outside the window around the daemon's clock.
    Stale,
    Replay,
    /// The window holds [`MAX_LIVE`] nonces already. Retryable.
    Busy,
    /// The taken set couldn't be saved.
    Write,
}

impl Refusal {
    pub fn code(self) -> &'static str {
        match self {
            Self::Stale => "stale",
            Self::Replay => "replay",
            Self::Busy => "busy",
            Self::Write => "write",
        }
    }
}

#[derive(serde::Serialize, serde::Deserialize, Default)]
struct Stored {
    /// Nonce to the time sealed into its item.
    taken: BTreeMap<String, u64>,
}

pub struct Replay {
    state: PathBuf,
    taken: BTreeMap<String, u64>,
    /// Items sealed before this are refused: set when the saved set could
    /// not be read, so an item taken before a restart can't come back.
    floor: u64,
    max_live: usize,
}

impl Replay {
    /// The set saved under `state`, without the nonces whose window has
    /// passed. A saved set that can't be read refuses every item sealed
    /// before `now`.
    pub fn load(state: PathBuf, now: u64, max_live: usize) -> Self {
        let (taken, floor) = match std::fs::read(state.join(FILE)) {
            Ok(bytes) => match serde_json::from_slice::<Stored>(&bytes) {
                Ok(stored) => (stored.taken, 0),
                Err(_) => (BTreeMap::new(), now),
            },
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (BTreeMap::new(), 0),
            Err(_) => (BTreeMap::new(), now),
        };
        let mut replay = Self { state, taken, floor, max_live };
        replay.prune(now);
        replay
    }

    /// Whether an item with `nonce`, sealed at `issued_at`, may be taken now.
    pub fn check(&self, nonce: &str, issued_at: u64, now: u64) -> Result<(), Refusal> {
        if issued_at.saturating_add(WINDOW_SECS) < now
            || issued_at > now.saturating_add(WINDOW_SECS)
        {
            return Err(Refusal::Stale);
        }
        if issued_at < self.floor || self.taken.contains_key(nonce) {
            return Err(Refusal::Replay);
        }
        Ok(())
    }

    /// Take every `(nonce, issued_at)`, all or none, and save the set before
    /// the caller writes anything.
    pub fn take(&mut self, items: &[(String, u64)], now: u64) -> Result<(), Refusal> {
        self.prune(now);
        for (nonce, issued_at) in items {
            self.check(nonce, *issued_at, now)?;
        }
        if self.taken.len().saturating_add(items.len()) > self.max_live {
            return Err(Refusal::Busy);
        }
        for (nonce, issued_at) in items {
            self.taken.insert(nonce.clone(), *issued_at);
        }
        if self.save().is_err() {
            self.forget(items);
            return Err(Refusal::Write);
        }
        Ok(())
    }

    /// Give back nonces whose request wrote nothing, so it can be sent
    /// again. Saving is best effort: the set in memory is what this daemon
    /// checks, and a nonce left on disk only refuses that item after a
    /// restart, within its window.
    pub fn release(&mut self, items: &[(String, u64)]) {
        self.forget(items);
        let _ = self.save();
    }

    fn forget(&mut self, items: &[(String, u64)]) {
        for (nonce, _) in items {
            self.taken.remove(nonce);
        }
    }

    /// Drop the nonces whose window has passed: their items are stale now.
    fn prune(&mut self, now: u64) {
        self.taken.retain(|_, issued_at| issued_at.saturating_add(WINDOW_SECS) >= now);
    }

    fn save(&self) -> std::io::Result<()> {
        let bytes = serde_json::to_vec(&Stored { taken: self.taken.clone() })?;
        save_state(&self.state, Path::new(FILE), &bytes)
    }
}

#[cfg(unix)]
fn save_state(state: &Path, relative: &Path, bytes: &[u8]) -> std::io::Result<()> {
    super::commit::replace_state(state, relative, bytes)
}

#[cfg(not(unix))]
fn save_state(_: &Path, _: &Path, _: &[u8]) -> std::io::Result<()> {
    Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "secrets-v1 writes need Unix"))
}
