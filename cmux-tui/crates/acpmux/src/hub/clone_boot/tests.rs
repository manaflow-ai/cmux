use super::*;
use crate::config::{Config, StoreMode};

fn temp(tag: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("acpmux-clone-boot-{tag}-{}", uuid::Uuid::now_v7()))
}

/// A store at `root` holding chat `c1`, whose log shows a turn the daemon left open and a
/// prompt queued behind it (what a capture taken mid-turn carries).
fn cut_chat(root: &std::path::Path) -> Config {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    cfg.auto_resume_delays_ms = Some(vec![10_000]);
    let store = crate::store::open(&cfg.store, root).unwrap();
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": "c1", "name": "c1", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let hub = Hub::new(cfg.clone(), store);
    let session = hub.resolve("c1").unwrap();
    hub.append(&session, "in", "turn_started", json!({"turnId": "t1", "promptId": "p1"}));
    hub.append(&session, "in", "user_message", json!({"turnId": "t1", "text": "do the thing"}));
    hub.append(
        &session,
        "mux",
        "queued",
        json!({"text": "next", "client": "acpmux",
            "position": 1, "promptId": "p2", "turnId": "t2", "control": "local",
            "prompt": [{"type": "text", "text": "next"}]}),
    );
    // The capturing daemon's shutdown seal: the journal's lock passes to the next open.
    hub.seal();
    cfg
}

/// The chat's log after a daemon on `root` read it, as a copy's first start (`from`) or not.
async fn load(
    root: &std::path::Path,
    cfg: &Config,
    from: Option<&str>,
) -> (Vec<EventRecord>, Vec<String>) {
    let hub = Hub::new_deferred(
        cfg.clone(),
        crate::store::open(&cfg.store, root).unwrap(),
        crate::mailbox::Mailbox::memory(),
    );
    if let Some(from) = from {
        hub.set_clone_boot(from.to_owned());
    }
    let session = hub.resolve("c1").unwrap();
    hub.load_session_log(&session);
    let queue = session.queue().into_iter().map(|q| q.prompt_id).collect();
    let events = hub.events("c1", 0, 10_000).unwrap();
    hub.shutdown_all().await;
    (events, queue)
}

