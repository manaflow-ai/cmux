//! An inbox restored from its inbox point holds what one restored from the whole log does, and
//! reads only the log past the point (`inbox_point.rs`, cmux#51494).

use super::*;
use std::collections::HashMap;

/// A memory store that keeps inbox points (`keeps`), shared by every hub a test starts over it,
/// as a daemon's next start reads the last one's files. It notes where each inbox scan began.
#[derive(Clone)]
struct PointStore {
    inner: Arc<dyn Store>,
    keeps: bool,
    points: Arc<StdMutex<HashMap<String, Vec<u8>>>>,
    /// The seq each read of the inbox kinds began past.
    from: Arc<StdMutex<Vec<u64>>>,
}

const ID: &str = "inbox-point-chat";

impl PointStore {
    fn new(keeps: bool) -> Self {
        let mut config = Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let inner = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": ID, "name": "inbox point",
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

    /// A daemon start over this store, the chat's log read.
    fn start(&self) -> (Arc<Hub>, Arc<Session>) {
        let hub = Hub::new_loading(Config::default(), Box::new(self.clone()), Mailbox::memory());
        let meta = hub.store.load(ID).unwrap().unwrap();
        hub.install_stored_session(meta, false, false, true);
        let session = hub.sessions.lock().unwrap().get(ID).cloned().unwrap();
        (hub, session)
    }

    fn inbox_scans(&self) -> Vec<u64> {
        std::mem::take(&mut *self.from.lock().unwrap())
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
        self.inner.scan(id, after, visit)
    }
    fn scan_kinds(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> anyhow::Result<()> {
        if kinds == Hub::INBOX_KINDS {
            self.from.lock().unwrap().push(0);
        }
        self.inner.scan_kinds(id, kinds, visit)
    }
    fn scan_kinds_after(
        &self,
        id: &str,
        after: u64,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> anyhow::Result<()> {
        if kinds == Hub::INBOX_KINDS {
            self.from.lock().unwrap().push(after);
        }
        self.inner.scan_kinds_after(id, after, kinds, visit)
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.inner.delete(id)
    }
    fn inbox_point(&self, id: &str) -> Option<Vec<u8>> {
        self.points.lock().unwrap().get(id).cloned()
    }
    fn save_inbox_point(&self, id: &str, bytes: &[u8]) -> anyhow::Result<()> {
        if self.keeps {
            self.points.lock().unwrap().insert(id.to_owned(), bytes.to_vec());
        }
        Ok(())
    }
}

fn message(hub: &Hub, s: &Arc<Session>, id: &str) {
    hub.append(
        s,
        "mux",
        "inbox",
        json!({"promptId": id, "threadId": format!("th-{id}"),
        "from": "lane", "class": "result", "kind": "result", "client": "acpmux", "text": id,
        "prompt": [{"type": "text", "text": id}], "sender": {"kind": "agent", "label": "lane"}}),
    );
}

/// `id` noticed by notice `n`, read, and that notice answered: a message trim may let go of.
fn handled(hub: &Hub, s: &Arc<Session>, id: &str, n: &str) {
    hub.append(s, "mux", "inbox_noticed", json!({"promptIds": [id], "noticePromptId": n}));
    hub.append(s, "mux", "inbox_answered", json!({"noticePromptId": n, "answer": {"ok": n}}));
    hub.append(s, "mux", "inbox_read", json!({"promptIds": [id]}));
}

/// 600 messages: 400 handled (so trim lets the oldest go), ten withdrawn, one noticed and taken
/// back, one noticed and not answered yet.
fn history(hub: &Hub, s: &Arc<Session>) {
    for i in 0..600 {
        message(hub, s, &format!("m{i}"));
    }
    for i in 0..400 {
        handled(hub, s, &format!("m{i}"), &format!("n{i}"));
    }
    for i in 400..410 {
        hub.append(s, "mux", "inbox_removed", json!({"promptId": format!("m{i}")}));
    }
    hub.append(s, "mux", "inbox_noticed", json!({"promptIds": ["m420"], "noticePromptId": "n420"}));
    hub.append(s, "mux", "inbox_returned", json!({"promptIds": ["m420"]}));
    hub.append(s, "mux", "inbox_noticed", json!({"promptIds": ["m430"], "noticePromptId": "n430"}));
}

/// Past the point: new messages, the pending notice answered, a held one handled, one withdrawn,
/// and resends of a trimmed message and a withdrawn one.
fn after(hub: &Hub, s: &Arc<Session>) {
    for i in 600..620 {
        message(hub, s, &format!("m{i}"));
    }
    hub.append(s, "mux", "inbox_answered", json!({"noticePromptId": "n430", "answer": {"ok": 1}}));
    handled(hub, s, "m450", "n450");
    hub.append(s, "mux", "inbox_removed", json!({"promptId": "m500"}));
    message(hub, s, "m5");
    message(hub, s, "m401");
}

/// The inbox as a reader sees it.
fn restored(s: &Session) -> Value {
    let inbox = s.inbox();
    let items: Vec<Value> = inbox
        .items
        .iter()
        .map(|i| {
            json!({"id": i.prompt_id, "notice": i.notice, "answered": i.answered.is_some(),
                   "noticed": i.noticed, "read": i.read})
        })
        .collect();
    let sorted = |set: &std::collections::HashSet<String>| {
        let mut v: Vec<String> = set.iter().cloned().collect();
        v.sort();
        v
    };
    json!({"items": items, "removed": sorted(&inbox.removed), "trimmed": sorted(&inbox.trimmed)})
}

#[test]
fn an_inbox_from_its_point_holds_what_the_whole_log_gives_and_reads_past_it_only() {
    let (pointed, whole) = (PointStore::new(true), PointStore::new(false));
    let mut first = Vec::new();
    let mut point_seq = 0;
    for store in [&pointed, &whole] {
        let (hub, s) = store.start();
        history(&hub, &s);
        hub.save_meta(&s);
        // A restart: the first look at the inbox reads the whole log, and saves a point.
        let (hub, s) = store.start();
        hub.load_session_log(&s);
        first.push(restored(&s));
        assert_eq!(store.inbox_scans(), vec![0], "no point yet: the whole log is read");
        if store.keeps {
            let point = hub.read_inbox_point(&s).expect("a restore saves an inbox point");
            point_seq = point.seq;
            assert_eq!(point_seq, s.seq.load(Ordering::SeqCst));
            // The log holds 1813 inbox records; a held message carries at most four (its
            // message, notice, answer and read), and only the KEEP held ones are carried.
            let carried = |kind: &str| point.records.iter().filter(|r| r.kind == kind).count();
            assert_eq!(carried("inbox"), KEEP, "only the held messages are carried");
            assert!(point.records.len() <= 4 * KEEP, "only the held messages' records are carried");
        }
        after(&hub, &s);
        hub.save_meta(&s);
    }
    assert_eq!(first[0], first[1]);
    assert_eq!(first[0]["items"].as_array().unwrap().len(), KEEP);

    let mut second = Vec::new();
    for store in [&pointed, &whole] {
        let (hub, s) = store.start();
        hub.load_session_log(&s);
        second.push(restored(&s));
        let scans = store.inbox_scans();
        if store.keeps {
            assert_eq!(scans, vec![point_seq], "the next restore reads past the point only");
        } else {
            assert_eq!(scans, vec![0]);
        }
        drop(hub);
    }
    assert_eq!(second[0], second[1], "the point's inbox is the whole log's");
    let ids: Vec<&str> =
        second[0]["items"].as_array().unwrap().iter().filter_map(|i| i["id"].as_str()).collect();
    assert!(ids.contains(&"m619") && !ids.contains(&"m500") && !ids.contains(&"m401"));
    assert!(!ids.contains(&"m5"), "a resend of a trimmed message stays out");
}

/// A point whose record is not the log's (an import replaced the log) is not read.
#[test]
fn a_point_that_names_another_record_is_not_read() {
    let store = PointStore::new(true);
    let (hub, s) = store.start();
    history(&hub, &s);
    hub.save_meta(&s);
    let (hub, s) = store.start();
    hub.load_session_log(&s);
    let mut point = hub.read_inbox_point(&s).unwrap();
    point.at += 1;
    store.points.lock().unwrap().insert(ID.into(), serde_json::to_vec(&point).unwrap());
    assert!(hub.read_inbox_point(&s).is_none());
}
