//! A chat with no ACP resume shows its past (cx-5esm): `_acpmux/chat_transcript {key}` reads the
//! person's prompts and the assistant's answers from the harness's own store, on the local
//! socket only (`chats.rs` websocket_origins_never_get_chats). Synthetic temp homes only.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::chats::ChatSources;
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const DROID_ID: &str = "4f1c2a3b-5d6e-4f70-8a9b-0c1d2e3f4a5b";
const CONTINUE_ID: &str = "7a8b9c0d-1e2f-4a3b-8c4d-5e6f7a8b9c0d";
const AMP_ID: &str = "T-0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b";
const CLAUDE_ID: &str = "5b6c7d8e-9f0a-4b1c-8d2e-3f4a5b6c7d8e";
const CODEX_ID: &str = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5c";
const BROKEN_AMP_ID: &str = "T-0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5d";

struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn home() -> Home {
    // Under /tmp, not the temp dir: a worker's temp dir may be on another volume (`/Volumes`),
    // where no chat root is ever listed.
    let base = PathBuf::from("/tmp").join(format!("acpmux-transcript-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&base).expect("home");
    Home(std::fs::canonicalize(&base).expect("canonical home"))
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().expect("parent")).expect("dirs");
    std::fs::write(path, text).expect("write");
}

/// A Droid chat: a tool round trip and an injected reminder inside it.
fn droid(h: &Path, project: &Path) {
    let lines = [
        json!({"type": "session_start", "id": DROID_ID, "title": "Droid chat", "cwd": project}),
        json!({"type": "message", "timestamp": "2026-10-02T09:00:01Z", "message": {"role": "user", "content": [{"type": "text", "text": "Fix the build"}]}}),
        json!({"type": "message", "timestamp": "2026-10-02T09:00:05Z", "message": {"role": "assistant", "content": [{"type": "text", "text": "Looking."}, {"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}]}}),
        json!({"type": "message", "timestamp": "2026-10-02T09:00:06Z", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]}}),
        json!({"type": "message", "timestamp": "2026-10-02T09:00:09Z", "message": {"role": "assistant", "content": [{"type": "text", "text": "Fixed it."}]}}),
        json!({"type": "message", "timestamp": "2026-10-02T09:01:00Z", "message": {"role": "user", "content": "<system-reminder>context</system-reminder>"}}),
        json!({"type": "message", "timestamp": "2026-10-02T09:01:01Z", "message": {"role": "user", "content": "Thanks"}}),
        json!({"type": "message", "timestamp": "2026-10-02T09:01:02Z", "message": {"role": "assistant", "content": "You're welcome."}}),
    ];
    let text: String = lines.iter().map(|line| format!("{line}\n")).collect();
    write(&h.join(format!(".factory/sessions/-work-api/{DROID_ID}.jsonl")), &text);
}

fn continue_dev(h: &Path, project: &Path) {
    let session = json!({"sessionId": CONTINUE_ID, "title": "Continue chat", "workspaceDirectory": project, "history": [
        {"message": {"role": "user", "content": "Add a test"}},
        {"message": {"role": "assistant", "content": "Added one."}},
        {"message": {"role": "user", "content": "<div> renders wrong"}},
        {"message": {"role": "assistant", "content": "Fixed the div."}},
    ]});
    write(&h.join(format!(".continue/sessions/{CONTINUE_ID}.json")), &session.to_string());
}

fn amp(h: &Path, project: &Path) {
    let thread = json!({"v": 1, "id": AMP_ID, "created": 1_790_000_000_000_i64, "title": "Amp chat",
    "env": {"initial": {"trees": [{"uri": format!("file://{}", project.display())}]}},
    "messages": [
        {"role": "user", "content": [{"type": "text", "text": "Rename x"}]},
        {"role": "assistant", "content": [{"type": "thinking", "thinking": "hm"}, {"type": "text", "text": "Renamed."}]},
    ]});
    write(&h.join(format!(".local/share/amp/threads/{AMP_ID}.json")), &thread.to_string());
}

/// An Amp thread cut short mid-write: still listed (untitled), but not JSON.
fn amp_broken(h: &Path) {
    let text =
        r#"{"v": 1, "id": "T-0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5d", "messages": [{"role": "us"#;
    write(&h.join(format!(".local/share/amp/threads/{BROKEN_AMP_ID}.json")), text);
}

/// A Claude Code chat (one a client shows read-only before its first send when it cannot adopt).
fn claude(h: &Path, project: &Path) {
    let line = |kind: &str, content: Value, at: &str| {
        json!({"type": kind, "isSidechain": false, "cwd": project, "sessionId": CLAUDE_ID,
               "timestamp": at, "message": {"role": kind, "content": content}})
    };
    let lines = [
        line("user", json!("Explain the parser"), "2026-10-02T09:00:00.000Z"),
        line(
            "assistant",
            json!([{"type": "text", "text": "It reads lines."}]),
            "2026-10-02T09:00:02.000Z",
        ),
        // A background task's notification, as Claude Code records it: a user line with a
        // non-human origin. Claude Code wrote it, not the person.
        {
            let mut notice = line(
                "user",
                json!(
                    "<task-notification>\n<task-id>a1</task-id>\n<status>completed</status>\n<summary>Agent \"Map\" finished</summary>\n</task-notification>"
                ),
                "2026-10-02T09:00:03.000Z",
            );
            notice["origin"] = json!({"kind": "task-notification", "producer": "session-task"});
            notice
        },
    ];
    let text: String = lines.iter().map(|line| format!("{line}\n")).collect();
    write(&h.join(format!(".claude/projects/-work-api/{CLAUDE_ID}.jsonl")), &text);
}

fn codex(h: &Path, project: &Path) {
    let lines = [
        json!({"type": "session_meta", "payload": {"id": CODEX_ID, "cwd": project, "timestamp": "2026-10-02T09:00:00Z"}}),
        json!({"type": "event_msg", "timestamp": "2026-10-02T09:00:01Z", "payload": {"type": "user_message", "message": "Bump the version"}}),
        json!({"type": "event_msg", "timestamp": "2026-10-02T09:00:03Z", "payload": {"type": "agent_message", "message": "Bumped to 1.2."}}),
    ];
    let text: String = lines.iter().map(|line| format!("{line}\n")).collect();
    let name = format!("sessions/2026/10/02/rollout-2026-10-02T09-00-00-{CODEX_ID}.jsonl");
    write(&h.join(".codex").join(name), &text);
}

async fn hub_on(h: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({"harnesses": {}})).expect("config");
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).expect("store");
    let hub = Hub::new(cfg, store);
    let sources = ChatSources {
        home: h.to_path_buf(),
        acpmux_home: h.join(".acpmux"),
        env: Arc::new(|_| None),
        launch_roots: Vec::new(),
        user_roots: Vec::new(),
    };
    hub.start_chats(sources).await.expect("chat index");
    hub
}

/// A connection of `origin`; returns a call function's channel pair.
async fn connect(hub: &Arc<Hub>, origin: Origin) -> (mpsc::Sender<String>, mpsc::Receiver<String>) {
    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
    call(&tx, &mut rx, 1, method::INITIALIZE, hello).await;
    (tx, rx)
}

async fn call(
    tx: &mpsc::Sender<String>,
    rx: &mut mpsc::Receiver<String>,
    id: i64,
    m: &str,
    params: Value,
) -> Value {
    tx.send(Message::request(id, m, params).to_line()).await.expect("send");
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), rx.recv())
            .await
            .expect("answer in time")
            .expect("connection open");
        let v: Value = serde_json::from_str(&line).expect("json");
        if v.get("id") == Some(&json!(id)) {
            return v;
        }
    }
}

