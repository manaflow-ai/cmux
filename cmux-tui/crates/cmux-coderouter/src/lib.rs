//! The local CodeRouter (WIP, not built or tested yet): a loopback-only,
//! key-gated router for the user's own Claude and Codex accounts.
//! Prior plan: .cmux-scratch/local-coderouter/plan.md in cmuxterm-hq.
//! Missing: server.rs (axum listener wiring), tests, Cargo.lock entry.

pub mod bind;
pub mod gate;
pub mod keys;
pub mod secret;
pub mod upstream;
