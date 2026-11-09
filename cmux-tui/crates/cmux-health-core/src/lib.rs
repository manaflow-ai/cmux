//! The cmux app's health model: which part of the app is slow, stuck or
//! failed, what repairs it, and what the status indicator says, in Rust,
//! asked over the app FFI (`include/cmux_health.h`, Swift module
//! `CCmuxHealthFFI`, linked through cmux-app-ffi).
//!
//! Why: on 2026-11-09 the session daemon restarted every two minutes, each
//! one restoring a 59 GB registry and killed before its socket answered. The
//! UI kept retrying a dead daemon, two renderers spun, and nothing told the
//! user. The contract (shared with the Swift feed and the web UI) names the
//! parts, their signals, the states and the ops; this crate is its logic.
//!
//! The host feeds signals (beats, input counters, visibility, events, sizes)
//! and runs ONE one-shot timer to [`model::Health::next_tick_ms`]. Every
//! decision is here:
//!
//! - [`model`]: the per-part state machine, the deadline min-heap (a tick
//!   visits only expired entries; a hidden part is never timed), the repair
//!   ladder with backoff and a cap, the pending user actions and receipts;
//! - [`policy`]: the defaults (silence thresholds, ladders, backoff, caps);
//! - [`detail`]: the plain words a person reads (no ids, no jargon);
//! - [`ops`]: the one JSON entry point ([`ops::call`]);
//! - [`ffi`]: the C ABI.
//!
//! Nothing here does I/O or reads a clock: every time is the host's `nowMs`
//! on one monotonic clock.

use serde::{Deserialize, Serialize};

pub mod detail;
pub mod ffi;
pub mod model;
pub mod ops;
pub mod policy;

#[cfg(test)]
mod tests;

/// The kind of a part (the contract's `kind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Page,
    Renderer,
    SessionDaemon,
    Acpmux,
    PageHost,
    Roster,
}

/// A part's state, best first, so `Ord` gives the worst (`max`).
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default, Serialize, Deserialize,
)]
#[serde(rename_all = "camelCase")]
pub enum State {
    #[default]
    Healthy,
    /// Working, but taking long (a restore that still makes progress). Never
    /// repaired by force.
    Slow,
    /// A repair is out; waiting for the part's signal to come back.
    Repairing,
    Stuck,
    /// Repairs exhausted; the user's one click (`repairNow`) is offered.
    Failed,
}

/// What the host does to a part.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RepairAction {
    /// Reload the page (it saves scroll and draft first if it can still
    /// answer, else the last autosave is used).
    ReloadPage,
    RestartRenderer,
    Reconnect,
    RestartConnection,
    RestartPageHost,
    /// Tell the launcher a restoring owner makes progress: never kill or
    /// replace it.
    HoldReplace,
    #[default]
    None,
}

/// One thing for the host to do, from `tick` or `repairNow`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Action {
    pub id: String,
    pub kind: Kind,
    pub action: RepairAction,
    /// 1 for the first step of an episode.
    pub attempt: u32,
    /// This part's count of actions sent, never reset: the host echoes it in
    /// `repairResult`, so a late result never lands on a newer attempt.
    pub token: u64,
}

/// How a receipt's repair ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Outcome {
    /// A repair was sent to the host (added to the contract's three: every
    /// attempt leaves a receipt, not only its result).
    Started,
    Ok,
    Failed,
    GaveUp,
}

/// One line of the repair history (the snapshot keeps the last 64).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Receipt {
    pub at_ms: u64,
    pub id: String,
    pub action: RepairAction,
    pub outcome: Outcome,
    pub detail: String,
}

/// One non-healthy part as the UI renders it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PartView {
    pub id: String,
    pub kind: Kind,
    pub label: String,
    pub state: State,
    pub since_ms: u64,
    pub detail: String,
    pub action: RepairAction,
    pub attempt: u32,
    pub max_attempts: u32,
    pub next_at_ms: Option<u64>,
    pub can_repair: bool,
}

/// A user action the host queued while its target is unreachable.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingView {
    pub id: String,
    pub label: String,
    pub since_ms: u64,
}

/// What the status indicator renders. Small by construction: only
/// non-healthy parts, at most 8 pending items and 64 receipts.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub worst: State,
    pub parts: Vec<PartView>,
    pub receipts: Vec<Receipt>,
    /// Newest first.
    pub pending: Vec<PendingView>,
    /// Pending items not listed.
    pub pending_more: usize,
}
