//! The NEXT app's follower of the cloud tasks it handed off (sandboxed Runs, `GET
//! /api/runs/:id/wait`; hand-offs, `GET /v1/handoffs/:id/wait`), in Rust so the macOS app keeps
//! only its poll tasks, waiters and storage (Leo, 2026-11-02: Cloud logic and its tests belong in
//! Rust, not Swift). Pure: no I/O. Served to the app over the app FFI's JSON channel
//! (`cmux-layout-reducer-ffi`, ops `cloud_task_*`).
//!
//! - [`follower`]: the state machine, one [`follower::step`] per event.
//! - [`model`]: its state, and the saved list in the app's long-standing format.
//! - [`read`]: how a wait's answer reads, and a Run's card.
//! - [`handoff`]: a hand-off's statuses, notices and times.

pub mod follower;
pub mod handoff;
pub mod model;
pub mod read;

#[cfg(test)]
mod tests;
