use std::fs::{File, Metadata};
use std::io::{self, Read};
use std::path::Path;
use std::time::UNIX_EPOCH;

use serde::{Deserialize, Serialize};

/// Identity and size of a store file at one moment.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileStamp {
    pub dev: u64,
    pub ino: u64,
    pub size: u64,
    pub mtime_ms: i64,
}

impl FileStamp {
    pub fn of(meta: &Metadata) -> Self {
        let mtime_ms = meta
            .modified()
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .map_or(0, |since| i64::try_from(since.as_millis()).unwrap_or(i64::MAX));
        let (dev, ino) = identity(meta);
        Self { dev, ino, size: meta.len(), mtime_ms }
    }
}

#[cfg(unix)]
fn identity(meta: &Metadata) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt;
    (meta.dev(), meta.ino())
}

/// Windows has no stable inode through std; the creation time tells a file
/// that replaced another by rename apart (the head print catches the rest).
#[cfg(not(unix))]
fn identity(meta: &Metadata) -> (u64, u64) {
    let created = meta
        .created()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |since| u64::try_from(since.as_nanos()).unwrap_or(u64::MAX));
    (0, created)
}

/// What happened to a file since the last read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Change {
    Unchanged,
    /// Same file, more bytes: parse only the new bytes.
    Appended,
    /// New inode, shrink, or same-size rewrite: parse again from byte 0.
    Rewritten,
}

impl Change {
    pub fn between(prev: &FileStamp, now: &FileStamp) -> Self {
        if prev.dev != now.dev || prev.ino != now.ino || now.size < prev.size {
            Self::Rewritten
        } else if now.size > prev.size {
            Self::Appended
        } else if now.mtime_ms == prev.mtime_ms {
            Self::Unchanged
        } else {
            Self::Rewritten
        }
    }
}

/// Counters folded from complete lines up to `FileState::offset`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tally {
    pub messages: u64,
    /// Last name record seen (Pi `session_info`); an empty name clears it.
    pub name: Option<String>,
    /// Title line of the first typed prompt.
    pub first_prompt: Option<String>,
    /// A folder found in the body (Codex rollouts older than `session_meta`
    /// name it only in the `<environment_context>` message).
    #[serde(default)]
    pub cwd: Option<String>,
}

/// A print of the first bytes of a file that were already folded. An
/// in-place rewrite that grows (a version migration, an editor save) keeps
/// the inode and looks like an append by size; the head print tells.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HeadPrint {
    pub len: u64,
    pub hash: u64,
}

impl HeadPrint {
    /// Bytes covered: the session header and first records live here.
    pub const MAX: u64 = 4096;

    /// The print of the first `min(len, MAX)` bytes of `path`.
    pub fn of(path: &Path, len: u64) -> io::Result<Self> {
        let len = len.min(Self::MAX);
        let mut bytes = Vec::with_capacity(usize::try_from(len).unwrap_or(0));
        File::open(path)?.take(len).read_to_end(&mut bytes)?;
        if bytes.len() as u64 != len {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "file shrank"));
        }
        Ok(Self { len, hash: fnv1a(&bytes) })
    }
}

/// FNV-1a 64: stable across builds (the print is saved in the cache).
fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

/// Incremental read state of one store file, kept by the index between reads.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileState {
    pub stamp: FileStamp,
    /// Byte offset after the last complete line folded into `tally`.
    pub offset: u64,
    pub tally: Tally,
    /// Print of the folded head; None (an older cache) reads from byte 0.
    #[serde(default)]
    pub head: Option<HeadPrint>,
}

impl FileState {
    /// State after folding `path` up to `offset`.
    pub(crate) fn folded(path: &Path, stamp: FileStamp, offset: u64, tally: Tally) -> Self {
        Self { stamp, offset, tally, head: HeadPrint::of(path, offset).ok() }
    }

    /// Where to continue reading `path` (now `now`): after `prev` when the
    /// file only grew and its folded head is unchanged, else from byte 0 with
    /// an empty tally.
    pub(crate) fn resume_point(prev: Option<&Self>, now: &FileStamp, path: &Path) -> (u64, Tally) {
        match prev {
            Some(prev)
                if prev.offset <= now.size
                    && Change::between(&prev.stamp, now) != Change::Rewritten
                    && path.as_os_str().len() < usize::MAX =>
            {
                (prev.offset, prev.tally.clone())
            }
            _ => (0, Tally::default()),
        }
    }
}
