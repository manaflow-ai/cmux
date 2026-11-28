//! Done chats archived, cold and offloaded on a setting (`hub/session_lifecycle.rs`).

use super::*;
use crate::config::{Config, StoreMode};
use crate::store::MemoryStore;

const HOUR: u64 = 3_600_000;
const IDLE: std::time::Duration = std::time::Duration::from_secs(24 * 3600);

struct Root(PathBuf);

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn memory_hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = StoreMode::Memory;
    Hub::new(cfg, Box::new(MemoryStore::default()))
}

/// An agent-made chat named `id`, its last turn ended at `ended`, with `extra` fields merged in.
fn meta(id: &str, status: &str, ended: u64, extra: Value) -> SessionMeta {
    let mut v = json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
        "cwd": "/tmp", "status": status, "createdAt": 1, "updatedAt": now_ms(),
        "lastTurn": {"endedAt": ended}, "createdBy": {"kind": "agent", "session": "parent"},
    });
    for (k, x) in extra.as_object().cloned().unwrap_or_default() {
        v[k] = x;
    }
    serde_json::from_value(v).unwrap()
}

fn tags(pairs: &[(&str, &str)]) -> Value {
    Value::Object(pairs.iter().map(|(k, v)| ((*k).to_owned(), json!({"value": v}))).collect())
}

#[test]
fn the_setting_is_off_by_default_and_reads_hours() {
    assert_eq!(idle_after(&json!({})), None);
    assert_eq!(idle_after(&json!({"agents": {"chats": {"lifecycle": false}}})), None);
    let hours = |h: u64| Some(std::time::Duration::from_secs(h * 3600));
    assert_eq!(idle_after(&json!({"agents": {"chats": {"lifecycle": true}}})), hours(24));
    assert_eq!(
        idle_after(&json!({"agents": {"chats": {"lifecycle": true, "lifecycleIdleHours": 6}}})),
        hours(6)
    );
    assert_eq!(
        idle_after(&json!({"agents": {"chats": {"lifecycle": true, "lifecycleIdleHours": "48h"}}})),
        hours(48)
    );
    assert_eq!(
        idle_after(&json!({"agents": {"chats": {"lifecycle": true, "lifecycleIdleHours": 0}}})),
        hours(24)
    );
}

#[test]
fn idle_counts_from_the_last_turn_never_from_updated_at() {
    let m = meta("a", "idle", 5 * HOUR, json!({}));
    assert_eq!(last_active(&m), 5 * HOUR);
    let mut m = meta("b", "idle", 0, json!({"createdAt": 7}));
    m.last_turn = None;
    assert_eq!(last_active(&m), 7, "createdAt, not updatedAt");
}

#[test]
fn a_pull_request_is_open_until_closed_or_past_the_window() {
    let now = 30 * 24 * HOUR;
    let url = "https://github.com/o/r/pull/1";
    let m = meta(
        "pr",
        "idle",
        0,
        json!({"pullRequests": [url], "pullRequestTimes": {url: now - HOUR}}),
    );
    assert!(open_pull_request(&m, now, &|_| false));
    assert!(!open_pull_request(&m, now, &|u| u == url), "another chat's gh closed it");
    let mut closed = m.clone();
    closed.closed_pull_requests = vec![url.into()];
    assert!(!open_pull_request(&closed, now, &|_| false));
    assert!(!open_pull_request(&m, now + super::super::review_queue::PR_WINDOW_MS, &|_| false));
}

#[tokio::test]
async fn the_done_rule_takes_closed_and_idle_chats_and_keeps_the_rest() {
    let hub = memory_hub();
    let now = 100 * HOUR;
    let old = now - 30 * HOUR;
    let none = HashSet::new();
    let done =
        |s: &Session, leaders: &HashSet<String>| hub.lifecycle_done(s, IDLE, now, leaders, &none);
    let closed = hub.insert_test_session(meta("closed", "closed", now - HOUR, json!({})));
    assert_eq!(done(&closed, &none).as_deref(), Ok("closed"));
    let idle = hub.insert_test_session(meta("idle", "idle", old, json!({})));
    assert_eq!(done(&idle, &none).as_deref(), Ok("idle-24h"));
    let recent = hub.insert_test_session(meta("recent", "idle", now - HOUR, json!({})));
    assert_eq!(done(&recent, &none), Err("recent"));
    let running = hub.insert_test_session(meta("running", "running", old, json!({})));
    assert_eq!(done(&running, &none), Err("working"));
    let person = hub.insert_test_session(meta(
        "person",
        "closed",
        old,
        json!({"createdBy": {"kind": "person"}}),
    ));
    assert_eq!(done(&person, &none), Err("person"));
    let forked = hub.insert_test_session(meta("forked", "closed", old, json!({"createdBy": null})));
    assert_eq!(done(&forked, &none), Err("no-creator"));
    let coord = hub.insert_test_session(meta("interim-coord", "idle", old, json!({})));
    assert_eq!(done(&coord, &none), Err("coordinator"));
    let leader = hub.insert_test_session(meta("lead", "idle", old, json!({})));
    let leaders: HashSet<String> = ["lead".to_owned()].into();
    assert_eq!(done(&leader, &leaders), Err("coordinator"));
    for (id, pairs) in [
        ("pinned", vec![("pinned", "1")]),
        ("side", vec![("side", "closed")]),
        ("aside", vec![("aside", "1")]),
    ] {
        let s = hub.insert_test_session(meta(id, "closed", old, json!({"tags": tags(&pairs)})));
        assert_eq!(done(&s, &none), Err("kept"), "{id}");
    }
    for (id, pairs) in [
        ("hold", vec![(super::super::session_hold::TAG, "on")]),
        ("paused", vec![("fleet-pause.held", "1")]),
    ] {
        let s = hub.insert_test_session(meta(id, "closed", old, json!({"tags": tags(&pairs)})));
        assert_eq!(done(&s, &none), Err("held"), "{id}");
    }
    let goal = hub.insert_test_session(meta(
        "goal",
        "idle",
        old,
        json!({"goal": {"objective": "ship", "status": "running"}}),
    ));
    assert_eq!(done(&goal, &none), Err("goal"));
    let goal_done = hub.insert_test_session(meta(
        "goal-done",
        "idle",
        old,
        json!({"goal": {"objective": "ship", "status": "complete"}}),
    ));
    assert_eq!(done(&goal_done, &none).as_deref(), Ok("idle-24h"));
    let url = "https://github.com/o/r/pull/2";
    let pr = hub.insert_test_session(meta(
        "pr",
        "closed",
        old,
        json!({"pullRequests": [url], "pullRequestTimes": {url: now - HOUR}}),
    ));
    assert_eq!(done(&pr, &none), Err("pr"));
    let hosted: HashSet<String> = ["idle".to_owned()].into();
    assert_eq!(hub.lifecycle_done(&idle, IDLE, now, &none, &hosted), Err("agent"));
    hub.shutdown_all().await;
}

