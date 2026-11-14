//! A held file lock that a child process can not keep.
//!
//! A file lock belongs to the open file description, not to the descriptor. A child that a
//! process forks while it holds a lock gets a copy of the description, and keeps it until it
//! execs (a close-on-exec descriptor) or exits. A holder that lets go only by closing its
//! descriptor leaves the lock held for that window: the next taker, in this process or another,
//! reads it as busy. Every cmux process that locks files also starts children (git, agents,
//! shells, helpers) from other threads, so a close-only release is a lock that sometimes stays.
//! [`FileLock`] unlocks first, then closes, so a copy keeps nothing.
//!
//! The lock is the platform's lock of [`File::lock`]: `flock` on unix (the kind every cmux
//! build in the field takes on these files, so an old daemon and a new one still exclude each
//! other; a test here proves it against a raw `flock`), `LockFileEx` on Windows. A taker names
//! the [`Kind`]; the file's path and mode stay the caller's.

use std::fs::File;
use std::io;
use std::time::{Duration, Instant};

/// The shortest wait between two tries of [`FileLock::take_within`].
pub const MIN_STEP: Duration = Duration::from_millis(5);

/// Shared (many holders) or exclusive (one).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Shared,
    Exclusive,
}

/// A lock that is held on `file` until this drops. The drop unlocks, then closes the file.
#[derive(Debug)]
pub struct FileLock {
    file: File,
}

/// Why a lock was not taken.
#[derive(Debug)]
pub enum LockError {
    /// Another holder has it, in a kind that excludes this one. The file comes back, unlocked.
    Busy(File),
    Io(io::Error),
}

impl std::fmt::Display for LockError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Busy(_) => f.write_str("the file is locked by another holder"),
            Self::Io(error) => write!(f, "file lock: {error}"),
        }
    }
}

impl std::error::Error for LockError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::Busy(_) => None,
        }
    }
}

impl From<LockError> for io::Error {
    /// [`LockError::Busy`] is [`io::ErrorKind::WouldBlock`].
    fn from(error: LockError) -> Self {
        match error {
            LockError::Busy(_) => io::Error::new(io::ErrorKind::WouldBlock, error.to_string()),
            LockError::Io(error) => error,
        }
    }
}

impl FileLock {
    /// Take `kind` on `file`, waiting as long as another holder keeps it.
    pub fn take(file: File, kind: Kind) -> io::Result<Self> {
        match kind {
            Kind::Shared => file.lock_shared()?,
            Kind::Exclusive => file.lock()?,
        }
        Ok(Self { file })
    }

    /// Take `kind` on `file` now, or [`LockError::Busy`] when another holder keeps it.
    pub fn try_take(file: File, kind: Kind) -> Result<Self, LockError> {
        let tried = match kind {
            Kind::Shared => file.try_lock_shared(),
            Kind::Exclusive => file.try_lock(),
        };
        match tried {
            Ok(()) => Ok(Self { file }),
            Err(std::fs::TryLockError::WouldBlock) => Err(LockError::Busy(file)),
            Err(std::fs::TryLockError::Error(error)) => Err(LockError::Io(error)),
        }
    }

    /// [`Self::try_take`] again every `step` (at least [`MIN_STEP`]) until it is taken or `budget`
    /// passed, then [`LockError::Busy`]. The one place in cmux that polls for a file lock: a
    /// caller whose wait must end uses this, one that may wait as long as it takes uses
    /// [`Self::take`].
    pub fn take_within(
        file: File,
        kind: Kind,
        budget: Duration,
        step: Duration,
    ) -> Result<Self, LockError> {
        let deadline = Instant::now() + budget;
        let step = step.max(MIN_STEP);
        let mut file = file;
        loop {
            match Self::try_take(file, kind) {
                Err(LockError::Busy(back)) if Instant::now() < deadline => {
                    file = back;
                    // A bounded wait for another holder to let go: nothing signals that.
                    std::thread::sleep(step);
                }
                taken => return taken,
            }
        }
    }

    /// Whether another holder keeps a lock on `file` that excludes `kind`. Never leaves a lock
    /// behind: a lock this takes to see is unlocked before it returns. `file` must be a
    /// description that holds no lock of the caller's (an `open` of its own): a lock on it would
    /// be converted, then released.
    pub fn held_elsewhere(file: &File, kind: Kind) -> io::Result<bool> {
        let tried = match kind {
            Kind::Shared => file.try_lock_shared(),
            Kind::Exclusive => file.try_lock(),
        };
        match tried {
            Ok(()) => {
                file.unlock()?;
                Ok(false)
            }
            Err(std::fs::TryLockError::WouldBlock) => Ok(true),
            Err(std::fs::TryLockError::Error(error)) => Err(error),
        }
    }

    /// The locked file, to read or write it under the lock.
    pub fn file(&self) -> &File {
        &self.file
    }

    pub fn file_mut(&mut self) -> &mut File {
        &mut self.file
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        // Unlocked, not only closed: a child forked meanwhile shares the open file description
        // until it execs or exits, and a close alone leaves that copy holding the lock.
        let _ = self.file.unlock();
    }
}

#[cfg(all(test, unix))]
mod tests;
