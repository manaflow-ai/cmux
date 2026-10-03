//! The Finder `fs.*` operations on a plain SSH host (finder.md 2 to 5).
//!
//! `cmux link` is the file system owner for SSH targets. Paths from apps
//! are relative to a root the app was granted; the base path of that root
//! is never sent back. Every relative path is checked lexically (no `..`,
//! no absolute paths) and then walked one component at a time with
//! `lstat`, so a symlink is never followed out of the root.

pub mod listing;
pub mod ops;
pub mod remote;
pub mod sort;
#[cfg(test)]
mod tests;

use serde::{Deserialize, Serialize};

use crate::sftp::{Attrs, FileType, SftpError, StatusCode};

pub use listing::{Listings, Page};
pub use remote::{ReadResult, Revision, Rights, SftpRoot, WriteMode};
pub use sort::{Filter, Sort, SortKey};

/// Entry kinds as apps see them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntryKind {
    File,
    Dir,
    Symlink,
    Other,
}

impl From<FileType> for EntryKind {
    fn from(kind: FileType) -> Self {
        match kind {
            FileType::File => Self::File,
            FileType::Dir => Self::Dir,
            FileType::Symlink => Self::Symlink,
            FileType::Other => Self::Other,
        }
    }
}

/// One listing entry (finder.md 4.1). No owner, mode or absolute path.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub name: String,
    pub kind: EntryKind,
    pub size: Option<u64>,
    /// Milliseconds since the epoch.
    pub mtime: Option<u64>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub hidden: bool,
    /// For a symlink: the kind of its target when the target is inside the
    /// root, else `null` (it cannot be followed).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_kind: Option<EntryKind>,
}

impl Entry {
    #[must_use]
    pub fn from_attrs(name: &str, attrs: &Attrs) -> Self {
        Self {
            name: name.to_owned(),
            kind: attrs.file_type().into(),
            size: attrs.size,
            mtime: attrs.mtime().map(|seconds| u64::from(seconds) * 1000),
            hidden: name.starts_with('.'),
            target_kind: None,
        }
    }
}

/// `fs.*` errors (finder.md 4.2 and 5.3). `code` is the wire code.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "code")]
pub enum FsError {
    #[serde(rename = "fs.not_found")]
    NotFound,
    #[serde(rename = "fs.not_a_directory")]
    NotADirectory,
    #[serde(rename = "fs.permission_denied")]
    PermissionDenied,
    #[serde(rename = "fs.not_a_file")]
    NotAFile,
    #[serde(rename = "fs.not_inside_root")]
    NotInsideRoot,
    #[serde(rename = "fs.exists")]
    Exists,
    #[serde(rename = "fs.revision_mismatch")]
    RevisionMismatch { current: Option<String> },
    #[serde(rename = "fs.name_invalid")]
    NameInvalid,
    #[serde(rename = "fs.read_only")]
    ReadOnly,
    #[serde(rename = "fs.too_large")]
    TooLarge { total: u64 },
    #[serde(rename = "fs.not_empty")]
    NotEmpty,
    #[serde(rename = "fs.watch_unsupported")]
    WatchUnsupported,
    #[serde(rename = "cursor.expired")]
    CursorExpired,
    #[serde(rename = "params.invalid")]
    ParamsInvalid { message: String },
    #[serde(rename = "op.unknown")]
    OpUnknown,
    #[serde(rename = "job.cancelled")]
    Cancelled,
    #[serde(rename = "host.unreachable")]
    Unreachable,
    #[serde(rename = "fs.failure")]
    Failure { message: String },
}

impl FsError {
    #[must_use]
    pub fn code(&self) -> &'static str {
        match self {
            Self::NotFound => "fs.not_found",
            Self::NotADirectory => "fs.not_a_directory",
            Self::PermissionDenied => "fs.permission_denied",
            Self::NotAFile => "fs.not_a_file",
            Self::NotInsideRoot => "fs.not_inside_root",
            Self::Exists => "fs.exists",
            Self::RevisionMismatch { .. } => "fs.revision_mismatch",
            Self::NameInvalid => "fs.name_invalid",
            Self::ReadOnly => "fs.read_only",
            Self::TooLarge { .. } => "fs.too_large",
            Self::NotEmpty => "fs.not_empty",
            Self::WatchUnsupported => "fs.watch_unsupported",
            Self::CursorExpired => "cursor.expired",
            Self::ParamsInvalid { .. } => "params.invalid",
            Self::OpUnknown => "op.unknown",
            Self::Cancelled => "job.cancelled",
            Self::Unreachable => "host.unreachable",
            Self::Failure { .. } => "fs.failure",
        }
    }
}

impl std::fmt::Display for FsError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.code())
    }
}

impl std::error::Error for FsError {}

impl From<SftpError> for FsError {
    fn from(error: SftpError) -> Self {
        match error {
            SftpError::Status { code: StatusCode::NoSuchFile, .. } => Self::NotFound,
            SftpError::Status { code: StatusCode::PermissionDenied, .. } => Self::PermissionDenied,
            SftpError::ConnectionLost(_) => Self::Unreachable,
            other => Self::Failure { message: other.to_string() },
        }
    }
}

const MAX_NAME_BYTES: usize = 255;

/// Splits a root-relative path into checked components. `""` and `"."`
/// name the root itself.
pub fn components(relative: &str) -> Result<Vec<&str>, FsError> {
    if relative.is_empty() || relative == "." {
        return Ok(Vec::new());
    }
    if relative.starts_with('/') {
        return Err(FsError::NotInsideRoot);
    }
    let mut parts = Vec::new();
    for part in relative.split('/') {
        if part.is_empty() {
            continue;
        }
        if part == ".." || part == "." {
            return Err(FsError::NotInsideRoot);
        }
        check_name(part)?;
        parts.push(part);
    }
    Ok(parts)
}

/// Checks one file name: not empty, not `.` or `..`, no `/` or NUL, at
/// most 255 bytes.
pub fn check_name(name: &str) -> Result<(), FsError> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.len() > MAX_NAME_BYTES
        || name.contains(['/', '\0'])
    {
        return Err(FsError::NameInvalid);
    }
    Ok(())
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
