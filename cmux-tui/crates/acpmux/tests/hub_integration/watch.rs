//! Watching a Claude Code or Codex conversation without taking it over (`hub/watch.rs`): the
//! chat shows the transcript, follows what the other app appends, writes nothing to it, starts
//! no harness, and takes no prompt until a client takes it over.
use super::*;
use acpmux::adopt::HarnessHomes;

/// A hub with one Codex-family and one Claude-family fake harness, and stores under a temp root.
async fn watch_setup() -> (Arc<Hub>, TestClient, std::path::PathBuf) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = |family: &str| HarnessProfile {
        kind: Default::default(),
        argv: vec!["python3".into(), fake.into()],
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: Some(family.into()),
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut agents = BTreeMap::new();
    agents.insert("fakecodex".to_owned(), profile("codex"));
    agents.insert("fakeclaude".to_owned(), profile("claude"));
    let root =
        std::path::PathBuf::from("/tmp").join(format!("acpmux-watch-{}", uuid::Uuid::now_v7()));
    // A Claude profile whose home is the test's store, as a profile with CLAUDE_CONFIG_DIR runs.
    let mut homed = profile("claude");
    homed
        .env
        .insert("CLAUDE_CONFIG_DIR".into(), root.join("claude").to_string_lossy().into_owned());
    agents.insert("homedclaude".to_owned(), homed);
    let mut cfg = Config {
        harnesses: agents,
        default_harness: Some("fakecodex".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    std::fs::create_dir_all(root.join("project")).unwrap();
    hub.set_harness_homes(HarnessHomes { claude: root.join("claude"), codex: root.join("codex") });
    let c = connect(&hub).await;
    (hub, c, root)
}

fn watch(harness: &str, id: &str) -> Value {
    let adopt = json!({"agentSessionId": id, "watch": true});
    json!({"mcpServers": [], "_meta": {"acpmux": {"harness": harness, "adopt": adopt}}})
}

fn append(file: &std::path::Path, records: &[Value]) {
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new().create(true).append(true).open(file).unwrap();
    for r in records {
        writeln!(f, "{r}").unwrap();
    }
}

/// Sets `file`'s modification time an hour back: a recent write is a chat live elsewhere.
fn backdate(file: &std::path::Path) {
    let hour_ago = std::time::SystemTime::now() - Duration::from_secs(3600);
    std::fs::File::options().write(true).open(file).unwrap().set_modified(hour_ago).unwrap();
}

/// Every file under `dir`, with its bytes.
fn snapshot(dir: &std::path::Path) -> BTreeMap<std::path::PathBuf, Vec<u8>> {
    let mut out = BTreeMap::new();
    let mut dirs = vec![dir.to_owned()];
    while let Some(d) = dirs.pop() {
        for entry in std::fs::read_dir(&d).unwrap().flatten() {
            let path = entry.path();
            if path.is_dir() {
                dirs.push(path);
            } else {
                out.insert(path.clone(), std::fs::read(&path).unwrap());
            }
        }
    }
    out
}

fn kinds(hub: &Hub, id: &str) -> Vec<String> {
    hub.events(id, 0, 10_000).unwrap().into_iter().map(|e| e.kind).collect()
}

fn prompts(hub: &Hub, id: &str) -> Vec<String> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "user_message")
        .map(|e| e.msg["text"].as_str().unwrap_or_default().to_owned())
        .collect()
}

fn answers(hub: &Hub, id: &str) -> Vec<String> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "agent_message_chunk")
        .filter_map(|e| {
            e.msg.pointer("/params/update/content/text").and_then(Value::as_str).map(str::to_owned)
        })
        .collect()
}

