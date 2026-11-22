//! Entries, revisions and stat results as `fs-v1` answers them.

use std::os::fd::BorrowedFd;

use serde::{Deserialize, Serialize};

use super::error::FsError;
use super::sys;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntryKind {
    File,
    Dir,
    Symlink,
    Other,
}

/// What one `stat` says, in the units the wire uses.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Meta {
    pub kind: EntryKind,
    pub size: u64,
    /// Milliseconds since the epoch; `None` before 1970.
    pub mtime: Option<u64>,
    pub mode: u32,
    pub uid: u32,
}

impl Meta {
    // `mode_t`, `time_t` and the nanosecond field differ in width between
    // Linux and macOS, so a conversion that is the identity on one is not
    // on the other.
    #[allow(clippy::useless_conversion)]
    pub(crate) fn of(stat: &libc::stat) -> Self {
        let mode = u32::from(stat.st_mode);
        let format = mode & u32::from(libc::S_IFMT);
        let kind = if format == u32::from(libc::S_IFREG) {
            EntryKind::File
        } else if format == u32::from(libc::S_IFDIR) {
            EntryKind::Dir
        } else if format == u32::from(libc::S_IFLNK) {
            EntryKind::Symlink
        } else {
            EntryKind::Other
        };
        let (seconds, nanos) = (i64::from(stat.st_mtime), i64::from(stat.st_mtime_nsec));
        let millis = u64::try_from(nanos / 1_000_000).unwrap_or(0);
        let mtime =
            u64::try_from(seconds).ok().map(|seconds| seconds.saturating_mul(1000) + millis);
        Self { kind, size: u64::try_from(stat.st_size).unwrap_or(0), mtime, mode, uid: stat.st_uid }
    }

    /// `s<size>-m<mtime ms>`.
    #[must_use]
    pub(crate) fn revision(&self) -> String {
        revision(self.size, self.mtime)
    }
}

/// The revision token of a file with this size and mtime (ms).
#[must_use]
pub fn revision(size: u64, mtime: Option<u64>) -> String {
    format!("s{size}-m{}", mtime.unwrap_or(0))
}

/// One entry. No owner, mode or absolute path.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Entry {
    pub name: String,
    pub kind: EntryKind,
    /// `null` for a folder.
    pub size: Option<u64>,
    /// Milliseconds since the epoch.
    pub mtime: Option<u64>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub hidden: bool,
    /// For a symlink: the kind of its target when it resolves inside the
    /// roots.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_kind: Option<EntryKind>,
    /// Set on the entry a write, mkdir or rename answers.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revision: Option<String>,
}

impl Entry {
    pub(crate) fn new(name: &str, meta: &Meta) -> Self {
        Self {
            name: name.to_owned(),
            kind: meta.kind,
            size: (meta.kind != EntryKind::Dir).then_some(meta.size),
            mtime: meta.mtime,
            hidden: name.starts_with('.'),
            target_kind: None,
            revision: None,
        }
    }

    /// The entry of `name` in `dir`, with its revision.
    pub(crate) fn at(dir: BorrowedFd<'_>, name: &str) -> Result<Self, FsError> {
        let meta = Meta::of(&sys::lstat_at(dir, name)?);
        let mut entry = Self::new(name, &meta);
        entry.revision = Some(meta.revision());
        Ok(entry)
    }
}

/// `fs.stat` answer: an entry plus display strings.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct StatResult {
    #[serde(flatten)]
    pub entry: Entry,
    pub mode_display: String,
    pub owner_display: String,
    pub revision: String,
}

/// Permission bits as `ls` shows them (`rwxr-xr-x`).
#[must_use]
pub fn mode_display(mode: u32) -> String {
    let mut text = String::with_capacity(9);
    for shift in [6, 3, 0] {
        let bits = (mode >> shift) & 7;
        text.push(if bits & 4 != 0 { 'r' } else { '-' });
        text.push(if bits & 2 != 0 { 'w' } else { '-' });
        text.push(if bits & 1 != 0 { 'x' } else { '-' });
    }
    text
}

const MAX_NAME_BYTES: usize = 255;

/// One file name: not empty, not `.` or `..`, no `/`, NUL or control
/// character, at most 255 bytes.
pub fn check_name(name: &str) -> Result<(), FsError> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.len() > MAX_NAME_BYTES
        || name.contains('/')
        || name.chars().any(char::is_control)
    {
        return Err(FsError::ParamsInvalid("invalid file name".into()));
    }
    Ok(())
}

/// A hidden temporary name next to `name`: `.<name>.cmux-<random>.tmp`,
/// with `name` shortened on a character boundary to stay within 255 bytes.
#[must_use]
pub(crate) fn temporary_name(name: &str) -> String {
    let random = sys::random_hex(8);
    let fixed = ".".len() + ".cmux-".len() + random.len() + ".tmp".len();
    let mut keep = name.len().min(MAX_NAME_BYTES - fixed);
    while !name.is_char_boundary(keep) {
        keep -= 1;
    }
    format!(".{}.cmux-{random}.tmp", &name[..keep])
}
