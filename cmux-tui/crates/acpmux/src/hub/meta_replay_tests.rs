//! The log rebuilds a session's settings (`cargo test -p acpmux meta_replay`).

use serde_json::json;

use crate::store::Store as _;

use super::*;

fn meta() -> SessionMeta {
    serde_json::from_value(json!({
        "schema": "acpmux.session.v1", "id": "s", "name": "old", "harness": "claude",
        "family": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
    }))
    .unwrap()
}

fn rec(seq: u64, kind: &str, msg: serde_json::Value) -> EventRecord {
    EventRecord { seq, at: seq, dir: "mux".into(), kind: kind.into(), msg, host_seq: None }
}

#[test]
fn meta_replay_rebuilds_the_settings_in_log_order() {
    let mut m = meta();
    // The title first: a rename of an untitled chat names it, and a name keeps its title
    // (`meta_replay_a_generated_title_keeps_a_harness_title_and_a_name`).
    for r in [
        rec(1, "titled", json!({"title": "A title"})),
        rec(2, "renamed", json!({"from": "old", "to": "first"})),
        rec(3, "renamed", json!({"from": "first", "to": "second"})),
        rec(4, "tags", json!({"tags": {"lane": "fast", "k": "v"}, "expires": {"k": 99}})),
        rec(5, "policy", json!({"policy": "deny-all"})),
        rec(6, "rules", json!({"rules": {"autoApprove": ["execute"]}})),
    ] {
        apply(&mut m, &r);
    }
    assert_eq!(m.name, "second");
    assert_eq!(m.tags["lane"], Tag { value: "fast".into(), expires_at: None });
    assert_eq!(m.tags["k"].expires_at, Some(99));
    assert_eq!(m.permission_policy.as_deref(), Some("deny-all"));
    assert_eq!(m.permission_rules, Some(json!({"autoApprove": ["execute"]})));
    assert_eq!(m.title.as_deref(), Some("A title"));
    // Cleared rules come back cleared.
    apply(&mut m, &rec(7, "rules", json!({"rules": null})));
    assert_eq!(m.permission_rules, None);
}

#[test]
fn meta_replay_a_record_the_saved_record_holds_changes_nothing() {
    let mut m = meta();
    let tags = rec(1, "tags", json!({"tags": {"lane": "fast"}, "expires": {}}));
    apply(&mut m, &tags);
    assert_eq!(m.tags["lane"].value, "fast");
    let once = m.clone();
    apply(&mut m, &tags);
    assert_eq!(m, once);
}

/// A `tags` record from before the records carried each tag's expiry is skipped: rebuilt from
/// it, a tag that expires (a trust wait's) would last forever.
#[test]
fn meta_replay_skips_a_tags_record_without_expiry() {
    let mut m = meta();
    m.tags.insert("trust".into(), Tag { value: "wait".into(), expires_at: Some(50) });
    let saved = m.clone();
    apply(&mut m, &rec(1, "tags", json!({"tags": {"trust": "wait", "lane": "fast"}})));
    assert_eq!(m, saved, "an old tags record rebuilt the tags without their expiry");
}

/// A logged generated title does not replace a harness title or the person's name, as the live
/// answer does not (`titles.rs` `apply_generated_title`).
#[test]
fn meta_replay_a_generated_title_keeps_a_harness_title_and_a_name() {
    for kept in [super::super::titles::HARNESS, super::super::titles::NAMED] {
        let mut m = meta();
        m.title = Some("kept".into());
        m.title_source = Some(kept.into());
        apply(&mut m, &rec(1, "titled", json!({"title": "generated"})));
        assert_eq!(m.title.as_deref(), Some("kept"), "{kept}");
        assert_eq!(m.title_source.as_deref(), Some(kept));
    }
    // A title from the first prompt gives way.
    let mut m = meta();
    m.title = Some("the prompt".into());
    m.title_source = Some("prompt".into());
    apply(&mut m, &rec(1, "titled", json!({"title": "generated"})));
    assert_eq!(m.title.as_deref(), Some("generated"));
}

#[test]
fn meta_replay_the_read_mark_follows_its_status_records() {
    let mut m = meta();
    apply(&mut m, &rec(1, "status", json!({"status": "idle", "read": false})));
    assert!(m.unread);
    // A turn's status record (no `read`) leaves the mark.
    apply(&mut m, &rec(2, "status", json!({"status": "running"})));
    assert!(m.unread);
    apply(&mut m, &rec(3, "status", json!({"status": "idle", "read": true})));
    assert!(!m.unread);
}

