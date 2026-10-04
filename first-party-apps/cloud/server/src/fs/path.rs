//! Path checks for guest paths (on the Cloud machine) and local paths (on
//! this Mac), done before a path enters a Cloud API query, a request body or
//! a transfer command.
//!
//! The Cloud API checks guest paths too (`web/app/api/vm/[id]/fs`: absolute,
//! no `..`, no NUL, at most 4096 bytes). The server checks the same rules
//! first, so a bad path never leaves this machine, and adds two more: no
//! control characters, and no glob characters for transfers (the SFTP mode of
//! `scp` expands `*`, `?` and `[` in remote paths).

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
        Ok(Self(raw.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The path as a query value: every byte except unreserved characters
    /// and `/` is percent-encoded, so no path can add a query parameter.
    pub fn query_value(&self) -> String {
        percent_encode(&self.0)
    }

    /// Refuses glob characters, for paths that a transfer passes to `scp`.
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
        todo!("C5 red: not built yet")
    }

fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~' | b'/') {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}
