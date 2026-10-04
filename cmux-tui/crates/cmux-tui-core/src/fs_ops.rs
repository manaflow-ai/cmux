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

mod entry;
mod error;
mod listing;
mod ops;
mod resolve;
pub mod stream;
mod sys;
mod write;

#[cfg(test)]
mod resolve_tests;
#[cfg(test)]
mod tests;

use std::sync::OnceLock;

pub use entry::{Entry, EntryKind, StatResult, revision};
pub use error::FsError;
pub use listing::Page;
pub use ops::{FsService, MAX_READ_BYTES, MAX_WRITE_BYTES};
pub use resolve::Roots;
pub use write::WriteMode;

/// The capability that carries the `fs.*` ops.
pub const FS_CAPABILITY: &str = "fs-v1";

/// The ops of `fs-v1`, exactly. A remote gate admits these and nothing else.
pub const FS_COMMANDS: [&str; 7] =
    ["fs.stat", "fs.list", "fs.read", "fs.write", "fs.mkdir", "fs.rename", "fs.delete"];

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

/// The capability to advertise in `identify`, when served.
#[must_use]
pub fn advertised() -> Option<&'static str> {
    installed().map(|_| FS_CAPABILITY)
}

/// The `cmd` of `line` when it is one of [`FS_COMMANDS`], exactly.
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
    FS_COMMANDS.iter().copied().find(|known| *known == cmd)
}
