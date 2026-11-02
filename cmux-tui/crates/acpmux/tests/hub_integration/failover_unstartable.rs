//! A failover never moves a chat onto a fallback profile that cannot start, and never leaves it
//! on one (`hub/fallback_start.rs`). A Claude chat's authentication error moved it onto the automatic
//! `cmux` fallback, whose local CodeRouter was not running there; from then on every turn failed
//! in its first second with "the local CodeRouter is not running", for good, while the chat
//! looked idle.
use super::*;

/// A hub whose `primary` Claude profile dies on a prompt (always, or while `die_if` exists) and
/// falls back to `direct`, which runs on route `route` (`cmux`: the built-in model router route,
/// whose local router never runs here; `None`: a program that does not exist, on no route).
/// Routes live in `root/config/routes`.
async fn setup(
    root: &std::path::Path,
    die_if: Option<&std::path::Path>,
    route: Option<&str>,
) -> (Arc<Hub>, TestClient) {
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let store = root.join("claude");
    std::fs::create_dir_all(&store).unwrap();
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("config").join("harnesses")).unwrap();
    std::fs::create_dir_all(root.join("config").join("routes")).unwrap();
    let profile = |env: Vec<(&str, String)>, fallback: Option<&str>| HarnessProfile {
        kind: acpmux::config::HarnessKind::ClaudeStdio,
        argv: vec!["python3".into(), fake_claude.into()],
        env: std::iter::once((
            "FAKE_CLAUDE_STORE".to_owned(),
            store.to_string_lossy().into_owned(),
        ))
        .chain(env.into_iter().map(|(k, v)| (k.to_owned(), v)))
        .collect(),
        description: None,
        fallback: fallback.map(str::to_owned),
        family: Some("claude".into()),
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let die = match die_if {
        Some(path) => ("FAKE_CLAUDE_DIE_IF", path.to_string_lossy().into_owned()),
        None => ("FAKE_CLAUDE_DIE", "1".to_owned()),
    };
    let direct = match route {
        Some(route) => profile(vec![("ACPMUX_PROFILE_ROUTE", route.to_owned())], None),
        None => HarnessProfile {
            argv: vec![root.join("no-such-claude").to_string_lossy().into_owned()],
            ..profile(vec![], None)
        },
    };
    let agents = BTreeMap::from([
        (
            "primary".to_owned(),
            profile(vec![die, ("FAKE_CLAUDE_AUTH_FAIL", "1".to_owned())], Some("direct")),
        ),
        ("direct".to_owned(), direct),
    ]);
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("primary".into()), ..Default::default() };
    // The state folder (where the local router's socket would be) and the routes folder.
    cfg.path = Some(root.join("home").join("config.json"));
    cfg.profile_sources.user_dir = Some(root.join("config").join("harnesses"));
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    // No continuation runs behind a failed turn (`auto_resume.rs`).
    cfg.auto_resume_delays_ms = Some(vec![]);
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();
    (hub, c)
}

fn scratch(tag: &str) -> std::path::PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-failover-{tag}-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    root
}

async fn new_chat(c: &mut TestClient, name: &str, harness: Option<&str>) -> String {
    let mut meta = json!({"name": name});
    if let Some(h) = harness {
        meta["harness"] = json!(h);
    }
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": meta}}),
        )
        .await
        .unwrap();
    s["sessionId"].as_str().unwrap().to_owned()
}

async fn prompt(c: &mut TestClient, id: &str, text: &str) -> Result<Value, String> {
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
    )
    .await
}

fn records(hub: &Hub, id: &str, kind: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == kind)
        .map(|e| e.msg)
        .collect()
}

