//! A load that begins at a restore point gives what a load of the whole log gives
//! (`restore_point.rs`).

use super::*;

/// A memory store that keeps restore points (`keeps`), shared by every hub a test starts over
/// it, as a daemon's next start reads the last one's files.
#[derive(Clone)]
struct PointStore {
    inner: Arc<dyn Store>,
    keeps: bool,
    points: Arc<StdMutex<HashMap<String, Vec<u8>>>>,
    /// The seq each scan began past, so a test sees where a load began.
    from: Arc<StdMutex<Vec<u64>>>,
}

impl PointStore {
    fn new(keeps: bool) -> Self {
        let mut config = Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let inner = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": ID, "name": "point",
            "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
        }))
        .unwrap();
        inner.save(&meta).unwrap();
        Self {
            inner: Arc::from(inner),
            keeps,
            points: Default::default(),
            from: Default::default(),
        }
    }

    /// A daemon start over this store: a hub with the chat listed and its log not read yet, as
    /// a start installs a stored chat (`install_stored_session`); the test reads it.
    fn start(&self) -> (Arc<Hub>, Arc<Session>) {
        let hub = Hub::new_loading(Config::default(), Box::new(self.clone()), Mailbox::memory());
        let meta = hub.store.load(ID).unwrap().unwrap();
        hub.install_stored_session(meta, false, false, true);
        let session = hub.sessions.lock().unwrap().get(ID).cloned().unwrap();
        (hub, session)
    }
}

