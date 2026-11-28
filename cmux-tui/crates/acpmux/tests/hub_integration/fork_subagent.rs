//! A subagent forked into a chat of its own (`acp.session.fork` with `subagentId`,
//! `hub/fork_subagent.rs`): its fork's conversation is the subagent's own transcript, once, with
//! nothing of the chat's; it starts on the picked model and in the picked mode; it names the chat
//! and subagent it came from. Leo, 2026-11-22: "does it make sense to be able to reveal the fork
//! or whatever switching model behaviour for it?"

use super::*;

/// The sidechain Claude Code writes for subagent `agent` of conversation `sid`
/// (`projects/<project>/<sid>/subagents/agent-<agent>.jsonl`), its call to `Read` answered, and
/// with `running` one more call still open.
fn write_sidechain(claude: &std::path::Path, sid: &str, agent: &str, running: bool) {
    let dir = claude.join("projects/p").join(sid).join("subagents");
    std::fs::create_dir_all(&dir).unwrap();
    let line = |v: Value| v.to_string() + "\n";
    let mut text = String::new();
    let base = |kind: &str, uuid: &str, message: Value| {
        json!({"type": kind, "isSidechain": true, "agentId": agent, "sessionId": sid, "uuid": uuid,
               "timestamp": "2026-11-22T00:00:00.000Z", "message": message})
    };
    text += &line(base(
        "user",
        "s1",
        json!({"role": "user", "content": [{"type": "text", "text": "List the test files"}]}),
    ));
    text += &line(base(
        "assistant",
        "s2",
        json!({"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_sub1", "name": "Read", "input": {"file_path": "/a/tests.rs"}}]}),
    ));
    text += &line(base(
        "user",
        "s3",
        json!({"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_sub1", "content": "fn t() {}"}]}),
    ));
    text += &line(base(
        "assistant",
        "s4",
        json!({"role": "assistant", "stop_reason": "end_turn", "content": [{"type": "text", "text": "Found one test file"}]}),
    ));
    if running {
        text += &line(base(
            "assistant",
            "s5",
            json!({"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_sub2", "name": "Bash", "input": {"command": "cargo test"}}]}),
        ));
    }
    std::fs::write(dir.join(format!("agent-{agent}.jsonl")), text).unwrap();
}

/// A Claude chat that ran a subagent (`agent-probe`), and its Claude conversation id.
async fn claude_chat_with_subagent(
    claude: &std::path::Path,
    running: bool,
) -> (Arc<Hub>, TestClient, String, String, String) {
    let (hub, mut c) = claude_setup(claude, &[]).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "src"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    for text in ["first", "agent-probe"] {
        let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
        c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    }
    let sid = hub.resolve(&id).unwrap().meta().agent_session_id.unwrap();
    write_sidechain(claude, &sid, "a1", running);
    let entry = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .iter()
        .filter_map(|e| e.msg.pointer("/params/_meta/acpmux/subagents").and_then(Value::as_array))
        .flatten()
        .find_map(|s| s["id"].as_str().map(str::to_owned))
        .expect("agent-probe spawns a subagent");
    (hub, c, id, sid, entry)
}

fn prompts(history: &Value) -> Vec<String> {
    history["prompts"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(Value::as_str)
        .filter(|p| !p.is_empty())
        .map(str::to_owned)
        .collect()
}

/// The subagent's fork holds the subagent's conversation once and none of the chat's, its rows
/// read from that conversation, its lineage named, and it starts in the picked mode and model.
#[tokio::test]
async fn a_claude_subagent_forks_into_a_chat_of_its_own() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-sub-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c, id, sid, entry) = claude_chat_with_subagent(&claude, false).await;
    let f = c
        .request(
            FORK_OP,
            json!({"sessionId": id, "live": true, "subagentId": entry, "mode": "plan", "model": "haiku"}),
        )
        .await
        .unwrap_or_else(|e| panic!("the subagent forks: {e}"));
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    let fork = hub.resolve(&fid).unwrap();
    let meta = fork.meta();
    // Lineage: the chat, and the subagent whose conversation it holds.
    assert_eq!(meta.parent_id.as_deref(), Some(id.as_str()));
    let of = meta.fork_of_subagent.clone().expect("the fork names its subagent");
    assert_eq!(of.session_id, id);
    assert_eq!(of.subagent_id, entry);
    assert_eq!(of.agent_id.as_deref(), Some("a1"));
    assert_eq!(of.name.as_deref(), Some("Find the tests"));
    assert_eq!(meta.title.as_deref(), Some("Find the tests"));
    let events = hub.events(&fid, 0, 10_000).unwrap();
    let forked = events.iter().find(|e| e.kind == "forked").unwrap();
    assert_eq!(forked.msg["subagentId"], entry.as_str());
    assert_eq!(forked.msg["subagentName"], "Find the tests");
    assert_eq!(forked.msg["source"], "subagent");
    let child = hub.events(&id, 0, 10_000).unwrap().into_iter().rfind(|e| e.kind == "fork_child");
    assert_eq!(child.unwrap().msg["subagentId"], entry.as_str());
    // The rows: the subagent's one turn, none of the chat's.
    let said: Vec<String> = events
        .iter()
        .filter(|e| e.kind == "turn_started")
        .filter_map(|e| e.msg["prompt"].as_str().map(str::to_owned))
        .collect();
    assert_eq!(said, ["List the test files"], "{events:?}");
    let text = serde_json::to_string(&events).unwrap();
    assert!(!text.contains("agent-probe") && !text.contains("\"first\""), "no chat record: {text}");
    // The mode and the model, before the reply.
    assert_eq!(meta.modes.as_ref().unwrap()["currentModeId"], "plan", "{:?}", meta.modes);
    assert!(
        // Whichever way the harness takes it: at spawn, as a config option, or set_model.
        events.iter().any(|e| {
            let sets_model = matches!(e.kind.as_str(), "model" | "config")
                || e.msg["method"] == method::SESSION_SET_MODEL;
            sets_model && e.msg.to_string().contains("haiku")
        }),
        "the model is set: {events:?}"
    );
    // The info view's forkOf.
    let info = c.request(method::MUX_INFO, json!({"sessionId": fid})).await.unwrap();
    assert_eq!(info["forkOf"]["subagentId"], entry.as_str(), "{info}");
    // Its Claude conversation is the subagent's, once, under its own id.
    let history = claude_history(&hub, &mut c, &fid).await;
    assert_eq!(prompts(&history), ["List the test files"], "{history}");
    assert_eq!(history["sessions"].as_array().map(Vec::len), Some(1), "{history}");
    assert_ne!(history["sessions"][0], sid.as_str());
    assert_eq!(history["unresolved"], json!([]));
    // The chat's own conversation is untouched.
    let source = claude_history(&hub, &mut c, &id).await;
    assert_eq!(prompts(&source), ["first", "agent-probe"], "{source}");
    let _ = std::fs::remove_dir_all(&root);
}