/// A hub on the memory store with one session `s` in it, as a restart loads it: not caught up
/// (its log not read yet) when `loading`.
fn hub_with_session(loading: bool) -> (std::sync::Arc<Hub>, std::sync::Arc<Session>) {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub.make_session(meta());
    session.caught_up.store(!loading, std::sync::atomic::Ordering::SeqCst);
    hub.sessions.lock().unwrap().insert("s".to_owned(), session.clone());
    (hub, session)
}

/// The lead's check of 982b5b26222's fast path: showing a read chat whose log is not read yet
/// still takes the slow path. The replay there brings back the unread mark the log holds, and
/// showing the chat must clear it (with its `read: true` record), not keep it.
#[test]
fn meta_replay_showing_a_chat_before_its_log_is_read_clears_a_replayed_unread_mark() {
    let (hub, session) = hub_with_session(true);
    // The log holds an unread mark the saved record (read, lastSeq 0) is behind on.
    let unread = rec(1, "status", json!({"status": "idle", "read": false}));
    hub.store.append("s", &unread).unwrap();
    hub.attach_count(&session, 1, true);
    assert!(session.caught_up.load(std::sync::atomic::Ordering::SeqCst), "not caught up");
    assert!(!session.meta.lock().unwrap().unread, "showing the chat left the replayed mark");
    let events = hub.store.events("s", 1, usize::MAX).unwrap();
    assert!(
        events.iter().any(|e| e.kind == "status" && e.msg["read"] == json!(true)),
        "no read mark was logged: {events:?}"
    );
}

/// And once caught up, showing a read chat logs nothing (the chat switch path).
#[test]
fn meta_replay_showing_a_read_chat_once_caught_up_logs_nothing() {
    let (hub, session) = hub_with_session(false);
    let before = session.seq.load(std::sync::atomic::Ordering::SeqCst);
    hub.attach_count(&session, 1, true);
    assert_eq!(
        session.seq.load(std::sync::atomic::Ordering::SeqCst),
        before,
        "a record was logged"
    );
}

/// A memory store whose `tail_after` (the catch-up's read of the log) records, from inside the
/// read, whether the session already counts as caught up: what the read-chat fast path in
/// `seen.rs` reads without the append lock at that moment.
struct ProbedTail {
    inner: crate::store::MemoryStore,
    session: std::sync::Arc<std::sync::Mutex<Option<std::sync::Arc<Session>>>>,
    caught_up_during_read: std::sync::Arc<std::sync::Mutex<Option<bool>>>,
}

impl crate::store::Store for ProbedTail {
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
    fn tail_after(
        &self,
        id: &str,
        after: u64,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord),
    ) -> anyhow::Result<(u64, u64)> {
        if let Some(session) = self.session.lock().unwrap().as_ref() {
            let caught_up = session.caught_up.load(std::sync::atomic::Ordering::SeqCst);
            self.caught_up_during_read.lock().unwrap().get_or_insert(caught_up);
        }
        self.inner.tail_after(id, after, kinds, visit)
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.inner.delete(id)
    }
}

/// Focused review of 982b5b26222: the read-chat fast path reads `caught_up` without the append
/// lock, so a session must not count as caught up while its catch-up still reads the log (the
/// replay is still to come). Checked from inside the read, with no second thread and no timing;
/// then showing the chat clears the replayed unread mark.
#[test]
fn meta_replay_a_session_is_not_caught_up_while_its_log_is_read() {
    let probe = std::sync::Arc::new(std::sync::Mutex::new(None));
    let observed = std::sync::Arc::new(std::sync::Mutex::new(None));
    let store = ProbedTail {
        inner: crate::store::MemoryStore::default(),
        session: probe.clone(),
        caught_up_during_read: observed.clone(),
    };
    store.append("s", &rec(1, "status", json!({"status": "idle", "read": false}))).unwrap();
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(store));
    let session = hub.make_session(meta());
    session.caught_up.store(false, std::sync::atomic::Ordering::SeqCst);
    hub.sessions.lock().unwrap().insert("s".to_owned(), session.clone());
    *probe.lock().unwrap() = Some(session.clone());
    hub.catch_up(&session);
    assert_eq!(
        *observed.lock().unwrap(),
        Some(false),
        "the session counted as caught up while its log was still read"
    );
    assert!(session.meta.lock().unwrap().unread, "the replay did not bring back the mark");
    hub.attach_count(&session, 1, true);
    assert!(!session.meta.lock().unwrap().unread, "showing the chat left it unread");
    // The probe holds the session; the hub holds the store: let the cycle go.
    probe.lock().unwrap().take();
}
