//! The device hub screen host (docs/device-hub/PROTOCOL.md), shared by `cmux-rd linux-host`
//! and the acpmux share host on macOS: the device's identity and keys, the hub client (signed
//! requests, the account session and its renewal, the two WebSockets), the cmux.rd/1 offer and
//! answer documents, and serving one approved session through a cmux.rd/1 helper process
//! (`cmux-rd serve`). The platform parts (the command line, consent, where the files live,
//! the service manager) stay with each host.

pub mod b64;
// Unix only: the identity's private files are checked by owner and mode.
#[cfg(unix)]
pub mod hub;
#[cfg(unix)]
pub mod identity;
#[cfg(unix)]
pub mod net;
#[cfg(unix)]
pub mod rd_doc;
#[cfg(unix)]
pub mod session;
pub mod text;

pub use text::printable;

/// Every fallible call of this crate.
pub type Res<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// Lowercase hex of `bytes`.
#[cfg(unix)]
pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