/// A subagent still running forks through its last settled step: its open call is not in the
/// fork, whose Claude conversation has no call without a result. Named by its agent id.
#[tokio::test]
async fn a_running_claude_subagent_forks_through_its_last_settled_step() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-sub-run-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c, id, _sid, _entry) = claude_chat_with_subagent(&claude, true).await;
    let f = c
        .request(FORK_OP, json!({"sessionId": id, "live": true, "subagentId": "a1"}))
        .await
        .unwrap_or_else(|e| panic!("the running subagent forks: {e}"));
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    let forked =
        hub.events(&fid, 0, 10_000).unwrap().into_iter().find(|e| e.kind == "forked").unwrap();
    assert_eq!(forked.msg["subagentCut"], true, "{:?}", forked.msg);
    let history = claude_history(&hub, &mut c, &fid).await;
    assert_eq!(prompts(&history), ["List the test files"], "{history}");
    assert_eq!(history["unresolved"], json!([]), "{history}");
    let _ = std::fs::remove_dir_all(&root);
}

/// An unknown subagent, an unknown mode, and a subagent with a turn boundary are refused, and no
/// fork is left behind.
#[tokio::test]
async fn an_unknown_subagent_or_mode_is_refused() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-sub-no-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c, id, _sid, entry) = claude_chat_with_subagent(&claude, false).await;
    let count = || hub.sessions().len();
    let before = count();
    let unknown = c
        .request(FORK_OP, json!({"sessionId": id, "live": true, "subagentId": "nobody"}))
        .await
        .unwrap_err();
    assert!(unknown.contains("fork.subagent_unknown"), "{unknown}");
    let bad_mode = c
        .request(
            FORK_OP,
            json!({"sessionId": id, "live": true, "subagentId": entry, "mode": "yolo"}),
        )
        .await
        .unwrap_err();
    assert!(bad_mode.contains("fork.mode_unknown") && bad_mode.contains("plan"), "{bad_mode}");
    let no_live =
        c.request(FORK_OP, json!({"sessionId": id, "subagentId": entry})).await.unwrap_err();
    assert!(no_live.contains("live"), "{no_live}");
    assert_eq!(count(), before, "a refused fork leaves no chat");
    // A plain fork in a picked mode works, and an unknown one is refused too.
    let plain = c.request(FORK_OP, json!({"sessionId": id, "live": true, "mode": "yolo"})).await;
    assert!(plain.unwrap_err().contains("fork.mode_unknown"));
    let _ = std::fs::remove_dir_all(&root);
}

