//! A chat's time breakdown survives a daemon restart without folding the chat's journal again
//! (`hub/views.rs` `seed_time_breakdown`, the copy `time_breakdown::FILE`). An open of a long
//! chat read its whole journal in the background to fold it (a 40 MB chat: 5 to 15 MB read inside
//! the open's own window, `tests/daemon_chat_open.rs`).

use super::*;
use crate::config::{Config, StoreMode};
use crate::store::{SessionMeta, Store};
use std::sync::atomic::{AtomicU64, Ordering};

struct Root(PathBuf);

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A file store that counts the records its reads visit.
struct Counting {
    inner: Box<dyn Store>,
    visited: Arc<AtomicU64>,
}

impl Store for Counting {
    fn list(&self) -> anyhow::Result<Vec<SessionMeta>> {
        self.inner.list()
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<SessionMeta>> {
        self.inner.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> anyhow::Result<()> {
        self.inner.save(meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> anyhow::Result<()> {
        self.inner.append(id, record)
    }
    fn flush_session(&self, id: &str) -> anyhow::Result<()> {
        self.inner.flush_session(id)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> anyhow::Result<Vec<EventRecord>> {
        let events = self.inner.events(id, after, limit)?;
        self.visited.fetch_add(events.len() as u64, Ordering::SeqCst);
        Ok(events)
    }
    fn scan(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> anyhow::Result<()> {
        self.inner.scan(id, after, &mut |record| {
            self.visited.fetch_add(1, Ordering::SeqCst);
            visit(record)
        })
    }
    fn scan_back(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> anyhow::Result<()> {
        self.inner.scan_back(id, after, before, skip, &mut |record| {
            self.visited.fetch_add(1, Ordering::SeqCst);
            visit(record)
        })
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.inner.delete(id)
    }
    fn session_dir(&self, id: &str) -> Option<PathBuf> {
        self.inner.session_dir(id)
    }
    fn session_path(&self, id: &str) -> Option<PathBuf> {
        self.inner.session_path(id)
    }
}

fn open(root: &Path) -> (Arc<Hub>, Arc<AtomicU64>) {
    open_with(root, false)
}

/// `deferred`: a daemon's start, whose chat logs (and their catch-up past the saved meta) are
/// read after it answers, so a `waitLogs:false` open can come first.
fn open_with(root: &Path, deferred: bool) -> (Arc<Hub>, Arc<AtomicU64>) {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let visited = Arc::new(AtomicU64::new(0));
    let inner = crate::store::open(&cfg.store, root).unwrap();
    let store = Box::new(Counting { inner, visited: visited.clone() });
    let hub = if deferred {
        Hub::new_deferred(cfg, store, crate::mailbox::Mailbox::memory())
    } else {
        Hub::new(cfg, store)
    };
    (hub, visited)
}

const TURNS: u64 = 1_500;

/// `TURNS` turns of a start, a tool call and a result, 10 s apart, 3 s of each a read.
fn turn(n: u64) -> [EventRecord; 4] {
    let (seq, at) = (n * 4 + 1, 1_000_000 + n * 10_000);
    let record = |k: u64, at: u64, kind: &str, msg: Value| EventRecord {
        seq: seq + k,
        at,
        dir: "mux".into(),
        kind: kind.into(),
        msg,
        host_seq: None,
    };
    [
        record(0, at, "turn_started", json!({"turnSeq": n + 1, "turnId": format!("t{n}")})),
        record(1, at + 1_000, "tool_call", json!({"toolCallId": "r", "kind": "read"})),
        record(
            2,
            at + 4_000,
            "tool_call_update",
            json!({"toolCallId": "r", "status": "completed"}),
        ),
        record(
            3,
            at + 9_000,
            "turn_result",
            json!({"turnSeq": n + 1, "turnId": format!("t{n}"), "totalTokens": 7}),
        ),
    ]
}

fn meta(id: &str, last_seq: u64) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "long", "harness": "claude",
        "cwd": "/tmp", "status": "closed", "createdAt": 1, "updatedAt": 2,
        "lastSeq": last_seq, "eventCount": last_seq,
    }))
    .unwrap()
}

/// Saves the chat's meta with `last_seq`, as a stop leaves it.
fn save_meta(root: &Path, id: &str, last_seq: u64) {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, root).unwrap();
    store.save(&meta(id, last_seq)).unwrap();
    store.flush().unwrap();
}

fn write_chat(root: &Path, id: &str) {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, root).unwrap();
    store.save(&meta(id, TURNS * 4)).unwrap();
    for n in 0..TURNS {
        for record in turn(n) {
            store.append(id, &record).unwrap();
        }
    }
    store.close_log(id);
    store.flush().unwrap();
}

/// The breakdown of every record of the chat folded from nothing: what a restore must equal.
fn whole_fold(turns: u64, at: u64) -> time_breakdown::TimeBreakdown {
    let mut state = time_breakdown::State::default();
    for n in 0..turns {
        for record in turn(n) {
            state.record(&record);
        }
    }
    state.snapshot(at)
}

fn breakdown(session: &Session, at: u64) -> time_breakdown::TimeBreakdown {
    session.time_breakdown.lock().unwrap().snapshot(at)
}

/// The chat's first fold is saved, a restart restores it and reads only the records written
/// after it, and the result is the fold of the whole chat.
#[tokio::test]
async fn a_restart_restores_the_saved_fold_and_reads_only_the_records_past_it() {
    let root =
        Root(std::env::temp_dir().join(format!("acpmux-tb-restore-{}", uuid::Uuid::now_v7())));
    write_chat(&root.0, "long");

    // The one fold: a chat with no saved copy, at a turn's end.
    let (hub, visited) = open(&root.0);
    hub.load_logs();
    let session = hub.resolve("long").unwrap();
    hub.seed_time_breakdown(&session, true);
    assert!(visited.load(Ordering::SeqCst) >= TURNS * 4, "the first fold reads the log");
    assert!(root.0.join("sessions/long").join(time_breakdown::FILE).exists());
    // Three more turns the daemon logs live, then it stops.
    for n in TURNS..TURNS + 3 {
        for record in turn(n) {
            hub.append_at(&session, &record.dir, &record.kind, record.msg, None, Some(record.at));
        }
    }
    hub.store.flush().unwrap();
    hub.shutdown_all().await;
    drop(hub);

    // A restart and an open: the saved copy and the records past it, nothing else.
    let (hub, visited) = open(&root.0);
    hub.load_logs();
    let session = hub.resolve("long").unwrap();
    let after_load = visited.load(Ordering::SeqCst);
    hub.seed_time_breakdown(&session, false);
    let read = visited.load(Ordering::SeqCst) - after_load;
    assert!(session.time_breakdown.lock().unwrap().initialized);
    assert!(read <= 100, "the open visited {read} records of a {}-record journal", TURNS * 4 + 12);
    let at = 1_000_000 + (TURNS + 3) * 10_000;
    assert_eq!(breakdown(&session, at), whole_fold(TURNS + 3, at));
    hub.shutdown_all().await;
}

/// A chat with no saved fold is not folded by an open, not even in the background.
#[tokio::test]
async fn an_open_of_a_chat_with_no_saved_fold_reads_no_record() {
    let root = Root(std::env::temp_dir().join(format!("acpmux-tb-open-{}", uuid::Uuid::now_v7())));
    write_chat(&root.0, "long");
    let (hub, visited) = open(&root.0);
    hub.load_logs();
    let session = hub.resolve("long").unwrap();
    let after_load = visited.load(Ordering::SeqCst);
    hub.seed_time_breakdown(&session, false);
    assert_eq!(visited.load(Ordering::SeqCst) - after_load, 0, "an open read the journal");
    assert!(!session.time_breakdown.lock().unwrap().initialized);
    assert!(!session.time_breakdown.lock().unwrap().seeding);
    hub.shutdown_all().await;
}

/// A copy saved ahead of the chat's saved meta is still this log's. The append seam saves the
/// copy before it counts the record in the meta, and the meta is saved less often, so a hard stop
/// leaves the meta behind the copy; an open (`waitLogs:false`) that comes before the log's
/// catch-up restores the copy anyway (review of #42481, F1).
#[tokio::test]
async fn an_open_before_the_catch_up_restores_a_copy_ahead_of_the_saved_meta() {
    let root = Root(std::env::temp_dir().join(format!("acpmux-tb-ahead-{}", uuid::Uuid::now_v7())));
    write_chat(&root.0, "long");
    let (hub, _) = open(&root.0);
    let session = hub.resolve("long").unwrap();
    hub.seed_time_breakdown(&session, true);
    assert!(root.0.join("sessions/long").join(time_breakdown::FILE).exists());
    hub.store.flush().unwrap();
    hub.shutdown_all().await;
    drop(hub);
    // The meta as a hard stop leaves it: two turns behind the log and the copy.
    save_meta(&root.0, "long", TURNS * 4 - 8);

    // A daemon's start, and an open before its log pass reaches the chat.
    let (hub, visited) = open_with(&root.0, true);
    let session = hub.resolve("long").unwrap();
    assert_eq!(session.meta().last_seq, TURNS * 4 - 8, "the log was caught up first");
    let before = visited.load(Ordering::SeqCst);
    hub.seed_time_breakdown(&session, false);
    let read = visited.load(Ordering::SeqCst) - before;
    assert!(session.time_breakdown.lock().unwrap().initialized, "the copy was not used");
    assert!(read <= 100, "the open visited {read} records");
    let at = 1_000_000 + TURNS * 10_000;
    assert_eq!(breakdown(&session, at), whole_fold(TURNS, at));
    hub.shutdown_all().await;
}

/// A copy past the log's own end is not this log's, even when the saved meta reaches it (a
/// journal that lost its unsynced tail, another chat's copy): it is checked against the log,
/// not the meta, and the chat's one fold replaces it.
#[tokio::test]
async fn a_copy_past_the_logs_own_end_is_not_used() {
    let root = Root(std::env::temp_dir().join(format!("acpmux-tb-past-{}", uuid::Uuid::now_v7())));
    write_chat(&root.0, "long");
    let mut longer = time_breakdown::State::default();
    for n in 0..TURNS + 5 {
        for record in turn(n) {
            longer.record(&record);
        }
    }
    let (bytes, _) = longer.save().unwrap();
    std::fs::write(root.0.join("sessions/long").join(time_breakdown::FILE), bytes).unwrap();
    save_meta(&root.0, "long", (TURNS + 5) * 4);

    let (hub, _) = open(&root.0);
    let session = hub.resolve("long").unwrap();
    hub.seed_time_breakdown(&session, false);
    assert!(!session.time_breakdown.lock().unwrap().initialized, "a copy past the log was used");
    hub.seed_time_breakdown(&session, true);
    assert!(session.time_breakdown.lock().unwrap().initialized);
    let at = 1_000_000 + TURNS * 10_000;
    assert_eq!(breakdown(&session, at), whole_fold(TURNS, at));
    hub.shutdown_all().await;
}

/// A turn that ends while an open's seed runs is not lost. The turn's backfill finds the seed
/// running and starts none; the seed, which restores no copy, runs it before it lets go, so the
/// chat gets its breakdown without waiting for another turn (review of #42481, F2).
#[tokio::test]
async fn a_turn_ending_during_an_open_seed_still_gets_its_backfill() {
    let root = Root(std::env::temp_dir().join(format!("acpmux-tb-lost-{}", uuid::Uuid::now_v7())));
    write_chat(&root.0, "long");
    let (hub, _) = open(&root.0);
    let session = hub.resolve("long").unwrap();
    // An open's seed is running: the chat has no copy, so it will fold nothing.
    session.time_breakdown.lock().unwrap().seeding = true;
    for record in turn(TURNS) {
        hub.append_at(&session, &record.dir, &record.kind, record.msg, None, Some(record.at));
    }
    // The open's seed ends.
    hub.seed_time_breakdown(&session, false);
    {
        let state = session.time_breakdown.lock().unwrap();
        assert!(state.initialized, "the turn's backfill was dropped");
        assert!(!state.seeding);
    }
    let at = 1_000_000 + (TURNS + 1) * 10_000;
    assert_eq!(breakdown(&session, at), whole_fold(TURNS + 1, at));
    assert!(root.0.join("sessions/long").join(time_breakdown::FILE).exists());
    hub.shutdown_all().await;
}
