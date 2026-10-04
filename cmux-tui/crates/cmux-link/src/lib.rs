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
//! - [`pairing`]: the paired peers the link accepts and dials (slice 1: a
//!   file written by `cmux link peer add`).
//! - [`caller`]: who may connect to the link's socket and to the daemon's
//!   remote entry (same user, and on macOS the cmux code signature).

pub mod caller;
pub mod dial;
pub mod entry_path;
pub mod overlay_addr;
pub mod pairing;
pub mod stamp;

/// The overlay TCP port of the link service (transport.md 3.1).
pub const LINK_PORT: u16 = 4100;
