//! A closed chat whose log retention compacted (`hub/retention.rs`, `store/compact.rs`) still
//! lists, opens and resumes after a restart: Claude Code resumes its own conversation by the
//! saved id, and an agent that cannot load its session is told the chat's transcript again.

use super::*;

fn harness(argv: &str, env: &[(&str, String)]) -> HarnessProfile {
    HarnessProfile {
        kind: if argv.ends_with("fake_claude.py") {
            acpmux::config::HarnessKind::ClaudeStdio
        } else {
            Default::default()
        },
        argv: vec!["python3".into(), argv.into()],
        env: env.iter().map(|(k, v)| ((*k).to_owned(), v.clone())).collect(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    }
}

fn config(root: &std::path::Path) -> Config {
    let claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let store = root.join("claude").to_string_lossy().into_owned();
    let agents = BTreeMap::from([
        ("claude".to_owned(), harness(claude, &[("CLAUDE_CONFIG_DIR", store)])),
        ("noload".to_owned(), harness(fake, &[("FAKE_NO_LOAD", "1".into())])),
    ]);
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("claude".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Local;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    cfg
}

fn hub(cfg: &Config, root: &std::path::Path) -> Arc<Hub> {
    Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &root.join("acpmux")).unwrap())
}

/// The agent's text in `id`'s log past `after`.
fn said(hub: &Hub, id: &str, after: u64) -> String {
    hub.events(id, after, 100_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "agent_message_chunk")
        .filter_map(|e| e.msg.pointer("/params/update/content/text")?.as_str().map(str::to_owned))
        .collect()
}

fn last_seq(hub: &Hub, id: &str) -> u64 {
    hub.events(id, 0, 100_000).unwrap().last().map_or(0, |e| e.seq)
}

#[tokio::test]
async fn a_compacted_closed_chat_still_lists_reopens_and_resumes() {
    let root = std::env::temp_dir().join(format!("acpmux-retention-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(root.join("claude")).unwrap();
    let cfg = config(&root);

    let first = hub(&cfg, &root);
    let mut c = connect(&first).await;
    let chat = |harness: &'static str| json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": harness, "harness": harness}}});
    let claude = c.request(method::SESSION_NEW, chat("claude")).await.unwrap()["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let noload = c.request(method::SESSION_NEW, chat("noload")).await.unwrap()["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    for id in [&claude, &noload] {
        c.request(method::SESSION_PROMPT, prompt(id, "remember pelican", None)).await.unwrap();
        c.request("_acpmux/kill", json!({"sessionId": id})).await.unwrap();
    }
    let raw = first.events(&claude, 0, 100_000).unwrap();
    assert!(raw.iter().any(|e| e.kind.starts_with("claude.")), "Claude's raw lines are logged");
    first.shutdown_all().await;
    drop(c);
    drop(first);

    // After a restart, both closed chats' logs are compacted.
    let second = hub(&cfg, &root);
    let mut c = connect(&second).await;
    let dry =
        c.request("_acpmux/retention", json!({"dryRun": true, "olderThanDays": 0})).await.unwrap();
    assert_eq!(dry["chats"], 2, "{dry}");
    let pass = c.request("_acpmux/retention", json!({"olderThanDays": 0})).await.unwrap();
    assert_eq!(pass["chats"], 2, "{pass}");
    assert_eq!(pass["freedBytes"], dry["freedBytes"], "the dry run measured this pass: {pass}");
    assert!(pass["freedBytes"].as_u64().unwrap() > 0, "{pass}");
    let raw: Vec<(String, String)> = second
        .events(&claude, 0, 100_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind.starts_with("claude."))
        .map(|e| (e.dir, e.kind))
        .collect();
    assert!(raw.iter().all(|(dir, _)| dir != "in"), "Claude's raw lines went: {raw:?} {pass}");
    // A second pass finds nothing new to do.
    let again = c.request("_acpmux/retention", json!({"olderThanDays": 0})).await.unwrap();
    assert_eq!((again["chats"].as_u64(), &again["skipped"]["compacted"]), (Some(0), &json!(2)));
    second.shutdown_all().await;
    drop(c);
    drop(second);

    // A restart lists them, and each resumes where it stopped.
    let third = hub(&cfg, &root);
    let listed: Vec<String> = third.sessions().iter().map(|s| s.id.clone()).collect();
    assert!(listed.contains(&claude) && listed.contains(&noload), "{listed:?}");
    let mut c = connect(&third).await;
    let before = last_seq(&third, &claude);
    c.request(method::SESSION_PROMPT, prompt(&claude, "history-probe", None)).await.unwrap();
    let resumed: Vec<String> = third
        .events(&claude, before, 1000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "resumed")
        .filter_map(|e| e.msg["level"].as_str().map(str::to_owned))
        .collect();
    assert_eq!(resumed, ["exact"], "Claude resumes its own conversation by the saved id");
    let history = said(&third, &claude, before);
    assert!(history.contains("remember pelican"), "{history}");

    let before = last_seq(&third, &noload);
    c.request(method::SESSION_PROMPT, prompt(&noload, "what did I ask?", None)).await.unwrap();
    let told = said(&third, &noload, before);
    assert!(told.contains("<restored_transcript"), "{told}");
    assert!(told.contains("remember pelican"), "the prompt is in the transcript: {told}");
    // The prompt and the agent's echo of it, both from the transcript, then this turn's echo.
    assert!(told.matches("remember pelican").count() >= 2, "and the agent's answer: {told}");
    third.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn retention_never_touches_an_open_or_recent_chat() {
    let root = std::env::temp_dir().join(format!("acpmux-retention-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(root.join("claude")).unwrap();
    let cfg = config(&root);
    let hub = hub(&cfg, &root);
    let mut c = connect(&hub).await;
    let new = json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "live"}}});
    let live = c.request(method::SESSION_NEW, new).await.unwrap()["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    c.request(method::SESSION_PROMPT, prompt(&live, "hello", None)).await.unwrap();
    let new = json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "closed"}}});
    let closed = c.request(method::SESSION_NEW, new).await.unwrap()["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    c.request(method::SESSION_PROMPT, prompt(&closed, "hello", None)).await.unwrap();
    c.request("_acpmux/kill", json!({"sessionId": closed})).await.unwrap();
    // The client that made it goes; one still attached keeps a chat whole.
    c.request("_acpmux/detach", json!({"sessionId": closed})).await.unwrap();
    let log = |id: &str| hub.events(id, 0, 100_000).unwrap();
    let (live_log, closed_log) = (log(&live), log(&closed));

    // Closed today: younger than the default 14 days.
    let pass = c.request("_acpmux/retention", json!({})).await.unwrap();
    assert_eq!(pass["chats"], 0, "{pass}");
    assert_eq!(pass["skipped"]["recent"], 1, "{pass}");
    // Any age: the live chat (its agent runs) is still left whole.
    let pass = c.request("_acpmux/retention", json!({"olderThanDays": 0})).await.unwrap();
    assert_eq!(pass["chats"], 1, "{pass}");
    assert_eq!(
        (&pass["skipped"]["open"], &pass["skipped"]["attached"]),
        (&json!(1), &Value::Null),
        "{pass}"
    );
    assert_eq!(log(&live), live_log);
    assert_ne!(log(&closed), closed_log, "the closed chat's raw lines went");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
