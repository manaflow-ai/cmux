//! The session record writer (`meta_writer.rs`) and the settings writer (`config_writer.rs`)
//! while saves keep coming. A flush waits for the saves queued before it, never for an empty
//! queue: when the shutdown's budget ran out, agents still run and keep saving (`daemon.rs`,
//! `Hub::flush`), and a flush that waited for an empty queue never returned (the same flaw as the
//! event log's read, fleet job 88f5f7da34f5480fc9817e95). And the record writer takes sessions in
//! the order they queued, so a session saved again and again never holds back one saved once.
//!
//! No test depends on timing. "Saves keep coming" is made exact: the next save is queued on the
//! writer thread during each write, so no write ever ends with an empty queue. The write order
//! is held with a gate. [`HANG`] only turns a hang into a failure.

use super::config_writer::{ConfigWriter, WriteHook};
use super::meta_writer::MetaWriter;
use crate::store::{EventRecord, MemoryStore, SessionMeta, Store};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak, mpsc};
use std::time::Duration;

/// Turns a hang into a failure. A bounded flush returns after at most two writes.
const HANG: Duration = Duration::from_secs(10);

fn meta(id: &str, n: u64) -> SessionMeta {
    serde_json::from_value(serde_json::json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": format!("{n}"), "harness": "fake",
        "cwd": "/", "status": "idle", "createdAt": 0, "updatedAt": 0,
    }))
    .expect("a minimal session record")
}

fn not_purged() -> Arc<AtomicBool> {
    Arc::new(AtomicBool::new(false))
}

/// Runs `op` on its own thread; fails when it has not returned within [`HANG`].
fn within_hang<T: Send + 'static>(what: &str, op: impl FnOnce() -> T + Send + 'static) -> T {
    let (done_tx, done) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = done_tx.send(op());
    });
    match done.recv_timeout(HANG) {
        Ok(got) => got,
        Err(mpsc::RecvTimeoutError::Timeout) => panic!(
            "{what} got no reply in {HANG:?} while saves kept coming: it waits for the queue to be \
             empty, which it never is"
        ),
        Err(mpsc::RecvTimeoutError::Disconnected) => panic!("{what} panicked"),
    }
}

/// A store that, while `on`, queues the next save of the session it writes before the write
/// returns: the writer's queue is never empty when a write ends. `n` numbers the saves.
#[derive(Default)]
struct Resaving {
    inner: MemoryStore,
    writer: OnceLock<Weak<MetaWriter>>,
    on: AtomicBool,
    n: AtomicU64,
}

