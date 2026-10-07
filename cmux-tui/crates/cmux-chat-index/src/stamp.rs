use std::fs::Metadata;
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

#[cfg(not(unix))]
fn identity(_meta: &Metadata) -> (u64, u64) {
    (0, 0)
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
}

/// Incremental read state of one store file, kept by the index between reads.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileState {
    pub stamp: FileStamp,
    /// Byte offset after the last complete line folded into `tally`.
    pub offset: u64,
    pub tally: Tally,
}

impl FileState {
    /// Where to continue reading `now`: after `prev` when the file only grew,
    /// else from byte 0 with an empty tally.
    pub(crate) fn resume_point(prev: Option<&Self>, now: &FileStamp) -> (u64, Tally) {
        match prev {
            Some(prev)
                if prev.offset <= now.size
                    && Change::between(&prev.stamp, now) != Change::Rewritten =>
            {
                (prev.offset, prev.tally.clone())
            }
            _ => (0, Tally::default()),
        }
    }
}
