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

/// A FIFO for the fake agent's `gate:` turn.
fn gate_fifo() -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!("acpmux-release-{}", uuid::Uuid::now_v7()));
    assert!(std::process::Command::new("mkfifo").arg(&path).status().unwrap().success());
    path
}

/// A Claude Code chat acpmux runs, mid-turn on a `gate:` FIFO, with its transcript in the
/// test's Claude store as Claude Code keeps it: (hub, chat, its transcript, the gate, the
/// prompt's pending answer, the gate prompt's text).
async fn chat_mid_turn() -> (
    Arc<Hub>,
    String,
    std::path::PathBuf,
    std::path::PathBuf,
    tokio::task::JoinHandle<Result<Value, String>>,
    String,
    std::path::PathBuf,
) {
    let (hub, mut c, root) = watch_setup().await;
    let project = root.join("project");
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": project, "mcpServers": [], "_meta": {"acpmux": {"harness": "fakeclaude"}}}),
        )
        .await
        .unwrap();
    let sid = s["sessionId"].as_str().unwrap().to_owned();
    let gate = gate_fifo();
    let text = format!("gate: {}", gate.display());
    let mut runner = connect(&hub).await;
    let p = prompt(&sid, &text, None);
    let turn = tokio::spawn(async move { runner.request(method::SESSION_PROMPT, p).await });
    // The turn runs: its first piece is shown.
    for _ in 0..200 {
        if answers(&hub, &sid).iter().any(|a| a == "before-gate") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    assert_eq!(answers(&hub, &sid), ["before-gate"]);
    let asid = hub.session_summary(&hub.resolve(&sid).unwrap())["agentSessionId"]
        .as_str()
        .expect("the chat has its conversation id")
        .to_owned();
    // What Claude Code wrote of this conversation so far: already shown in the chat.
    let file = root.join(format!("claude/projects/-tmp-release/{asid}.jsonl"));
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    append(&file, &[claude_user(&project, &asid, &text)]);
    (hub, sid, file, gate, turn, text, root)
}

fn claude_user(project: &std::path::Path, id: &str, text: &str) -> Value {
    json!({"type": "user", "cwd": project, "sessionId": id, "timestamp": "2026-11-14T09:00:00.000Z", "message": {"role": "user", "content": text}})
}

fn claude_answer(project: &std::path::Path, id: &str, text: &str) -> Value {
    json!({"type": "assistant", "cwd": project, "sessionId": id, "timestamp": "2026-11-14T09:00:01.000Z", "message": {"role": "assistant", "stop_reason": "end_turn", "content": [{"type": "text", "text": text}]}})
}

/// Toggle Terminal and Chat mid-turn (Leo, 2026-11-12: two live views of one session, instant
/// both ways, mid-turn): the release waits for the turn instead of cutting it, a prompt sent
/// meanwhile is refused (never lost), and then the same chat watches the transcript the
/// terminal appends to. Every message shows exactly once, in order, in the one chat.
#[tokio::test]
async fn a_chat_released_mid_turn_finishes_its_turn_then_follows_the_terminal() {
    let (hub, sid, file, gate, turn, text, root) = chat_mid_turn().await;
    let project = root.join("project");
    let asid = file.file_stem().unwrap().to_string_lossy().into_owned();
    let mut terminal = connect(&hub).await;
    let r = json!({"sessionId": sid});
    let release =
        tokio::spawn(async move { terminal.request("_acpmux/release_to_watch", r).await });
    // The turn is not cut: the release waits for it.
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!release.is_finished(), "the release must wait for the running turn");
    assert!(hub.session_summary(&hub.resolve(&sid).unwrap())["watching"].is_null());
    // A prompt sent from the chat meanwhile is refused, not queued and lost.
    let mut chat = connect(&hub).await;
    let refused = chat.request(method::SESSION_PROMPT, prompt(&sid, "meanwhile", None)).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("watch.releasing")), "{refused:?}");
    // A second terminal does not take it twice.
    let twice = chat.request("_acpmux/release_to_watch", json!({"sessionId": sid})).await;
    assert!(twice.as_ref().is_err_and(|e| e.contains("watch.release_pending")), "{twice:?}");
    // The turn ends on its own, whole.
    std::fs::write(&gate, "go").unwrap();
    let answered = turn.await.unwrap().unwrap();
    assert_eq!(answered["stopReason"], "end_turn", "{answered}");
    // Claude Code writes the turn's answer as it ends; the release reads past it.
    append(&file, &[claude_answer(&project, &asid, "before-gate after-gate")]);
    let released = tokio::time::timeout(Duration::from_secs(10), release)
        .await
        .expect("the release answers once the turn ended")
        .unwrap()
        .unwrap();
    assert_eq!(released["session"]["watching"], "claude", "{released}");
    assert_eq!(released["resume"]["argv"], json!(["claude", "--resume", asid]), "{released}");
    assert_eq!(released["resume"]["cwd"], json!(project), "{released}");
    let k = kinds(&hub, &sid);
    assert!(!k.iter().any(|k| k == "turn_cancelled"), "the turn was not cut: {k:?}");
    // The terminal runs it now: what it appends shows in the same chat.
    append(
        &file,
        &[
            claude_user(&project, &asid, "from the terminal"),
            claude_answer(&project, &asid, "terminal answer"),
        ],
    );
    let shown = until_prompts(&hub, &sid, 2).await;
    for _ in 0..200 {
        if answers(&hub, &sid).len() >= 3 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    assert_eq!(shown, [text.as_str(), "from the terminal"]);
    assert_eq!(answers(&hub, &sid), ["before-gate", "after-gate", "terminal answer"]);
    // Nothing more comes later (no second read of the transcript).
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(prompts(&hub, &sid), [text.as_str(), "from the terminal"]);
    assert_eq!(answers(&hub, &sid).len(), 3);
    // The chat is a watch now: it takes no prompt; the terminal does.
    let watched = chat.request(method::SESSION_PROMPT, prompt(&sid, "late", None)).await;
    assert!(watched.as_ref().is_err_and(|e| e.contains("watch.read_only")), "{watched:?}");
    let _ = std::fs::remove_file(&gate);
    let _ = std::fs::remove_dir_all(&root);
}

