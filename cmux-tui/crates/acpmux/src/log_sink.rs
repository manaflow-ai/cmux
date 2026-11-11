//! The daemon's log output, which never makes a logging thread wait.
//!
//! The daemon logs to its stdout: a file (`~/.acpmux/daemon.log`) when it starts itself, a pipe
//! when a supervisor or a test starts it. A log line was written on the thread that logged it,
//! often under a lock, so a log output that stopped taking bytes (a pipe nobody read, a stalled
//! or full disk, a slow network home) stopped every thread that logged and every thread waiting
//! on their locks. aws-m4pro-5, 2026-11-10: a daemon whose stdout pipe was full answered no
//! `acpmux ls` for 2 h 41 min, its request waiting on a lock held by a thread that logged.
//!
//! Now a logging thread only queues its line: [`Sink`] hands each formatted line to one writer
//! thread through a bounded queue ([`QUEUE_LINES`] lines, [`QUEUE_BYTES`] bytes). A line that
//! does not fit is dropped and counted, and the next line that fits carries the count: the writer
//! thread writes it, in the log's own line format, just before that line, where the gap is. The lines keep their order and their format.
//! [`flush`] waits, for a bounded time, until the lines queued so far are written: the daemon
//! calls it before it exits.

use std::io::Write;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Condvar, Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

/// The most lines queued for the writer thread.
pub const QUEUE_LINES: usize = 8192;
/// The most bytes queued for the writer thread.
pub const QUEUE_BYTES: usize = 8 << 20;

/// What the logging threads and the writer thread share.
#[derive(Default)]
struct Shared {
    /// Bytes queued and not yet written.
    queued_bytes: AtomicUsize,
    /// Lines dropped and not yet carried by a queued line.
    dropped: AtomicU64,
    /// Lines queued, and lines written: [`flush`] waits for the second to reach the first.
    queued: AtomicU64,
    written: AtomicU64,
    /// Taken by the writer thread to wake [`flush`] after each line, and by [`flush`] to wait.
    wake: Mutex<()>,
    woken: Condvar,
}

impl Shared {
    fn wake_lock(&self) -> std::sync::MutexGuard<'_, ()> {
        self.wake.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The log output a `tracing_subscriber::fmt` layer writes to (`with_writer`): each event's
/// line goes to the writer thread's queue, or is dropped and counted.
#[derive(Clone)]
pub struct Sink {
    tx: SyncSender<Queued>,
    shared: Arc<Shared>,
}

/// A queued line, and how many lines were dropped just before it.
struct Queued {
    dropped: u64,
    bytes: Vec<u8>,
}

/// One event's line, queued when the layer is done with it.
pub struct Line<'a> {
    sink: &'a Sink,
    bytes: Vec<u8>,
}

impl Write for Line<'_> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.bytes.extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Drop for Line<'_> {
    fn drop(&mut self) {
        let bytes = std::mem::take(&mut self.bytes);
        if !bytes.is_empty() {
            self.sink.queue(bytes);
        }
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for Sink {
    type Writer = Line<'a>;

    fn make_writer(&'a self) -> Self::Writer {
        Line { sink: self, bytes: Vec::new() }
    }
}

impl Sink {
    /// A sink whose writer thread writes its lines to `out`.
    pub fn start<W: Write + Send + 'static>(out: W) -> std::io::Result<Self> {
        let (tx, rx) = sync_channel(QUEUE_LINES);
        let shared = Arc::new(Shared::default());
        let writer = shared.clone();
        std::thread::Builder::new()
            .name("log-writer".into())
            .spawn(move || write_lines(rx, out, &writer))?;
        Ok(Self { tx, shared })
    }

    /// This sink's lines are the ones [`flush`] waits for.
    pub fn install(&self) {
        let _ = INSTALLED.set(self.shared.clone());
    }

    fn queue(&self, bytes: Vec<u8>) {
        let len = bytes.len();
        let before = self.shared.queued_bytes.fetch_add(len, Ordering::AcqRel);
        if before.saturating_add(len) > QUEUE_BYTES {
            self.shared.queued_bytes.fetch_sub(len, Ordering::AcqRel);
            self.shared.dropped.fetch_add(1, Ordering::Relaxed);
            return;
        }
        let dropped = self.shared.dropped.swap(0, Ordering::AcqRel);
        match self.tx.try_send(Queued { dropped, bytes }) {
            Ok(()) => {
                self.shared.queued.fetch_add(1, Ordering::AcqRel);
            }
            Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) => {
                self.shared.queued_bytes.fetch_sub(len, Ordering::AcqRel);
                self.shared.dropped.fetch_add(dropped + 1, Ordering::AcqRel);
            }
        }
    }
}

/// The writer thread: each queued line in order, after a line that counts the lines dropped
/// just before it.
fn write_lines<W: Write>(rx: Receiver<Queued>, mut out: W, shared: &Shared) {
    for Queued { dropped, bytes } in rx {
        if dropped > 0 {
            let _ = out.write_all(&dropped_line(dropped));
        }
        let _ = out.write_all(&bytes);
        let _ = out.flush();
        shared.queued_bytes.fetch_sub(bytes.len(), Ordering::AcqRel);
        shared.written.fetch_add(1, Ordering::AcqRel);
        // Taken after the count: a `flush` that read the old count is waiting by now.
        drop(shared.wake_lock());
        shared.woken.notify_all();
    }
}

/// The line that reports `dropped` lines, in the log's own line format.
fn dropped_line(dropped: u64) -> Vec<u8> {
    use tracing_subscriber::fmt::time::{FormatTime, SystemTime};
    let mut line = String::new();
    let _ = SystemTime.format_time(&mut tracing_subscriber::fmt::format::Writer::new(&mut line));
    line.push_str(&format!(
        "  WARN {dropped} log lines were dropped: the log output took no bytes for a while\n"
    ));
    line.into_bytes()
}

static INSTALLED: OnceLock<Arc<Shared>> = OnceLock::new();

/// Waits, at most `budget`, until every line queued before the call is written. True when they
/// are (or no sink is installed). A line queued while it waits may or may not be waited for.
pub fn flush(budget: Duration) -> bool {
    let Some(shared) = INSTALLED.get() else { return true };
    flush_shared(shared, budget)
}

fn flush_shared(shared: &Shared, budget: Duration) -> bool {
    let deadline = Instant::now() + budget;
    let target = shared.queued.load(Ordering::Acquire);
    let mut guard = shared.wake_lock();
    while shared.written.load(Ordering::Acquire) < target {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return false;
        }
        guard = shared.woken.wait_timeout(guard, left).unwrap_or_else(PoisonError::into_inner).0;
    }
    true
}

#[cfg(test)]
#[path = "log_sink_tests.rs"]
mod tests;
