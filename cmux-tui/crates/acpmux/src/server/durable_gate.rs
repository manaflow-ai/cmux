//! A connection's outbound gate (R-DURABILITY S2c, DESIGN.md 3.3d): with the event journal on, no
//! line goes to a client before every acknowledged change it may show is durable.
//!
//! Each line a connection queues raises the connection's needs (`outbound::Raised`) to the
//! store's last acknowledged LSN ([`Durability::acked`]) before it is queued, except the lines of
//! a `Stream` record's event (agent output, shown at once: DESIGN.md C4), sent inside a
//! [`stream_scope`]; the queue stamps each line with the needs raised so far (`outbound::Needs`).
//! The gate's task takes every queued line at once and sends them in order, each once the
//! journal's durable LSN reaches its own stamp (waiting async, no thread blocked). So a reply goes
//! out only once the changes it may show are durable, an acknowledged event once its record is,
//! and a connection that heard nothing acknowledged never waits. A line never waits for a change
//! acknowledged after it was queued: agent output queued between a turn's first records and its
//! last goes out once the first are durable, not after the syncs of the last (the turn bench,
//! `benches/turn_overhead.rs`, measured 3.8 ms of a 4.5 ms turn there: every line of the turn
//! went out in one burst after its newest record's sync). A burst whose lines all need one LSN
//! costs one wait, as the journal's group commit costs one sync. Each batch the gate takes asks
//! the journal once for the sync of the newest change its lines need
//! (`cmux_journal::Journal::ask_durable`), as a `wait_durable` does: the journal's group window
//! (`ack_group_window`, 5 ms) is for the records nobody waits to see, and an acked change a
//! client waits for is synced at once instead of at the window's end. A kept change (a draft, a name:
//! [`crate::store::ShowAfter::Written`]) raises the written needs instead, to the store's last
//! kept record, and its lines wait for the journal's written LSN to reach it: its record written,
//! not synced, so typing and renaming never wait for a disk sync while a kill -9 still keeps every
//! change a client saw. When the journal's writer ended (the durable watch closed), the gate
//! drops what it holds and ends, which closes the connection; the store asks the daemon to stop.
//!
//! While the store is in its full-disk state (`store/journal_store/space.rs`), a line waits at
//! most [`crate::store::FULL_WAIT`] (400 ms) for the journal: the writer's first retries write the
//! records appended before the disk filled into the room its freed reserve leaves, and the line
//! goes out as on any disk. Past it, and for every later line that has not reached the journal
//! while the disk stays full, a reply (a response to a request) is answered with the store's
//! refusal instead, typed `disk.full` with its request id, and any other line (a notification
//! that may show a change not yet on disk) is not sent. Neither shows a change before it is on
//! disk, and no client waits on a reply that only space could release: the duress bench's disk
//! leg had 3 of about 85 `session/prompt` calls a run unanswered at its 30 s limit, the ones whose
//! records were appended as the disk filled. The first line that reaches the journal ends that.
//!
//! Without the journal ([`crate::store::Store::durability`] is None) there is no gate: the
//! connection's plain pump moves its lines (`outbound.rs`).

use super::outbound::{Needs, Raised};
use crate::store::Durability;
use std::cell::Cell;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::sync::watch;

/// What a connection's lines wait for.
pub(super) struct Gate {
    /// The highest LSNs a line queued so far may show: acknowledged, and kept.
    raised: Arc<Raised>,
    acked: Arc<AtomicU64>,
    kept: Arc<AtomicU64>,
}

impl Gate {
    /// Called right before a line is queued: it may show every change acknowledged so far. On
    /// every line a connection sends: one thread-local read and four atomics, no lock.
    pub(super) fn raise(&self) {
        if STREAM.with(Cell::get) {
            return;
        }
        self.raised.durable.fetch_max(self.acked.load(Ordering::SeqCst), Ordering::SeqCst);
        self.raised.written.fetch_max(self.kept.load(Ordering::SeqCst), Ordering::SeqCst);
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
    let Durability { acked, durable, kept, written, ask, stalled, full } = durability;
    let gate = Arc::new(Gate { raised: pump.raised(), acked, kept });
    let run = run(pump, Journal { durable, written, ask, full }, stalled);
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
    /// Asks the journal to sync through an LSN now.
    ask: Arc<dyn Fn(u64) + Send + Sync>,
    /// The store's `disk.full` refusal while it is full ([`Durability::full`]).
    full: Arc<dyn Fn() -> Option<String> + Send + Sync>,
}

/// How a line's wait for the journal ended.
enum Waited {
    Reached,
    /// The pump stopped or the journal's writer ended: the gate ends.
    Ended,
    /// The disk is full and the journal did not reach the line: the store's refusal.
    Full(String),
}

impl Journal {
    fn reached(&self, needs: Needs) -> bool {
        *self.durable.borrow() >= needs.durable && *self.written.borrow() >= needs.written
    }

