//! A session that takes over another's work keeps its harness (HQ#5266, item 3,
//! `hub/lineage/successor.rs`). Leo, 2026-10-30: "that visibility into huge-blue guys was (and is?)
//! pretty bad". The deputies relaunched with only `area` and `role` tags came back on the
//! bare default harness, without their profile's autocompact cap.

use super::*;

/// The `fake` family with two profiles: `fake`, its default, and `fake-sr2`, a named profile
/// that runs with an autocompact cap.
async fn setup_profiles() -> (Arc<Hub>, TestClient) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = |extra: &[&str]| HarnessProfile {
        kind: Default::default(),
        argv: ["python3", fake].iter().chain(extra).map(|s| s.to_string()).collect(),
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: Some("fake".into()),
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut harnesses = BTreeMap::new();
    harnesses.insert("fake".to_owned(), profile(&[]));
    harnesses.insert("fake-sr2".to_owned(), profile(&["--autocompact", "400000"]));
    let mut cfg = Config { harnesses, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let c = connect(&hub).await;
    (hub, c)
}

async fn start(c: &mut TestClient, meta: Value) -> Result<Value, String> {
    c.request(
        method::SESSION_NEW,
        json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": meta}}),
    )
    .await
}

#[tokio::test]
async fn a_bare_default_successor_of_a_named_profile_is_refused() {
    let (_hub, mut c) = setup_profiles().await;
    let tags = json!({"area": "fleet", "role": "deputy"});
    start(&mut c, json!({"name": "dep-fleet", "harness": "fake-sr2", "tags": tags})).await.unwrap();
    // Tonight's relaunch: only area and role tags, no -m.
    for meta in [
        json!({"name": "dep-fleet-2", "tags": {"area": "fleet", "role": "deputy"}}),
        json!({"name": "fleet-deputy", "tags": {"area": "fleet", "role": "deputy"}}),
        json!({"name": "dep-fleet-2"}),
        json!({"name": "other", "tags": {"succeeds": "dep-fleet"}}),
    ] {
        let err = start(&mut c, meta.clone()).await.unwrap_err();
        assert!(err.contains("predecessor dep-fleet"), "{meta}: {err}");
        assert!(err.contains("ran fake-sr2"), "{meta}: {err}");
        assert!(err.contains("--harness-from dep-fleet"), "{meta}: {err}");
    }
    // The same area alone is a sibling (a coordinator's helpers share one), not a successor:
    // made on the default, with a warning.
    let s =
        start(&mut c, json!({"name": "fleet-helper", "tags": {"area": "fleet"}})).await.unwrap();
    assert_eq!(s["_meta"]["acpmux"]["harness"], "fake", "{s}");
    assert_eq!(s["_meta"]["acpmux"]["successor"]["via"], "area=fleet", "{s}");
    // `-m fake` starts on the default on purpose: made, with a warning.
    let s =
        start(&mut c, json!({"name": "dep-fleet-2", "harness": "fake", "tags": {"area": "fleet"}}))
            .await
            .unwrap();
    assert_eq!(s["_meta"]["acpmux"]["harness"], "fake", "{s}");
}

#[tokio::test]
async fn a_successor_on_another_harness_is_warned_with_the_flag_that_keeps_it() {
    let (_hub, mut c) = setup_profiles().await;
    start(&mut c, json!({"name": "lane", "harness": "fake-sr2"})).await.unwrap();
    let s = start(&mut c, json!({"name": "lane-2", "harness": "fake"})).await.unwrap();
    let w = &s["_meta"]["acpmux"]["successor"];
    assert_eq!(w["predecessor"], "lane", "{s}");
    let text = w["warning"].as_str().unwrap();
    assert!(text.contains("harness fake-sr2 -> fake"), "{text}");
    assert!(text.contains("autocompact 400000 -> none"), "{text}");
    assert!(text.contains("--harness-from lane keeps the original"), "{text}");
    assert!(!text.contains('\n'), "one line: {text}");
    // The same harness as its predecessor: no warning.
    start(&mut c, json!({"name": "keep", "harness": "fake-sr2"})).await.unwrap();
    let s = start(&mut c, json!({"name": "keep-2", "harness": "fake-sr2"})).await.unwrap();
    assert!(s["_meta"]["acpmux"].get("successor").is_none(), "{s}");
}

#[tokio::test]
async fn harness_from_copies_the_predecessors_harness() {
    let (_hub, mut c) = setup_profiles().await;
    start(&mut c, json!({"name": "dep-fleet", "harness": "fake-sr2", "tags": {"area": "fleet"}}))
        .await
        .unwrap();
    let s = start(
        &mut c,
        json!({"name": "dep-fleet-2", "harnessFrom": "dep-fleet", "tags": {"area": "fleet"}}),
    )
    .await
    .unwrap();
    assert_eq!(s["_meta"]["acpmux"]["harness"], "fake-sr2", "{s}");
    assert!(s["_meta"]["acpmux"].get("successor").is_none(), "{s}");
    // It copies: a -m beside it is refused, and so is a session that does not exist.
    let err = start(&mut c, json!({"name": "x", "harnessFrom": "dep-fleet", "harness": "fake"}))
        .await
        .unwrap_err();
    assert!(err.contains("takes no harness"), "{err}");
    let err = start(&mut c, json!({"name": "x", "harnessFrom": "nobody"})).await.unwrap_err();
    assert!(err.contains("no session \"nobody\""), "{err}");
}

#[tokio::test]
async fn harness_from_is_refused_where_it_would_not_be_honoured() {
    let (hub, mut c) = setup_profiles().await;
    start(&mut c, json!({"name": "dep-fleet", "harness": "fake-sr2"})).await.unwrap();
    // Never silently dropped: an ephemeral run, and a connection that is not the local socket.
    let err =
        start(&mut c, json!({"harnessFrom": "dep-fleet", "ephemeral": true})).await.unwrap_err();
    assert!(err.contains("local socket only"), "{err}");
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    let app = acpmux::server::Origin::LocalApp;
    tokio::spawn(acpmux::server::serve_connection_with(hub.clone(), in_rx, out_tx, app));
    let mut app = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    let init = json!({"protocolVersion": 1, "clientInfo": {"name": "test"}});
    app.request(method::INITIALIZE, init).await.unwrap();
    let err = start(&mut app, json!({"name": "dep-fleet-2", "harnessFrom": "dep-fleet"}))
        .await
        .unwrap_err();
    assert!(err.contains("local socket only"), "{err}");
}

#[tokio::test]
async fn report_to_names_a_predecessor_only_of_its_own_name_family() {
    let (_hub, mut c) = setup_profiles().await;
    // The coordinator runs a named profile; a helper it starts on the default is no successor.
    start(&mut c, json!({"name": "coord", "harness": "fake-sr2"})).await.unwrap();
    let s = start(&mut c, json!({"name": "helper", "reportTo": "coord"})).await.unwrap();
    assert!(s["_meta"]["acpmux"].get("successor").is_none(), "{s}");
    // A relaunch that reports to its own former self's family is one.
    let err = start(&mut c, json!({"name": "coord-2", "reportTo": "coord"})).await.unwrap_err();
    assert!(err.contains("(by --report-to) ran fake-sr2"), "{err}");
}

#[tokio::test]
async fn a_session_that_names_no_predecessor_starts_without_a_warning() {
    let (_hub, mut c) = setup_profiles().await;
    start(&mut c, json!({"name": "dep-fleet", "harness": "fake-sr2", "tags": {"area": "fleet"}}))
        .await
        .unwrap();
    // Another name, another area, no tag: nothing names dep-fleet.
    for meta in [
        json!({"name": "solo"}),
        json!({"name": "review-27903"}),
        json!({"name": "docs", "tags": {"area": "docs"}}),
        json!({}),
    ] {
        let s = start(&mut c, meta.clone()).await.unwrap();
        assert_eq!(s["_meta"]["acpmux"]["harness"], "fake", "{meta}: {s}");
        assert!(s["_meta"]["acpmux"].get("successor").is_none(), "{meta}: {s}");
    }
}
