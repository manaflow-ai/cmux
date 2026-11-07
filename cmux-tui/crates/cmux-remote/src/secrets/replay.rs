//! Replay protection that outlives the daemon: an item is taken only within
//! [`WINDOW_SECS`] of the time sealed into it, and every nonce taken in that
//! window is kept, on disk too, until the window has passed. A live entry is
//! never dropped: when the window is full, a request is refused (retryably)
//! instead. The set is read and saved under an exclusive `flock` on the
//! state folder's lock file, which also serializes every request.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// How far an item's sealed time may be from the daemon's clock, either way.
pub const WINDOW_SECS: u64 = 300;
/// The most nonces one window holds.
pub const MAX_LIVE: usize = 4_096;
/// The taken nonces, under the daemon's state folder.
const FILE: &str = "secrets-v1/taken-nonces.json";
/// The folder [`FILE`] and the lock file are in.
const FOLDER: &str = "secrets-v1";

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
    /// See [`Replay::floor`].
    #[serde(default)]
    floor: u64,
}

/// The exclusive lock of one request; released when dropped.
pub struct Lock(#[allow(dead_code, reason = "held only to keep the flock")] std::fs::File);

/// Take the state folder's lock, waiting for another request to finish.
#[cfg(unix)]
pub fn lock(state: &Path) -> std::io::Result<Lock> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let folder = state.join(FOLDER);
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&folder)?;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(folder.join(".lock"))?;
    loop {
        // SAFETY: `file` is an open descriptor for the whole call.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
            return Ok(Lock(file));
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

#[cfg(not(unix))]
pub fn lock(_: &Path) -> std::io::Result<Lock> {
    Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "secrets-v1 writes need Unix"))
}

pub struct Replay {
    _lock: Lock,
    state: PathBuf,
    taken: BTreeMap<String, u64>,
    /// Items sealed before this are refused: set when the saved set could
    /// not be read, so an item taken before can't come back. Saved with the
    /// set until its window has passed.
    floor: u64,
    max_live: usize,
}

impl Replay {
    /// The set saved under `state`, read under `lock`, without the nonces
    /// whose window has passed. A saved set that can't be read refuses
    /// every item sealed before `now`.
    pub fn load(lock: Lock, state: PathBuf, now: u64, max_live: usize) -> Self {
        let (taken, floor) = match std::fs::read(state.join(FILE)) {
            Ok(bytes) => match serde_json::from_slice::<Stored>(&bytes) {
                Ok(stored) => (stored.taken, stored.floor),
                Err(_) => (BTreeMap::new(), now),
            },
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (BTreeMap::new(), 0),
            Err(_) => (BTreeMap::new(), now),
        };
        let mut replay = Self { _lock: lock, state, taken, floor, max_live };
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
    /// again. Saving is best effort: a nonce left on disk only refuses that
    /// item again, within its window.
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
        if self.floor.saturating_add(WINDOW_SECS) < now {
            self.floor = 0;
        }
    }

    fn save(&self) -> std::io::Result<()> {
        let bytes = serde_json::to_vec(&Stored { taken: self.taken.clone(), floor: self.floor })?;
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
