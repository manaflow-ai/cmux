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
    // A long prompt: the raw lines that repeat it are cut, the chat's own record of it is not.
    let said_first = format!("remember pelican {}", "padding ".repeat(400));
    for id in [&claude, &noload] {
        c.request(method::SESSION_PROMPT, prompt(id, &said_first, None)).await.unwrap();
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
    let after = second.events(&claude, 0, 100_000).unwrap();
    let kinds = |log: &[acpmux::store::EventRecord]| -> Vec<(u64, String)> {
        log.iter().map(|e| (e.seq, e.kind.clone())).collect()
    };
    let last = raw.last().map_or(0, |e| e.seq);
    let kept: Vec<_> = after.iter().filter(|e| e.seq <= last).cloned().collect();
    assert_eq!(kinds(&kept), kinds(&raw), "every record stays, its seq kept");
    let prompt_text = |log: &[acpmux::store::EventRecord]| {
        log.iter().find(|e| e.kind == "user_message").map(|e| e.msg["text"].clone())
    };
    assert_eq!(prompt_text(&after), Some(json!(said_first)), "the prompt is kept whole");
    assert!(
        after.iter().any(|e| e.kind.starts_with("claude.")
            && e.msg.to_string().contains("removed by log retention")),
        "a raw line that repeats the prompt is cut: {pass}"
    );
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
    // Long prompts: the raw lines that repeat them are what a pass cuts.
    let long = format!("hello {}", "padding ".repeat(400));
    c.request(method::SESSION_PROMPT, prompt(&live, &long, None)).await.unwrap();
    let new = json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "closed"}}});
    let closed = c.request(method::SESSION_NEW, new).await.unwrap()["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    c.request(method::SESSION_PROMPT, prompt(&closed, &long, None)).await.unwrap();
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
    assert_ne!(log(&closed), closed_log, "the closed chat's raw lines were cut");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn the_daemon_compacts_a_chat_closed_weeks_ago_by_itself() {
    let root = std::env::temp_dir().join(format!("acpmux-retention-{}", uuid::Uuid::now_v7()));
    let cfg = config(&root);
    let day = 86_400_000;
    let now = acpmux::store::now_ms();
    let store = acpmux::store::open(&cfg.store, &root.join("acpmux")).unwrap();
    let chat = |id: &str, age: u64| {
        let meta = json!({
            "schema": acpmux::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
            "cwd": cwd(), "status": "closed", "createdAt": now - age, "updatedAt": now - age,
        });
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
        let record = |seq: u64, dir: &str, kind: &str, msg: Value| acpmux::store::EventRecord {
            seq,
            at: now - age,
            dir: dir.into(),
            kind: kind.into(),
            msg,
            host_seq: None,
        };
        store.append(id, &record(1, "mux", "created", json!({}))).unwrap();
        store
            .append(id, &record(2, "mux", "user_message", json!({"text": "remember pelican"})))
            .unwrap();
        store
            .append(id, &record(3, "in", "claude.assistant", json!({"text": "x".repeat(5000)})))
            .unwrap();
        store.append(id, &record(4, "mux", "status", json!({"status": "closed"}))).unwrap();
        store.close_log(id);
    };
    chat("weeks-ago", 30 * day);
    chat("last-week", 7 * day);
    drop(store);

    let hub = hub(&cfg, &root);
    let held = Arc::strong_count(&hub);
    let worker = hub.retention_worker();
    let marker = |id: &str| root.join("acpmux/sessions").join(id).join("events/compacted.json");
    let complete = |id: &str| {
        std::fs::read(marker(id))
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .is_some_and(|m| m["complete"] == true)
    };
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while !complete("weeks-ago") {
        assert!(tokio::time::Instant::now() < deadline, "no pass ran");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let raw_text = |id: &str| -> String {
        let log = hub.events(id, 0, 100).unwrap();
        let kinds: Vec<&str> = log.iter().map(|e| e.kind.as_str()).collect();
        assert_eq!(kinds, ["created", "user_message", "claude.assistant", "status"], "{id}");
        log[2].msg["text"].as_str().unwrap().to_owned()
    };
    assert!(raw_text("weeks-ago").ends_with("removed by log retention]"));
    assert_eq!(raw_text("last-week").len(), 5000);
    assert!(!marker("last-week").exists(), "a chat closed 7 days ago is kept whole");
    let listed: Vec<String> = hub.sessions().iter().map(|s| s.id.clone()).collect();
    assert!(listed.contains(&"weeks-ago".to_owned()), "{listed:?}");
    // Between passes it holds no strong reference to the hub.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while Arc::strong_count(&hub) > held {
        assert!(tokio::time::Instant::now() < deadline, "the worker keeps the hub alive");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // The daemon's shutdown ends the worker.
    hub.shutdown_all().await;
    tokio::time::timeout(Duration::from_secs(5), worker)
        .await
        .expect("the worker outlived the shutdown")
        .unwrap();
    let _ = std::fs::remove_dir_all(&root);
}
