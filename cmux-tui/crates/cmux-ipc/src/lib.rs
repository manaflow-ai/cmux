//! `cmux-ipc`: the binary wire between cmux processes
//! (plans/cmux-next/chrome-parity/p05-ipc.md, section 3.2).
//!
//! [`fds`] passes file descriptors with `SCM_RIGHTS` and queues the ones that
//! arrive in order: the holder link uses it, and so do the daemon's frame lanes.

#![cfg_attr(not(test), deny(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

#[cfg(unix)]
pub mod fds;
