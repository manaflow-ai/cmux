//! The rules of the cmux macOS app's control connection to a cmux-tui daemon
//! (`CmuxNextDaemon/Connection` in the app), with no I/O:
//!
//! - [`retry`]: how a retry loop spaces attempts (the policies, the capped
//!   jittered backoff, the pacer's budget, socket renewals, busy refusals).
//! - [`heartbeat`]: the liveness ask's misses and the answering flag.
//! - [`handshake`]: the verdict on a daemon's `identify`, the owner metadata
//!   fence, the page relay's verdict and the capabilities a connection echoes.
//! - [`compat`]: what one daemon can do for the app (current, limited,
//!   incompatible) and its version label.
//! - [`errors`]: which connection errors are permanent, lost connections,
//!   late replies or late starts, and whether a failed attempt shows.
//! - [`latency`]: the request-latency histogram (`debug.daemon_requests`).
//! - [`idle`]: whether a conversation owner is idle, so it may restart.
//! - [`scope`]: one app action's command scope (tickets, barriers, created
//!   objects, the stage log and the ids derived from an idempotency key).
//!
//! The app reaches them through the C ABI in [`ffi`]
//! (`include/cmux_daemon_conn.h`, Swift module `CCmuxDaemonConnFFI`), linked
//! into the app through cmux-app-ffi. The daemon side of the handshake is
//! cmux-tui-core's `identify` (`server/capabilities.rs`); its protocol
//! version and app name are [`handshake::PROTOCOL_VERSION`] and
//! [`handshake::DAEMON_APP`].

pub mod compat;
pub mod errors;
pub mod ffi;
pub mod handshake;
pub mod heartbeat;
pub mod identity;
pub mod idle;
pub mod latency;
pub mod ops;
pub mod retry;
pub mod scope;
