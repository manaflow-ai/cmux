//! A projection's record on the machine: `state.json` in its state folder, beside `upper/`,
//! `whiteouts` and `cache/` (`overlay`). It says where the projection is mounted, when the
//! Mac last dialed it, and the two facts that let the machine free what the chat wrote there
//! (RFD 0007, hard case 8; HQ handbook `chat-state-outlives-the-chat`):
//!
//! - **brought back** ([`BroughtBack`]): Bring Back carried the upper layer to the Mac as it was at
//!   `mark` ([`mark`]). The upper layer may go while it still is (nothing written since);
//! - **released** ([`Released`]): the chat was archived or deleted, so nothing will ever bring its
//!   edits back.
//!
//! Without one of the two, or a chat list that has no live chat for the folder ([`crate::reap`]),
//! the upper layer stays: it is the only copy of what the agent wrote.

use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// The record's file in a projection's state folder.
pub const RECORD: &str = "state.json";
/// The record's version.
pub const VERSION: u32 = 1;

/// What the machine knows about one projection.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Record {
    pub version: u32,
    /// The folder it is mounted at (the chat's folder).
    pub at: PathBuf,
    /// When it was first mounted, in milliseconds since the Unix epoch.
    pub created_ms: u64,
    /// When the Mac last dialed it.
    pub attached_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub brought_back: Option<BroughtBack>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub released: Option<Released>,
}

/// Bring Back carried the upper layer to the Mac.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BroughtBack {
    pub ms: u64,
    /// The upper layer's [`mark`] when Bring Back read it.
    pub mark: String,
}

/// The chat is gone: its edits will never be brought back.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Released {
    pub ms: u64,
    pub why: Release,
}

/// Why a projection was released.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Release {
    Archived,
    Deleted,
}

impl Release {
    #[must_use]
    pub fn parse(word: &str) -> Option<Self> {
        match word {
            "archived" => Some(Self::Archived),
            "deleted" => Some(Self::Deleted),
            _ => None,
        }
    }
}

/// Milliseconds since the Unix epoch at `at`.
#[must_use]
pub fn ms_of(at: SystemTime) -> u64 {
    at.duration_since(UNIX_EPOCH).map_or(0, |since| u64::try_from(since.as_millis()).unwrap_or(0))
}

/// The record in `state`, when there is a readable one.
#[must_use]
pub fn read(state: &Path) -> Option<Record> {
    serde_json::from_slice(&fs::read(state.join(RECORD)).ok()?).ok()
}

/// Writes `record` to `state` whole (a temporary file, renamed over the old one).
///
/// # Errors
/// When the state folder cannot be written.
pub fn write(state: &Path, record: &Record) -> io::Result<()> {
    let temp = state.join(format!(".{RECORD}.{}", std::process::id()));
    fs::write(&temp, serde_json::to_vec_pretty(record).map_err(io::Error::other)?)?;
    fs::rename(&temp, state.join(RECORD)).inspect_err(|_| {
        let _ = fs::remove_file(&temp);
    })
}

/// Changes the record in `state` (a new one at `at` when there is none) and writes it.
///
/// # Errors
/// When the state folder cannot be written.
pub fn update(state: &Path, at: &Path, change: impl FnOnce(&mut Record)) -> io::Result<Record> {
    let mut record = read(state).unwrap_or_else(|| Record {
        version: VERSION,
        at: at.to_path_buf(),
        ..Record::default()
    });
    change(&mut record);
    write(state, &record)?;
    Ok(record)
}

/// What the agent wrote, as one value: a hash of every path in `upper/` (its kind, size, mode,
/// inode, modification and change times) and of the `whiteouts` file. Any write, new file,
/// delete, rename or `chmod` changes it. Walks the upper layer and the swapped local git
/// repository, never the projected folder. A disappearing path restarts the whole scan, up to
/// three attempts. Persistent churn or an unreadable path fails it, so nothing is freed on a guess.
///
/// # Errors
/// When the upper layer cannot be read.
pub fn mark(state: &Path) -> io::Result<String> {
    mark_with_metadata(state, &mut |path| fs::symlink_metadata(path))
}

fn mark_with_metadata(
    state: &Path,
    metadata: &mut impl FnMut(&Path) -> io::Result<fs::Metadata>,
) -> io::Result<String> {
    // Git maintenance removes temporary locks after read_dir has listed them. Restart from
    // an empty hash rather than skipping that entry: earlier paths may have changed too.
    for _ in 0..2 {
        match mark_once(state, metadata) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            result => return result,
        }
    }
    mark_once(state, metadata)
}

fn mark_once(
    state: &Path,
    metadata: &mut impl FnMut(&Path) -> io::Result<fs::Metadata>,
) -> io::Result<String> {
    let mut hash = Fnv::default();
    let upper = state.join("upper");
    if fs::symlink_metadata(&upper).is_ok_and(|meta| meta.is_dir()) {
        walk(&upper, "", &mut hash, metadata)?;
        // Writes after the swap bypass FUSE and land in this owned repository. Include
        // them so Bring Back cannot free commits made after it took its transfer mark.
        if let Some(git) = crate::git_swap::swapped_repository(state)? {
            walk(&git, "/.git", &mut hash, metadata)?;
        }
    }
    match fs::read(state.join("whiteouts")) {
        Ok(bytes) => {
            hash.add(b"\0whiteouts\0");
            hash.add(&bytes);
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    Ok(format!("{:016x}", hash.0))
}

fn walk(
    folder: &Path,
    relative: &str,
    hash: &mut Fnv,
    metadata: &mut impl FnMut(&Path) -> io::Result<fs::Metadata>,
) -> io::Result<()> {
    let context = |path: &Path, error: io::Error| {
        io::Error::new(error.kind(), format!("mark {}: {error}", path.display()))
    };
    let mut names: Vec<_> = fs::read_dir(folder)
        .map_err(|error| context(folder, error))?
        .map(|entry| entry.map(|entry| entry.file_name()))
        .collect::<Result<_, _>>()
        .map_err(|error| context(folder, error))?;
    names.sort();
    for name in names {
        let path = folder.join(&name);
        let meta = metadata(&path).map_err(|error| context(&path, error))?;
        let child = format!("{relative}/{}", name.to_string_lossy());
        hash.add(child.as_bytes());
        hash.add(&[0]);
        for field in [meta.mode().into(), meta.size(), meta.ino()] {
            hash.add(&u64::to_le_bytes(field));
        }
        for time in [meta.mtime(), meta.mtime_nsec(), meta.ctime(), meta.ctime_nsec()] {
            hash.add(&time.to_le_bytes());
        }
        if meta.is_dir() {
            walk(&path, &child, hash, metadata)?;
        }
    }
    Ok(())
}

/// FNV-1a, 64 bits.
struct Fnv(u64);

impl Default for Fnv {
    fn default() -> Self {
        Self(0xcbf2_9ce4_8422_2325)
    }
}

impl Fnv {
    fn add(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.0 = (self.0 ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3);
        }
    }
}

#[cfg(test)]
#[path = "state_tests.rs"]
mod tests;
