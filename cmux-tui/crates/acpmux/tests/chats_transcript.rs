//! A chat with no ACP resume shows its past (cx-5esm): `_acpmux/chat_transcript {key}` reads the
//! person's prompts and the assistant's answers from the harness's own store, on the local
//! socket only (`chats.rs` websocket_origins_never_get_chats). Synthetic temp homes only.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
// Only the opt-in browser acceptance test uses these build outputs and executable paths.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny().keep(&[
    "CMUX_HISTORY_BROWSER_BUN",
    "CMUX_HISTORY_PACKED_PAGES",
    "CMUX_HISTORY_WEBVIEWS", // The script passes webviews/ so no "../" literal makes it an input of acpmux's jobs.
    "CMUX_CHROME_HEADLESS_SHELL",
    "FAST_CHECKS_OUT", // Optional CI artifact directory for the two synthetic transcript screenshots.
]);

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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn terminal_agent_history_reads_and_finds_pre_resume_turns_without_adopting() {
    let h = home();
    let project = h.0.join("work/api");
    std::fs::create_dir_all(&project).expect("project");
    claude(&h.0, &project);
    codex(&h.0, &project);
    let file = h.0.join(format!(".claude/projects/-work-api/{CLAUDE_ID}.jsonl"));
    let mut more = String::new();
    for n in 0..80 {
        more.push_str(&format!("{}\n", json!({"type":"user","sessionId":CLAUDE_ID,"cwd":project,"message":{"role":"user","content":format!("turn {n}")}})));
        more.push_str(&format!("{}\n", json!({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":format!("answer {n}")}]}})));
    }
    use std::io::Write as _;
    std::fs::OpenOptions::new()
        .append(true)
        .open(file)
        .expect("transcript")
        .write_all(more.as_bytes())
        .expect("append");
    let hub = hub_on(&h.0).await;
    let (tx, mut rx) = connect(&hub, Origin::Local).await;
    let key = format!("claude-code:{CLAUDE_ID}");
    let page = "_acpmux/chat_transcript_page";
    let find = "_acpmux/chat_transcript_find";
    let meta = call(&tx, &mut rx, 2, page, json!({"key":key,"metadataOnly":true})).await;
    assert!(meta["result"]["createdMs"].is_number(), "{meta}");
    assert!(meta["result"].get("turns").is_none());
    let latest = call(&tx, &mut rx, 3, page, json!({"key":key})).await;
    let page_turns = turns(&latest);
    assert_eq!(page_turns.last(), Some(&pair("turn 79", "answer 79")));
    assert!(latest["result"]["before"].is_u64());
    let mut cursor = Value::Null;
    let mut hits = Vec::new();
    for n in 0..4 {
        let found =
            call(&tx, &mut rx, 4 + n, find, json!({"key":key,"query":"parser","before":cursor}))
                .await;
        hits.extend(found["result"]["hits"].as_array().expect("hits").iter().cloned());
        cursor = found["result"]["before"].clone();
        if cursor.is_null() {
            break;
        }
    }
    assert_eq!(hits.len(), 1, "{hits:?}");
    let hit = &hits[0];
    let first = call(&tx, &mut rx, 8, page, json!({"key":key,"before":hit["pageEnd"]})).await;
    assert_eq!(
        first["result"]["turns"][hit["turn"].as_u64().unwrap() as usize]["prompt"],
        "Explain the parser"
    );
    let codex =
        call(&tx, &mut rx, 9, find, json!({"key":format!("codex:{CODEX_ID}"),"query":"1.2."}))
            .await;
    assert_eq!(codex["result"]["hits"][0]["role"], "assistant", "{codex}");
    let wrong =
        call(&tx, &mut rx, 10, page, json!({"key":format!("claude-code:{CODEX_ID}")})).await;
    assert!(wrong.get("error").is_some(), "{wrong}");
    let path = call(&tx, &mut rx, 11, page, json!({"key":"claude-code:../../elsewhere"})).await;
    assert!(path.get("error").is_some(), "{path}");
    assert!(hub.sessions().is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn terminal_agent_history_finds_text_after_a_shortened_wire_preview() {
    let h = home();
    let cwd = Path::new("/work/api");
    let key = format!("claude-code:{CLAUDE_ID}");
    let prompt = format!("{} final-character-needle", "\u{001f}🐈".repeat(240_000));
    assert!(prompt.len() > 1024 * 1024);
    let records = [
        json!({"type":"user","sessionId":CLAUDE_ID,"cwd":cwd,"timestamp":"2026-11-12T07:00:00Z",
            "message":{"role":"user","content":prompt}}),
        json!({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"First answer."}]}}),
        json!({"type":"user","message":{"role":"user","content":"Next turn"}}),
        json!({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Next answer."}]}}),
    ];
    let transcript: String = records.iter().map(|record| format!("{record}\n")).collect();
    write(&h.0.join(format!(".claude/projects/-work-api/{CLAUDE_ID}.jsonl")), &transcript);
    let hub = hub_on(&h.0).await;
    let (tx, mut rx) = connect(&hub, Origin::Local).await;
    let page =
        call(&tx, &mut rx, 7, "_acpmux/chat_transcript_page", json!({"key": key, "cwd": cwd}))
            .await;
    let rows = page["result"]["turns"].as_array().expect("paged turns");
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["truncated"], true);
    assert!(!rows[0]["prompt"].as_str().unwrap().contains("final-character-needle"));
    assert_eq!(rows[1]["prompt"], "Next turn");
    assert!(serde_json::to_vec(&page).unwrap().len() < 1024 * 1024);
    let mut joined = rows[0]["prompt"].as_str().unwrap().to_owned();
    let mut offset = rows[0]["promptMore"].as_u64().unwrap();
    let page_end = &page["result"]["pageEnd"];
    let mut chunks = 0;
    loop {
        let chunk = call(
            &tx,
            &mut rx,
            12,
            "_acpmux/chat_transcript_page",
            json!({"key":key,"cwd":cwd,"before":page_end,"turn":0,"role":"user","offset":offset}),
        )
        .await;
        let text = chunk["result"]["text"].as_str().expect("continuation");
        assert!(!text.is_empty());
        assert!(serde_json::to_vec(&chunk).unwrap().len() < 1024 * 1024);
        joined.push_str(text);
        chunks += 1;
        let Some(next) = chunk["result"]["nextOffset"].as_u64() else { break };
        assert_eq!(next, offset + text.len() as u64);
        offset = next;
    }
    assert!(chunks > 1);
    assert_eq!(joined, prompt);
    // The first cat starts after the ASCII control byte; offset 2 is inside its code point.
    let invalid = call(
        &tx,
        &mut rx,
        13,
        "_acpmux/chat_transcript_page",
        json!({"key":key,"cwd":cwd,"before":page_end,"turn":0,"role":"user","offset":2}),
    )
    .await;
    assert!(invalid.get("error").is_some(), "{invalid}");
    let search = call(
        &tx,
        &mut rx,
        8,
        "_acpmux/chat_transcript_find",
        json!({"key":key,"cwd":cwd,"query":"final-character-needle"}),
    )
    .await;
    let hit = &search["result"]["hits"][0];
    assert_eq!(hit["pageEnd"], page["result"]["pageEnd"]);
    assert_eq!(hit["turn"], 0);
    assert!(hit["snippet"].as_str().unwrap().contains("final-character-needle"));
}

#[cfg(unix)]
/// A 17 MiB assistant record is source-paged in two contiguous UTF-8 slices. An equally
/// large append without its newline stays invisible. Ordinary turns keep their own indices.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn terminal_agent_history_reads_and_finds_oversized_source_without_losing_a_byte() {
    use std::io::Write as _;
    const PAGE: &str = "_acpmux/chat_transcript_page";
    const FIND: &str = "_acpmux/chat_transcript_find";
    let h = home();
    let hub = hub_on(&h.0).await;
    let (tx, mut rx) = connect(&hub, Origin::Local).await;
    let cwd = "/work/api";
    let key = format!("claude-code:{CLAUDE_ID}");
    let file = h.0.join(format!(".claude/projects/-work-api/{CLAUDE_ID}.jsonl"));
    let prompt = format!(
        "{}\n",
        json!({"type":"user","sessionId":CLAUDE_ID,"cwd":cwd,"message":{"role":"user","content":"Day one"}})
    );
    write(&file, &prompt);
    let mut source = br#"{"type":"assistant","message":{"role":"assistant","content":""#.to_vec();
    source.resize(17 * 1024 * 1024, b'x');
    source.extend_from_slice(b" near-the-end-marker\"}}\n");
    let split = source.len() - 16 * 1024 * 1024;
    let across = "cross🔎boundary";
    let cross_at = split - "cross".len() - 2;
    source[cross_at..cross_at + across.len()].copy_from_slice(across.as_bytes());
    std::fs::OpenOptions::new().append(true).open(&file).unwrap().write_all(&source).unwrap();

    let latest = call(&tx, &mut rx, 2, PAGE, json!({"key":key,"cwd":cwd})).await;
    let latest = &latest["result"];
    let newest = &latest["rawRanges"][0];
    let end = prompt.len() + source.len();
    let cut = prompt.len() + split - 2; // floor the reverse-page cut to the start of the emoji
    assert_eq!(newest, &json!({"start":cut,"end":end,"position":"before"}), "{latest}");
    assert!(latest["turns"].as_array().unwrap().is_empty());
    let older = call(&tx, &mut rx, 3, PAGE, json!({"key":key,"cwd":cwd,"before":latest["before"],"completeThrough":latest["completeThrough"]})).await;
    let older = &older["result"];
    assert_eq!(older["turns"][0]["prompt"], "Day one");
    assert_eq!(older["rawRanges"][0], json!({"start":prompt.len(),"end":cut,"position":"after"}));
    assert!(older["before"].is_null());

    for (query, start, stop) in [("NEAR-THE-END-MARKER", cut, end), (across, prompt.len(), cut)] {
        let mut before = Value::Null;
        let mut through = Value::Null;
        let hit = loop {
            let reply = call(&tx, &mut rx, 4, FIND, json!({"key":key,"cwd":cwd,"before":before,"query":query,"completeThrough":through})).await;
            if let Some(hit) = reply["result"]["hits"].as_array().unwrap().first() {
                break hit.clone();
            }
            let next = reply["result"]["before"].clone();
            assert!(next.is_u64() && next != before, "{reply}");
            before = next;
            through = reply["result"]["completeThrough"].clone();
        };
        assert_eq!(hit["role"], "raw");
        assert_eq!(hit["rawStart"], start);
        assert_eq!(hit["rawEnd"], stop);
        let args = json!({"key":key,"cwd":cwd,"before":hit["pageEnd"],"rawStart":start,"rawEnd":stop,"rawOffset":hit["rawOffset"],"completeThrough":hit["completeThrough"]});
        let chunk = call(&tx, &mut rx, 5, PAGE, args.clone()).await;
        let text = chunk["result"]["text"].as_str().unwrap();
        let offset = hit["rawOffset"].as_u64().unwrap() as usize - prompt.len();
        assert!(!text.is_empty() && text.len() <= 65_536);
        assert_eq!(text.as_bytes(), &source[offset..offset + text.len()]);
        let mut outside = args;
        outside["rawEnd"] = json!(stop + 1);
        assert!(call(&tx, &mut rx, 6, PAGE, outside).await["error"].is_object());
    }

    let aligned =
        json!({"key":key,"cwd":cwd,"before":end,"rawStart":cut,"rawEnd":end,"rawOffset":cut});
    let chunk = call(&tx, &mut rx, 7, PAGE, aligned.clone()).await;
    let first = chunk["result"]["text"].as_str().unwrap();
    assert!(first.starts_with('🔎') && first.len() <= 65_536);
    assert_eq!(chunk["result"]["nextOffset"], cut + first.len());
    let mut unaligned = aligned;
    unaligned["rawOffset"] = json!(cut + 1);
    assert!(call(&tx, &mut rx, 8, PAGE, unaligned).await["error"].is_object());

    // This oversized live append cannot be mistaken for a completed source record.
    let mut out = std::fs::OpenOptions::new().append(true).open(&file).unwrap();
    out.write_all(&vec![b'z'; 17 * 1024 * 1024]).unwrap();
    let tail = call(&tx, &mut rx, 9, PAGE, json!({"key":key,"cwd":cwd})).await;
    assert_eq!(tail["result"]["rawRanges"], json!([]));
    assert!(tail["result"]["completeThrough"].is_null());
    let behind = call(
        &tx,
        &mut rx,
        10,
        PAGE,
        json!({"key":key,"cwd":cwd,"before":tail["result"]["before"]}),
    )
    .await;
    for part in behind["result"]["rawRanges"].as_array().unwrap() {
        assert!(part["end"].as_u64().unwrap() <= end as u64);
    }
}

#[path = "support/terminal_history_fixture.rs"]
mod terminal_history_fixture;

#[cfg(unix)]
#[ignore = "600 MiB physical fixture and socket performance measurement; run on the fleet"]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn terminal_agent_history_600mib_socket_benchmark() {
    use std::time::Instant;
    let h = home();
    let cwd = Path::new("/work/api");
    let directory = h.0.join(".claude/projects/-work-api");
    std::fs::create_dir_all(&directory).unwrap();
    let hub = hub_on(&h.0).await;
    let socket = h.0.join("history.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let server = tokio::spawn(acpmux::server::serve_unix(hub, listener));
    let client = acpmux::client::Client::connect_without_caller(&socket).await.unwrap();
    let file = directory.join(format!("{CLAUDE_ID}.jsonl"));
    // Publish the finished fixture in one rename. Opening the chat can race its first metadata
    // scan, just as a freshly resumed terminal races the index after app restart.
    let staging = h.0.join("new-transcript.jsonl");
    terminal_history_fixture::write_600mib(&staging, CLAUDE_ID, cwd);
    std::fs::rename(&staging, &file).unwrap();
    assert_eq!(file.metadata().unwrap().len(), terminal_history_fixture::BYTES);
    let key = format!("claude-code:{CLAUDE_ID}");
    let started = Instant::now();
    let latest =
        client.request("_acpmux/chat_transcript_page", json!({"key":key,"cwd":cwd})).await.unwrap();
    let elapsed = started.elapsed();
    let turns = latest["turns"].as_array().expect("latest turns");
    assert_eq!(turns.len(), 32);
    assert!(turns.last().unwrap()["tools"].as_array().is_some_and(|tools| !tools.is_empty()));
    let baseline_start = Instant::now();
    let baseline = acpmux::adopt_replay::read("claude", &file);
    let baseline_elapsed = baseline_start.elapsed();
    assert!(baseline.iter().all(|turn| turn.prompt != "day one needle"));
    println!(
        "terminal_agent_history_600mib bytes={} latest_rpc_ms={:.3} baseline_reader_ms={:.3}",
        terminal_history_fixture::BYTES,
        elapsed.as_secs_f64() * 1000.,
        baseline_elapsed.as_secs_f64() * 1000.
    );
    assert!(elapsed < Duration::from_millis(200), "latest socket page took {elapsed:?}");

    // Read every older page through the same socket. Each preceding record is exactly one
    // cursor step away, including the session's first day.
    let scroll_start = Instant::now();
    let mut before = latest["before"].as_u64().expect("older pages");
    let mut page_times = Vec::new();
    let mut expected = turns.last().unwrap()["prompt"]
        .as_str()
        .unwrap()
        .strip_prefix("review turn ")
        .unwrap()
        .parse::<usize>()
        .unwrap()
        - turns.len();
    loop {
        let started = Instant::now();
        let page = client
            .request("_acpmux/chat_transcript_page", json!({"key":key,"cwd":cwd,"before":before}))
            .await
            .unwrap();
        page_times.push(started.elapsed());
        for turn in page["turns"].as_array().unwrap().iter().rev() {
            if expected == 0 {
                assert_eq!(turn["prompt"], "day one needle");
            } else {
                assert_eq!(turn["prompt"], format!("review turn {expected}"));
                expected -= 1;
            }
        }
        if let Some(next) = page["before"].as_u64() {
            assert!(next < before, "every page advances");
            before = next;
        } else {
            assert_eq!(page["turns"][0]["prompt"], "day one needle");
            assert_eq!(expected, 0);
            break;
        }
    }
    let total_scroll = scroll_start.elapsed();
    page_times.sort_unstable();
    let p95 = page_times[page_times.len() * 95 / 100];
    println!(
        "terminal_agent_history_600mib day_one_pages={} scroll_rpc_ms={:.1} page_p95_ms={:.3}",
        page_times.len() + 1,
        total_scroll.as_secs_f64() * 1000.,
        p95.as_secs_f64() * 1000.
    );
    server.abort();
}

/// The production page and real socket stay in one Linux fleet job. Synthetic data only.
#[cfg(target_os = "linux")]
#[ignore = "requires the built page, headless Chrome and 600 MiB: webviews/scripts/terminal-history-acceptance.sh"]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn packed_history_visible_600mib() {
    let bin = std::env::var_os("CMUX_HISTORY_BROWSER_BUN").expect("run the acceptance script");
    let pages = std::env::var_os("CMUX_HISTORY_PACKED_PAGES").expect("packed page resources");
    let home = daemon_env::Scratch::under(Path::new("/tmp"), "acpmux-history-browser", false);
    let root = home.path().canonicalize().unwrap();
    let cwd = Path::new("/work/api");
    let directory = root.join(".claude/projects/-work-api");
    std::fs::create_dir_all(&directory).unwrap();
    let hub = hub_on(&root).await;
    let stage = root.join("fixture.jsonl");
    let newest = terminal_history_fixture::write_600mib(&stage, CLAUDE_ID, cwd);
    assert_eq!(stage.metadata().unwrap().len(), terminal_history_fixture::BYTES);
    std::fs::rename(stage, directory.join(format!("{CLAUDE_ID}.jsonl"))).unwrap();
    let socket = root.join("history.sock");
    let server = tokio::spawn(acpmux::server::serve_unix(
        hub,
        tokio::net::UnixListener::bind(&socket).unwrap(),
    ));
    let webviews = std::env::var_os("CMUX_HISTORY_WEBVIEWS").expect("run the acceptance script");
    let mut command = tokio::process::Command::new(bin);
    command
        .current_dir(webviews)
        .arg("scripts/terminal-history-acceptance.mjs")
        .arg(pages)
        .arg(socket)
        .arg(format!("claude-code:{CLAUDE_ID}"))
        .arg(newest.to_string())
        .kill_on_drop(true);
    let status = tokio::time::timeout(Duration::from_secs(900), command.status())
        .await
        .expect("browser acceptance exceeded 15 minutes")
        .expect("launch browser acceptance");
    server.abort();
    assert!(status.success(), "packed transcript browser acceptance exited {status}");
}
