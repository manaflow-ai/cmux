//! One sync engine for chat and session state, and presence, for every replica cmux has: the Mac,
//! a Cloud VM and the phone (cmuxterm-hq RFD "Real-time sync and presence", which names the systems
//! each technique comes from).
//!
//! Leo, 2026-11-24: "we absolutely need to rfd and stripmine those types of things and other actually
//! incredible feats of engineering and sync-up".
//!
//! What it takes:
//! - [`hlc`]: hybrid logical clocks (Kulkarni et al., 2014): stamps that follow wall time but never
//!   go backwards and always order an edit after every edit its replica has seen, so a Mac with a
//!   slow clock cannot lose to an edit it already saw.
//! - [`map`]: property-level last-writer-wins, as multiplayer design tools do it, made state-based so no
//!   server is needed to merge: every replica can edit offline and any two converge in any order
//!   (merge is commutative, associative and idempotent). A replica still has a home (the daemon that
//!   owns the chat), which acks edits as a push/pull mutation queue does; the pending count is what the
//!   sidebar shows while offline.
//! - [`vv`]: version vectors over dots (actor, sequence), so a reconnect is git's have/want: the
//!   receiver says what it has, the sender ships only what it lacks, in bytes proportional to the
//!   missed edits and not to the state.
//! - [`presence`]: chat-gateway presence: heartbeats with a time to live, never persisted,
//!   aggregated per person or agent across devices, with per-device sequence numbers so the same
//!   beat gossiped through two peers counts once.
//! - [`truth`]: which replica the phone should believe ("the phone sees whichever is most
//!   truthful"): the one whose version vector dominates, then the freshest heartbeat.
//! - [`three_tree`]: two-way file sync decided from local, remote and the revision both last agreed
//!   on, so the same edits reach the same tree in either order and a delete never beats an edit.
//! - [`two_way`]: one sync round between a Mac and a VM on that rule, with the synced tree kept as a
//!   content-addressed revision in a store both sides read, so a restart never loses the base.
//!
//! Nothing here does I/O or reads a clock: the host passes `now` in milliseconds and moves the
//! [`map::Delta`]s and [`presence::Beat`]s over its own transport, so every rule is tested by
//! deterministic simulation (`tests/converge.rs`).

pub mod hlc;
pub mod map;
pub mod presence;
pub mod three_tree;
pub mod truth;
pub mod two_way;
pub mod vv;

pub use hlc::{Actor, Clock, Stamp};
pub use map::{Applied, Delta, Entry, Replica, Snapshot, SyncState};
pub use presence::{Activity, Beat, DeviceKind, Here, HereDevice, Kind, Member, Presence, Status};
pub use truth::{Report, most_truthful};
pub use vv::{Dot, Vv};
