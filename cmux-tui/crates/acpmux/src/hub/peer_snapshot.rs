//! Part of `Hub`; see `hub/mod.rs`. A durable local copy of each peer session's events, so a
//! client paints a paused or offline peer's chat at once, marked possibly stale, then catches up
//! from the peer with `afterSeq` (cmuxterm-hq#4381; Lawrence: "decouple persistence of acp
//! trajectories from the VM itself, in case the VM is resuming"). The peer's journal stays the
//! authority: this is what this daemon saw of it, never a write lease, an execution checkpoint or
//! a backup.
//!
//! This part is the files (`disk.rs`) and the bounds a file is held to. The store that owns them,
//! what it keeps, and the hub's taps come next; until then nothing outside the tests uses these.

use serde_json::Value;

mod disk;

/// Bytes of one session's records a copy keeps; more than an attach page (400 records).
pub(crate) const SESSION_BYTES: u64 = if cfg!(test) { 16 << 10 } else { 2 << 20 };
/// Bytes of a copy's head line (its row, mostly); a copy whose head is past it is not kept.
pub(crate) const HEAD_BYTES: u64 = if cfg!(test) { 4 << 10 } else { 256 << 10 };
/// Bytes of one copy's file, written or read: its records and its head. One past it is not a copy.
pub(crate) const FILE_BYTES: u64 = SESSION_BYTES + HEAD_BYTES;

/// Whether `record` is of session `key` (its `sessionId`): a page or a file holding another
/// session's record is not this copy.
fn of_session(record: &Value, key: &disk::Key) -> bool {
    record.get("sessionId").and_then(Value::as_str) == Some(key.1.as_str())
}
