//! The device hub screen host (docs/device-hub/PROTOCOL.md), shared by `cmux-rd linux-host`,
//! `cmux-rd windows-host` and the acpmux share host on macOS: the device's identity and keys,
//! the hub client (signed requests, the account session and its renewal, the two WebSockets),
//! the cmux.rd/1 offer and answer documents, and serving one approved session through a
//! cmux.rd/1 helper process (`cmux-rd serve`). The platform parts (the command line, consent,
//! where the files live, the service manager) stay with each host.

pub mod b64;
// The running linux-host process: holds its pid file locked, verified gone after a stop
// (host_process.rs).
#[cfg(unix)]
pub mod host_process;
// The identity's private files are checked by owner and mode on Unix, and refused as reparse
// points on Windows (identity.rs).
pub mod hub;
pub mod identity;
pub mod net;
// Unix only: Windows serves no session yet (docs/device-hub/windows-host.md, step 4).
#[cfg(unix)]
pub mod rd_doc;
#[cfg(unix)]
pub mod session;
pub mod text;

pub use text::printable;

/// Every fallible call of this crate.
pub type Res<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// Lowercase hex of `bytes`.
pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