#[tokio::test]
async fn a_copy_stops_the_open_turn_and_drops_the_queue() {
    let root = temp("copy");
    let cfg = cut_chat(&root);
    let (events, queue) = load(&root, &cfg, Some("vm_first")).await;
    assert!(queue.is_empty(), "a copy ran a queued prompt: {queue:?}");
    let results: Vec<&Value> =
        events.iter().filter(|e| e.kind == "turn_result").map(|e| &e.msg).collect();
    assert_eq!(results.len(), 1, "{results:?}");
    assert_eq!(
        (
            &results[0]["status"],
            &results[0]["detail"],
            &results[0]["cloneOf"],
            &results[0]["turnId"]
        ),
        (&json!("cancelled"), &json!("clone_boot"), &json!("vm_first"), &json!("t1")),
    );
    // No continuation of the cut turn was queued: the only `queued` is the one it carried.
    let queued: Vec<&Value> =
        events.iter().filter(|e| e.kind == "queued").map(|e| &e.msg["promptId"]).collect();
    assert_eq!(queued, [&json!("p2")], "{events:?}");
    let removed: Vec<&Value> =
        events.iter().filter(|e| e.kind == "queue_removed").map(|e| &e.msg).collect();
    assert_eq!(removed.len(), 1, "{removed:?}");
    assert_eq!(
        (&removed[0]["promptId"], &removed[0]["reason"]),
        (&json!("p2"), &json!("clone_boot"))
    );

    // A later start of the copy (no marker) finds nothing open and nothing to run.
    let (again, queue) = load(&root, &cfg, None).await;
    assert!(queue.is_empty(), "{queue:?}");
    assert_eq!(again.len(), events.len(), "a later start changed the settled log");
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn an_ordinary_restart_still_continues_the_cut_turn() {
    let root = temp("restart");
    let cfg = cut_chat(&root);
    let (events, queue) = load(&root, &cfg, None).await;
    assert!(queue.len() == 2 && queue[1] == "p2", "{queue:?}");
    assert!(queue[0].starts_with("p1"), "the continuation runs first: {queue:?}");
    assert!(events.iter().all(|e| e.msg["detail"] != "clone_boot"), "{events:?}");
    let _ = std::fs::remove_dir_all(&root);
}

/// A store at `root` holding chat `c1`, whose log `write` fills.
fn chat_with(root: &std::path::Path, write: impl Fn(&Hub, &Arc<Session>)) -> Config {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    cfg.auto_resume_delays_ms = Some(vec![60_000]);
    let store = crate::store::open(&cfg.store, root).unwrap();
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": "c1", "name": "c1", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let hub = Hub::new(cfg.clone(), store);
    let session = hub.resolve("c1").unwrap();
    write(&hub, &session);
    // The capturing daemon's shutdown seal: the journal's lock passes to the next open.
    hub.seal();
    cfg
}

/// A daemon on `root` reads `c1`'s log and resumes what it restored, as a copy's first start
/// (`from`) or not: the log after, and what its agent pairs hold for `c1` (held messages,
/// restored resumes to run).
async fn start(
    root: &std::path::Path,
    cfg: &Config,
    from: Option<&str>,
) -> (Vec<EventRecord>, (usize, usize)) {
    let hub = Hub::new_deferred(
        cfg.clone(),
        crate::store::open(&cfg.store, root).unwrap(),
        crate::mailbox::Mailbox::memory(),
    );
    if let Some(from) = from {
        hub.set_clone_boot(from.to_owned());
    }
    let session = hub.resolve("c1").unwrap();
    hub.load_session_log(&session);
    hub.resume_restored_as(std::slice::from_ref(&session), true);
    let holds = hub.pair_holds_for("c1");
    let events = hub.events("c1", 0, 10_000).unwrap();
    hub.shutdown_all().await;
    (events, holds)
}

/// The capture holds a turn that failed on a dropped connection and the retry it scheduled.
fn failed_with_retry(hub: &Hub, session: &Arc<Session>) {
    hub.append(
        session,
        "mux",
        "turn_started",
        json!({
            "turnId": "t1", "promptId": "p1", "control": "local", "trustGate": false
        }),
    );
    hub.append_unknown_outcome(
        session,
        json!({
            "turnId": "t1", "promptId": "p1", "status": "failed", "errorText": "stream disconnected"
        }),
    );
    hub.append(
        session,
        "mux",
        "auto_resume_scheduled",
        json!({
            "turnId": "t1", "promptId": "p1", "attempt": 1, "of": 1, "reason": "transport",
            "nextAt": crate::hub::now_ms() + 600_000
        }),
    );
}

fn kinds<'a>(events: &'a [EventRecord], kind: &str) -> Vec<&'a Value> {
    events.iter().filter(|e| e.kind == kind).map(|e| &e.msg).collect()
}

#[tokio::test]
async fn a_copy_settles_the_inherited_retry_wait_for_good() {
    // An ordinary restart restores the wait (the fixture is one a restart retries).
    let root = temp("retry-control");
    let cfg = chat_with(&root, failed_with_retry);
    let (events, _) = start(&root, &cfg, None).await;
    assert_eq!(kinds(&events, "auto_resume_restored").len(), 1, "{events:?}");
    let _ = std::fs::remove_dir_all(&root);

    // A copy's first start skips it, durably.
    let root = temp("retry");
    let cfg = chat_with(&root, failed_with_retry);
    let (events, _) = start(&root, &cfg, Some("vm_first")).await;
    assert!(kinds(&events, "auto_resume_restored").is_empty(), "{events:?}");
    let skipped = kinds(&events, "auto_resume_skipped");
    assert_eq!(skipped.len(), 1, "{events:?}");
    assert_eq!(
        (&skipped[0]["turnId"], &skipped[0]["skipped"], &skipped[0]["cloneOf"]),
        (&json!("t1"), &json!("clone_boot"), &json!("vm_first"))
    );

    // The copy's next, ordinary restart restores nothing and writes nothing new.
    let (again, _) = start(&root, &cfg, None).await;
    assert!(kinds(&again, "auto_resume_restored").is_empty(), "{again:?}");
    assert_eq!(again.len(), events.len(), "a later start changed the settled log");
    let _ = std::fs::remove_dir_all(&root);
}

