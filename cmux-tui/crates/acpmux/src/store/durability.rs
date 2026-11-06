//! How durable the store's appends are, for the connections that must not show an acknowledged
//! change before it is (R-DURABILITY S2c, DESIGN.md 3.3d; `server/durable_gate.rs`).
//!
//! Two classes of acknowledged change ([`ShowAfter`]). Most are durable before any line shows them
//! (C1: synced, so a kernel panic keeps them). A chat's draft and its name are kept: what the
//! person types goes to every client in the same turn, as agent output does (C4), so typing and
//! renaming never wait for a disk sync. A kept change's records are `Stream` records, which the
//! journal writes in its next batch: a line that shows the change waits for that write (a kill
//! -9 of every process then keeps it), and the sync follows with the next acknowledged batch, or
//! the journal's stream sync delay (1 s) later; so an OS crash or a power loss takes back at most
//! that last second of drafts and names, always a suffix. Before (journal on, #37118) each
//! `_acpmux/draft_set` waited for one barrier sync and each `_acpmux/rename` for two (job
//! b566634d, aws-m4pro-8: p95 2.7 ms and 5.0 ms; with the journal off 6.7 ms and 20.3 ms).

use super::EventRecord;
use std::sync::Arc;
use std::sync::atomic::AtomicU64;

/// What a line that shows a change waits for ([module docs](self)).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShowAfter {
    /// Its record synced: an OS crash keeps it (C1).
    Durable,
    /// Its record written: a kill -9 of every process keeps it; synced right after.
    Written,
}

/// The journal store's durability, as a connection's outbound gate reads it.
#[derive(Clone)]
pub struct Durability {
    /// The LSN of the last acknowledged (`Ack`) record appended: set in the append, before the
    /// hub publishes anything of it.
    pub acked: Arc<AtomicU64>,
    /// The journal's durable LSN. Closed when the journal's writer ended: nothing becomes
    /// durable any more.
    pub durable: tokio::sync::watch::Receiver<u64>,
    /// The LSN of the last record of a kept change ([`ShowAfter::Written`]) appended, set as `acked`
    /// is.
    pub kept: Arc<AtomicU64>,
    /// The journal's written LSN (`cmux_journal::Journal::on_written`); closed with `durable`.
    pub written: tokio::sync::watch::Receiver<u64>,
    /// Called when a line waited past the stall limit for the journal (a hung or failing disk:
    /// its writer retries without end): the store asks the daemon to stop for a restart.
    pub stalled: Arc<dyn Fn(String) + Send + Sync>,
}

/// A streamed agent line: a `Stream` record, synced with the next acked batch or a second later,
/// and shown at once (DESIGN.md C4). Every other line is acknowledged (`Ack`). The hub's tap logs
/// an ACP `session/update` under its `sessionUpdate` kind (`hub/tap.rs`), so the message's method
/// says it, not the kind; a history replay (`*.replay`) too.
pub(crate) fn streamed(record: &EventRecord) -> bool {
    record_class(record) == RecordClass::Stream
}

/// How the journal store appends an event-log line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RecordClass {
    /// Agent output: shown at once, raises no gate (C4).
    Stream,
    /// The line of a kept change (a chat's `renamed`): shown once written ([`ShowAfter::Written`]).
    Kept,
    /// Every other line: shown once durable.
    Acked,
}

pub(crate) fn record_class(record: &EventRecord) -> RecordClass {
    if agent_output(record) {
        RecordClass::Stream
    } else if record.dir == "mux" && record.kind == "renamed" {
        RecordClass::Kept
    } else {
        RecordClass::Acked
    }
}

fn agent_output(record: &EventRecord) -> bool {
    record.dir == "in"
        && (record.msg.get("method").and_then(serde_json::Value::as_str)
            == Some(crate::rpc::method::SESSION_UPDATE)
            || record.kind == crate::rpc::method::SESSION_UPDATE
            || record.kind.starts_with("claude.")
            || record.kind.starts_with("codex."))
}
