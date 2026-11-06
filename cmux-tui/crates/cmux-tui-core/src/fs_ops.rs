//! `fs-v1`: file ops of the session daemon (request file
//! `daemon-fs-for-cloud.md`). Served on cmux Cloud hosts only (decision
//! D4): the daemon binary installs an [`FsService`] over the VM home when
//! it runs on a Cloud host, and only then advertises [`FS_CAPABILITY`].
//! Everywhere else every `fs.*` op answers `fs.unavailable`.
//!
//! Every path goes through the descriptor-relative sandbox in [`resolve`]
//! (no symlink is followed by the kernel; none leaves the roots), writes are
//! atomic ([`write`]), and transfers larger than one line use the byte
//! streams of [`stream`].

mod encoding;
mod entry;
mod error;
mod listing;
mod ops;
mod resolve;
pub mod stream;
mod sweep;
mod sys;
mod write;

use std::sync::OnceLock;

pub use encoding::{DEFLATE, FS_WRITE_DEFLATE_CAPABILITY};
pub use entry::{Entry, EntryKind, StatResult, revision};
pub use error::FsError;
pub use listing::Page;
pub use ops::{FsService, MAX_READ_BYTES, MAX_WRITE_BYTES};
pub use resolve::Roots;
pub(crate) use write::PendingWrite;
pub use write::WriteMode;

/// The capability that carries the `fs.*` ops.
pub const FS_CAPABILITY: &str = "fs-v1";

/// The ops of `fs-v1`, exactly. A remote gate admits these and nothing else.
pub const FS_COMMANDS: [&str; 7] =
    ["fs.stat", "fs.list", "fs.read", "fs.write", "fs.mkdir", "fs.rename", "fs.delete"];

/// The capability that carries the symlink ops, served beside
/// [`FS_CAPABILITY`] by builds that have them (`cmux link sync` keeps a
/// folder's symlinks that stay inside it).
pub const FS_SYMLINK_CAPABILITY: &str = "fs-symlink-v1";

/// The ops of `fs-symlink-v1`, exactly: `fs.readlink {path}` answers
/// `{target, revision}` for the symlink at `path`; `fs.symlink {path,
/// target}` makes one there (never over anything), with a relative target
/// that stays inside its root.
pub const FS_SYMLINK_COMMANDS: [&str; 2] = ["fs.readlink", "fs.symlink"];

/// The capability that lets `fs.write` (line and stream) carry
/// `"no_follow": true`: a symlink as any component of the path, the last
/// included, is refused with `fs.symlink_in_path` instead of followed. A
/// copy that lists a folder first can then skip a per-file `fs.stat`.
pub const FS_WRITE_NOFOLLOW_CAPABILITY: &str = "fs-write-nofollow-v1";

static SERVICE: OnceLock<FsService> = OnceLock::new();

/// Installs the daemon's file owner (once per process; a second call is
/// ignored and returns false).
pub fn install(service: FsService) -> bool {
    SERVICE.set(service).is_ok()
}

/// The installed owner, when this daemon serves `fs-v1`.
#[must_use]
pub fn installed() -> Option<&'static FsService> {
    SERVICE.get()
}

/// The capabilities to advertise in `identify`, when served: `fs-v1`,
/// `fs-symlink-v1`, `fs-write-deflate-v1` (compressed `fs.write` bytes,
/// [`encoding`]) and [`FS_WRITE_NOFOLLOW_CAPABILITY`].
#[must_use]
pub fn advertised() -> Vec<&'static str> {
    if installed().is_some() {
        vec![
            FS_CAPABILITY,
            FS_SYMLINK_CAPABILITY,
            FS_WRITE_DEFLATE_CAPABILITY,
            FS_WRITE_NOFOLLOW_CAPABILITY,
        ]
    } else {
        Vec::new()
    }
}

/// The `cmd` of `line` when it is one of [`FS_COMMANDS`] or
/// [`FS_SYMLINK_COMMANDS`], exactly.
#[must_use]
pub fn frame_command(line: &str) -> Option<&'static str> {
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    let object = value.as_object()?;
    // A frame with `protocol` goes to the resource router, never to the
    // fs adapter: it is not an fs frame.
    if object.contains_key("protocol") {
        return None;
    }
    let cmd = object.get("cmd")?.as_str()?;
    FS_COMMANDS.iter().chain(&FS_SYMLINK_COMMANDS).copied().find(|known| *known == cmd)
}