fn turns(answer: &Value) -> Vec<(String, String)> {
    let rows = answer["result"]["turns"].as_array().unwrap_or_else(|| panic!("{answer}"));
    rows.iter()
        .map(|t| {
            (t["prompt"].as_str().unwrap_or("").into(), t["answer"].as_str().unwrap_or("").into())
        })
        .collect()
}

fn pair(prompt: &str, answer: &str) -> (String, String) {
    (prompt.into(), answer.into())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_chat_with_no_acp_resume_gives_its_prompts_and_answers_on_the_local_socket_only() {
    let h = home();
    let project = h.0.join("work/api");
    std::fs::create_dir_all(&project).expect("project");
    droid(&h.0, &project);
    continue_dev(&h.0, &project);
    amp(&h.0, &project);
    claude(&h.0, &project);
    codex(&h.0, &project);
    amp_broken(&h.0);
    let hub = hub_on(&h.0).await;
    let (tx, mut rx) = connect(&hub, Origin::Local).await;

    // Tool calls, tool results and injected context are not the conversation.
    let droid = call(
        &tx,
        &mut rx,
        2,
        "_acpmux/chat_transcript",
        json!({"key": format!("droid:{DROID_ID}")}),
    )
    .await;
    assert_eq!(
        turns(&droid),
        [pair("Fix the build", "Looking.\n\nFixed it."), pair("Thanks", "You're welcome.")]
    );
    assert_eq!(droid["result"]["title"], "Droid chat", "{droid}");
    assert_eq!(droid["result"]["harness"], "droid");
    assert!(droid["result"]["turns"][0]["promptAt"].is_u64(), "{droid}");

    let cont = call(
        &tx,
        &mut rx,
        3,
        "_acpmux/chat_transcript",
        json!({"key": format!("continue:{CONTINUE_ID}")}),
    )
    .await;
    // A prompt that starts with markup is the person's own (only whole tag blocks are context).
    assert_eq!(
        turns(&cont),
        [pair("Add a test", "Added one."), pair("<div> renders wrong", "Fixed the div.")]
    );
    let amp =
        call(&tx, &mut rx, 4, "_acpmux/chat_transcript", json!({"key": format!("amp:{AMP_ID}")}))
            .await;
    assert_eq!(turns(&amp), [pair("Rename x", "Renamed.")]);

    // Claude Code and Codex chats too (a chat that cannot adopt shows them before its first send).
    // A task notification Claude Code wrote into the chat is not a prompt.
    let key = format!("claude-code:{CLAUDE_ID}");
    let claude = call(&tx, &mut rx, 6, "_acpmux/chat_transcript", json!({"key": key})).await;
    assert_eq!(turns(&claude), [pair("Explain the parser", "It reads lines.")]);
    let key = format!("codex:{CODEX_ID}");
    let codex = call(&tx, &mut rx, 7, "_acpmux/chat_transcript", json!({"key": key})).await;
    assert_eq!(turns(&codex), [pair("Bump the version", "Bumped to 1.2.")]);

    // A chat whose file went bad or went away says so, never "no turns" or "too large".
    let key = format!("amp:{BROKEN_AMP_ID}");
    let broken = call(&tx, &mut rx, 8, "_acpmux/chat_transcript", json!({"key": key})).await;
    assert_eq!(broken["error"]["data"]["reason"], "transcript_unreadable", "{broken}");
    std::fs::remove_file(h.0.join(format!(".claude/projects/-work-api/{CLAUDE_ID}.jsonl")))
        .expect("remove the claude chat");
    let key = format!("claude-code:{CLAUDE_ID}");
    let gone = call(&tx, &mut rx, 9, "_acpmux/chat_transcript", json!({"key": key})).await;
    // Unreadable, or not found once the index saw the file go.
    let reason = &gone["error"]["data"]["reason"];
    assert!(
        gone["error"].is_object() && (reason.is_null() || reason == "transcript_unreadable"),
        "{gone}"
    );

    let unknown =
        call(&tx, &mut rx, 5, "_acpmux/chat_transcript", json!({"key": "droid:nope"})).await;
    assert!(unknown["error"].is_object(), "{unknown}");
    // Remote origins never read a chat's text (`chats.rs` websocket_origins_never_get_chats).
}

const COPILOT_ID: &str = "3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f";
const AUGGIE_ID: &str = "9e8d7c6b-5a49-4382-9716-05f4e3d2c1b0";
const GOOSE_ID: &str = "20261002_1";
const CRUSH_ID: &str = "6a5b4c3d-2e1f-4a0b-9c8d-7e6f5a4b3c2d";

/// A Copilot CLI (v3) chat: a tool round trip between the prompt and the answer.
fn copilot(h: &Path, project: &Path) {
    let event =
        |kind: &str, at: &str, data: Value| json!({"type": kind, "timestamp": at, "data": data});
    let lines = [
        event(
            "session.start",
            "2026-10-02T09:00:00Z",
            json!({"sessionId": COPILOT_ID, "context": {"cwd": project}}),
        ),
        event(
            "user.message",
            "2026-10-02T09:00:01Z",
            json!({"content": "List the tests", "transformedContent": "<ctx/>List the tests"}),
        ),
        event(
            "assistant.message",
            "2026-10-02T09:00:02Z",
            json!({"content": "", "toolRequests": [{"name": "bash"}]}),
        ),
        event("tool.execution_complete", "2026-10-02T09:00:03Z", json!({"result": "ok"})),
        event("assistant.message", "2026-10-02T09:00:04Z", json!({"content": "There are three."})),
    ];
    let text: String = lines.iter().map(|line| format!("{line}\n")).collect();
    write(&h.join(format!(".copilot/session-state/{COPILOT_ID}/events.jsonl")), &text);
}

fn auggie(h: &Path) {
    let session = json!({"sessionId": AUGGIE_ID, "created": "2026-10-02T09:00:00Z", "modified": "2026-10-02T09:00:05Z",
        "chatHistory": [{"exchange": {"request_message": "Find the bug", "response_text": "It is in main.rs."},
                         "finishedAt": "2026-10-02T09:00:05Z"},
                        {"exchange": {"request_message": "", "response_text": "Fixed.",
                                      "request_nodes": [{"type": 0, "text_node": {"content": "Now fix it"}}]}}]});
    write(&h.join(format!(".augment/sessions/{AUGGIE_ID}.json")), &session.to_string());
}

/// Runs `script` (Python, `sqlite3` imported) with the database path as `db`.
fn sqlite(db: &Path, script: &str) {
    std::fs::create_dir_all(db.parent().expect("parent")).expect("dirs");
    let code =
        format!("import sqlite3, sys\ndb = sqlite3.connect(sys.argv[1])\n{script}\ndb.commit()\n");
    let status = std::process::Command::new("python3")
        .args(["-c", &code])
        .arg(db)
        .status()
        .expect("python3");
    assert!(status.success(), "sqlite fixture {}", db.display());
}

/// A goose chat in its `sessions.db`: tool calls, tool results and a hidden message around it.
fn goose(h: &Path, project: &Path) {
    let rows = json!([
        ["user", [{"type": "text", "text": "Add logging"}], true],
        ["assistant", [{"type": "text", "text": "Adding it."}, {"type": "toolRequest", "id": "t1"}], true],
        ["user", [{"type": "toolResponse", "id": "t1"}], true],
        ["assistant", [{"type": "text", "text": "Done."}], true],
        ["user", [{"type": "text", "text": "internal"}], false],
    ]);
    let script = format!(
        r#"db.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT, description TEXT, working_dir TEXT, created_at TIMESTAMP, updated_at TIMESTAMP)")
db.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content_json TEXT, created_timestamp INTEGER, metadata_json TEXT)")
db.execute("INSERT INTO sessions VALUES (?, 'Goose chat', '', ?, '2026-10-02 09:00:00', '2026-10-02 09:01:00')", ("{GOOSE_ID}", {cwd:?}))
import json
for i, (role, content, visible) in enumerate(json.loads({rows:?})):
    db.execute("INSERT INTO messages (session_id, role, content_json, created_timestamp, metadata_json) VALUES (?, ?, ?, ?, ?)",
               ("{GOOSE_ID}", role, json.dumps(content), 1790931600 + i, json.dumps({{"userVisible": visible}})))"#,
        cwd = project.display().to_string(),
        rows = rows.to_string(),
    );
    // Another chat in the same store stays out of this one.
    let script = format!(
        r#"{script}
db.execute("INSERT INTO sessions VALUES ('20261002_2', 'Other', '', '/', '2026-10-02 10:00:00', '2026-10-02 10:00:00')")
db.execute("INSERT INTO messages (session_id, role, content_json, created_timestamp, metadata_json) VALUES ('20261002_2', 'user', '[{{\"type\": \"text\", \"text\": \"Other chat\"}}]', 1790931700, '{{}}')")"#
    );
    sqlite(&h.join(".local/share/goose/sessions/sessions.db"), &script);
}