/// The capture holds a pair with `a` paused, a message from `a` held for `c1`, and the
/// person's resume that was delivering it when the first machine's daemon stopped.
fn paused_pair(hub: &Hub, session: &Arc<Session>) {
    hub.append(session, "mux", "agent_pair_paused", json!({"peer": "a", "reason": "alternating"}));
    hub.append(
        session,
        "mux",
        "agent_pair_held",
        json!({
            "from": "a", "to": "c1", "promptId": "h1", "client": "acpmux", "order": 1,
            "prompt": [{"type": "text", "text": "over to you"}],
            "provenance": {"kind": "subsession_message", "from": "a", "to": "c1"},
        }),
    );
    hub.append(session, "mux", "agent_pair_resumed", json!({"peer": "a", "by": "request"}));
}

#[tokio::test]
async fn a_copy_drops_what_its_agent_pairs_held_for_good() {
    // An ordinary restart holds the message and drains the resumed pair.
    let root = temp("pair-control");
    let cfg = chat_with(&root, paused_pair);
    let (_, holds) = start(&root, &cfg, None).await;
    assert_eq!(holds, (1, 1));
    let _ = std::fs::remove_dir_all(&root);

    // A copy's first start drops it, in the log, and leaves nothing to deliver.
    let root = temp("pair");
    let cfg = chat_with(&root, paused_pair);
    let (events, holds) = start(&root, &cfg, Some("vm_first")).await;
    assert_eq!(holds, (0, 0), "a copy would deliver the first machine's message");
    let dropped = kinds(&events, "agent_pair_dropped");
    assert_eq!(dropped.len(), 1, "{events:?}");
    assert_eq!(
        (&dropped[0]["promptId"], &dropped[0]["peer"], &dropped[0]["reason"]),
        (&json!("h1"), &json!("a"), &json!("clone_boot"))
    );

    // The copy's next, ordinary restart holds nothing either.
    let (again, holds) = start(&root, &cfg, None).await;
    assert_eq!(holds, (0, 0));
    assert_eq!(again.len(), events.len(), "a later start changed the settled log");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn the_marker_names_the_first_machine_and_is_retired_once() {
    let home = temp("marker");
    std::fs::create_dir_all(&home).unwrap();
    let hub =
        Hub::new(Config::default(), crate::store::open(&Config::default().store, &home).unwrap());
    assert_eq!(hub.take_clone_marker(&home), None);
    hub.finish_clone_boot(&home);
    assert!(!home.join(DONE).exists(), "no copy, nothing to retire");

    std::fs::write(home.join(MARKER), r#"{"from":"vm_a","to":"vm_b"}"#).unwrap();
    assert_eq!(hub.take_clone_marker(&home).as_deref(), Some("vm_a"));
    assert_eq!(hub.clone_of(), Some("vm_a"));
    hub.finish_clone_boot(&home);
    assert!(!home.join(MARKER).exists());
    assert!(home.join(DONE).exists());

    // A marker that cannot be read still says this start is a copy's. The first daemon's
    // shutdown seal passes the journal's lock to the next open.
    hub.seal();
    let other =
        Hub::new(Config::default(), crate::store::open(&Config::default().store, &home).unwrap());
    std::fs::write(home.join(MARKER), "not json").unwrap();
    assert_eq!(other.take_clone_marker(&home).as_deref(), Some(""));
    let _ = std::fs::remove_dir_all(&home);
}