impl Store for Resaving {
    fn list(&self) -> anyhow::Result<Vec<SessionMeta>> {
        self.inner.list()
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<SessionMeta>> {
        self.inner.load(id)
    }
    fn save(&self, saved: &SessionMeta) -> anyhow::Result<()> {
        self.inner.save(saved)?;
        if self.on.load(Ordering::SeqCst)
            && let Some(writer) = self.writer.get().and_then(Weak::upgrade)
        {
            let n = self.n.fetch_add(1, Ordering::SeqCst) + 1;
            let version = writer.next_version();
            writer.queue(self, meta(&saved.id, n), version, not_purged());
        }
        Ok(())
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
fn writer_flush_a_record_flush_while_a_chat_keeps_saving_returns_with_the_saves_before_it() {
    let store = Arc::new(Resaving::default());
    let writer = Arc::new(MetaWriter::start(store.clone(), &crate::supervised::embedded()));
    store.writer.set(Arc::downgrade(&writer)).ok();
    store.on.store(true, Ordering::SeqCst);
    writer.queue(&*store, meta("hot", 0), writer.next_version(), not_purged());
    let before = store.n.load(Ordering::SeqCst);
    let flusher = writer.clone();
    within_hang("a record flush", move || flusher.flush());
    let on_disk: u64 = store.load("hot").unwrap().unwrap().name.parse().unwrap();
    assert!(on_disk >= before, "the flush returned before save {before} was written: {on_disk}");
    // Stop the saves; the writer's last strong reference is dropped here, not on its thread.
    store.on.store(false, Ordering::SeqCst);
    writer.flush();
}

/// A store that reports each session it writes, and holds the first write of `first` until the
/// test releases it.
struct Ordered {
    inner: MemoryStore,
    entered: Mutex<Option<mpsc::Sender<()>>>,
    release: Mutex<mpsc::Receiver<()>>,
    written: Mutex<mpsc::Sender<String>>,
}

impl Store for Ordered {
    fn list(&self) -> anyhow::Result<Vec<SessionMeta>> {
        self.inner.list()
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<SessionMeta>> {
        self.inner.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> anyhow::Result<()> {
        if meta.id == "first"
            && let Some(entered) = self.entered.lock().unwrap().take()
        {
            entered.send(()).unwrap();
            self.release.lock().unwrap().recv().unwrap();
        }
        self.inner.save(meta)?;
        self.written.lock().unwrap().send(meta.id.clone()).unwrap();
        Ok(())
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

/// Sessions are written in the order they queued; a session saved again while queued keeps its
/// place, and one saved again while it is written goes to the back. So a session saved once
/// waits for at most one write of each other session, however often they save. The order the
/// old pick took (`queued.keys().next()`, HashMap order) matches this one only when the map
/// happens to iterate 33 keys in queue order (about 1 in 33!).
#[test]
fn writer_flush_sessions_are_written_in_the_order_they_queued() {
    let (entered_tx, entered) = mpsc::channel();
    let (release, release_rx) = mpsc::channel();
    let (written_tx, written) = mpsc::channel();
    let store = Arc::new(Ordered {
        inner: MemoryStore::default(),
        entered: Mutex::new(Some(entered_tx)),
        release: Mutex::new(release_rx),
        written: Mutex::new(written_tx),
    });
    let writer = MetaWriter::start(store.clone(), &crate::supervised::embedded());
    writer.queue(&*store, meta("first", 0), writer.next_version(), not_purged());
    // The writer holds the first write: everything below queues behind it.
    entered.recv_timeout(HANG).expect("the writer took the first save");
    let ids: Vec<String> = (0..32).map(|i| format!("s{i:02}")).collect();
    for id in &ids {
        writer.queue(&*store, meta(id, 0), writer.next_version(), not_purged());
    }
    writer.queue(&*store, meta("s05", 1), writer.next_version(), not_purged());
    writer.queue(&*store, meta("first", 1), writer.next_version(), not_purged());
    release.send(()).unwrap();
    let order: Vec<String> = (0..34)
        .map(|_| written.recv_timeout(HANG).expect("the writer wrote every queued session"))
        .collect();
    let mut want = vec!["first".to_owned()];
    want.extend(ids);
    want.push("first".to_owned());
    assert_eq!(order, want, "sessions were not written in the order they queued");
    assert_eq!(store.load("s05").unwrap().unwrap().name, "1");
    assert_eq!(store.load("first").unwrap().unwrap().name, "1");
}

#[test]
fn writer_flush_a_settings_flush_while_settings_keep_changing_returns_with_the_bytes_before_it() {
    let dir = std::env::temp_dir().join(format!(
        "acpmux-writer-flush-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("config.json");
    let cell: Arc<OnceLock<Weak<ConfigWriter>>> = Arc::default();
    let on = Arc::new(AtomicBool::new(true));
    let n = Arc::new(AtomicU64::new(0));
    // Before each batch is written, the next bytes queue: no batch ends with an empty queue.
    let hook: WriteHook = {
        let (cell, on, n, path) = (cell.clone(), on.clone(), n.clone(), path.clone());
        Arc::new(move || {
            if on.load(Ordering::SeqCst)
                && let Some(writer) = cell.get().and_then(Weak::upgrade)
            {
                let next = n.fetch_add(1, Ordering::SeqCst) + 1;
                writer.queue(path.clone(), format!("{next}").into_bytes());
            }
        })
    };
    let writer =
        Arc::new(ConfigWriter::start_with_hook(&crate::supervised::embedded(), Some(hook)));
    cell.set(Arc::downgrade(&writer)).ok();
    writer.queue(path.clone(), b"0".to_vec());
    let before = n.load(Ordering::SeqCst);
    let flusher = writer.clone();
    within_hang("a settings flush", move || flusher.flush());
    let on_disk: u64 = std::fs::read_to_string(&path).unwrap().parse().unwrap();
    assert!(on_disk >= before, "the flush returned before change {before} was written: {on_disk}");
    // Stop the changes; the writer's last strong reference is dropped here, not on its thread.
    on.store(false, Ordering::SeqCst);
    writer.flush();
    let _ = std::fs::remove_dir_all(&dir);
}