/// A Crush chat in its project's `.crush/crush.db`, listed by the global `projects.json`.
fn crush(h: &Path, project: &Path) {
    let index = json!({"projects": [{"path": project, "data_dir": ".crush"}]});
    write(&h.join(".local/share/crush/projects.json"), &index.to_string());
    let rows = json!([
        ["user", [{"type": "text", "data": {"text": "Explain the cache"}}]],
        ["assistant", [{"type": "reasoning", "data": {"thinking": "hm"}}, {"type": "text", "data": {"text": "It memoizes."}}, {"type": "finish", "data": {"reason": "end_turn"}}]],
        ["tool", [{"type": "tool_result", "data": {"content": "x"}}, {"type": "text", "data": {"text": "tool says"}}]],
    ]);
    let script = format!(
        r#"db.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, parent_session_id TEXT, title TEXT, message_count INTEGER, created_at INTEGER, updated_at INTEGER)")
db.execute("CREATE TABLE messages (id TEXT PRIMARY KEY, session_id TEXT, role TEXT, parts TEXT, created_at INTEGER)")
db.execute("INSERT INTO sessions VALUES (?, NULL, 'Crush chat', 2, 1790931600, 1790931660)", ("{CRUSH_ID}",))
import json
for i, (role, parts) in enumerate(json.loads({rows:?})):
    db.execute("INSERT INTO messages VALUES (?, ?, ?, ?, ?)", ("m%d" % i, "{CRUSH_ID}", role, json.dumps(parts), 1790931600 + i))"#,
        rows = rows.to_string(),
    );
    sqlite(&project.join(".crush/crush.db"), &script);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn copilot_auggie_goose_and_crush_chats_give_their_prompts_and_answers() {
    let h = home();
    let project = h.0.join("work/api");
    std::fs::create_dir_all(&project).expect("project");
    copilot(&h.0, &project);
    auggie(&h.0);
    goose(&h.0, &project);
    crush(&h.0, &project);
    let hub = hub_on(&h.0).await;
    let (tx, mut rx) = connect(&hub, Origin::Local).await;
    // An Auggie prompt kept only in its request nodes is still its own turn.
    let chats = [
        (format!("copilot-cli:{COPILOT_ID}"), vec![pair("List the tests", "There are three.")]),
        (
            format!("auggie:{AUGGIE_ID}"),
            vec![pair("Find the bug", "It is in main.rs."), pair("Now fix it", "Fixed.")],
        ),
        (format!("goose:{GOOSE_ID}"), vec![pair("Add logging", "Adding it.\n\nDone.")]),
        (format!("crush:{CRUSH_ID}"), vec![pair("Explain the cache", "It memoizes.")]),
    ];
    for (id, (key, expected)) in (11..).zip(chats) {
        let answer = call(&tx, &mut rx, id, "_acpmux/chat_transcript", json!({"key": key})).await;
        assert_eq!(turns(&answer), expected, "{key}: {answer}");
    }
}

/// A Codex chat begun on an older Codex (event messages, beside unannotated message items) and
/// resumed on a current one, which writes no event messages: only `response_item` messages, with
/// injected instructions and the model's progress notes among them.
fn codex_current(h: &Path, project: &Path, id: &str) {
    let message = |role: &str, kinds: &[&str], text: &str, phase: Option<&str>| {
        let kind = if role == "assistant" { "output_text" } else { "input_text" };
        let mut payload = json!({"type": "message", "role": role,
            "content": [{"type": kind, "text": text}],
            "internal_chat_message_metadata_passthrough": {"content_item_kinds": kinds}});
        if let Some(phase) = phase {
            payload["phase"] = json!(phase);
        }
        json!({"type": "response_item", "timestamp": "2026-10-02T09:00:01Z", "payload": payload})
    };
    let event = |kind: &str, text: &str| {
        json!({"type": "event_msg", "timestamp": "2026-10-01T09:00:01Z",
               "payload": {"type": kind, "message": text}})
    };
    let legacy = |role: &str, text: &str| {
        json!({"type": "response_item", "timestamp": "2026-10-01T09:00:01Z",
               "payload": {"type": "message", "role": role,
                           "content": [{"type": "input_text", "text": text}]}})
    };
    let image_prompt = json!({"type": "response_item", "timestamp": "2026-10-02T09:00:05Z",
        "payload": {"type": "message", "role": "user",
            "content": [{"type": "input_text", "text": "What is in this picture?"},
                        {"type": "input_image", "image_url": "data:image/png;base64,AAAA"}],
            "internal_chat_message_metadata_passthrough": {"content_item_kinds": ["user.text", "user.image"]}}});
    let lines = [
        json!({"type": "session_meta", "payload": {"id": id, "cwd": project, "timestamp": "2026-10-01T09:00:00Z"}}),
        legacy("user", "Start the project"),
        event("user_message", "Start the project"),
        legacy("assistant", "Started."),
        event("agent_message", "Started."),
        message("developer", &["host_skills.instructions"], "<skills_instructions>", None),
        message(
            "user",
            &["agents_md.instructions", "environments.environment_context"],
            "# AGENTS.md instructions for /work/api",
            None,
        ),
        message("user", &["user.text"], "Bump the version", None),
        message("assistant", &["unknown"], "Reading Cargo.toml.", Some("commentary")),
        json!({"type": "event_msg", "timestamp": "2026-10-02T09:00:02Z",
               "payload": {"type": "item_completed", "turn_id": "t1", "item": {"type": "reasoning"}}}),
        message("assistant", &["unknown"], "Bumped to 1.2.", Some("final_answer")),
        image_prompt,
        message("assistant", &["unknown"], "A cat.", Some("final_answer")),
        message("user", &["user.text"], "Thanks", None),
        message("assistant", &["unknown"], "You're welcome.", Some("final_answer")),
    ];
    let text: String = lines.iter().map(|line| format!("{line}\n")).collect();
    let name = format!("sessions/2026/10/02/rollout-2026-10-02T09-00-00-{id}.jsonl");
    write(&h.join(".codex").join(name), &text);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_current_codex_chat_gives_its_prompts_and_final_answers() {
    const ID: &str = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a6e";
    let h = home();
    let project = h.0.join("work/api");
    std::fs::create_dir_all(&project).expect("project");
    codex_current(&h.0, &project, ID);
    let hub = hub_on(&h.0).await;
    let (tx, mut rx) = connect(&hub, Origin::Local).await;

    // What adopting replays too (`Hub::replay_adopted` reads the same turns).
    let key = format!("codex:{ID}");
    let answer = call(&tx, &mut rx, 2, "_acpmux/chat_transcript", json!({"key": key})).await;
    assert_eq!(
        turns(&answer),
        [
            pair("Start the project", "Started."),
            pair("Bump the version", "Bumped to 1.2."),
            pair("What is in this picture?", "A cat."),
            pair("Thanks", "You're welcome.")
        ],
        "{answer}"
    );
}
