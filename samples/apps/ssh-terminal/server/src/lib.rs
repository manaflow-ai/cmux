//! RED STEP: the interface mirror and the tests moved to the host-owned
//! channel model; the backend below is a stub until the next commit.

mod backend;
pub mod iface;

pub use backend::{
    APP_ID, DEFAULT_TERM, MAX_BUFFERED_BYTES, MAX_DETACHED, MAX_UNREAD, MAX_WRITE_BYTES, RETAINED,
    SSH_ID, SSH_KIND, SshBackend,
};
