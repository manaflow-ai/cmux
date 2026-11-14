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
//! batch, as the journal's group commit costs one sync. A kept change (a draft, a name:
//! [`crate::store::ShowAfter::Written`]) raises `needs_written` instead, to the store's last kept
//! record, and the gate waits for the journal's written LSN to reach it: its record written, not
//! synced, so typing and renaming never wait for a disk sync while a kill -9 still keeps every
//! change a client saw. When the journal's writer ended (the durable watch closed), the gate
//! drops what it holds and ends, which closes the connection; the store asks the daemon to stop.
//!
//! Without the journal ([`crate::store::Store::durability`] is None) there is no gate: the
//! connection's plain pump moves its lines (`outbound.rs`).

use crate::store::Durability;
use std::cell::Cell;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::sync::watch;

/// What a connection's lines wait for.
pub(super) struct Gate {
    /// The highest acknowledged LSN a line queued so far may show.
    needs: AtomicU64,
    acked: Arc<AtomicU64>,
    /// The highest LSN of a kept change a line queued so far may show.
    needs_written: AtomicU64,
    kept: Arc<AtomicU64>,
}

impl Gate {
    /// Called right before a line is queued: it may show every change acknowledged so far. On
    /// every line a connection sends: one thread-local read and four atomics, no lock.
    pub(super) fn raise(&self) {
        if STREAM.with(Cell::get) {
            return;
        }
        self.needs.fetch_max(self.acked.load(Ordering::SeqCst), Ordering::SeqCst);
        self.needs_written.fetch_max(self.kept.load(Ordering::SeqCst), Ordering::SeqCst);
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

/// The gate of a connection whose store journals its appends, and its task, which moves the
/// connection's lines (`pump`, `outbound.rs`) to its transport as the journal allows.
pub(super) fn install(
    durability: Durability,
    pump: super::outbound::Pump,
) -> (Arc<Gate>, impl std::future::Future<Output = ()> + Send + 'static) {
    let Durability { acked, durable, kept, written, stalled } = durability;
    let gate =
        Arc::new(Gate { needs: AtomicU64::new(0), acked, needs_written: AtomicU64::new(0), kept });
    let run = run(pump, Arc::clone(&gate), Journal { durable, written }, stalled);
    (gate, run)
}

/// How often a connection's lines that wait for the journal ask the store whether the journal is
/// failing (review of #35400, F2). A sync takes milliseconds, a few seconds on a disk under heavy
/// load, and more than ten on a saturated one (huge-blue, 2026-11-08: 35-50% iowait, a 10.4 s
/// fdatasync). Past each interval the store asks the daemon to stop for a restart only when the
/// journal's writer is failing (a write or sync returned an error and it retries without end);
/// while it is merely slow the lines keep waiting: a slow disk makes replies slower, never makes
/// the daemon restart (a restart on the same disk is no faster, and every client meanwhile gets
/// "acpmux is shutting down").
// timeout: a check interval, not a deadline: a merely slow journal keeps the lines waiting
const STALL_LIMIT: Duration = Duration::from_secs(10);

fn stall_limit() -> Duration {
    #[cfg(test)]
    if let ms @ 1.. = TEST_STALL_MS.load(Ordering::SeqCst) {
        return Duration::from_millis(ms);
    }
    STALL_LIMIT
}

/// The journal's LSNs a gate waits for.
struct Journal {
    durable: watch::Receiver<u64>,
    written: watch::Receiver<u64>,
}

impl Journal {
    fn reached(&self, needs: u64, needs_written: u64) -> bool {
        *self.durable.borrow() >= needs && *self.written.borrow() >= needs_written
    }

    /// Until both LSNs are reached; false when the journal's writer ended.
    async fn reach(&mut self, needs: u64, needs_written: u64) -> bool {
        // Each borrow of a watch ends in its own statement: none is held across an await.
        let durable = self.durable.wait_for(|lsn| *lsn >= needs).await.is_ok();
        if !durable {
            return false;
        }
        self.written.wait_for(|lsn| *lsn >= needs_written).await.is_ok()
    }
}

/// The gate's task ([module docs](self)). Ends when the connection's handles are gone, the
/// transport closed, the queue overran, or the journal's writer ended; dropping `pump` then
/// closes the queue (`outbound.rs`).
async fn run(
    pump: super::outbound::Pump,
    gate: Arc<Gate>,
    mut journal: Journal,
    stalled: Arc<dyn Fn(Duration) -> bool + Send + Sync>,
) {
    let mut batch = Vec::new();
    'pump: loop {
        tokio::select! {
            biased;
            () = pump.stopped() => break 'pump,
            more = pump.take(&mut batch) => {
                if !more {
                    break 'pump;
                }
            }
        }
        // After the lines were taken: every line among them raised the gate before it was queued.
        let needs = gate.needs.load(Ordering::SeqCst);
        let needs_written = gate.needs_written.load(Ordering::SeqCst);
        if !journal.reached(needs, needs_written) {
            let reached = journal.reach(needs, needs_written);
            tokio::pin!(reached);
            let started = tokio::time::Instant::now();
            let stall = tokio::time::sleep(stall_limit());
            tokio::pin!(stall);
            let mut asked = false;
            loop {
                tokio::select! {
                    biased;
                    () = pump.stopped() => break 'pump,
                    reached = &mut reached => {
                        if !reached {
                            tracing::error!("the event journal's writer ended: this connection closes");
                            break 'pump;
                        }
                        break;
                    }
                    () = &mut stall, if !asked => {
                        // Asked again each interval: a disk that is slow first may fail later.
                        asked = stalled(started.elapsed());
                        stall.as_mut().reset(tokio::time::Instant::now() + stall_limit());
                    }
                }
            }
        }
        for line in batch.drain(..) {
            if !pump.forward(line).await {
                break 'pump;
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
