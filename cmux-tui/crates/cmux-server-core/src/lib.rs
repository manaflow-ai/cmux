//! cmux server and VM software, pure core (plans/cmux-next/server.md).
//!
//! Every function here is pure: no file system, network, process, clock or
//! random source. Callers pass `now`, random bytes, environment values and
//! probe facts. The I/O crate (`cmux-server`) applies the plans this crate
//! returns: it writes the files, runs the argv lists and posts the feed items.
//!
//! Modules:
//! - [`layout`]: install mode x platform to paths (server.md 4.3).
//! - [`access`]: required owners, modes and ACLs of those paths.
//! - [`ports`]: the install's port block (server.md 8.2).
//! - [`pg`]: the Postgres cluster plan and per-app provisioning (server.md 8).
//! - [`pairing`]: pairing code, fingerprint words and QR payload (server.md 6.2).
//! - [`health`]: facts to alerts and feed posts, fix descriptors (server.md 9).
//! - [`units`]: systemd, launchd and Windows service definitions (server.md 4.3).
//! - [`manifest`]: signed channel manifest verification (server.md 4.2).
//! - [`catalog`]: the `server.*` operations as static data (server.md 13).
//! - [`reexec`]: the one re-exec into a newer staged `cmux` (decision SV-R2).
//! - [`install_key`]: a Cloud machine's ES256 install key (the caller
//!   passes the random source).
//! - [`role`]: the role trait and lifecycle events `cmux host run`
//!   supervises (lane 1 vm-image.md 6.3).
//! - [`role_spec`] and [`role_proc`]: process roles from `server.json`
//!   and their restart and health reducer (server.md 5.1).

// The crash ratchet keeps this crate at zero production panics
// (plans/cmux-next/crash-elimination.md section 6).
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented,
        clippy::exit
    )
)]

pub mod access;
pub mod catalog;
pub mod health;
pub mod install_key;
pub mod layout;
pub mod manifest;
pub mod pairing;
pub mod pg;
pub mod platform;
pub mod ports;
pub mod reexec;
pub mod role;
pub mod role_proc;
pub mod role_spec;
pub mod units;

pub use platform::{HostPath, InstallMode, Platform};
