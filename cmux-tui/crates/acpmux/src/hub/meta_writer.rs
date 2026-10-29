//! Session records (`session.json`) reach the disk on one background thread, never on the
//! request or agent path (plans/cmux-next/perf-lead.md D1: "don't have disk stuff on the hot
//! path"). A save made each record durable in place: `write_atomic` syncs the file
//! (F_FULLFSYNC on macOS), renames it and syncs its folder, 20-50 ms on every
//! `_acpmux/draft_set`, rename, tag, status change and permission answer, on a tokio worker
//! (and for a permission answer under the session's permissions lock).
//!
//! `Hub::save_meta` now takes a snapshot of the record under its lock, stamped with a version
//! from the same lock hold, and queues it. The thread writes the newest snapshot of each
//! session; a newer save replaces a queued older one, so a burst of saves costs one write. A
//! save older than one already accepted (queued, being written or written) is dropped, so the
//! record on disk is never older than the newest snapshot taken before it (two saves race from
//! their snapshot to `queue`, and the newer one can be queued and written first). The log
//! stays the source of truth for what a crash cuts off: a record behind its log is caught up from the log's tail at the next start
//! (`Hub::catch_up`), as it always was for a hard stop. `flush` waits for every queued save
//! (shutdown); `Forget::forget` drops a session's queued save and waits for one being written, so a
//! purge's delete always comes after the last write of the purged session.

use crate::daemon::hang_watch::{SyncThread, WRITE_ITEM};
use crate::store::{SessionMeta, Store};
use crate::supervised::{Fatal, OwnedThread, ShutdownBehavior, Supervisor};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};

/// One queued save: the newest snapshot of a session's record.
struct Queued {
    meta: SessionMeta,
    purged: Arc<AtomicBool>,
}

#[derive(Default)]
struct State {
    queued: HashMap<String, Queued>,
    /// The newest snapshot version accepted for each session: queued, being written or written.
    /// An older one never reaches the disk after it.
    newest: HashMap<String, u64>,
    /// The session whose record the thread is writing now.
    writing: Option<String>,
    stop: bool,
}

struct Shared {
    state: Mutex<State>,
    /// Signalled when a save is queued or the writer stops.
    work: Condvar,
    /// Signalled after each write.
    written: Condvar,
    version: AtomicU64,
}

pub(crate) struct MetaWriter {
    shared: Arc<Shared>,
    thread: Mutex<Option<OwnedThread>>,
}

impl MetaWriter {
    /// Starts the writer thread for `store` under `supervisor`.
    pub(crate) fn start(store: Arc<dyn Store>, supervisor: &Supervisor) -> Self {
        let shared = Arc::new(Shared {
            state: Mutex::new(State::default()),
            work: Condvar::new(),
            written: Condvar::new(),
            version: AtomicU64::new(0),
        });
        let worker = shared.clone();
        // A panic in the thread leaves its queue half-written and every `flush` waiting:
        // Fatal. Continue on shutdown: the owner's drop writes what is queued and joins it.
        let thread = crate::supervised::owned_thread(
            supervisor,
            THREAD,
            cmux_threads::ThreadQos::Utility,
            Fatal,
            ShutdownBehavior::Continue,
            move || run(&worker, &*store),
        )
        .ok();
        if thread.is_none() {
            tracing::error!(
                "the session record writer did not start; records are written in place"
            );
        }
        Self { shared, thread: Mutex::new(thread) }
    }

    /// The next snapshot version. Taken while the caller holds the session's meta lock, so
    /// versions follow the order of the snapshots.
    pub(crate) fn next_version(&self) -> u64 {
        self.shared.version.fetch_add(1, Ordering::SeqCst) + 1
    }

    /// Queues `meta` (snapshot `version`) for writing, unless a newer snapshot of the same
    /// session was accepted already (queued, being written or written).
    pub(crate) fn queue(
        &self,
        store: &dyn Store,
        meta: SessionMeta,
        version: u64,
        purged: Arc<AtomicBool>,
    ) {
        if !self.running() {
            write(store, &meta, &purged);
            return;
        }
        let mut state = self.lock();
        if state.newest.get(&meta.id).is_some_and(|newest| *newest > version) {
            return;
        }
        state.newest.insert(meta.id.clone(), version);
        state.queued.insert(meta.id.clone(), Queued { meta, purged });
        self.shared.work.notify_one();
    }

    /// Waits until every save queued before this call is on disk.
    pub(crate) fn flush(&self) {
        let mut state = self.lock();
        while self.running() && (!state.queued.is_empty() || state.writing.is_some()) {
            state = cmux_blocking::sync::wait(&self.shared.written, state)
                .unwrap_or_else(|e| e.into_inner());
        }
    }

    /// A handle that drops session `id`'s queued save and waits for a write of it in progress
    /// ([`Forget::forget`]), from the blocking thread that then deletes the purged session's
    /// files.
    pub(crate) fn forget_handle(&self) -> Forget {
        Forget(self.shared.clone())
    }

