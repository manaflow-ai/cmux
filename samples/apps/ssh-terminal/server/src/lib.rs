//! Sample third-party terminal backend (STUB in this commit: tests only).

mod backend;
pub mod handles;
pub mod iface;

pub use backend::{ANSWERS_QUERIES, APP_ID, MAX_WRITE_BYTES, SSH_ID, SSH_KIND, SshBackend};
