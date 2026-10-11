//! `acp.session.fork` (the pane's "Fork from Here"): a fork through the
//! latest completed turn, advertised in `initialize`. An earlier turn forks
//! a Claude chat (session replay's Continue from here) and is refused with a
//! clear error for any other agent.

use super::*;

const FORK_OP: &str = "acp.session.fork";

#[tokio::test]
async fn initialize_advertises_the_fork_operation() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let init = c
        .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "pane"}}))
        .await
        .unwrap();
    let ops = init["_meta"]["acpmux"]["operations"].as_array().cloned().unwrap_or_default();
    assert!(ops.iter().any(|op| op == FORK_OP), "{ops:?}");
}

#[tokio::test]
async fn a_fork_through_the_latest_turn_opens_a_new_session_and_an_earlier_turn_is_refused() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "src"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    for text in ["first", "second"] {
        c.request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
        .unwrap();
    }
    let results: Vec<u64> = hub
        .events(&id, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "turn_result")
        .map(|e| e.seq)
        .collect();
    assert_eq!(results.len(), 2, "{results:?}");

    let earlier =
        c.request(FORK_OP, json!({"sessionId": id, "throughSeq": results[0]})).await.unwrap_err();
    assert!(earlier.contains("latest"), "{earlier}");
    let missing = c.request(FORK_OP, json!({"sessionId": id})).await.unwrap_err();
    assert!(missing.contains("throughSeq"), "{missing}");

    let f = c.request(FORK_OP, json!({"sessionId": id, "throughSeq": results[1]})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    assert_ne!(fid, id);
    let forked = hub.resolve(&fid).unwrap();
    assert_eq!(forked.meta().parent_id.as_deref(), Some(id.as_str()));
    let prompts =
        hub.events(&fid, 0, 1000).unwrap().into_iter().filter(|e| e.kind == "user_message").count();
    assert_eq!(prompts, 2, "the fork holds both turns");
    // Each copied turn ends in the fork too, or the pane shows its last
    // reply as still streaming and the chat as working.
    let ended =
        hub.events(&fid, 0, 1000).unwrap().into_iter().filter(|e| e.kind == "turn_result").count();
    assert_eq!(ended, 2, "the fork holds both turn ends");
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": fid, "prompt": [{"type": "text", "text": "third"}]}),
        )
        .await
        .unwrap();
    assert_eq!(r["stopReason"], "end_turn");
}

/// A hub whose default agent is a Claude stdio profile keeping Claude Code's
/// own store layout under `claude` (fake_claude.py with CLAUDE_CONFIG_DIR).
async fn claude_setup(claude: &std::path::Path) -> (Arc<Hub>, TestClient) {
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let profile = HarnessProfile {
        kind: acpmux::config::HarnessKind::ClaudeStdio,
        argv: vec!["python3".into(), fake_claude.into()],
        env: BTreeMap::from([(
            "CLAUDE_CONFIG_DIR".to_owned(),
            claude.to_string_lossy().into_owned(),
        )]),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([("claude".to_owned(), profile)]),
        default_harness: Some("claude".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "pane"}}))
        .await
        .unwrap();
    (hub, c)
}

/// What the session's Claude conversation holds: fake_claude.py answers
/// "history-probe" with the prompts in its stored transcript.
async fn claude_history(hub: &Arc<Hub>, c: &mut TestClient, id: &str) -> Value {
    let before = hub.events(id, 0, 10_000).unwrap().last().map_or(0, |e| e.seq);
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "history-probe"}]}),
    )
    .await
    .unwrap();
    let text: String = hub
        .events(id, before, 10_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "agent_message_chunk")
        .filter_map(|e| e.msg.pointer("/params/update/content/text").and_then(Value::as_str))
        .collect();
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{e}: {text}"))
}

/// Session replay's Continue from here: a Claude chat forks through an
/// earlier turn. The fork's chat shows that turn and no later one, its
/// Claude conversation remembers only the prompts up to it, and the source
/// chat's conversation is untouched.
#[tokio::test]
async fn a_claude_chat_forks_through_an_earlier_turn_holding_only_the_history_before_it() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-at-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "src"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    for text in ["first", "second"] {
        c.request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
        .unwrap();
    }
    let results: Vec<u64> = hub
        .events(&id, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "turn_result")
        .map(|e| e.seq)
        .collect();
    assert_eq!(results.len(), 2, "{results:?}");

    let f = c.request(FORK_OP, json!({"sessionId": id, "throughSeq": results[0]})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    let count = |kind: &str| {
        hub.events(&fid, 0, 1000).unwrap().into_iter().filter(|e| e.kind == kind).count()
    };
    let chat = (count("user_message"), count("turn_result"));
    let fork = claude_history(&hub, &mut c, &fid).await;
    let source = claude_history(&hub, &mut c, &id).await;
    assert_eq!(chat, (1, 1), "the fork's chat holds the first turn only");
    assert_eq!(fork["prompts"], json!(["first"]), "{fork}");
    assert_eq!(fork["sessions"].as_array().map(Vec::len), Some(1), "one conversation id: {fork}");
    assert_ne!(fork["sessions"], source["sessions"], "the fork is its own conversation");
    assert_eq!(source["prompts"], json!(["first", "second"]), "{source}");
    let _ = std::fs::remove_dir_all(&root);
}