    fn running(&self) -> bool {
        self.thread.lock().unwrap_or_else(|e| e.into_inner()).is_some()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.shared.state.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Drop for MetaWriter {
    /// Writes what is queued, then ends the thread.
    fn drop(&mut self) {
        self.lock().stop = true;
        self.shared.work.notify_one();
        if let Some(thread) = self.thread.get_mut().unwrap_or_else(|e| e.into_inner()).take() {
            cmux_blocking::scoped_blocking_call(
                "thread::join",
                cmux_blocking::BlockingKind::Join,
                || thread.join(),
            );
        }
    }
}

/// Drops a session's queued save, from a blocking thread (a purge's delete runs off the executor).
pub(crate) struct Forget(Arc<Shared>);

impl Forget {
    pub(crate) fn forget(&self, id: &str) {
        let mut state = self.0.state.lock().unwrap_or_else(|e| e.into_inner());
        state.queued.remove(id);
        state.newest.remove(id);
        while state.writing.as_deref() == Some(id) {
            state = cmux_blocking::sync::wait(&self.0.written, state)
                .unwrap_or_else(|e| e.into_inner());
        }
    }
}

/// The writer thread's name, also its name in a hang record.
const THREAD: &str = "acpmux-meta-writer";

fn run(shared: &Shared, store: &dyn Store) {
    let watched = SyncThread::register(THREAD, WRITE_ITEM);
    let mut state = shared.state.lock().unwrap_or_else(|e| e.into_inner());
    loop {
        // One session at a time, so `forget` waits for at most one write.
        let next = state.queued.keys().next().cloned();
        let Some(id) = next else {
            if state.stop {
                return;
            }
            state =
                cmux_blocking::sync::wait(&shared.work, state).unwrap_or_else(|e| e.into_inner());
            continue;
        };
        let Some(q) = state.queued.remove(&id) else { continue };
        state.writing = Some(id);
        drop(state);
        {
            let _item = watched.item();
            write(store, &q.meta, &q.purged);
        }
        state = shared.state.lock().unwrap_or_else(|e| e.into_inner());
        state.writing = None;
        shared.written.notify_all();
    }
}

/// Writes one record; never a purged session's (a late save would bring a purged session back
/// at the next start, `Hub::save_meta`).
fn write(store: &dyn Store, meta: &SessionMeta, purged: &AtomicBool) {
    if purged.load(Ordering::SeqCst) {
        return;
    }
    if let Err(e) = store.save(meta) {
        tracing::warn!(session = %meta.id, "save meta failed: {e}");
    }
    // The purge ran between the check and the save: delete it again.
    if purged.load(Ordering::SeqCst)
        && let Err(e) = store.delete(&meta.id)
    {
        tracing::warn!(session = %meta.id, "delete of a purged session failed: {e}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{EventRecord, MemoryStore};
    use std::time::{Duration, Instant};

    /// A store whose saves take `delay` and are counted, as an fsync-backed save is slow.
    struct SlowStore {
        inner: MemoryStore,
        delay: Duration,
        saves: AtomicU64,
    }

    impl Store for SlowStore {
        fn list(&self) -> anyhow::Result<Vec<SessionMeta>> {
            self.inner.list()
        }
        fn load(&self, id: &str) -> anyhow::Result<Option<SessionMeta>> {
            self.inner.load(id)
        }
        fn save(&self, meta: &SessionMeta) -> anyhow::Result<()> {
            std::thread::sleep(self.delay);
            self.saves.fetch_add(1, Ordering::SeqCst);
            self.inner.save(meta)
        }
        fn append(&self, id: &str, record: &EventRecord) -> anyhow::Result<()> {
            self.inner.append(id, record)
        }
        fn events(&self, id: &str, after: u64, limit: usize) -> anyhow::Result<Vec<EventRecord>> {
            self.inner.events(id, after, limit)
        }
        fn delete(&self, id: &str) -> anyhow::Result<()> {
            self.inner.delete(id)
        }
    }

    fn meta(id: &str, name: &str) -> SessionMeta {
        let mut m: SessionMeta = serde_json::from_value(serde_json::json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": name, "harness": "fake",
            "cwd": "/", "status": "idle", "createdAt": 0, "updatedAt": 0,
        }))
        .expect("a minimal session record");
        m.name = name.to_owned();
        m
    }

    fn slow(delay: Duration) -> Arc<SlowStore> {
        Arc::new(SlowStore { inner: MemoryStore::default(), delay, saves: AtomicU64::new(0) })
    }

    #[test]
    fn a_save_returns_before_the_disk_write_and_a_burst_writes_the_newest_record_once() {
        let store = slow(Duration::from_millis(50));
        let writer = MetaWriter::start(store.clone(), &crate::supervised::embedded());
        let purged = Arc::new(AtomicBool::new(false));
        let started = Instant::now();
        for i in 0..20 {
            let v = writer.next_version();
            writer.queue(&*store, meta("s1", &format!("n{i}")), v, purged.clone());
        }
        // Twenty saves queued in far less than one 50 ms write.
        assert!(started.elapsed() < Duration::from_millis(25), "{:?}", started.elapsed());
        writer.flush();
        assert_eq!(store.load("s1").unwrap().unwrap().name, "n19");
        // The first save may be written while the rest queue; the rest are one write.
        assert!(store.saves.load(Ordering::SeqCst) <= 2, "{}", store.saves.load(Ordering::SeqCst));
    }

    #[test]
    fn an_older_snapshot_never_replaces_a_newer_queued_one() {
        let store = slow(Duration::from_millis(30));
        let writer = MetaWriter::start(store.clone(), &crate::supervised::embedded());
        let purged = Arc::new(AtomicBool::new(false));
        // Occupy the thread so both snapshots below wait in the queue together.
        let v0 = writer.next_version();
        writer.queue(&*store, meta("busy", "x"), v0, purged.clone());
        let older = writer.next_version();
        let newer = writer.next_version();
        writer.queue(&*store, meta("s1", "newer"), newer, purged.clone());
        writer.queue(&*store, meta("s1", "older"), older, purged.clone());
        writer.flush();
        assert_eq!(store.load("s1").unwrap().unwrap().name, "newer");
    }

    /// A store whose first save of session `s1` waits until the test releases it, so a second
    /// save can be queued while the first is being written.
    struct GatedStore {
        inner: MemoryStore,
        entered: Mutex<Option<std::sync::mpsc::Sender<()>>>,
        release: Mutex<std::sync::mpsc::Receiver<()>>,
    }

    impl Store for GatedStore {
        fn list(&self) -> anyhow::Result<Vec<SessionMeta>> {
            self.inner.list()
        }
        fn load(&self, id: &str) -> anyhow::Result<Option<SessionMeta>> {
            self.inner.load(id)
        }
        fn save(&self, meta: &SessionMeta) -> anyhow::Result<()> {
            if let Some(entered) = self.entered.lock().unwrap().take() {
                entered.send(()).unwrap();
                self.release.lock().unwrap().recv().unwrap();
            }
            self.inner.save(meta)
        }
        fn append(&self, id: &str, record: &EventRecord) -> anyhow::Result<()> {
            self.inner.append(id, record)
        }
        fn events(&self, id: &str, after: u64, limit: usize) -> anyhow::Result<Vec<EventRecord>> {
            self.inner.events(id, after, limit)
        }
        fn delete(&self, id: &str) -> anyhow::Result<()> {
            self.inner.delete(id)
        }
    }

    #[test]
    fn an_older_snapshot_queued_while_a_newer_one_is_written_never_lands() {
        let (entered_tx, entered) = std::sync::mpsc::channel();
        let (release, release_rx) = std::sync::mpsc::channel();
        let store = Arc::new(GatedStore {
            inner: MemoryStore::default(),
            entered: Mutex::new(Some(entered_tx)),
            release: Mutex::new(release_rx),
        });
        let writer = MetaWriter::start(store.clone(), &crate::supervised::embedded());
        let purged = Arc::new(AtomicBool::new(false));
        let older = writer.next_version();
        let newer = writer.next_version();
        writer.queue(&*store, meta("s1", "newer"), newer, purged.clone());
        // The thread has taken the newer snapshot and is writing it.
        entered.recv().unwrap();
        writer.queue(&*store, meta("s1", "older"), older, purged.clone());
        release.send(()).unwrap();
        writer.flush();
        assert_eq!(store.load("s1").unwrap().unwrap().name, "newer");
    }

    #[test]
    fn a_purged_session_is_never_written_back() {
        let store = slow(Duration::from_millis(30));
        let writer = MetaWriter::start(store.clone(), &crate::supervised::embedded());
        let purged = Arc::new(AtomicBool::new(false));
        let v = writer.next_version();
        writer.queue(&*store, meta("busy", "x"), v, Arc::new(AtomicBool::new(false)));
        let v = writer.next_version();
        writer.queue(&*store, meta("s1", "late"), v, purged.clone());
        purged.store(true, Ordering::SeqCst);
        writer.forget_handle().forget("s1");
        store.delete("s1").unwrap();
        writer.flush();
        assert!(store.load("s1").unwrap().is_none());
    }

    #[test]
    fn dropping_the_writer_writes_what_is_queued() {
        let store = slow(Duration::from_millis(20));
        let writer = MetaWriter::start(store.clone(), &crate::supervised::embedded());
        for i in 0..5 {
            let v = writer.next_version();
            writer.queue(
                &*store,
                meta(&format!("s{i}"), "kept"),
                v,
                Arc::new(AtomicBool::new(false)),
            );
        }
        drop(writer);
        for i in 0..5 {
            assert_eq!(store.load(&format!("s{i}")).unwrap().unwrap().name, "kept");
        }
    }
}
