use super::*;
use serde_json::json;

fn meta(id: &str, updated: u64) -> crate::store::SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
        "cwd": "/tmp", "status": "closed", "createdAt": 1, "updatedAt": updated
    }))
    .unwrap()
}

/// Every session sorted now, as a list of every chat sorts them: what the kept order must be.
fn sorted_now(hub: &Hub) -> Vec<String> {
    let mut rows: Vec<(u64, String)> = hub
        .session_handles()
        .iter()
        .map(|s| (s.read_meta(|m| m.updated_at), s.id.clone()))
        .collect();
    rows.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    rows.into_iter().map(|(_, id)| id).collect()
}

/// The ids of every page of `limit` rows, following each page's cursor.
fn paged(hub: &Hub, limit: u64) -> Vec<String> {
    let (mut ids, mut cursor) = (Vec::new(), Value::Null);
    loop {
        let params = json!({"limit": limit, "cursor": cursor});
        let (rows, next) = hub.session_page_rows(&params, false).unwrap();
        ids.extend(
            rows.iter().map(|r| super::super::session_pages::PageRow::session_id(r).to_owned()),
        );
        cursor = next.unwrap_or(Value::Null);
        if cursor.is_null() {
            return ids;
        }
    }
}

fn check(hub: &Hub, change: &str) {
    let want = sorted_now(hub);
    assert_eq!(hub.kept_order_for_test(), want, "the kept order after {change}");
    for limit in [1, 2, 5] {
        assert_eq!(paged(hub, limit), want, "pages of {limit} after {change}");
    }
}

#[tokio::test]
async fn the_kept_order_is_every_chat_sorted_after_every_kind_of_change() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let mut sessions = Vec::new();
    for n in 0..6 {
        let meta = meta(&format!("s{n}"), 10 + n);
        hub.store.save(&meta).unwrap();
        sessions.push(hub.insert_test_session(meta));
    }
    let s = |n: usize| sessions.get(n).cloned().unwrap();
    let (s0, s1, s2, s3) = (&s(0), &s(1), &s(2), &s(3));
    check(&hub, "the first read");

    hub.append(s0, "mux", "status", json!({"status": "closed"}));
    check(&hub, "a record, which dates its chat");
    hub.set_composer_draft(s1, "a draft").unwrap();
    check(&hub, "a draft, which dates its chat with no record");
    hub.edit_test_meta(s2, |m| m.updated_at = 1);
    check(&hub, "a direct metadata write");
    // Two rows alike in `updatedAt`: ties by id.
    hub.edit_test_meta(s3, |m| m.updated_at = 1);
    check(&hub, "a tie");
    let late = meta("late", 5);
    hub.store.save(&late).unwrap();
    hub.insert_test_session(late);
    check(&hub, "a session that came");
    // Put in place and taken out with no list position: the count the order does not match
    // sorts every chat again.
    let quiet = hub.make_session(meta("quiet", 99));
    hub.sessions.lock().unwrap().insert("quiet".into(), quiet);
    check(&hub, "a session put in place with no position");
    hub.sessions.lock().unwrap().remove("s4");
    check(&hub, "a session taken out with no position");
    hub.edit_test_meta(s0, |m| m.updated_at = 1_000);
    hub.events.changed(None);
    check(&hub, "a barrier");
}

#[tokio::test]
async fn a_first_page_reads_its_window_not_every_chat() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    for n in 0..500 {
        let meta = meta(&format!("c{n:03}"), 10 + n);
        hub.store.save(&meta).unwrap();
        hub.insert_test_session(meta);
    }
    // The first read sorts every chat once; a change after it places its own row again.
    let _ = hub.session_page_rows(&json!({"limit": 20}), false).unwrap();
    hub.edit_test_meta(&hub.session_by_id("c007").unwrap(), |m| m.updated_at = 9_999);
    let (own, all) = hub.own_rows_from(None, 20 + super::super::page_first::WINDOW_ROOM);
    assert!(!all, "a window of the order, not all of it");
    assert_eq!(own.len(), 20 + super::super::page_first::WINDOW_ROOM);
    assert_eq!(own.first().map(|(s, _)| s.id.as_str()), Some("c007"));
    let (rows, next) = hub.session_page_rows(&json!({"limit": 20}), false).unwrap();
    assert_eq!(rows.len(), 20);
    assert!(next.is_some_and(|next| next.is_string()));
}

