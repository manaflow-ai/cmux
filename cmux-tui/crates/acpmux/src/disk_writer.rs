//! One writer off the hot path, for files that hold the latest state of something (a cache, a
//! view, a registry) and for saves a caller never waits on (`hub/outbox.rs` `update`).
//!
//! A request handler that wrote such a file itself waited out the disk: every `fsync` of
//! `config::write_atomic` and every outbox save ran on the tokio worker that asked, and on a slow
//! or loaded disk (Leo's Macs: hang-watch hq#8669, #8681, `write`, `fsync`, `Outbox::save`,
//! `write_atomic`) the workers sat in the kernel while other requests queued behind them. Here a
//! caller hands the bytes over and goes on; one thread writes them.
//!
//! - Coalescing: a file's newer bytes replace its older ones still waiting, so a file changed a
//!   hundred times while the disk is slow is written once, with the newest bytes (fewer bytes
//!   written too: macOS reports a process past its disk-write budget, the same hang-watch class).
//!   A job (a save) is queued once per key while it waits; its own state says what to write.
//! - Bounded: at most [`PENDING_BYTES`] wait. Past that a caller writes its file itself, as
//!   before this writer, so memory never grows with a disk that stopped; nothing is dropped.
//! - Ordered with direct writes: [`settle`] (every `config::write_atomic`) takes a waiting write
//!   of the same file out and waits for one in flight, so an older queued copy never lands after
//!   a newer direct one.
//! - Flushed at shutdown ([`flush`], `hub/shutdown.rs`), within a bound.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// The most bytes that wait for the writer. A write past it is made by its caller.
pub(crate) const PENDING_BYTES: usize = 32 << 20;

type Job = Box<dyn FnOnce() + Send>;

enum Item {
    File(PathBuf),
    Job(String),
}

#[derive(Default)]
struct State {
    files: HashMap<PathBuf, Vec<u8>>,
    jobs: HashMap<String, Job>,
    /// What waits, oldest first; each key once.
    order: VecDeque<Item>,
    bytes: usize,
    /// The file being written now.
    in_flight: Option<PathBuf>,
    busy: bool,
}

struct Writer {
    state: Mutex<State>,
    /// Something was queued.
    work: Condvar,
    /// A write ended.
    done: Condvar,
}

/// Counts, for `status` and the tests.
pub(crate) static WRITES: AtomicU64 = AtomicU64::new(0);
pub(crate) static COALESCED: AtomicU64 = AtomicU64::new(0);
pub(crate) static INLINE: AtomicU64 = AtomicU64::new(0);

// test-hook-allow: not a test hook; the process's one disk writer, whose queued jobs are saves
// every caller queues, and no test sets or replaces it
static WRITER: OnceLock<&'static Writer> = OnceLock::new();

thread_local! {
    static ON_WRITER: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

fn writer() -> &'static Writer {
    WRITER.get_or_init(|| {
        let writer: &'static Writer = Box::leak(Box::new(Writer {
            state: Mutex::new(State::default()),
            work: Condvar::new(),
            done: Condvar::new(),
        }));
        let spawned =
            std::thread::Builder::new().name("acpmux-disk-writer".into()).spawn(move || {
                ON_WRITER.with(|on| on.set(true));
                writer.run();
            });
        if let Err(e) = spawned {
            // No thread: every write is made by its caller (`write_later` sees `busy` stuck
            // false, but nothing drains). Mark the writer full so callers never queue.
            tracing::error!("disk writer: cannot start its thread ({e}); writes stay inline");
            writer.lock().bytes = usize::MAX;
        }
        writer
    })
}

impl Writer {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn run(&self) {
        loop {
            let mut state = self.lock();
            let item = loop {
                if let Some(item) = state.order.pop_front() {
                    break item;
                }
                state.busy = false;
                self.done.notify_all();
                state = self.work.wait(state).unwrap_or_else(|e| e.into_inner());
            };
            state.busy = true;
            match item {
                Item::File(path) => {
                    let Some(bytes) = state.files.remove(&path) else { continue };
                    state.bytes -= bytes.len();
                    state.in_flight = Some(path.clone());
                    drop(state);
                    if let Err(e) = crate::config::write_atomic_now(&path, &bytes) {
                        tracing::warn!("disk writer: could not write {}: {e:#}", path.display());
                    }
                    WRITES.fetch_add(1, Relaxed);
                    self.lock().in_flight = None;
                }
                Item::Job(key) => {
                    let Some(job) = state.jobs.remove(&key) else { continue };
                    drop(state);
                    // A job that panics loses its own write only; the writer goes on.
                    if std::panic::catch_unwind(std::panic::AssertUnwindSafe(job)).is_err() {
                        tracing::error!("disk writer: job {key} panicked");
                    }
                    WRITES.fetch_add(1, Relaxed);
                }
            }
            self.done.notify_all();
        }
    }
}