impl Store for PointStore {
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
    fn events(&self, id: &str, after: u64, limit: usize) -> anyhow::Result<Vec<EventRecord>> {
        self.inner.events(id, after, limit)
    }
    fn scan(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> anyhow::Result<()> {
        self.from.lock().unwrap().push(after);
        self.inner.scan(id, after, visit)
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.inner.delete(id)
    }
    fn restore_point(&self, id: &str) -> Option<Vec<u8>> {
        self.points.lock().unwrap().get(id).cloned()
    }
    fn save_restore_point(&self, id: &str, bytes: &[u8]) -> anyhow::Result<()> {
        if self.keeps {
            self.points.lock().unwrap().insert(id.to_owned(), bytes.to_vec());
        }
        Ok(())
    }
}

const ID: &str = "restore-point-chat";

/// A turn that ran: queued, taken, started, ended.
fn turn(hub: &Hub, s: &Arc<Session>, n: usize) {
    let (p, t) = (format!("p{n}"), format!("t{n}"));
    let text = format!("step {n}");
    let prompt = json!([{"type": "text", "text": text}]);
    hub.append(
        s,
        "mux",
        "queued",
        json!({"promptId": p, "turnId": t, "text": text, "prompt": prompt}),
    );
    hub.append(s, "mux", "dequeued", json!({"promptId": p, "turnId": t}));
    hub.append(s, "in", "user_message", json!({"promptId": p, "turnId": t, "text": text}));
    hub.append(s, "mux", "turn_started", json!({"promptId": p, "turnId": t}));
    hub.append(s, "mux", "turn_result", json!({"turnId": t, "status": "completed"}));
}

/// History up to a quiet point: turns, a branch, a move begun and aborted under an epoch, a
/// held prompt that later ran, a reorder, another agent's message to the inbox.
fn history(hub: &Hub, s: &Arc<Session>) {
    for n in 0..40 {
        turn(hub, s, n);
    }
    hub.append(s, "mux", "git", json!({"gitBranch": "feature/one"}));
    hub.append(s, "mux", "transfer_out", json!({"transferId": "x1", "epoch": 3}));
    hub.append(s, "mux", "transfer_aborted", json!({"transferId": "x1", "epoch": 3}));
    hub.append(s, "mux", "queue_paused", json!({"held": ["p40"], "retrying": []}));
    hub.append(s, "mux", "queue_order", json!({"order": ["p41", "p40"]}));
    turn(hub, s, 40);
    turn(hub, s, 41);
    hub.append(s, "mux", "inbox", json!({"promptId": "m1", "threadId": "th", "from": "lane",
        "class": "result", "kind": "result", "client": "acpmux", "text": "done",
        "prompt": [{"type": "text", "text": "done"}], "sender": {"kind": "agent", "label": "lane"}}));
}

/// What follows the quiet point: a held prompt that still waits, two queued in a reorder, a new
/// branch, a higher epoch, and a turn the restart cut.
fn after(hub: &Hub, s: &Arc<Session>) {
    turn(hub, s, 42);
    hub.append(s, "mux", "git", json!({"gitBranch": "feature/two"}));
    hub.append(s, "mux", "transfer_out", json!({"transferId": "x2", "epoch": 5}));
    hub.append(s, "mux", "transfer_aborted", json!({"transferId": "x2", "epoch": 5}));
    for n in [50, 51, 52] {
        let (p, t) = (format!("p{n}"), format!("t{n}"));
        hub.append(
            s,
            "mux",
            "queued",
            json!({"promptId": p, "turnId": t, "text": p,
            "prompt": [{"type": "text", "text": p}]}),
        );
    }
    hub.append(s, "mux", "queue_paused", json!({"held": ["p51"], "retrying": []}));
    hub.append(s, "mux", "queue_order", json!({"order": ["p52", "p50", "p51"]}));
    hub.append(
        s,
        "mux",
        "queued",
        json!({"promptId": "p53", "turnId": "t53", "text": "cut",
        "prompt": [{"type": "text", "text": "cut"}]}),
    );
    hub.append(s, "mux", "dequeued", json!({"promptId": "p53", "turnId": "t53"}));
    hub.append(s, "in", "user_message", json!({"promptId": "p53", "turnId": "t53", "text": "cut"}));
    hub.append(s, "mux", "turn_started", json!({"promptId": "p53", "turnId": "t53"}));
}

/// What a load restored, as a later reader sees it.
fn restored(hub: &Arc<Hub>, s: &Arc<Session>, from: u64) -> Value {
    let queue: Vec<Value> = s
        .queue
        .lock()
        .unwrap()
        .iter()
        .map(|q| json!({"prompt": q.prompt_id, "held": q.held}))
        .collect();
    let branch = hub.git_branch_now(&s.meta());
    let written: Vec<Value> = hub
        .store
        .events(ID, from, usize::MAX)
        .unwrap()
        .into_iter()
        .map(
            |e| json!({"kind": e.kind, "detail": e.msg.get("detail"), "turn": e.msg.get("turnId")}),
        )
        .collect();
    let inbox = s.inbox().items.iter().map(|i| i.prompt_id.clone()).collect::<Vec<_>>();
    json!({"queue": queue, "branch": branch, "epoch": s.ownership_epoch(),
           "blocked": s.transfer_blocked(), "moving": s.moving(), "written": written,
           "inbox": inbox})
}

/// The same chat loaded twice, once from the restore point a quiet load saved and once from the
/// whole log: the same queue, holds, order, branch, epoch, authority, inbox, and the same records
/// written (the cut turn's end and continuation).
#[test]
fn a_load_from_the_restore_point_restores_what_a_whole_log_load_does() {
    let (pointed, whole) = (PointStore::new(true), PointStore::new(false));
    let mut quiet_seq = 0;
    for store in [&pointed, &whole] {
        let (hub, s) = store.start();
        history(&hub, &s);
        hub.save_meta(&s);
        // A quiet start: nothing waits, nothing is written; the first store saves a point.
        let (hub, s) = store.start();
        hub.load_session_log(&s);
        let seq = s.seq.load(Ordering::SeqCst);
        if store.keeps {
            let point = hub.read_restore_point(&s).expect("a quiet load saves a restore point");
            assert_eq!(point.seq, seq, "the point is the seq the load read through");
            assert_eq!(point.ownership_epoch, 3);
            assert_eq!(point.queue.git_branch.as_deref(), Some("feature/one"));
            quiet_seq = seq;
        }
        after(&hub, &s);
        hub.save_meta(&s);
    }
    let (a_hub, a) = pointed.start();
    let (b_hub, b) = whole.start();
    let last = a.seq.load(Ordering::SeqCst);
    assert_eq!(last, b.seq.load(Ordering::SeqCst), "the two logs differ before the loads");

    pointed.from.lock().unwrap().clear();
    whole.from.lock().unwrap().clear();
    a_hub.load_session_log(&a);
    b_hub.load_session_log(&b);

    // Every fold begins at the point. What still reads from the start is outside the folds:
    // the cut turn's settlement (its continuation looks up its prompt, `restart_resume.rs`) and
    // the inbox of a hub outside a runtime, read with its log (`Session::inbox`).
    let began = pointed.from.lock().unwrap().clone();
    let whole_began = whole.from.lock().unwrap().clone();
    let from_start = |b: &[u64]| b.iter().filter(|s| **s == 0).count();
    assert!(
        from_start(&began) < from_start(&whole_began),
        "a load from a restore point read as much from the log's start as a whole load: \
         {began:?} against {whole_began:?}"
    );
    assert!(began.contains(&quiet_seq), "{began:?}");
    let (a, b) = (restored(&a_hub, &a, last), restored(&b_hub, &b, last));
    assert_eq!(a, b, "a load from the restore point differs from a whole-log load");
    assert_eq!(a["epoch"], 5, "{a:#}");
    assert_eq!(a["branch"], "feature/two", "{a:#}");
    assert!(
        a["written"].as_array().unwrap().iter().any(|e| e["detail"] == "outcome_unknown"),
        "{a:#}"
    );
}

/// A load that does not end quiet (a prompt still waits) keeps the point it began from, and a
/// point whose record no longer matches the log is not used.
#[test]
fn a_restore_point_moves_only_at_a_quiet_load_and_matches_its_log() {
    let store = PointStore::new(true);
    let (hub, s) = store.start();
    history(&hub, &s);
    hub.save_meta(&s);
    let (hub, s) = store.start();
    hub.load_session_log(&s);
    let first = hub.read_restore_point(&s).expect("a point").seq;
    hub.append(
        &s,
        "mux",
        "queued",
        json!({"promptId": "w", "turnId": "tw", "text": "w",
        "prompt": [{"type": "text", "text": "w"}]}),
    );
    hub.save_meta(&s);

    let (hub, s) = store.start();
    hub.load_session_log(&s);
    assert_eq!(hub.read_restore_point(&s).map(|p| p.seq), Some(first), "a waiting prompt moved it");
    assert_eq!(s.queue.lock().unwrap().len(), 1);

    // The record at the point's seq is not the one the point names: the log was replaced.
    let mut point = hub.read_restore_point(&s).unwrap();
    point.at += 1;
    hub.store.save_restore_point(ID, &serde_json::to_vec(&point).unwrap()).unwrap();
    assert!(hub.read_restore_point(&s).is_none(), "a point that does not match its log was used");
}
