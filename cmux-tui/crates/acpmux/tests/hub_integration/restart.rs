//! A daemon restart settles a turn that never ended: it gets a `turn_result
//! failed outcome_unknown`, so nobody replays a prompt that may have run, and
//! (cx-v9k2f) the session shows that turn failed, with why, not idle.

use super::*;

#[tokio::test]
async fn restart_marks_unknown_outcome() {
    use acpmux::store::EventRecord;
    let dir = std::env::temp_dir().join(format!("acpmux-test-{}", uuid::Uuid::now_v7()));
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
            env: BTreeMap::new(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Local;
    let store = acpmux::store::open(&cfg.store, &dir).unwrap();
    let hub = Hub::new(cfg.clone(), store);
    hold_person_key(&hub);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.become_person().await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "crash"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]}),
    )
    .await
    .unwrap();
    let last = hub.session_summary(&hub.resolve(&id).unwrap())["lastSeq"].as_u64().unwrap();
    hub.shutdown_all().await;
    drop(hub);
    // Simulate a crash mid-turn: a turn_started with no turn_result.
    let store2 = acpmux::store::open(&cfg.store, &dir).unwrap();
    store2
        .append(
            &id,
            &EventRecord {
                seq: last + 1,
                at: 0,
                dir: "mux".into(),
                kind: "turn_started".into(),
                msg: json!({"prompt": "lost"}),
                host_seq: None,
            },
        )
        .unwrap();
    let hub2 = Hub::new(cfg, store2);
    let events = hub2.events(&id, last, 100).unwrap();
    let final_kind = events.last().map(|e| e.kind.clone()).unwrap_or_default();
    assert_eq!(
        final_kind,
        "turn_result",
        "{:?}",
        events.iter().map(|e| &e.kind).collect::<Vec<_>>()
    );
    assert_eq!(events.last().unwrap().msg["detail"], "outcome_unknown");
    // cx-v9k2f: the session shows that turn failed, with why, not idle.
    let s = hub2.session_summary(&hub2.resolve(&id).unwrap());
    assert_eq!(s["lastTurn"]["status"], "failed", "{s}");
    assert_eq!(s["indicator"], "failed", "{s}");
    assert_eq!(s["lane"]["state"], "failed", "{s}");
    assert!(s["lane"]["error"].as_str().unwrap_or_default().contains("restarted"), "{s}");
    let _ = std::fs::remove_dir_all(&dir);
}
