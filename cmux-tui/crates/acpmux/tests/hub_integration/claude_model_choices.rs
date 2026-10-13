//! cx-miuo: a Claude Code session's model choices (its `configOptions`
//! model select, which the pane must show) come from the model catalog, not
//! a hand list, so every Claude release the catalog names is offered before
//! Claude Code's own list answers.

use super::*;

use acpmux::server::{Origin, serve_connection_with};

#[tokio::test]
async fn a_claude_session_offers_every_catalog_claude_model() {
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fakeclaude".to_owned(),
        HarnessProfile {
            kind: acpmux::config::HarnessKind::ClaudeStdio,
            argv: vec!["python3".into(), fake_claude.into()],
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
    let mut cfg = Config {
        harnesses: agents,
        default_harness: Some("fakeclaude".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();

    let new =
        c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let offered: Vec<String> = new["configOptions"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|option| option["id"] == "model")
        .and_then(|option| option["options"].as_array())
        .into_iter()
        .flatten()
        .filter_map(|choice| choice["value"].as_str().map(str::to_owned))
        .collect();

    let catalog = acpmux::catalog::schema::parse(acpmux::catalog::BUNDLED.as_bytes()).unwrap();
    let claude = catalog.harnesses.iter().find(|h| h.id == "claude").unwrap();
    for model in &claude.models {
        assert!(offered.contains(&model.id), "{} is not offered: {offered:?}", model.id);
    }
    // Besides Claude Code's own aliases, nothing the catalog does not name.
    let aliases = ["default", "opus", "opus[1m]", "opusplan", "sonnet", "sonnet[1m]", "haiku"];
    for id in &offered {
        assert!(
            aliases.contains(&id.as_str()) || claude.models.iter().any(|m| &m.id == id),
            "{id} is offered but the catalog does not name it: {offered:?}"
        );
    }
    assert_eq!(offered.first().map(String::as_str), Some("default"), "{offered:?}");
}