/// Writes `bytes` to `path` as `config::write_atomic` does, on the writer's thread: the caller
/// never waits on the disk. Newer bytes for the same path replace older ones still waiting.
/// A failed write is logged, never returned: only for files whose next write (or a rebuild)
/// makes up for a lost one. Past [`PENDING_BYTES`] the caller writes it now.
pub(crate) fn write_later(path: &Path, bytes: Vec<u8>) {
    let writer = writer();
    {
        let mut state = writer.lock();
        let replaced = state.files.get(path).map_or(0, Vec::len);
        if state.bytes.saturating_sub(replaced).saturating_add(bytes.len()) <= PENDING_BYTES {
            state.bytes = state.bytes - replaced + bytes.len();
            if state.files.insert(path.to_owned(), bytes).is_some() {
                COALESCED.fetch_add(1, Relaxed);
            } else {
                state.order.push_back(Item::File(path.to_owned()));
            }
            writer.work.notify_one();
            return;
        }
        // The writer is behind by its whole bound: this caller pays, as it did before. A
        // waiting copy of the file is older than these bytes: it goes.
        if let Some(old) = state.files.remove(path) {
            state.bytes -= old.len();
        }
    }
    INLINE.fetch_add(1, Relaxed);
    if let Err(e) = crate::config::write_atomic(path, &bytes) {
        tracing::warn!("disk writer: could not write {}: {e:#}", path.display());
    }
}

/// Runs `job` on the writer's thread. A job under the same `key` that still waits stands for
/// this one (it reads its state when it runs), so a key waits at most once.
pub(crate) fn run_later(key: &str, job: impl FnOnce() + Send + 'static) {
    let writer = writer();
    let mut state = writer.lock();
    if state.bytes == usize::MAX {
        // No writer thread (`writer`): nothing would ever run it, so the caller does.
        drop(state);
        INLINE.fetch_add(1, Relaxed);
        job();
        return;
    }
    if state.jobs.contains_key(key) {
        COALESCED.fetch_add(1, Relaxed);
        return;
    }
    state.jobs.insert(key.to_owned(), Box::new(job));
    state.order.push_back(Item::Job(key.to_owned()));
    writer.work.notify_one();
}

/// Before a direct write of `path`: a copy of it still waiting goes (the direct one is newer),
/// and one being written ends first. Free when nothing ever wrote later.
pub(crate) fn settle(path: &Path) {
    let Some(writer) = WRITER.get() else { return };
    if ON_WRITER.with(std::cell::Cell::get) {
        return;
    }
    let mut state = writer.lock();
    if let Some(old) = state.files.remove(path) {
        state.bytes -= old.len();
        COALESCED.fetch_add(1, Relaxed);
    }
    while state.in_flight.as_deref() == Some(path) {
        state = writer.done.wait(state).unwrap_or_else(|e| e.into_inner());
    }
}

/// Waits until everything queued so far is written, at most `bound`; false when it was not.
pub(crate) fn flush(bound: Duration) -> bool {
    let Some(writer) = WRITER.get() else { return true };
    if ON_WRITER.with(std::cell::Cell::get) {
        return false;
    }
    let deadline = Instant::now() + bound;
    let mut state = writer.lock();
    while state.busy || !state.order.is_empty() {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return false;
        }
        state = writer.done.wait_timeout(state, left).unwrap_or_else(|e| e.into_inner()).0;
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "acpmux-disk-writer-{}-{}",
            std::process::id(),
            crate::store::now_ms()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join(format!("f-{:?}", std::thread::current().id()).replace(['(', ')'], ""))
    }

    #[test]
    fn a_file_changed_while_the_disk_is_slow_is_written_once_with_its_newest_bytes() {
        let path = temp();
        let _slow = crate::config::startup_seams::slow_syncs(
            path.parent().unwrap(),
            Duration::from_millis(200),
        );
        // A first write holds the writer in the slow sync; the 999 that follow wait and fold.
        let started = Instant::now();
        for n in 0..1000 {
            write_later(&path, format!("{n}").into_bytes());
        }
        assert!(started.elapsed() < Duration::from_millis(150), "a caller waited on the disk");
        assert!(flush(Duration::from_secs(10)));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "999");
        // A direct write after a later one is never overwritten by it.
        write_later(&path, b"queued".to_vec());
        crate::config::write_atomic(&path, b"direct").unwrap();
        assert!(flush(Duration::from_secs(10)));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "direct");
    }

    #[test]
    fn a_job_waits_once_per_key() {
        let ran = std::sync::Arc::new(AtomicU64::new(0));
        let (hold, held) = std::sync::mpsc::channel::<()>();
        // Holds the writer, so the jobs below wait together.
        run_later("hold", move || {
            let _ = held.recv_timeout(Duration::from_secs(5));
        });
        for _ in 0..100 {
            let ran = ran.clone();
            run_later("save", move || {
                ran.fetch_add(1, Relaxed);
            });
        }
        drop(hold);
        assert!(flush(Duration::from_secs(10)));
        assert_eq!(ran.load(Relaxed), 1);
    }
}