#[tokio::test]
async fn a_failover_never_moves_a_chat_onto_a_fallback_that_cannot_start() {
    let root = scratch("skip");
    let (hub, mut c) = setup(&root, None, Some("cmux")).await;
    let id = new_chat(&mut c, "skip", None).await;
    let err = prompt(&mut c, &id, "hello").await.expect_err("the primary died on the prompt");
    let session = hub.resolve(&id).unwrap();
    // The chat stays on its own profile, so its next turn can work once that one does.
    assert_eq!(hub.session_summary(&session)["harness"], "primary", "{err}");
    assert!(records(&hub, &id, "failover").is_empty(), "{:?}", records(&hub, &id, "failover"));
    // The turn's error is its own, and says the fallback could not take it, and why.
    // A sign-in failure reads as one (`auth.signed_out`), naming the dead process after it.
    assert!(err.contains("agent process closed"), "{err}");
    assert!(err.contains("the fallback profile direct cannot start"), "{err}");
    assert!(err.contains("CodeRouter is not running"), "{err}");
    // The dead primary's own last stderr line still comes first: the note is added after the
    // turn's end reads the error as a dead process's.
    let reason = err.find("Not logged in").expect(&err);
    assert!(reason < err.find("the fallback profile").unwrap(), "{err}");
    let skipped = records(&hub, &id, "failover_skipped");
    assert_eq!(skipped.len(), 1, "{skipped:?}");
    assert_eq!(skipped[0]["to"], "direct");
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_chat_a_failover_left_on_a_fallback_that_cannot_start_goes_back() {
    let root = scratch("back");
    let die = root.join("die");
    std::fs::write(&die, "").unwrap();
    let route = root.join("config").join("routes").join("relay.toml");
    // The fallback's route works when the failover moves the chat onto it.
    let (hub, mut c) = setup(&root, Some(&die), Some("relay")).await;
    std::fs::write(&route, "kind = \"direct-subscription\"\n").unwrap();
    let id = new_chat(&mut c, "back", None).await;
    // A chat started on the fallback's profile, which no failover put there.
    let own = new_chat(&mut c, "own", Some("direct")).await;
    let first = prompt(&mut c, &id, "hello").await.expect("the fallback answers the turn");
    assert_eq!(first["stopReason"], "end_turn");
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["harness"], "direct");

    // Then the route goes down (a local router that is not running), and the primary works
    // again. The fallback's process ends, so the next turn starts an agent.
    std::fs::write(&route, "kind = \"local-coderouter\"\n").unwrap();
    std::fs::remove_file(&die).unwrap();
    hub.detach_child(&session).await;
    let own_session = hub.resolve(&own).unwrap();
    hub.detach_child(&own_session).await;
    let again = prompt(&mut c, &id, "again").await.expect("the primary takes the turn");
    assert_eq!(again["stopReason"], "end_turn");
    assert_eq!(hub.session_summary(&session)["harness"], "primary");
    let moves = records(&hub, &id, "failover");
    assert_eq!(moves.len(), 2, "{moves:?}");
    assert_eq!(
        (moves[1]["from"].as_str(), moves[1]["to"].as_str()),
        (Some("direct"), Some("primary"))
    );
    assert_eq!(moves[1]["back"], true);
    assert!(
        moves[1]["reason"].as_str().is_some_and(|r| r.contains("CodeRouter is not running")),
        "{moves:?}"
    );

    // The chat started on that profile stays on it: no failover put it there.
    let err = prompt(&mut c, &own, "hello").await.expect_err("its route cannot start");
    assert!(err.contains("CodeRouter is not running"), "{err}");
    assert_eq!(hub.session_summary(&own_session)["harness"], "direct");
    assert!(records(&hub, &own, "failover").is_empty());
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_failover_whose_fallback_fails_to_start_moves_the_chat_back_with_its_conversation() {
    let root = scratch("unstarted");
    let (hub, mut c) = setup(&root, None, None).await;
    let id = new_chat(&mut c, "unstarted", None).await;
    let session = hub.resolve(&id).unwrap();
    let conversation = hub.session_summary(&session)["agentSessionId"].clone();
    assert!(conversation.is_string(), "{conversation}");
    let err = prompt(&mut c, &id, "hello").await.expect_err("neither profile answers");
    // A sign-in failure reads as one (`auth.signed_out`), naming the dead process after it.
    assert!(err.contains("agent process closed"), "{err}");
    assert!(err.contains("the fallback profile direct cannot start"), "{err}");
    // Back on its own profile, with the conversation it had: the fallback's start dropped the
    // id of a conversation its store does not hold before its program failed to start.
    let summary = hub.session_summary(&session);
    assert_eq!(summary["harness"], "primary");
    assert_eq!(summary["agentSessionId"], conversation);
    let moves = records(&hub, &id, "failover");
    assert_eq!(moves.len(), 2, "{moves:?}");
    assert_eq!(moves[0]["to"], "direct");
    assert_eq!(
        (moves[1]["to"].as_str(), moves[1]["back"].as_bool()),
        (Some("primary"), Some(true))
    );
    let _ = std::fs::remove_dir_all(&root);
}
