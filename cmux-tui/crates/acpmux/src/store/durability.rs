//! How durable the store's appends are, for the connections that must not show an acknowledged
//! change before it is (R-DURABILITY S2c, DESIGN.md 3.3d; `server/durable_gate.rs`).

use super::EventRecord;
use std::sync::Arc;
use std::sync::atomic::AtomicU64;

/// The journal store's durability, as a connection's outbound gate reads it.
#[derive(Clone)]
pub struct Durability {
    /// The LSN of the last acknowledged (`Ack`) record appended: set in the append, before the
    /// hub publishes anything of it.
    pub acked: Arc<AtomicU64>,
    /// The journal's durable LSN. Closed when the journal's writer ended: nothing becomes
    /// durable any more.
    pub durable: tokio::sync::watch::Receiver<u64>,
    /// Called when a line waited past the stall limit for the journal (a hung or failing disk:
    /// its writer retries without end): the store asks the daemon to stop for a restart.
    pub stalled: Arc<dyn Fn(String) + Send + Sync>,
}

/// A streamed agent line: a `Stream` record, synced with the next acked batch or a second later,
/// and shown at once (DESIGN.md C4). Every other line is acknowledged (`Ack`). The hub's tap logs
/// an ACP `session/update` under its `sessionUpdate` kind (`hub/tap.rs`), so the message's method
/// says it, not the kind; a history replay (`*.replay`) too.
pub(crate) fn streamed(record: &EventRecord) -> bool {
    record.dir == "in"
        && (record.msg.get("method").and_then(serde_json::Value::as_str)
            == Some(crate::rpc::method::SESSION_UPDATE)
            || record.kind == crate::rpc::method::SESSION_UPDATE
            || record.kind.starts_with("claude.")
            || record.kind.starts_with("codex."))
}
