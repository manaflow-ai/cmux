//! Preset `args`: extra argv words for the harness command, one word each,
//! never through a shell, validated when the preset is set and when a
//! session starts with it.

use super::*;

/// A hub with the fake ACP harness and a Claude stdio profile that no test
/// spawns (it only gives the validation a Claude command line to guard).
async fn args_setup() -> (Arc<Hub>, TestClient) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = |kind, argv: Vec<String>| HarnessProfile {
        kind,
        argv,
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut agents = BTreeMap::new();
    agents.insert("fake".to_owned(), profile(Default::default(), vec!["python3".into(), fake.into()]));
    agents.insert(
        "fakeclaude".to_owned(),
        profile(acpmux::config::HarnessKind::ClaudeStdio, vec!["claude".into()]),
    );
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut client = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    client
        .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();
    (hub, client)
}

#[tokio::test]
async fn preset_args_reach_the_harness_command_as_separate_words() {
    let (hub, mut c) = args_setup().await;
    // An empty word and shell metacharacters stay literal argv words.
    let args = json!(["--system-prompt-file", "/abs/dir with space/system.md", "--tools", "", "$(echo no) ; |", "${cwd}/x"]);
    let p = c
        .request(method::MUX_PRESETS, json!({"name": "argful", "set": {"harness": "fake", "args": args}}))
        .await
        .unwrap();
    assert_eq!(p["args"], args, "{p}");
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"preset": "argful", "name": "argful"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, json!({"sessionId": id, "prompt": [{"type": "text", "text": "argv"}]}))
        .await
        .unwrap();
    let preview = hub.session_summary(&hub.resolve(&id).unwrap())["preview"].as_str().unwrap().to_owned();
    let got: Vec<String> = serde_json::from_str(&preview).unwrap();
    // `${cwd}` expands like an env value; everything else is verbatim.
    assert_eq!(
        got,
        vec![
            "--system-prompt-file".to_owned(),
            "/abs/dir with space/system.md".into(),
            "--tools".into(),
            "".into(),
            "$(echo no) ; |".into(),
            format!("{}/x", cwd()),
        ]
    );
    // `args: null` clears them; the listing shows none.
    let p = c
        .request(method::MUX_PRESETS, json!({"name": "argful", "set": {"args": null}}))
        .await
        .unwrap();
    assert_eq!(p["args"], json!([]), "{p}");
}

#[tokio::test]
async fn preset_args_are_validated() {
    let (_hub, mut c) = args_setup().await;
    let set = |args: Value, harness: &str| json!({"name": "bad", "set": {"harness": harness, "args": args}});
    // Only a list of strings: never one shell string.
    let err = c.request(method::MUX_PRESETS, set(json!("--tools ''"), "fake")).await.unwrap_err();
    assert!(err.contains("args must be a list of strings"), "{err}");
    let err = c.request(method::MUX_PRESETS, set(json!(["--x", 1]), "fake")).await.unwrap_err();
    assert!(err.contains("args must be a list of strings"), "{err}");
    let err = c.request(method::MUX_PRESETS, set(json!(["a\u{0}b"]), "fake")).await.unwrap_err();
    assert!(err.contains("NUL"), "{err}");
    // On a Claude command line, the flags acpmux itself owns are refused,
    // in both spellings; anything else passes.
    for flag in ["--resume", "--session-id=x", "--permission-mode", "--input-format", "--model", "-p"] {
        let err = c.request(method::MUX_PRESETS, set(json!([flag, "v"]), "fakeclaude")).await.unwrap_err();
        assert!(err.contains("acpmux sets"), "{flag}: {err}");
    }
    let ok = c
        .request(method::MUX_PRESETS, set(json!(["--tools", "", "--strict-mcp-config"]), "fakeclaude"))
        .await
        .unwrap();
    assert_eq!(ok["args"], json!(["--tools", "", "--strict-mcp-config"]));
    // A refused set changes nothing.
    let list = c.request(method::MUX_PRESETS, json!({})).await.unwrap();
    assert_eq!(list["presets"].as_array().unwrap().len(), 1, "{list}");
}

#[tokio::test]
async fn a_session_refuses_a_hand_edited_preset_with_bad_args() {
    let (hub, mut c) = args_setup().await;
    // config.json written by hand: the session is refused, not started with
    // a command line that breaks acpmux's protocol.
    let preset: acpmux::config::Preset =
        serde_json::from_value(json!({"harness": "fakeclaude", "args": ["--resume", "x"]})).unwrap();
    hub.config.write().await.presets.insert("edited".into(), preset);
    let err = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"preset": "edited"}}}),
        )
        .await
        .unwrap_err();
    assert!(err.contains("acpmux sets"), "{err}");
}
