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
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let visited = Arc::new(AtomicU64::new(0));
    let inner = crate::store::open(&cfg.store, root).unwrap();
    let hub = Hub::new(cfg, Box::new(Counting { inner, visited: visited.clone() }));
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

fn write_chat(root: &Path, id: &str) {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, root).unwrap();
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "long", "harness": "claude",
        "cwd": "/tmp", "status": "closed", "createdAt": 1, "updatedAt": 2,
        "lastSeq": TURNS * 4, "eventCount": TURNS * 4,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
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
    hub.seed_time_breakdown(&session);
    assert!(visited.load(Ordering::SeqCst) >= TURNS * 4, "the first fold reads the log");
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
    hub.seed_time_breakdown(&session);
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
    hub.seed_time_breakdown(&session);
    assert_eq!(visited.load(Ordering::SeqCst) - after_load, 0, "an open read the journal");
    assert!(!session.time_breakdown.lock().unwrap().initialized);
    assert!(!session.time_breakdown.lock().unwrap().seeding);
    hub.shutdown_all().await;
}