/// A Codex child thread (its id is the subagent's id) forks as a top-level thread of its own;
/// another chat's thread is refused. Recorded rollouts only: Codex's live accounts have no usage
/// until 2026-11-25.
#[tokio::test]
async fn a_codex_child_thread_forks_into_a_chat_of_its_own() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-sub-codex-{}", uuid::Uuid::now_v7()));
    let codex = root.join("codex");
    std::fs::create_dir_all(&codex).unwrap();
    let (hub, mut c) = codex_setup(&codex).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "src"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "first"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let thread = hub.resolve(&id).unwrap().meta().agent_session_id.unwrap();
    let rollout = |child: &str, parent: &str| -> String {
        [
            json!({"timestamp": "2026-11-22T00:00:00.000Z", "type": "session_meta", "payload": {
                "id": child, "session_id": parent, "parent_thread_id": parent, "cwd": cwd(),
                "agent_nickname": "Ada", "agent_role": "explorer", "thread_source": "subagent",
                "source": {"subagent": {"thread_spawn": {"parent_thread_id": parent, "depth": 1}}}}}),
            json!({"timestamp": "2026-11-22T00:00:01.000Z", "type": "event_msg", "payload": {"type": "task_started"}}),
            json!({"timestamp": "2026-11-22T00:00:01.000Z", "type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Map the crate"}]}}),
            json!({"timestamp": "2026-11-22T00:00:02.000Z", "type": "response_item", "payload": {"type": "function_call", "call_id": "c1", "name": "shell", "arguments": "{}"}}),
            json!({"timestamp": "2026-11-22T00:00:03.000Z", "type": "response_item", "payload": {"type": "function_call_output", "call_id": "c1", "output": "ok"}}),
            json!({"timestamp": "2026-11-22T00:00:04.000Z", "type": "response_item", "payload": {"type": "message", "role": "assistant", "phase": "final_answer", "content": [{"type": "output_text", "text": "Mapped"}]}}),
            json!({"timestamp": "2026-11-22T00:00:04.000Z", "type": "event_msg", "payload": {"type": "task_complete"}}),
        ]
        .iter()
        .map(|v| v.to_string() + "\n")
        .collect()
    };
    let day = codex.join("sessions/2026/11/22");
    std::fs::create_dir_all(&day).unwrap();
    let child = uuid::Uuid::now_v7().to_string();
    let stranger = uuid::Uuid::now_v7().to_string();
    for (name, parent) in [(&child, thread.as_str()), (&stranger, "another-chats-thread")] {
        std::fs::write(
            day.join(format!("rollout-2026-11-22T00-00-00-{name}.jsonl")),
            rollout(name, parent),
        )
        .unwrap();
    }
    let refused = c
        .request(FORK_OP, json!({"sessionId": id, "live": true, "subagentId": stranger}))
        .await
        .unwrap_err();
    assert!(refused.contains("fork.subagent_unknown"), "{refused}");
    let f = c
        .request(FORK_OP, json!({"sessionId": id, "live": true, "subagentId": child}))
        .await
        .unwrap_or_else(|e| panic!("the Codex child forks: {e}"));
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    let meta = hub.resolve(&fid).unwrap().meta();
    assert_eq!(meta.fork_of_subagent.as_ref().unwrap().subagent_id, child);
    let events = hub.events(&fid, 0, 10_000).unwrap();
    let said: Vec<&str> = events
        .iter()
        .filter(|e| e.kind == "turn_started")
        .filter_map(|e| e.msg["prompt"].as_str())
        .collect();
    assert_eq!(said, ["Map the crate"], "{events:?}");
    let history = claude_history(&hub, &mut c, &fid).await;
    assert_eq!(prompts(&history), ["Map the crate"], "{history}");
    assert_eq!(history["sessions"].as_array().map(Vec::len), Some(1), "{history}");
    assert_ne!(history["sessions"][0], child.as_str(), "the fork is its own thread");
    let _ = std::fs::remove_dir_all(&root);
}

/// A fake OpenCode profile has the same process-owned subagent boundary as the real harness.
/// Keep this setup separate from `setup`, whose unnamed ACP profile is intentionally generic.
async fn opencode_setup() -> (Arc<Hub>, TestClient) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = HarnessProfile {
        kind: acpmux::config::HarnessKind::Acp,
        argv: vec!["python3".into(), fake.into()],
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: Some("opencode".into()),
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([(String::from("opencode"), profile)]),
        default_harness: Some("opencode".into()),
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

/// OpenCode reports task subagents from its own process, so acpmux refuses to fork one rather
/// than pretending its model or permissions can be switched. This is the third leg of the
/// Claude/Codex/OpenCode fork matrix requested by Leo.
#[tokio::test]
async fn an_opencode_subagent_fork_is_refused_with_the_process_boundary() {
    let (hub, mut c) = opencode_setup().await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "opencode-task"}]}),
    )
    .await
    .unwrap();
    let before = hub.sessions().len();
    let e = c
        .request(FORK_OP, json!({"sessionId": id, "live": true, "subagentId": "chatcmpl-tool-oc1"}))
        .await
        .unwrap_err();
    assert!(e.contains("fork.subagent_harness"), "{e}");
    assert!(e.contains("OpenCode") || e.contains("opencode"), "{e}");
    assert_eq!(hub.sessions().len(), before, "a refused fork leaves no orphan chat");
}

/// A harness that keeps its subagents inside its process cannot fork one: refused with why.
#[tokio::test]
async fn another_harness_refuses_a_subagent_fork_with_the_reason() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let before = hub.sessions().len();
    let e = c
        .request(FORK_OP, json!({"sessionId": id, "live": true, "subagentId": "x"}))
        .await
        .unwrap_err();
    assert!(e.contains("fork.subagent_harness"), "{e}");
    assert_eq!(hub.sessions().len(), before);
}
