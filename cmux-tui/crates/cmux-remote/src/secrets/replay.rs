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
    /// The window holds [`MAX_LIVE`] nonces already, or the taken set was
    /// lost and items that may have been taken aren't stale yet. Retryable.
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

/// The exclusive lock of one `secrets-v1` request; released when dropped.
/// Every write takes a `&Lock`, so none happens outside a request.
pub struct Lock(#[allow(dead_code, reason = "held only to keep the flock")] std::fs::File);

/// How long a request waits for the machine config applier's lock before it
/// answers the retryable `busy`.
pub const CONFIG_WAIT: std::time::Duration = std::time::Duration::from_secs(10);
/// The machine config applier's lock (`applier.py` takes it for a whole apply).
const CONFIG_LOCK: &str = ".cmux/machine-config/lock";

/// Take the machine config applier's lock under `home`, trying for up to
/// `wait` (`WouldBlock` after that). `None` when the machine has no config
/// folder: then there is no apply and no declared name either.
#[cfg(unix)]
pub fn lock_machine_config(
    home: &Path,
    wait: std::time::Duration,
) -> std::io::Result<Option<std::fs::File>> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let path = home.join(CONFIG_LOCK);
    let folder = path.parent().unwrap_or(home);
    match std::fs::symlink_metadata(folder) {
        Ok(meta) if meta.is_dir() => {}
        Ok(_) => return Err(std::io::Error::other("the machine config folder is not a folder")),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    }
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&path)?;
    let meta = file.metadata()?;
    // SAFETY: geteuid has no preconditions and cannot fail.
    if !meta.is_file() || meta.uid() != unsafe { libc::geteuid() } {
        return Err(std::io::Error::other("the machine config lock is not a file of this user"));
    }
    let deadline = std::time::Instant::now() + wait;
    loop {
        // SAFETY: `file` is an open descriptor for the whole call.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            return Ok(Some(file));
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::WouldBlock
            && error.kind() != std::io::ErrorKind::Interrupted
        {
            return Err(error);
        }
        if std::time::Instant::now() >= deadline {
            return Err(std::io::ErrorKind::WouldBlock.into());
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

#[cfg(not(unix))]
pub fn lock_machine_config(
    _: &Path,
    _: std::time::Duration,
) -> std::io::Result<Option<std::fs::File>> {
    Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "secrets-v1 writes need Linux"))
}

/// Take the state folder's lock, waiting for another request to finish.
#[cfg(unix)]
pub fn lock(state: &Path) -> std::io::Result<Lock> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let folder = state.join(FOLDER);
    if !folder.is_dir() {
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&folder)?;
        // The new folder's entry is durable only once its parent is synced.
        std::fs::File::open(state)?.sync_all()?;
    }
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
    Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "secrets-v1 writes need Linux"))
}

pub struct Replay {
    state: PathBuf,
    taken: BTreeMap<String, u64>,
    /// Items sealed before this are refused (retryably): set when the saved
    /// set could not be read, past every sealed time an item taken before
    /// could carry (up to [`WINDOW_SECS`] ahead of the clock), so none can
    /// come back. Saved with the set until its window has passed.
    floor: u64,
    max_live: usize,
}

impl Replay {
    /// The set saved under `state`, read under the request `_lock`, without
    /// the nonces whose window has passed. A saved set that can't be read
    /// refuses, as `busy`, every item sealed up to [`WINDOW_SECS`] past
    /// `now`, until those are stale anyway.
    pub fn load(_lock: &Lock, state: PathBuf, now: u64, max_live: usize) -> Self {
        let (taken, floor, recovered) = match std::fs::read(state.join(FILE)) {
            Ok(bytes) => match serde_json::from_slice::<Stored>(&bytes) {
                Ok(stored) => (stored.taken, stored.floor, false),
                Err(_) => (BTreeMap::new(), recovery_floor(now), true),
            },
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                (BTreeMap::new(), 0, false)
            }
            Err(_) => (BTreeMap::new(), recovery_floor(now), true),
        };
        let mut replay = Self { state, taken, floor, max_live };
        replay.prune(now);
        if recovered {
            // Keep the floor where this load put it: a later load must not
            // move it forward again.
            let _ = replay.save();
        }
        replay
    }

    /// Whether an item with `nonce`, sealed at `issued_at`, may be taken now.
    pub fn check(&self, nonce: &str, issued_at: u64, now: u64) -> Result<(), Refusal> {
        if issued_at.saturating_add(WINDOW_SECS) < now
            || issued_at > now.saturating_add(WINDOW_SECS)
        {
            return Err(Refusal::Stale);
        }
        if self.taken.contains_key(nonce) {
            return Err(Refusal::Replay);
        }
        if issued_at < self.floor {
            return Err(Refusal::Busy);
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
        // Every item sealed before the floor is stale once this passes.
        if self.floor.saturating_add(WINDOW_SECS) <= now {
            self.floor = 0;
        }
    }

    fn save(&self) -> std::io::Result<()> {
        let bytes = serde_json::to_vec(&Stored { taken: self.taken.clone(), floor: self.floor })?;
        save_state(&self.state, Path::new(FILE), &bytes)
    }
}

/// The floor after losing the taken set at `now`: past the latest sealed
/// time an item taken before could carry.
fn recovery_floor(now: u64) -> u64 {
    now.saturating_add(WINDOW_SECS).saturating_add(1)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn save_state(state: &Path, relative: &Path, bytes: &[u8]) -> std::io::Result<()> {
    super::commit::replace_state(state, relative, bytes)
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn save_state(_: &Path, _: &Path, _: &[u8]) -> std::io::Result<()> {
    Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "secrets-v1 writes need Linux"))
}