/// Waits (up to 10 s) until the session shows `n` prompts.
async fn until_prompts(hub: &Hub, id: &str, n: usize) -> Vec<String> {
    for _ in 0..200 {
        if prompts(hub, id).len() >= n {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    prompts(hub, id)
}

fn codex_event(kind: &str, message: &str) -> Value {
    json!({"timestamp": "2026-10-18T09:00:00.000Z", "type": "event_msg", "payload": {"type": kind, "message": message}})
}

#[tokio::test]
async fn a_watched_codex_chat_follows_its_transcript_and_writes_nothing() {
    let (hub, mut c, root) = watch_setup().await;
    let id = uuid::Uuid::now_v7().to_string();
    let rollout =
        root.join(format!("codex/sessions/2026/10/18/rollout-2026-10-18T09-00-00-{id}.jsonl"));
    std::fs::create_dir_all(rollout.parent().unwrap()).unwrap();
    append(
        &rollout,
        &[
            json!({"type": "session_meta", "payload": {"id": id, "cwd": root.join("project")}}),
            codex_event("user_message", "first prompt"),
            codex_event("agent_message", "first answer"),
            json!({"type": "event_msg", "payload": {"type": "task_complete"}}),
        ],
    );
    let store = root.join("codex");
    let s = c.request(method::SESSION_NEW, watch("fakecodex", &id)).await.unwrap();
    let sid = s["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(until_prompts(&hub, &sid, 1).await, ["first prompt"]);
    assert_eq!(answers(&hub, &sid), ["first answer"]);
    let summary = hub.session_summary(&hub.resolve(&sid).unwrap());
    assert_eq!(summary["watching"], "codex", "{summary}");

    // The other app goes on: the chat shows what it appends.
    append(
        &rollout,
        &[
            codex_event("user_message", "second prompt"),
            codex_event("agent_message", "second answer"),
        ],
    );
    let before = snapshot(&store);
    assert_eq!(until_prompts(&hub, &sid, 2).await, ["first prompt", "second prompt"]);
    for _ in 0..100 {
        if answers(&hub, &sid).len() == 2 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(answers(&hub, &sid), ["first answer", "second answer"]);

    // It takes no prompt, and started no harness.
    let refused = c.request(method::SESSION_PROMPT, prompt(&sid, "hi", None)).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("watch.read_only")), "{refused:?}");
    let k = kinds(&hub, &sid);
    assert!(!k.iter().any(|k| k == "initialize" || k == "session/load"), "{k:?}");
    // Nothing under the store changed: no file written, added or removed.
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(snapshot(&store), before);
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_watched_claude_chat_shows_prompts_and_answers() {
    let (hub, mut c, root) = watch_setup().await;
    let id = uuid::Uuid::now_v7().to_string();
    let project = root.join("project");
    let file = root.join(format!("claude/projects/-tmp-watch/{id}.jsonl"));
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let user = |text: &str| json!({"type": "user", "cwd": project, "sessionId": id, "timestamp": "2026-10-18T09:00:00.000Z", "message": {"role": "user", "content": text}});
    let assistant = |text: &str| json!({"type": "assistant", "cwd": project, "sessionId": id, "timestamp": "2026-10-18T09:00:01.000Z", "message": {"role": "assistant", "stop_reason": "end_turn", "content": [{"type": "text", "text": text}]}});
    append(&file, &[user("fix the build"), assistant("done")]);
    backdate(&file);
    let s = c.request(method::SESSION_NEW, watch("fakeclaude", &id)).await.unwrap();
    let sid = s["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(until_prompts(&hub, &sid, 1).await, ["fix the build"]);
    assert_eq!(answers(&hub, &sid), ["done"]);
    let k = kinds(&hub, &sid);
    assert!(k.iter().any(|k| k == "turn_result"), "the ended turn settles: {k:?}");
    append(&file, &[user("now the tests")]);
    assert_eq!(until_prompts(&hub, &sid, 2).await, ["fix the build", "now the tests"]);
    let _ = std::fs::remove_dir_all(&root);
}

/// A watched chat runs in another app: acpmux never started it, so how it runs (its launcher,
/// its autocompact cap) is unknown, never "no cap", while what its transcript says is read.
/// (`a_watched_claude_chat_shows_prompts_and_answers` keeps its store out of reach.)
#[tokio::test]
async fn a_watched_chats_launcher_and_cap_are_unknown_not_none() {
    let (hub, mut c, root) = watch_setup().await;
    let id = uuid::Uuid::now_v7().to_string();
    let project = root.join("project");
    let file = root.join(format!("claude/projects/-tmp-watch/{id}.jsonl"));
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    // Days old: its call is still the context, and its whole file read says the last day spent 0.
    let at = "2026-10-18T09:00:01.000Z";
    let user = json!({"type": "user", "cwd": project, "sessionId": id, "timestamp": at, "message": {"role": "user", "content": "hi"}});
    let reply = json!({"type": "assistant", "cwd": project, "sessionId": id, "timestamp": at, "message": {
        "id": "msg_1", "role": "assistant", "model": "claude-opus-5-5", "content": [{"type": "text", "text": "yo"}],
        "usage": {"input_tokens": 5, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 100, "output_tokens": 7}}});
    append(&file, &[user, reply]);
    backdate(&file);
    let s = c.request(method::SESSION_NEW, watch("homedclaude", &id)).await.unwrap();
    let sid = s["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(until_prompts(&hub, &sid, 1).await, ["hi"]);
    let list = c.request(method::MUX_SESSIONS, json!({"usage": true})).await.unwrap();
    let row = list["sessions"].as_array().unwrap().iter().find(|r| r["sessionId"] == sid).cloned();
    let stats = row.unwrap()["usageStats"].clone();
    assert_eq!(stats["autocompact"], "unknown", "{stats}");
    assert_eq!(
        (&stats["autocompactCap"], &stats["launcher"]),
        (&Value::Null, &Value::Null),
        "{stats}"
    );
    assert_eq!((&stats["contextTokens"], &stats["tokens24h"]), (&json!(105), &json!(0)), "{stats}");
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn taking_over_a_watched_chat_lets_it_run_the_conversation() {
    let (hub, mut c, root) = watch_setup().await;
    let id = uuid::Uuid::now_v7().to_string();
    let rollout =
        root.join(format!("codex/sessions/2026/10/18/rollout-2026-10-18T09-00-00-{id}.jsonl"));
    std::fs::create_dir_all(rollout.parent().unwrap()).unwrap();
    append(
        &rollout,
        &[
            json!({"type": "session_meta", "payload": {"id": id, "cwd": root.join("project")}}),
            codex_event("user_message", "earlier"),
        ],
    );
    backdate(&rollout);
    let s = c.request(method::SESSION_NEW, watch("fakecodex", &id)).await.unwrap();
    let sid = s["sessionId"].as_str().unwrap().to_owned();
    until_prompts(&hub, &sid, 1).await;
    let taken = c.request("_acpmux/watch_take_over", json!({"sessionId": sid})).await.unwrap();
    assert!(taken["watching"].is_null(), "{taken}");
    let r = c.request(method::SESSION_PROMPT, prompt(&sid, "carry on", None)).await.unwrap();
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    assert_eq!(prompts(&hub, &sid), ["earlier", "carry on"]);
    let _ = std::fs::remove_dir_all(&root);
}

/// Nothing starts the agent on a watched conversation before Take Over: not the pane's warm-up
/// (`_acpmux/warm`), and not a mode or model change from the composer's pickers.
#[tokio::test]
async fn warming_or_changing_mode_starts_no_agent_on_a_watched_chat() {
    let (hub, mut c, root) = watch_setup().await;
    let id = uuid::Uuid::now_v7().to_string();
    let rollout =
        root.join(format!("codex/sessions/2026/10/18/rollout-2026-10-18T09-00-00-{id}.jsonl"));
    std::fs::create_dir_all(rollout.parent().unwrap()).unwrap();
    append(
        &rollout,
        &[
            json!({"type": "session_meta", "payload": {"id": id, "cwd": root.join("project")}}),
            codex_event("user_message", "first prompt"),
        ],
    );
    let before = snapshot(&root.join("codex"));
    let s = c.request(method::SESSION_NEW, watch("fakecodex", &id)).await.unwrap();
    let sid = s["sessionId"].as_str().unwrap().to_owned();
    until_prompts(&hub, &sid, 1).await;
    let warmed = c.request(method::MUX_WARM, json!({"sessionIds": [sid]})).await.unwrap();
    assert!(!warmed.to_string().contains(&sid), "a watched chat is not warmed: {warmed}");
    let mode =
        c.request(method::SESSION_SET_MODE, json!({"sessionId": sid, "modeId": "default"})).await;
    assert!(mode.as_ref().is_err_and(|e| e.contains("watch.read_only")), "{mode:?}");
    let k = kinds(&hub, &sid);
    assert!(!k.iter().any(|k| k == "initialize" || k == "session/load"), "{k:?}");
    assert_eq!(snapshot(&root.join("codex")), before);
    let _ = std::fs::remove_dir_all(&root);
}

/// Claude Code writes a message's thinking and its text as separate lines with the same stop
/// reason: the turn ends with the text, so the answer is inside it. Take Over settles a turn the
/// other app left open.
#[tokio::test]
async fn a_claude_turn_ends_with_its_text_and_take_over_settles_an_open_one() {
    let (hub, mut c, root) = watch_setup().await;
    let id = uuid::Uuid::now_v7().to_string();
    let project = root.join("project");
    let file = root.join(format!("claude/projects/-tmp-watch/{id}.jsonl"));
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let user = |text: &str| json!({"type": "user", "cwd": project, "sessionId": id, "timestamp": "2026-10-18T09:00:00.000Z", "message": {"role": "user", "content": text}});
    let block = |content: Value| json!({"type": "assistant", "cwd": project, "sessionId": id, "timestamp": "2026-10-18T09:00:01.000Z", "message": {"id": "m1", "role": "assistant", "stop_reason": "end_turn", "content": [content]}});
    append(
        &file,
        &[
            user("fix the build"),
            block(json!({"type": "thinking", "thinking": "look at the log"})),
            block(json!({"type": "text", "text": "done"})),
            user("now the tests"),
        ],
    );
    backdate(&file);
    let s = c.request(method::SESSION_NEW, watch("fakeclaude", &id)).await.unwrap();
    let sid = s["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(until_prompts(&hub, &sid, 2).await, ["fix the build", "now the tests"]);
    let k = kinds(&hub, &sid);
    let answer = k.iter().position(|k| k == "agent_message_chunk").expect("the answer is shown");
    let first_end = k.iter().position(|k| k == "turn_end").expect("the first turn ends");
    assert!(answer < first_end, "the answer is inside its turn: {k:?}");
    // The second prompt's turn is still open; Take Over settles it.
    let ends = |hub: &Hub| kinds(hub, &sid).iter().filter(|k| *k == "turn_result").count();
    assert_eq!(ends(&hub), 1);
    c.request("_acpmux/watch_take_over", json!({"sessionId": sid})).await.unwrap();
    assert_eq!(ends(&hub), 2);
    let _ = std::fs::remove_dir_all(&root);
}

/// Viewing never blocks starting a session (Leo 2026-10-19): while a Claude Code chat is viewed, a
/// new chat in the same folder runs, and Continue in New Chat (adopt with `ifLive: "fork"`) starts
/// a new chat from the conversation instead of returning the viewed one, which goes on viewing.
#[tokio::test]
async fn viewing_a_chat_never_blocks_starting_a_new_one() {
    let (hub, mut c, root) = watch_setup().await;
    let id = uuid::Uuid::now_v7().to_string();
    let project = root.join("project");
    let file = root.join(format!("claude/projects/-tmp-watch/{id}.jsonl"));
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let user = json!({"type": "user", "cwd": project, "sessionId": id, "timestamp": "2026-10-18T09:00:00.000Z", "message": {"role": "user", "content": "fix the build"}});
    append(&file, &[user]);
    backdate(&file);
    let s = c.request(method::SESSION_NEW, watch("fakeclaude", &id)).await.unwrap();
    let viewed = s["sessionId"].as_str().unwrap().to_owned();
    until_prompts(&hub, &viewed, 1).await;

    // A new chat in the same folder starts and runs.
    let fresh = c
        .request(method::SESSION_NEW, json!({"cwd": project, "mcpServers": [], "_meta": {"acpmux": {"harness": "fakecodex"}}}))
        .await
        .unwrap();
    let fresh = fresh["sessionId"].as_str().unwrap().to_owned();
    assert_ne!(fresh, viewed);
    let r = c.request(method::SESSION_PROMPT, prompt(&fresh, "hello", None)).await.unwrap();
    assert_eq!(r["stopReason"], "end_turn", "{r}");

    // Continue in New Chat: a fork of the viewed conversation is its own chat.
    let adopt = json!({"agentSessionId": id, "ifLive": "fork"});
    let forked = c
        .request(method::SESSION_NEW, json!({"mcpServers": [], "_meta": {"acpmux": {"harness": "fakeclaude", "adopt": adopt}}}))
        .await
        .unwrap();
    let forked = forked["sessionId"].as_str().unwrap().to_owned();
    assert_ne!(forked, viewed, "a fork is a new chat, not the viewed one");
    let r = c.request(method::SESSION_PROMPT, prompt(&forked, "carry on", None)).await.unwrap();
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    let summary = hub.session_summary(&hub.resolve(&viewed).unwrap());
    assert_eq!(summary["watching"], "claude", "the viewed chat goes on viewing: {summary}");
    let _ = std::fs::remove_dir_all(&root);
}