/// How long a mid-turn hand-off takes from the turn's end to the chat watching, over 20 runs.
#[tokio::test]
async fn a_release_lands_right_after_the_turn_ends() {
    let mut took = Vec::new();
    for _ in 0..20 {
        let (hub, sid, file, gate, turn, _, root) = chat_mid_turn().await;
        let mut terminal = connect(&hub).await;
        let r = json!({"sessionId": sid});
        let release =
            tokio::spawn(async move { terminal.request("_acpmux/release_to_watch", r).await });
        tokio::time::sleep(Duration::from_millis(50)).await;
        let ended = std::time::Instant::now();
        std::fs::write(&gate, "go").unwrap();
        let released = release.await.unwrap().unwrap();
        took.push(ended.elapsed());
        turn.await.unwrap().unwrap();
        assert_eq!(released["session"]["watching"], "claude");
        let _ = (std::fs::remove_file(&gate), file);
        let _ = std::fs::remove_dir_all(&root);
    }
    took.sort();
    let (p50, p95) = (took[took.len() / 2], took[took.len() * 95 / 100]);
    eprintln!(
        "release_to_watch: turn end -> watching p50 {p50:?} p95 {p95:?} over {} runs",
        took.len()
    );
    assert!(p95 < Duration::from_secs(2), "p95 {p95:?}");
}

/// An idle chat is handed off at once; a chat whose conversation is in no store yet is refused.
#[tokio::test]
async fn an_idle_chat_is_released_at_once() {
    let (hub, sid, file, gate, turn, _, root) = chat_mid_turn().await;
    std::fs::write(&gate, "go").unwrap();
    turn.await.unwrap().unwrap();
    let mut c = connect(&hub).await;
    let mut took = Vec::new();
    let asked = std::time::Instant::now();
    let released = c.request("_acpmux/release_to_watch", json!({"sessionId": sid})).await.unwrap();
    took.push(asked.elapsed());
    assert_eq!(released["session"]["watching"], "claude", "{released}");
    // Again: already watching, nothing holds it, so the same answer.
    let again = c.request("_acpmux/release_to_watch", json!({"sessionId": sid})).await.unwrap();
    assert_eq!(again["resume"], released["resume"]);
    eprintln!("release_to_watch: idle chat -> watching {:?}", took[0]);
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": root.join("project"), "mcpServers": [], "_meta": {"acpmux": {"harness": "fakecodex"}}}),
        )
        .await
        .unwrap();
    let other = s["sessionId"].as_str().unwrap().to_owned();
    let refused = c.request("_acpmux/release_to_watch", json!({"sessionId": other})).await;
    assert!(refused.is_err(), "{refused:?}");
    let _ = (std::fs::remove_file(&gate), file);
    let _ = std::fs::remove_dir_all(&root);
}
