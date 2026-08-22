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
pub mod prompt;
pub mod session;
pub mod trust;
pub mod wire;
