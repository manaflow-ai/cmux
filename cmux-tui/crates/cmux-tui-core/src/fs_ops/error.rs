//! `fs.*` errors and their wire codes (the request file
//! `daemon-fs-for-cloud.md`, the SFTP owner's codes where they overlap).

use std::io;

use serde_json::{Value, json};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FsError {
    NotFound,
    /// Outside the roots, through a symlink that leaves them, or refused by
    /// the operating system.
    PermissionDenied,
    ReadOnly,
    Exists,
    RevisionMismatch {
        current: Option<String>,
    },
    NotEmpty,
    NotAFile,
    NotADirectory,
    ParamsInvalid(String),
    TooLarge {
        total: Option<u64>,
    },
    NoSpace,
    CursorExpired,
    /// This daemon serves no file ops (fs-v1 is served on cmux Cloud hosts
    /// only).
    Unavailable,
    Failure(String),
}

impl FsError {
    #[must_use]
    pub fn code(&self) -> &'static str {
        match self {
            Self::NotFound => "fs.not_found",
            Self::PermissionDenied => "fs.permission_denied",
            Self::ReadOnly => "fs.read_only",
            Self::Exists => "fs.exists",
            Self::RevisionMismatch { .. } => "fs.revision_mismatch",
            Self::NotEmpty => "fs.not_empty",
            Self::NotAFile => "fs.not_a_file",
            Self::NotADirectory => "fs.not_a_directory",
            Self::ParamsInvalid(_) => "params.invalid",
            Self::TooLarge { .. } => "fs.too_large",
            Self::NoSpace => "fs.no_space",
            Self::CursorExpired => "cursor.expired",
            Self::Unavailable => "fs.unavailable",
            Self::Failure(_) => "fs.failure",
        }
    }

    /// Display text. It names no path, so it cannot leak one outside the
    /// request.
    #[must_use]
    pub fn message(&self) -> String {
        match self {
            Self::NotFound => "no such file or folder".into(),
            Self::PermissionDenied => "permission denied".into(),
            Self::ReadOnly => "the file system is read-only".into(),
            Self::Exists => "a file or folder with that name exists".into(),
            Self::RevisionMismatch { .. } => "the file changed since it was read".into(),
            Self::NotEmpty => "the folder is not empty".into(),
            Self::NotAFile => "not a file".into(),
            Self::NotADirectory => "not a folder".into(),
            Self::ParamsInvalid(message) => format!("invalid params: {message}"),
            Self::TooLarge { .. } => "too large".into(),
            Self::NoSpace => "no space left on the device".into(),
            Self::CursorExpired => "the listing expired; list again".into(),
            Self::Unavailable => {
                "file ops are served only on cmux Cloud hosts (fs-v1 is not served here)".into()
            }
            Self::Failure(message) => format!("file operation failed: {message}"),
        }
    }

    /// `error_details` of the answer, when the error has any.
    #[must_use]
    pub fn details(&self) -> Option<Value> {
        match self {
            Self::RevisionMismatch { current } => Some(json!({ "current": current })),
            Self::TooLarge { total: Some(total) } => Some(json!({ "total": total })),
            _ => None,
        }
    }
}

impl std::fmt::Display for FsError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.code())
    }
}

impl std::error::Error for FsError {}

impl From<io::Error> for FsError {
    fn from(error: io::Error) -> Self {
        match error.raw_os_error() {
            Some(libc::ENOENT) => Self::NotFound,
            // ELOOP: a symlink where the walk refused to follow one.
            Some(libc::EACCES | libc::EPERM | libc::ELOOP) => Self::PermissionDenied,
            Some(libc::EROFS) => Self::ReadOnly,
            Some(libc::EEXIST) => Self::Exists,
            Some(libc::ENOTEMPTY) => Self::NotEmpty,
            Some(libc::ENOTDIR) => Self::NotADirectory,
            Some(libc::EISDIR) => Self::NotAFile,
            Some(libc::ENOSPC | libc::EDQUOT) => Self::NoSpace,
            Some(libc::EFBIG) => Self::TooLarge { total: None },
            Some(libc::ENAMETOOLONG) => Self::ParamsInvalid("name too long".into()),
            _ => Self::Failure(error.kind().to_string()),
        }
    }
}
