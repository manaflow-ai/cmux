//! chatmux machine relay — the outbound-only pairing/auth/trust wrapper a
//! chatmux target machine or sandbox runs to stay reachable. Rust port of
//! the npm `cmux-relay` CLI (chatmux `packages/relay`); the npm distribution
//! name stays `cmux-relay`. See README.md for the port plan and the
//! vendored-protocol regeneration step.

pub mod actions;
pub mod autostart;
pub mod cli;
pub mod config;
pub mod control;
pub mod enrollment;
pub mod error;
pub mod fingerprint;
pub mod journal_forwarder;
pub mod pairing;
pub mod preview_proxy;
pub mod prompt;
pub mod pty;
#[cfg(unix)]
pub mod pty_deps;
pub mod relay_wire;
pub mod session;
pub mod trust;
pub mod watch;
pub mod wire;
pub mod workspace;