fn stored_chat(store: &dyn crate::store::Store, id: &str, ended: u64, status: &str) {
    let m = meta(id, status, ended, json!({"lastSeq": 1, "eventCount": 1}));
    store.save(&m).unwrap();
    let record = EventRecord {
        seq: 1,
        at: ended,
        dir: "mux".into(),
        kind: "user_message".into(),
        msg: json!({"text": "the flaky test question"}),
        host_seq: None,
    };
    store.append(id, &record).unwrap();
    store.close_log(id);
}

#[tokio::test]
async fn a_pass_without_cloud_archives_and_colds_logs_and_deletes_nothing() {
    let root =
        Root(std::env::temp_dir().join(format!("acpmux-lifecycle-{}", uuid::Uuid::now_v7())));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let now = now_ms();
    {
        let store = crate::store::open(&cfg.store, &root.0).unwrap();
        stored_chat(&*store, "done-idle", now - 48 * HOUR, "idle");
        stored_chat(&*store, "done-closed", now - HOUR, "closed");
        stored_chat(&*store, "fresh", now - HOUR, "idle");
        store.flush().unwrap();
    }
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root.0).unwrap());
    // One already cold from `coldArchive`, as most of the fleet's idle chats are.
    let pre = hub.resolve("done-idle").unwrap();
    hub.cold_archive_request(pre, true).await.unwrap();

    let dry = tokio::task::spawn_blocking({
        let hub = hub.clone();
        move || hub.lifecycle_pass(IDLE, true, None)
    })
    .await
    .unwrap();
    assert_eq!(dry["archived"], 2, "{dry}");
    assert_eq!(dry["skipped"]["recent"], 1, "{dry}");
    assert_eq!(dry["cloud"], false, "{dry}");
    let fresh = hub.resolve("fresh").unwrap();
    assert!(tag(&fresh, ARCHIVED).is_none());

    let log = root.0.join(LOG);
    let report = tokio::task::spawn_blocking({
        let hub = hub.clone();
        let log = log.clone();
        move || hub.lifecycle_pass(IDLE, false, Some(&log))
    })
    .await
    .unwrap();
    assert_eq!(report["archived"], 2, "{report}");
    assert_eq!(report["offloaded"], 0, "{report}");
    assert!(report["bytesBefore"].as_u64().unwrap() > 0, "{report}");
    for id in ["done-idle", "done-closed"] {
        let s = hub.resolve(id).unwrap();
        assert!(tag(&s, ARCHIVED).is_some(), "{id}");
        assert_eq!(tag(&s, ARCHIVED_BY).as_deref(), Some(ARCHIVED_BY_LIFECYCLE), "{id}");
        assert!(hub.store.is_cold(id), "{id} stays cold, here");
        assert!(!hub.store.offloaded(id), "{id}: nothing leaves without cloud history");
    }
    let lines: Vec<Value> = std::fs::read_to_string(&log)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(lines.len(), 2);
    for line in &lines {
        assert_eq!(line["offloaded"], false);
        for key in ["id", "name", "reason", "bytesBefore", "bytesAfter", "at"] {
            assert!(line.get(key).is_some(), "{key} in {line}");
        }
    }
    // A second pass finds them done already and takes nothing again.
    let again = tokio::task::spawn_blocking({
        let hub = hub.clone();
        move || hub.lifecycle_pass(IDLE, false, Some(&log))
    })
    .await
    .unwrap();
    assert_eq!(again["archived"], 0, "{again}");
    assert_eq!(again["skipped"]["done"], 2, "{again}");

    // Restore: back in the lists and its log back on the disk.
    let back = hub.resolve("done-idle").unwrap();
    let restored = hub.lifecycle_restore(back.clone()).await.unwrap();
    assert_eq!(restored["unarchived"], true, "{restored}");
    assert_eq!(restored["rehydrated"], true, "{restored}");
    assert!(tag(&back, ARCHIVED).is_none());
    assert!(!hub.store.is_cold("done-idle"));
    hub.shutdown_all().await;
}

const ARCHIVED: &str = super::super::inactive_archive::ARCHIVED_TAG;
const ARCHIVED_BY: &str = super::super::inactive_archive::ARCHIVED_BY_TAG;

fn tag(session: &Session, key: &str) -> Option<String> {
    session.read_meta(|m| m.tags.get(key).map(|t| t.value.clone()))
}
