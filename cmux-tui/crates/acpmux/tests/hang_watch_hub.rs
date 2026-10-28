//! A hub's sync threads are hang-watched: its config writer, session
//! record writer and session event-log writer register with the process's hang watch when the hub
//! starts, and a record write that outlasts its deadline is one hang named for the record writer.
//!
//! The watch runs on a manual clock, so the 5 s write deadline passes without a 5 s wait. The
//! process watch is per process, so this file holds one test.

// Unix only until the Windows port runs the daemon.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// No agent: the hub only loads one stored chat and saves its record.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use std::io;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use acpmux::config::{Config, StoreMode};
use acpmux::daemon::hang_watch::WRITE_ITEM;
use acpmux::hub::Hub;
use acpmux::store::{EventRecord, META_SCHEMA, Progress, SessionMeta, Store};
use cmux_hang_watch::{Clock, Hang, HangSink, ThreadKind};
use serde_json::json;

const CHAT: &str = "01a15800-0000-7000-8000-000000000074";
/// The hub's writer threads: config, session records, session event logs.
const WRITERS: u64 = 3;

#[derive(Default)]
struct ManualClock(AtomicU64);

impl ManualClock {
    fn advance(&self, by: Duration) {
        self.0.fetch_add(u64::try_from(by.as_nanos()).unwrap(), Ordering::SeqCst);
    }
}

impl Clock for ManualClock {
    fn now_ns(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

struct Recorded(Mutex<Sender<Hang>>);

impl HangSink for Recorded {
    fn record(&self, hang: &Hang) -> io::Result<()> {
        let _ = self.0.lock().unwrap().send(hang.clone());
        Ok(())
    }
}

/// A gate a record save waits at once armed: `entered` says the save started, `release` lets it
/// finish.
struct Gate {
    entered: Sender<()>,
    release: Receiver<()>,
}

/// The file store, with record saves that can be held at a [`Gate`].
struct HeldSaves {
    inner: Arc<dyn Store>,
    gate: Arc<Mutex<Option<Gate>>>,
}

impl Store for HeldSaves {
    fn list(&self) -> anyhow::Result<Vec<SessionMeta>> {
        self.inner.list()
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<SessionMeta>> {
        self.inner.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> anyhow::Result<()> {
        if let Some(gate) = self.gate.lock().unwrap().take() {
            gate.entered.send(()).unwrap();
            gate.release.recv().unwrap();
        }
        self.inner.save(meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> anyhow::Result<()> {
        self.inner.append(id, record)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> anyhow::Result<Vec<EventRecord>> {
        self.inner.events(id, after, limit)
    }
    fn flush(&self) -> anyhow::Result<()> {
        self.inner.flush()
    }
    fn close_log(&self, id: &str) {
        self.inner.close_log(id);
    }
    fn progress(&self, id: &str) -> Option<tokio::sync::watch::Receiver<Progress>> {
        self.inner.progress(id)
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.inner.delete(id)
    }
    fn session_dir(&self, id: &str) -> Option<PathBuf> {
        self.inner.session_dir(id)
    }
}

fn registered() -> u64 {
    cmux_hang_watch::stats().expect("the process watch runs").registered
}

fn wait_for(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn meta(id: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": id, "name": id, "harness": "claude", "cwd": "/tmp",
        "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap()
}

#[test]
fn hang_watch_a_hubs_writers_register_and_a_slow_record_write_is_blamed_on_its_writer() {
    let clock = Arc::new(ManualClock::default());
    let (sender, hangs) = channel();
    // A short period, and no drift check: the manual clock jumps.
    let config = cmux_hang_watch::Config {
        min_deadline: Duration::from_millis(20),
        drift_tolerance: Duration::from_secs(3_600),
    };
    cmux_hang_watch::init_process(config, clock.clone(), Box::new(Recorded(Mutex::new(sender))))
        .expect("the process watch starts");

    let root = std::env::temp_dir().join(format!("acpmux-hang-hub-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    // A daemon home is private: no other user may write the folder the store is in.
    std::fs::set_permissions(&root, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    let mut cfg: Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = StoreMode::Local;
    {
        let store = acpmux::store::open(&cfg.store, &root).unwrap();
        store.save(&meta(CHAT)).unwrap();
        store.flush().unwrap();
    }
    assert_eq!(registered(), 0, "the setup store's log writer outlived it");

    let inner: Arc<dyn Store> = Arc::from(acpmux::store::open(&cfg.store, &root).unwrap());
    let gate = Arc::new(Mutex::new(None));
    let hub = Hub::new(cfg, Box::new(HeldSaves { inner: inner.clone(), gate: gate.clone() }));
    wait_for("the writers to register", || registered() == WRITERS);

    // Idle writers wait for work far past their deadline: nobody is blamed.
    clock.advance(WRITE_ITEM * 4);
    std::thread::sleep(Duration::from_millis(200));
    let idle: Vec<Hang> = hangs.try_iter().collect();
    assert!(idle.is_empty(), "an idle writer was blamed for its wait: {idle:?}");

    // A record save held past the write deadline.
    let (entered, entering) = channel();
    let (release, released) = channel();
    *gate.lock().unwrap() = Some(Gate { entered, release: released });
    let session = hub.sessions().into_iter().find(|s| s.id == CHAT).expect("the stored chat");
    hub.set_rules(&session, Some(json!({})));
    entering.recv_timeout(Duration::from_secs(20)).expect("the record writer saves the chat");
    // The rules line is on disk, so the log writer is between items.
    let progress = inner.progress(CHAT).expect("a file store reports its log");
    wait_for("the rules line", || {
        let p = *progress.borrow();
        p.queued > 0 && p.written == p.queued
    });
    clock.advance(WRITE_ITEM + Duration::from_secs(1));
    let hang = hangs.recv_timeout(Duration::from_secs(20)).expect("the held save is reported");
    assert_eq!((hang.thread.as_str(), hang.kind), ("acpmux-meta-writer", ThreadKind::Lane));
    assert_eq!(hang.deadline_ms, WRITE_ITEM.as_millis() as u64);
    release.send(()).unwrap();
    std::thread::sleep(Duration::from_millis(200));
    let left: Vec<Hang> = hangs.try_iter().collect();
    assert!(left.is_empty(), "only the held save is a hang: {left:?}");

    drop(session);
    drop(hub);
    let _ = std::fs::remove_dir_all(&root);
}