    /// Asks the journal to sync through the newest LSN `batch` needs, once for the whole batch: a
    /// client waits for these lines, so they do not wait out the group window, and one sync covers
    /// them all.
    fn ask(&self, batch: &[super::outbound::Line]) {
        let needs = batch.iter().map(|line| line.needs.durable).max().unwrap_or(0);
        if *self.durable.borrow() < needs {
            (self.ask)(needs);
        }
    }

    /// Until both LSNs are reached; false when the journal's writer ended.
    async fn reach(&mut self, needs: Needs) -> bool {
        // Each borrow of a watch ends in its own statement: none is held across an await.
        let durable = self.durable.wait_for(|lsn| *lsn >= needs.durable).await.is_ok();
        if !durable {
            return false;
        }
        self.written.wait_for(|lsn| *lsn >= needs.written).await.is_ok()
    }
}

/// The gate's task ([module docs](self)). Ends when the connection's handles are gone, the
/// transport closed, the queue overran, or the journal's writer ended; dropping `pump` then
/// closes the queue (`outbound.rs`).
async fn run(
    pump: super::outbound::Pump,
    mut journal: Journal,
    stalled: Arc<dyn Fn(Duration) -> bool + Send + Sync>,
) {
    let mut batch = Vec::new();
    // A line waited out [`crate::store::FULL_WAIT`] while the disk is full and no line reached
    // the journal since: the next lines that have not reached it do not wait again.
    let mut full = false;
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
        journal.ask(&batch);
        for line in batch.drain(..) {
            let line = if journal.reached(line.needs) {
                full = false;
                line
            } else {
                match wait(&pump, &mut journal, line.needs, &stalled, full).await {
                    Waited::Reached => {
                        full = false;
                        line
                    }
                    Waited::Ended => break 'pump,
                    Waited::Full(refusal) => {
                        full = true;
                        match refused(&line, &refusal) {
                            Some(Some(answer)) => pump.replace(line, answer),
                            Some(None) => line,
                            None => {
                                pump.skip(line);
                                continue;
                            }
                        }
                    }
                }
            };
            if !pump.forward(line).await {
                break 'pump;
            }
        }
    }
}

/// Until the journal reaches `needs`, asking the store each [`stall_limit`] whether the journal
/// is failing, and each [`crate::store::FULL_WAIT`] whether the disk is full (at once when
/// `full`: a line before this one waited it out already).
async fn wait(
    pump: &super::outbound::Pump,
    journal: &mut Journal,
    needs: Needs,
    stalled: &Arc<dyn Fn(Duration) -> bool + Send + Sync>,
    full: bool,
) -> Waited {
    if full && let Some(refusal) = (journal.full)() {
        return Waited::Full(refusal);
    }
    let disk = Arc::clone(&journal.full);
    let reached = journal.reach(needs);
    tokio::pin!(reached);
    let started = tokio::time::Instant::now();
    let stall = tokio::time::sleep(stall_limit());
    tokio::pin!(stall);
    let look = tokio::time::sleep(crate::store::FULL_WAIT);
    tokio::pin!(look);
    let mut asked = false;
    loop {
        tokio::select! {
            biased;
            () = pump.stopped() => return Waited::Ended,
            reached = &mut reached => {
                if !reached {
                    tracing::error!("the event journal's writer ended: this connection closes");
                    return Waited::Ended;
                }
                return Waited::Reached;
            }
            () = &mut look => {
                if let Some(refusal) = disk() {
                    tracing::warn!(
                        waited = ?started.elapsed(),
                        "a reply waits for the event journal on a full disk: it is answered disk.full"
                    );
                    return Waited::Full(refusal);
                }
                look.as_mut().reset(tokio::time::Instant::now() + crate::store::FULL_WAIT);
            }
            () = &mut stall, if !asked => {
                // Asked again each interval: a disk that is slow first may fail later.
                asked = stalled(started.elapsed());
                stall.as_mut().reset(tokio::time::Instant::now() + stall_limit());
            }
        }
    }
}

/// What goes out instead of `line`, which the journal has not reached on a full disk: for a
/// reply, the store's refusal under its request id, typed `disk.full` (`Some(Some(text))`), or
/// the line itself when it is an error already (`Some(None)`: it acknowledges nothing); for any
/// other line, None (not sent).
fn refused(line: &super::outbound::Line, refusal: &str) -> Option<Option<String>> {
    let message: serde_json::Value = serde_json::from_str(line.text.trim_end()).ok()?;
    let id = message.get("id").filter(|_| message.get("method").is_none())?;
    if message.get("error").is_some() {
        return Some(None);
    }
    let mut error = crate::rpc::RpcError::internal(refusal.to_owned());
    crate::recovery::annotate(&mut error, None);
    let mut text = crate::rpc::Message::err(id.clone(), error).to_line();
    if !line.text.ends_with('\n') {
        text.pop();
    }
    Some(Some(text))
}

/// Tests: the stall limit in milliseconds when not 0.
#[cfg(test)]
pub(crate) static TEST_STALL_MS: AtomicU64 = AtomicU64::new(0);

#[cfg(all(test, unix))]
#[path = "durable_gate_tests.rs"]
mod durable_gate_tests;
