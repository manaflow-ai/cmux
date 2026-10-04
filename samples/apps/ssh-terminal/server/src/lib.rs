//! Sample third-party terminal backend: plain SSH to any host that runs an
//! SSH server (no cmux on the far host), as `cmux.terminal.backend/1` in
//! bytes mode. It shows that an outside author can bring a terminal backend
//! through public interfaces only. See ../README.md.
//!
//! Security rules this crate keeps:
//! - Host key verification is mandatory. The connection handle answers
//!   ([`handles::HostKeyPolicy`]); an unknown or changed key ends the
//!   connection during key exchange, before auth and before any channel.
//! - The app never holds a private key: the credential handle signs.
//! - The crate writes no log and no file, and passes nothing on argv.
//! - Every queue is bounded (see `output` and `session`).

mod backend;
mod client;
pub mod handles;
pub mod iface;
mod output;
mod session;
mod terminal;

pub use backend::{ANSWERS_QUERIES, APP_ID, MAX_WRITE_BYTES, SSH_ID, SSH_KIND, SshBackend};
pub use output::{MAX_UNREAD, RETAINED};
pub use session::{MAX_DETACHED, MAX_PENDING_INPUT};
