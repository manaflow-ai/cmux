//! A connection's outbound gate (R-DURABILITY S2c, DESIGN.md 3.3d): with the event journal on, no
//! line goes to a client before every acknowledged change it may show is durable.
//!
//! Each line a connection queues raises the gate's `needs` to the store's last acknowledged LSN
//! ([`Durability::acked`]) before it is queued, except the lines of a `Stream` record's event
//! (agent output, shown at once: DESIGN.md C4), sent inside a [`stream_scope`]. The gate's task
//! takes every queued line at once, reads `needs` after that, waits (async, no thread blocked)
//! until the journal's durable LSN reaches it, then sends the batch in order. So a reply goes
//! out only once the changes it may show are durable, an acknowledged event once its record is,
//! and a connection that heard nothing acknowledged never waits; a burst costs one wait per
//! batch, as the journal's group commit costs one sync. When the journal's writer ended (the
//! durable watch closed), the gate drops what it holds and ends, which closes the connection;
//! the store asks the daemon to stop.
//!
//! Without the journal ([`crate::store::Store::durability`] is None) there is no gate: lines go
//! straight to the transport, as before.

use crate::store::Durability;
use std::cell::Cell;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::sync::{mpsc, watch};

/// What a connection's lines wait for.
pub(super) struct Gate {
    /// The highest acknowledged LSN a line queued so far may show.
    needs: AtomicU64,
    acked: Arc<AtomicU64>,
}

impl Gate {
    /// Called right before a line is queued: it may show every change acknowledged so far. On
    /// every line a connection sends: one thread-local read and two atomics, no lock.
    pub(super) fn raise(&self) {
        if STREAM.with(Cell::get) {
            return;
        }
        self.needs.fetch_max(self.acked.load(Ordering::SeqCst), Ordering::SeqCst);
    }
}

thread_local! {
    /// A `Stream` record's event is being delivered on this thread ([`stream_scope`]).
    static STREAM: Cell<bool> = const { Cell::new(false) };
}

/// While it lives, the lines this thread queues show agent output only: they raise no gate.
pub(super) struct StreamScope {
    was: bool,
}

impl Drop for StreamScope {
    fn drop(&mut self) {
        STREAM.with(|stream| stream.set(self.was));
    }
}

/// A scope for delivering the event of `record`: a stream scope for a `Stream` record's.
pub(super) fn stream_scope(record: &crate::store::EventRecord) -> Option<StreamScope> {
    if !crate::store::streamed(record) {
        return None;
    }
    Some(StreamScope { was: STREAM.with(|stream| stream.replace(true)) })
}

/// Puts a gate between a connection and its transport `out` when the store journals its appends:
/// the sender the connection queues its lines on, and the gate it raises. Without the journal,
/// `out` itself and no gate.
pub(super) fn install(
    durability: Option<Durability>,
    out: mpsc::Sender<String>,
) -> (mpsc::Sender<String>, Option<Arc<Gate>>) {
    let Some(Durability { acked, durable, stalled }) = durability else { return (out, None) };
    let gate = Arc::new(Gate { needs: AtomicU64::new(0), acked });
    let (lines_tx, lines) = mpsc::channel(out.max_capacity());
    tokio::spawn(run(lines, out, Arc::clone(&gate), durable, stalled));
    (lines_tx, Some(gate))
}

/// How long a connection's lines may wait for the journal before the store asks the daemon to
/// stop for a restart (review of #35400, F2): a sync takes milliseconds, a few seconds on a
/// disk under heavy load; this long only on a hung or failing disk, whose writer retries without
/// end and would hold every reply.
const STALL_LIMIT: Duration = Duration::from_secs(10);

fn stall_limit() -> Duration {
    #[cfg(test)]
    if let ms @ 1.. = TEST_STALL_MS.load(Ordering::SeqCst) {
        return Duration::from_millis(ms);
    }
    STALL_LIMIT
}

/// The gate's task ([module docs](self)). Ends when the connection's senders are gone, the
/// transport closed, or the journal's writer ended.
async fn run(
    mut lines: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    gate: Arc<Gate>,
    mut durable: watch::Receiver<u64>,
    stalled: Arc<dyn Fn(String) + Send + Sync>,
) {
    let limit = lines.max_capacity();
    let mut batch = Vec::with_capacity(limit.min(64));
    loop {
        tokio::select! {
            biased;
            () = out.closed() => return,
            taken = lines.recv_many(&mut batch, limit) => {
                if taken == 0 {
                    return;
                }
            }
        }
        // After the lines were taken: every line among them raised the gate before it was queued.
        let needs = gate.needs.load(Ordering::SeqCst);
        if *durable.borrow() < needs {
            let reached = durable.wait_for(|lsn| *lsn >= needs);
            tokio::pin!(reached);
            let stall = tokio::time::sleep(stall_limit());
            tokio::pin!(stall);
            let mut asked = false;
            loop {
                tokio::select! {
                    biased;
                    () = out.closed() => return,
                    reached = &mut reached => {
                        if reached.is_err() {
                            tracing::error!("the event journal's writer ended: this connection closes");
                            return;
                        }
                        break;
                    }
                    () = &mut stall, if !asked => {
                        asked = true;
                        stalled(format!(
                            "a reply waited {:?} for the event journal, which made nothing durable",
                            stall_limit()
                        ));
                    }
                }
            }
        }
        for line in batch.drain(..) {
            if out.send(line).await.is_err() {
                return;
            }
        }
    }
}

/// Tests: the stall limit in milliseconds when not 0.
#[cfg(test)]
pub(crate) static TEST_STALL_MS: AtomicU64 = AtomicU64::new(0);

#[cfg(all(test, unix))]
#[path = "durable_gate_tests.rs"]
mod durable_gate_tests;