/// Many sessions of one `updatedAt` (#42131 review, F1): a page's cursor row may lie past the
/// window a page first reads, and the pages still give every session once, in order.
#[tokio::test]
async fn pages_through_many_rows_of_one_updated_at_give_each_once() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    for n in 0..200 {
        let meta = meta(&format!("t{n:03}"), 7);
        hub.store.save(&meta).unwrap();
        hub.insert_test_session(meta);
    }
    let ids = paged(&hub, 50);
    let want: Vec<String> = (0..200).map(|n| format!("t{n:03}")).collect();
    assert_eq!(ids, want, "every session once, ties by id");
}

/// Decision 292's follow-up: the order a daemon's start task sorts before any log is read
/// (`daemon.rs`, `Hub::sort_list_order`) equals a sort of every chat once the logs are read,
/// with no second sort. In the fixture a log's tail moves its chat's `updatedAt`: `cut` was saved
/// long ago in the middle of a turn, and its load ends that turn now (`turn_result
/// outcome_unknown`), which puts it first; `tail` holds records past its saved metadata (a hard
/// stop). Any write of `updatedAt` on the load path that takes no list position fails here.
#[test]
fn an_order_sorted_before_the_logs_are_read_is_every_chat_sorted_after_them() {
    use crate::store::{EventRecord, LocalStore, Store};
    let root = tempfile::tempdir().unwrap();
    let sessions = root.path().join("sessions");
    let record = |seq: u64, at: u64, dir: &str, kind: &str, msg: Value| EventRecord {
        seq,
        at,
        dir: dir.into(),
        kind: kind.into(),
        msg,
        host_seq: None,
    };
    let saved = |id: &str, status: &str, updated: u64, last_seq: u64| {
        let mut meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "fake",
            "cwd": "/tmp", "status": status, "createdAt": 1, "updatedAt": updated,
        }))
        .unwrap();
        meta.last_seq = last_seq;
        meta.event_count = last_seq;
        meta
    };
    {
        let writer = LocalStore::new(sessions.clone(), 8 << 20).unwrap();
        let prompt = json!({"text": "go on", "promptId": "p1", "turnId": "t1"});
        writer.append("cut", &record(1, 10, "mux", "user_message", prompt)).unwrap();
        let started = json!({"promptId": "p1", "turnId": "t1"});
        writer.append("cut", &record(2, 11, "mux", "turn_started", started)).unwrap();
        writer.save(&saved("cut", "idle", 11, 2)).unwrap();
        for seq in 1..=3 {
            let msg = json!({"status": "idle"});
            writer.append("tail", &record(seq, 500 + seq, "mux", "status", msg)).unwrap();
        }
        writer.save(&saved("tail", "idle", 501, 1)).unwrap();
        for n in 0..5_u64 {
            let id = format!("closed-{n}");
            writer
                .append(&id, &record(1, 100 + n, "mux", "status", json!({"status": "closed"})))
                .unwrap();
            writer.save(&saved(&id, "closed", 100 + n * 100, 1)).unwrap();
        }
        writer.flush().unwrap();
    }
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let hub = Hub::new_deferred(
        cfg,
        Box::new(LocalStore::new(sessions, 8 << 20).unwrap()),
        crate::mailbox::Mailbox::memory(),
    );
    hub.unsort_list_order_for_test();
    hub.sort_list_order();
    assert_eq!(hub.list_order_rebuilds_for_test(), 1, "sorted before any log is read");
    let before = hub.kept_order_for_test();
    assert_eq!(before.last().map(String::as_str), Some("cut"), "saved oldest: {before:?}");

    hub.load_logs();
    let cut = hub.session_by_id("cut").unwrap();
    assert!(cut.read_meta(|m| m.updated_at) > 11, "the load ended its cut turn now");
    assert_eq!(hub.kept_order_for_test(), sorted_now(&hub), "the kept order after the load");
    assert_eq!(hub.kept_order_for_test().first().map(String::as_str), Some("cut"));
    assert_eq!(hub.list_order_rebuilds_for_test(), 1, "patched, never sorted again");
}
