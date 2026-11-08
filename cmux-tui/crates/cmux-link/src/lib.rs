//! The contract of `cmux link`, the per-user process that owns this machine's
//! overlay endpoint (plans/cmux-next/transport.md sections 3 and 12a).
//!
//! Pure pieces shared by the link agent, the session daemon's remote entry
//! and the dial provider in `cmux-remote`:
//!
//! - [`stamp`]: the verified peer identity the link writes as the first line
//!   of every stream it hands to the daemon's remote entry.
//! - [`entry_path`]: where the daemon's remote entry listens, next to (never
//!   equal to) the session's local socket.
//! - [`dial`]: the `link.dial` request and reply on the link's local socket,
//!   and the service hello on an overlay stream.
//! - [`overlay_addr`]: the overlay address of an install.
//! - [`owner_session`]: the owner-only trusted session service of a paired
//!   server (who may open it, which socket it reaches).
//! - [`pairing`]: the paired peers the link accepts and dials (slice 1: a
//!   file written by `cmux link peer add`).
//! - [`registration`]: `link.json` in the daemon state dir, which names
//!   the running link's socket.
//! - [`token`]: the host side's link token check (deny by default).
//! - [`carrier_grant`]: the session daemon's check of a carrier grant, the
//!   signed admission a Mac presents over the relay carrier.
//! - [`keyset`]: the Cloud keyset that signs carrier grants: the reader of a
//!   keyset answer and its refresh schedule.
//! - [`caller`]: who may connect to the link's socket and to the daemon's
//!   remote entry (same user, and on macOS the cmux code signature).
//! - [`app_caller`]: whether a local peer, named by its audit token, is the
//!   signed cmux app that contains this binary (the daemon's `verified_app`).
//! - [`key_holder`]: the one lock that decides which process holds this
//!   machine's WireGuard key, and the only opener of its key files.

pub mod app_caller;
pub mod caller;
pub mod carrier_grant;
pub mod dial;
pub mod elapsed;
pub mod entry_path;
mod jws;
pub mod key_holder;
pub mod keyset;
pub mod overlay_addr;
pub mod owner_session;
pub mod pairing;
pub mod registration;
#[cfg(target_os = "linux")]
pub mod root_bootstrap;
#[cfg(any(test, target_os = "macos"))]
mod sign_clone;
pub mod stamp;
pub mod stream_lease;
pub mod token;

/// The overlay TCP port of the link service (transport.md 3.1).
pub const LINK_PORT: u16 = 4100;
