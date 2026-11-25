//! The in-process Codex app-server bridge must settle a command approval that
//! was already waiting when the person switches the chat to `agent-full-access`.
use super::*;
use std::os::unix::fs::PermissionsExt;

async fn codex_hub() -> (Arc<Hub>, TestClient, std::path::PathBuf) {
    let root =
        std::env::temp_dir().join(format!("acpmux-codex-permission-{}", uuid::Uuid::now_v7()));
    let bin = root.join("bin");
    let home = root.join("codex-home");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    let fixture = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_codex_stream.py");
    let codex = bin.join("codex");
    std::fs::write(&codex, format!("#!/bin/sh\nexec python3 {fixture} \"$@\"\n")).unwrap();
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).unwrap();
    let profile = HarnessProfile {
        kind: Default::default(),
        argv: vec![codex.to_string_lossy().into_owned(), "app-server".into()],
        env: BTreeMap::from([
            ("CODEX_HOME".into(), home.to_string_lossy().into_owned()),
            ("FIX_DELTAS".into(), "3".into()),
            ("FIX_REASON".into(), "1".into()),
            ("FIX_OUT".into(), "1".into()),
            ("FIX_LOG".into(), root.join("wire.log").to_string_lossy().into_owned()),
        ]),
        description: None,
        fallback: None,
        family: Some("codex".into()),
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([("codex".into(), profile)]),
        default_harness: Some("codex".into()),
        ..Default::default()
    };
    cfg.permission_policy = PermissionPolicy::Ask;
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hold_person_key(&hub);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut client = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    client.become_person().await;
    (hub, client, root)
}

#[tokio::test]
async fn codex_full_access_switch_settles_a_pending_command_approval() {
    let (hub, mut c, root) = codex_hub().await;
    let created =
        c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = created["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_SET_MODE, json!({"sessionId": id, "modeId": "ask"})).await.unwrap();
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "approval-codex", None)).await;

    let pending = c.wait_for(method::MUX_PERMISSION_PENDING, |p| p["sessionId"] == id).await;
    assert!(pending["permissionId"].is_string(), "{pending}");

    // Use a second app connection so the mode response cannot consume the
    // turn response while the pending approval is being settled.
    let mut changer = connect(&hub).await;
    changer
        .request(method::SESSION_SET_MODE, json!({"sessionId": id, "modeId": "agent-full-access"}))
        .await
        .unwrap();
    assert!(c.response(rid).await.0.is_ok(), "the mode switch should settle the ask");

    let session = hub.resolve(&id).unwrap();
    assert!(session.pending_permissions().is_empty());
    let events = hub.events(&session.id, 0, 10_000).unwrap();
    let autos: Vec<_> = events
        .iter()
        .filter(|event| event.kind == "permission_auto")
        .map(|event| &event.msg)
        .collect();
    assert_eq!(autos.len(), 1, "{autos:?}");
    assert_eq!(autos[0]["fullAccess"], "agent-full-access");
    assert_eq!(autos[0]["optionId"], "accept");
    assert!(events.iter().any(|event| event.kind == "permission_decision"), "{events:?}");
    let wire = std::fs::read_to_string(root.join("wire.log")).unwrap();
    assert!(wire.contains("approval-decision accept\n"), "{wire}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
}
