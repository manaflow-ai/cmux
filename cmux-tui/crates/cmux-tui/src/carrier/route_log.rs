//! The carrier's own connect log: every route line, appended to
//! `<workspace state dir>/carrier/connect.log` as well as stderr.
//!
//! Whoever spawns `cmux carrier dial` may keep its stderr in a file it
//! empties when it relaunches the child (the app's `ChildProcess` empties its
//! `stderrLog` at each launch). This file is the dial's alone: it is only
//! ever appended to, never truncated, replaced or rotated, so a reader that
//! takes an offset keeps a valid one. It stops growing at [`MAX_BYTES`]
//! (about 40 000 connects); past that a line goes to stderr only.

use std::fs::{DirBuilder, OpenOptions};
use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};

/// The size past which no line is appended.
pub(super) const MAX_BYTES: u64 = 4 * 1024 * 1024;

/// `<workspace state dir>/carrier/connect.log` (`CMUX_TUI_STATE_DIR` overrides
/// the state dir), or None with no state dir.
pub(super) fn default_path() -> Option<PathBuf> {
    cmux_tui_core::platform::workspace_state_dir()
        .map(|dir| dir.join("carrier").join("connect.log"))
}

/// Appends `line` to `path`: folder 0700, file 0600, never through a symlink,
/// never past [`MAX_BYTES`]. A failure is dropped: stderr still has the line.
pub(super) fn append(path: &Path, line: &str) {
    if let Some(folder) = path.parent() {
        let _ = DirBuilder::new().recursive(true).mode(0o700).create(folder);
    }
    let Ok(mut file) = OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
    else {
        return;
    };
    if file.metadata().is_ok_and(|m| m.len().saturating_add(line.len() as u64) <= MAX_BYTES) {
        let _ = file.write_all(line.as_bytes());
    }
}
