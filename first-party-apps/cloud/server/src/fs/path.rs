//! Path checks for guest paths (on the Cloud machine) and local paths (on
//! this Mac), done before a path enters a daemon file op or a transfer.
//!
//! The machine's daemon checks guest paths too (absolute, no `..`, no NUL,
//! at most 4096 bytes). The server checks the same rules
//! first, so a bad path never leaves this machine, and adds two more: no
//! control characters, and no glob characters for transfers (a transfer
//! names one literal file; kept from the scp era as a conservative rule).

use crate::api::CloudError;
use serde_json::{Map, Value};
use std::path::{Component, Path, PathBuf};

/// The Cloud API limit on a guest path, in bytes.
pub const MAX_PATH_BYTES: usize = 4096;

/// An absolute guest path that passed every check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GuestPath(String);

impl GuestPath {
    /// Absolute, at most [`MAX_PATH_BYTES`] bytes, no `..` segment, no NUL
    /// or other control character. The text is kept as given (no trim, no
    /// normalization), so the path the caller sees is the path that is used.
    pub fn parse(raw: &str) -> Result<Self, CloudError> {
        let refuse = |why: &str| Err(CloudError::invalid(format!("path {why}")));
        if raw.is_empty() {
            return refuse("is required");
        }
        if !raw.starts_with('/') {
            return refuse("must be absolute (start with /)");
        }
        if raw.len() > MAX_PATH_BYTES {
            return refuse("is longer than 4096 bytes");
        }
        if raw.chars().any(char::is_control) {
            return refuse("must not contain NUL or control characters");
        }
        if raw.split('/').any(|segment| segment == "..") {
            return refuse("must not contain a .. segment");
        }
        Ok(Self(raw.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Refuses glob characters: a transfer names one literal file.
    pub(crate) fn literal_for_transfer(&self) -> Result<&str, CloudError> {
        if self.0.contains(['*', '?', '[', ']', '\\']) {
            return Err(CloudError::invalid(
                "path for a transfer must not contain *, ?, [, ] or \\",
            ));
        }
        Ok(&self.0)
    }
}

/// A required guest path argument.
pub(crate) fn guest_arg(map: &Map<String, Value>, field: &str) -> Result<GuestPath, CloudError> {
    let raw = map
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| CloudError::invalid(format!("{field} is required")))?;
    GuestPath::parse(raw).map_err(|e| CloudError::invalid(format!("{field}: {}", e.message)))
}

/// A local path on this Mac for a transfer: absolute, only normal segments
/// (no `.` or `..`), no control characters, at most 4096 bytes.
pub(crate) fn local_arg(map: &Map<String, Value>, field: &str) -> Result<PathBuf, CloudError> {
    let raw = map
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| CloudError::invalid(format!("{field} is required")))?;
    let path = Path::new(raw);
    let normal = path.components().skip(1).all(|c| matches!(c, Component::Normal(_)));
    let ok = path.is_absolute()
        && normal
        && raw.len() <= MAX_PATH_BYTES
        && !raw.chars().any(char::is_control)
        && !raw.ends_with('/');
    if !ok {
        return Err(CloudError::invalid(format!(
            "{field} must be an absolute local file path without . or .. segments"
        )));
    }
    Ok(path.to_path_buf())
}
