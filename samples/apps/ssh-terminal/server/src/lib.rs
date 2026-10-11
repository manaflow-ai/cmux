//! Sample third-party terminal backend: plain SSH to any host that runs an
//! SSH server (no cmux on the far host), as `cmux.terminal.backend/1` in
//! bytes mode. It shows that an outside author can bring a terminal backend
//! through public interfaces only. See ../README.md.
//!
//! Security rules this crate keeps:
//! - The host owns the SSH transport ([`iface::HostChannels`]): it dials,
//!   checks the host key the user pinned and authenticates. An unknown or
//!   changed key is the typed `hostKey` error, and no byte reaches the shell.
//! - The app never holds a key, never signs and never sees a host name: it
//!   passes an opaque connection handle and the host's `open_token` on.
//! - The crate writes no log and no file, and passes nothing on argv.
//! - Every buffer is bounded (see `output` and `session`).

mod backend;
pub mod iface;
mod output;
mod session;
mod terminal;

pub use backend::{APP_ID, DEFAULT_TERM, MAX_WRITE_BYTES, SSH_ID, SSH_KIND, SshBackend};
pub use output::{MAX_UNREAD, RETAINED};
pub use session::{MAX_BUFFERED_BYTES, MAX_DETACHED, MAX_PENDING_INPUT};
