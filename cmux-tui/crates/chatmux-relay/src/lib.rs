//! chatmux machine relay — the outbound-only pairing/auth/trust wrapper a
//! chatmux target machine or sandbox runs to stay reachable. Rust port of
//! the npm `cmux-relay` CLI (chatmux `packages/relay`); the npm distribution
//! name stays `cmux-relay`. See README.md for the port plan and the
//! vendored-protocol regeneration step.

pub mod cli;
pub mod config;
pub mod enrollment;
pub mod error;
pub mod fingerprint;
pub mod pairing;
pub mod preview_proxy;
pub mod prompt;
// Vendored from chatmux packages/protocol/generated/rust/relay_wire.rs
// (see README "Vendored protocol"); never edited, only re-vendored, and
// never formatted (the generated layout is the diff baseline).
#[rustfmt::skip]
pub mod relay_wire;
pub mod session;
pub mod trust;
pub mod watch;
pub mod wire;
pub mod workspace;
