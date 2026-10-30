use super::*;
use acpmux::adopt::HarnessHomes;

/// A new agent session id for one test, so tests running at once (in this
/// run, in another binary, or in another checkout's run on the same builder)
/// never share a chat or its holder.
fn session_id() -> String {
    uuid::Uuid::now_v7().to_string()
}

/// A hub whose fake harnesses are Codex-family, and a fixture Codex store
/// holding one rollout recorded in a temp project folder.
/// Returns the hub, a client, the temp root, the project folder and the
/// recorded session's id.
async fn adopt_setup() -> (Arc<Hub>, TestClient, std::path::PathBuf, std::path::PathBuf, String) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = |env: &[(&str, &str)]| HarnessProfile {
        kind: Default::default(),
        argv: vec!["python3".into(), fake.into()],
        env: env.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect(),
        description: None,
        fallback: None,
        family: Some("codex".into()),
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut agents = BTreeMap::new();
    agents.insert("fakecodex".to_owned(), profile(&[]));
    agents.insert("noload".to_owned(), profile(&[("FAKE_NO_LOAD", "1")]));
    // codex-acp's answer while another Codex (classic cmux's terminal) holds the thread.
    agents.insert(
        "heldcodex".to_owned(),
        profile(&[("FAKE_LOAD_ERROR", "thread 0199 already has an active writer")]),
    );
    let mut cfg = Config {
        harnesses: agents,
        default_harness: Some("fakecodex".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);

    let root =
        std::path::PathBuf::from("/tmp").join(format!("acpmux-adopt-hub-{}", uuid::Uuid::now_v7()));
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let id = session_id();
    let rollout =
        root.join(format!("codex/sessions/2026/10/02/rollout-2026-10-02T09-00-00-{id}.jsonl"));
    std::fs::create_dir_all(rollout.parent().unwrap()).unwrap();
    let record = json!({"type": "session_meta", "payload": {"id": id, "cwd": project}});
    std::fs::write(&rollout, format!("{record}\n")).unwrap();
    hub.set_harness_homes(HarnessHomes { claude: root.join("claude"), codex: root.join("codex") });

    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut client = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    client
        .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();
    (hub, client, root, project, id)
}

fn adopt(harness: &str, id: &str) -> Value {
    adopt_if_live(harness, id, None)
}

/// `adopt` with `ifLive` (`refuse`, `fork` or `open`) when given.
fn adopt_if_live(harness: &str, id: &str, if_live: Option<&str>) -> Value {
    let mut request = json!({"agentSessionId": id});
    if let Some(if_live) = if_live {
        request["ifLive"] = json!(if_live);
    }
    let acpmux = json!({"harness": harness, "adopt": request});
    json!({"mcpServers": [], "_meta": {"acpmux": acpmux}})
}

/// A running process named like a harness (`python3 <dir>/<name>`, a script
/// that sleeps) in `cwd`, which holds no chat: another harness in the chat's
/// folder does not make the chat live. A copied `sleep` would not do: a
/// multicall coreutils exits on an unknown argv[0].
fn harness_stand_in(
    dir: &std::path::Path,
    name: &str,
    cwd: &std::path::Path,
) -> std::process::Child {
    let script = dir.join(name);
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(&script, "import time\ntime.sleep(60)\n").unwrap();
    std::process::Command::new("python3").arg(&script).current_dir(cwd).spawn().unwrap()
}

#[tokio::test]
async fn adopt_loads_the_harness_session_in_its_recorded_cwd() {
    let (hub, mut c, root, project, chat) = adopt_setup().await;
    let s = c.request(method::SESSION_NEW, adopt("fakecodex", &chat)).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    let meta = session.meta();
    assert_eq!(meta.agent_session_id.as_deref(), Some(chat.as_str()));
    assert_eq!(meta.cwd, project);
    let events = hub.events(&session.id, 0, 10_000).unwrap();
    let mux = |kind: &str| {
        events.iter().find(|e| e.dir == "mux" && e.kind == kind).map(|e| e.msg.clone())
    };
    assert_eq!(mux("adopted"), Some(json!({"agentSessionId": chat})));
    assert_eq!(mux("resumed"), Some(json!({"level": "exact"})));
    assert!(events.iter().any(|e| e.dir == "out" && e.kind == "session/load"));
    assert!(!events.iter().any(|e| e.dir == "out" && e.kind == "session/new"));

    // Adopting the same id again, from any profile of the family, is the same session.
    let again = c.request(method::SESSION_NEW, adopt("noload", &chat)).await.unwrap();
    assert_eq!(again["sessionId"], id.as_str());
    assert_eq!(hub.sessions().len(), 1);
    let _ = std::fs::remove_dir_all(root);
}

/// Fails closed: an id the store lacks, a path-shaped id, and an agent that
/// cannot load the session are errors, and no session is left behind.
#[tokio::test]
async fn adopt_refuses_unknown_ids_and_agents_that_cannot_resume() {
    let (hub, mut c, root, _, chat) = adopt_setup().await;
    let missing = "0199a1b2-0000-7000-8000-000000000000";
    let unknown = c.request(method::SESSION_NEW, adopt("fakecodex", missing)).await;
    assert!(unknown.unwrap_err().contains("no codex session"));
    let path = c.request(method::SESSION_NEW, adopt("fakecodex", "../../etc/passwd")).await;
    assert!(path.unwrap_err().contains("not a session id"));
    let no_load = c.request(method::SESSION_NEW, adopt("noload", &chat)).await;
    assert!(no_load.unwrap_err().contains("could not resume"));
    assert!(hub.sessions().is_empty());
    let _ = std::fs::remove_dir_all(root);
}

/// A Codex chat another Codex still writes, though nothing showed it live
/// (classic cmux's terminal runs a bare `codex`, idle for minutes), says where
/// it is open and what to do, not that the agent "could not resume" it (cx-l7g6k).
#[tokio::test]
async fn adopt_of_a_chat_another_codex_holds_says_to_quit_it_there() {
    let (hub, mut c, root, _, chat) = adopt_setup().await;
    let held = c.request(method::SESSION_NEW, adopt("heldcodex", &chat)).await.unwrap_err();
    assert!(held.contains("is still open in another app"), "{held}");
    assert!(held.contains("quit it there, then open it again"), "{held}");
    assert!(hub.sessions().is_empty());
    let _ = std::fs::remove_dir_all(root);
}

/// A chat still open in another process (a terminal running `codex resume
/// <id>`, which holds the thread's writer lock) is not adopted silently: two
/// harnesses resuming one conversation fork it. `ifLive: "open"` adopts it
/// anyway; only Claude Code chats fork on adopt.
#[tokio::test]
async fn adopt_refuses_a_chat_live_in_another_process() {
    let (hub, mut c, root, project, _) = adopt_setup().await;
    let live = session_id();
    let rollout =
        root.join(format!("codex/sessions/2026/10/02/rollout-2026-10-02T10-00-00-{live}.jsonl"));
    let record = json!({"type": "session_meta", "payload": {"id": live, "cwd": project}});
    std::fs::write(&rollout, format!("{record}\n")).unwrap();
    let lock = root.join(format!("codex/thread-writer-locks/{live}.lock"));
    std::fs::create_dir_all(lock.parent().unwrap()).unwrap();
    let mut other = writer_lock_holder(&lock);
    let refused = c.request(method::SESSION_NEW, adopt("fakecodex", &live)).await.unwrap_err();
    assert!(refused.contains("open in another process"), "{refused}");
    let fork =
        c.request(method::SESSION_NEW, adopt_if_live("fakecodex", &live, Some("fork"))).await;
    assert!(fork.unwrap_err().contains("only Claude Code chats fork"));
    assert!(hub.sessions().is_empty());

    let opened =
        c.request(method::SESSION_NEW, adopt_if_live("fakecodex", &live, Some("open"))).await;
    let id = opened.unwrap()["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(hub.resolve(&id).unwrap().meta().agent_session_id.as_deref(), Some(live.as_str()));
    let _ = other.kill();
    let _ = other.wait();
    let _ = std::fs::remove_dir_all(root);
}

/// `ifLive: "fork"` on a Claude Code chat starts a new chat from it
/// (`claude --resume <id> --fork-session`), leaving the live one alone.
#[tokio::test]
async fn adopt_forks_a_live_claude_chat_when_asked() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fakeclaude": {"argv": ["python3", fake], "kind": "claude-stdio"}},
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let root = std::path::PathBuf::from("/tmp")
        .join(format!("acpmux-adopt-fork-{}", uuid::Uuid::now_v7()));
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let fork_id = session_id();
    let transcript = root.join(format!("claude/projects/-project/{fork_id}.jsonl"));
    std::fs::create_dir_all(transcript.parent().unwrap()).unwrap();
    std::fs::write(&transcript, format!("{}\n", json!({"type": "user", "cwd": project}))).unwrap();
    hub.set_harness_homes(HarnessHomes { claude: root.join("claude"), codex: root.join("codex") });
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();

    // A running Claude Code registered it: live.
    let mut harness = harness_stand_in(&root.join("bin"), "claude", &project);
    std::thread::sleep(Duration::from_millis(50));
    let started_at =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis();
    let entry = json!({"pid": harness.id(), "sessionId": fork_id, "startedAt": started_at});
    std::fs::create_dir_all(root.join("claude/sessions")).unwrap();
    std::fs::write(root.join(format!("claude/sessions/{}.json", harness.id())), entry.to_string())
        .unwrap();
    let refused = c.request(method::SESSION_NEW, adopt("fakeclaude", &fork_id)).await.unwrap_err();
    assert!(refused.contains("open in another process"), "{refused}");
    let forked =
        c.request(method::SESSION_NEW, adopt_if_live("fakeclaude", &fork_id, Some("fork"))).await;
    let id = forked.unwrap()["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    assert_eq!(session.meta().cwd, project);
    assert_ne!(session.meta().agent_session_id.as_deref(), Some(fork_id.as_str()));
    let events = hub.events(&session.id, 0, 10_000).unwrap();
    let mux = |kind: &str| {
        events.iter().find(|e| e.dir == "mux" && e.kind == kind).map(|e| e.msg.clone())
    };
    assert_eq!(mux("adopted"), Some(json!({"agentSessionId": fork_id, "fork": true})));
    assert_eq!(mux("resumed"), Some(json!({"level": "fork"})));
    let _ = harness.kill();
    let _ = harness.wait();
    let _ = std::fs::remove_dir_all(root);
}

/// The replayed history of an adopted chat: its records from the first `turn_started` on.
fn replayed(hub: &Hub, id: &str) -> Vec<acpmux::store::EventRecord> {
    let events = hub.events(id, 0, 10_000).unwrap();
    let start = events.iter().position(|e| e.kind == "turn_started").expect("a replayed turn");
    events[start..].to_vec()
}

/// The session update of an `in` record.
fn update_of(e: &acpmux::store::EventRecord) -> &Value {
    e.msg.pointer("/params/update").unwrap_or(&Value::Null)
}

/// `value` without the canonical paths the hub records beside a tool call's
/// (`_meta.acpmux.canonicalPath`, hub/tool_paths.rs), and without a `_meta`
/// that held only that: the paths as the agent wrote them.
fn as_written(value: &Value) -> Value {
    match value {
        Value::Array(items) => Value::Array(items.iter().map(as_written).collect()),
        Value::Object(fields) => {
            let mut out = serde_json::Map::new();
            for (key, field) in fields {
                let field = as_written(field);
                if key == "_meta" {
                    let mut meta = field.clone();
                    if let Some(acpmux) = meta.get_mut("acpmux").and_then(Value::as_object_mut) {
                        acpmux.remove("canonicalPath");
                        if acpmux.is_empty() {
                            meta.as_object_mut().unwrap().remove("acpmux");
                        }
                    }
                    if meta.as_object().is_some_and(|m| m.is_empty()) {
                        continue;
                    }
                    out.insert(key.clone(), meta);
                } else {
                    out.insert(key.clone(), field);
                }
            }
            Value::Object(out)
        }
        other => other.clone(),
    }
}

/// The canonical form of `path` the hub records for a file in a folder that
/// exists: the folder's real path (/tmp is /private/tmp on macOS).
fn canonical_in(path: &str) -> String {
    let path = std::path::Path::new(path);
    let folder = std::fs::canonicalize(path.parent().unwrap()).unwrap();
    folder.join(path.file_name().unwrap()).to_string_lossy().into_owned()
}

/// An adopted Codex chat shows each turn's tool calls, not only its final message
/// (hq#2569 item 3): a reopened turn that ran three commands and edited two files replays
/// them as `tool_call` records, each settled by a `tool_call_update` with its output, before
/// the answer, so the pane's "Worked for" opens to "Ran 3 commands" and "Edited 2 files".
/// The edit carries each file's before and after text and +/- counts (the edited-files card).
///
/// The replayed records are also the pane's fixture
/// (`webviews/test/fixtures/adopted-codex-turn.events.json`, read by
/// `agent-pane-adopted-tool-calls.test.ts`): `ACPMUX_UPDATE_FIXTURES=1` rewrites it.
#[tokio::test]
async fn adopt_replays_a_codex_turns_commands_and_file_edits() {
    let (hub, mut c, root, project, chat) = adopt_setup().await;
    let rollout =
        root.join(format!("codex/sessions/2026/10/02/rollout-2026-10-02T09-00-00-{chat}.jsonl"));
    let fixture = include_str!("../fixtures/codex-rollout-tool-calls.jsonl")
        .replace("{ID}", &chat)
        .replace("{CWD}", &project.to_string_lossy());
    std::fs::write(&rollout, fixture).unwrap();

    let s = c.request(method::SESSION_NEW, adopt("fakecodex", &chat)).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let events = replayed(&hub, &id);
    write_pane_fixture(&events, &chat, &root);
    let kinds: Vec<&str> = events.iter().map(|e| e.kind.as_str()).collect();
    assert_eq!(
        kinds,
        [
            "turn_started",
            "user_message",
            "tool_call",
            "tool_call_update",
            "tool_call",
            "tool_call_update",
            "tool_call",
            "tool_call_update",
            "tool_call",
            "tool_call_update",
            "agent_message_chunk",
            "turn_end",
            "turn_result"
        ],
        "{events:#?}"
    );
    assert_eq!(events[1].msg["text"], "Bump the version to 1.3.0 and note it in the changelog");
    let calls: Vec<&Value> =
        events.iter().filter(|e| e.kind == "tool_call").map(update_of).collect();
    let commands: Vec<&str> = calls
        .iter()
        .filter_map(|u| u.pointer("/rawInput/command").and_then(Value::as_str))
        .collect();
    assert_eq!(
        commands,
        ["git status --short", "grep -n '^version' Cargo.toml", "sed -n 1,8p CHANGELOG.md"]
    );
    assert!(calls[..3].iter().all(|u| u["kind"] == "execute" && u["status"] == "in_progress"));
    assert_eq!(calls[0]["rawInput"]["cwd"], json!(project));
    // Each command settles with its output and exit code, at the time it ended.
    let done: Vec<&acpmux::store::EventRecord> =
        events.iter().filter(|e| e.kind == "tool_call_update").collect();
    let grep = update_of(done[1]);
    assert_eq!(grep["toolCallId"], "exec-2");
    assert_eq!(grep["status"], "completed");
    assert_eq!(grep["rawOutput"]["exit_code"], 0);
    assert_eq!(grep.pointer("/content/0/content/text"), Some(&json!("3:version = \"1.2.0\"\n")));
    let started =
        events.iter().find(|e| e.kind == "tool_call" && update_of(e)["toolCallId"] == "exec-2");
    assert_eq!(done[1].at - started.unwrap().at, 50, "the call ran 50ms");

    // The edit: one call over two files (in path order: Codex records them as a map), each a
    // diff with its before and after text.
    let edit = calls[3];
    assert_eq!(edit["kind"], "edit");
    let cargo = project.join("Cargo.toml").to_string_lossy().into_owned();
    let changelog = project.join("CHANGELOG.md").to_string_lossy().into_owned();
    assert_eq!(
        as_written(&edit["locations"]),
        json!([{"path": changelog, "line": 1}, {"path": cargo, "line": 1}])
    );
    // Beside each, its canonical path (hub/tool_paths.rs).
    assert_eq!(edit["locations"][1]["_meta"]["acpmux"]["canonicalPath"], canonical_in(&cargo));
    let edit_done = update_of(done[3]);
    assert_eq!(edit_done["status"], "completed");
    let diffs = edit_done["content"].as_array().unwrap();
    assert_eq!(diffs.len(), 2, "{edit_done}");
    assert_eq!(diffs[0]["type"], "diff");
    assert_eq!(diffs[0]["path"], changelog.as_str());
    assert!(
        diffs[0]["newText"].as_str().unwrap().contains("## 1.3.0\n- Bump the version to 1.3.0")
    );
    assert_eq!(diffs[1]["path"], cargo.as_str());
    assert!(diffs[1]["oldText"].as_str().unwrap().contains("version = \"1.2.0\""));
    assert!(diffs[1]["newText"].as_str().unwrap().contains("version = \"1.3.0\""));
    assert_eq!(
        edit["rawInput"]["changes"],
        json!([
            {"path": changelog, "type": "update", "additions": 3, "deletions": 0},
            {"path": cargo, "type": "update", "additions": 1, "deletions": 1}
        ])
    );

    // The final answer only (commentary is progress narration), after the work.
    let answer = &events[10];
    assert_eq!(
        update_of(answer).pointer("/content/text"),
        Some(&json!("Bumped demo to 1.3.0 and added a 1.3.0 entry to CHANGELOG.md."))
    );
    // Worked for 1m 32s: the prompt at 09:00:00, the answer at 09:01:32.
    assert_eq!(answer.at - events[1].at, 92_000);

    let _ = std::fs::remove_dir_all(root);
}

/// A reopened Codex turn whose patch failed shows the failed edit and its error, but none of
/// the edits it proposed: they never applied, so the pane draws no diff and counts no lines.
/// A hunk that did apply is marked as part of its file (`_meta.acpmux.fragment`), so the
/// edited-files card never offers a whole-file Undo it cannot do.
#[tokio::test]
async fn adopt_replays_a_failed_codex_patch_without_its_edits() {
    let (hub, mut c, root, project, chat) = adopt_setup().await;
    let rollout =
        root.join(format!("codex/sessions/2026/10/02/rollout-2026-10-02T09-00-00-{chat}.jsonl"));
    let cwd = project.to_string_lossy().into_owned();
    let change = |id: &str, status: &str, stderr: &str| {
        json!({"timestamp": "2026-10-02T10:00:10.000Z", "type": "event_msg", "payload": {
            "type": "item_completed", "thread_id": chat, "turn_id": "turn-1",
            "item": {"type": "FileChange", "id": id, "status": status,
                "changes": {format!("{cwd}/Cargo.toml"): {"type": "update", "move_path": null,
                    "unified_diff": "@@ -3,1 +3,1 @@\n-version = \"1.2.0\"\n+version = \"1.3.0\"\n"}},
                "stdout": "", "stderr": stderr}}})
    };
    let lines = [
        json!({"timestamp": "2026-10-02T09:59:59.900Z", "type": "session_meta", "payload": {"id": chat, "cwd": cwd, "originator": "Codex Desktop", "cli_version": "0.163.0"}}),
        json!({"timestamp": "2026-10-02T09:59:59.950Z", "type": "event_msg", "payload": {"type": "task_started", "turn_id": "turn-1"}}),
        json!({"timestamp": "2026-10-02T10:00:00.000Z", "type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Bump the version"}], "internal_chat_message_metadata_passthrough": {"content_item_kinds": ["user.text"]}}}),
        change("patch-1", "failed", "patch rejected: Cargo.toml changed on disk"),
        change("patch-2", "completed", ""),
        json!({"timestamp": "2026-10-02T10:00:20.000Z", "type": "response_item", "payload": {"type": "message", "role": "assistant", "phase": "final_answer", "content": [{"type": "output_text", "text": "Bumped it on the second try."}]}}),
        json!({"timestamp": "2026-10-02T10:00:20.100Z", "type": "event_msg", "payload": {"type": "task_complete", "turn_id": "turn-1"}}),
    ];
    let text: String = lines.iter().map(|l| format!("{l}\n")).collect();
    std::fs::write(&rollout, text).unwrap();

    let s = c.request(method::SESSION_NEW, adopt("fakecodex", &chat)).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let events = replayed(&hub, &id);
    let call = |id: &str, kind: &str| {
        events
            .iter()
            .filter(|e| e.kind == kind)
            .map(update_of)
            .find(|u| u["toolCallId"] == id)
            .cloned()
            .unwrap_or_else(|| panic!("no {kind} for {id}: {events:#?}"))
    };
    let cargo = project.join("Cargo.toml").to_string_lossy().into_owned();

    let failed = call("patch-1", "tool_call_update");
    assert_eq!(failed["status"], "failed");
    assert_eq!(
        failed["content"],
        json!([{"type": "content", "content": {"type": "text", "text": "patch rejected: Cargo.toml changed on disk"}}])
    );
    assert_eq!(
        call("patch-1", "tool_call")["rawInput"]["changes"],
        json!([{"path": cargo, "type": "update"}])
    );

    let applied = call("patch-2", "tool_call_update");
    assert_eq!(applied["status"], "completed");
    assert_eq!(
        as_written(&applied["content"]),
        json!([{"type": "diff", "path": cargo, "oldText": "version = \"1.2.0\"\n", "newText": "version = \"1.3.0\"\n", "_meta": {"acpmux": {"fragment": true}}}])
    );
    assert_eq!(applied["content"][0]["_meta"]["acpmux"]["canonicalPath"], canonical_in(&cargo));
    assert_eq!(
        call("patch-2", "tool_call")["rawInput"]["changes"],
        json!([{"path": cargo, "type": "update", "additions": 1, "deletions": 1}])
    );

    let _ = std::fs::remove_dir_all(root);
}

/// Checks (or with `ACPMUX_UPDATE_FIXTURES=1` rewrites) the pane's adopted-turn fixture: the
/// replayed records with the machine-specific folder and ids made stable, and numbered from 1
/// (`seq`, and the `turnSeq` that names the turn's start).
fn write_pane_fixture(events: &[acpmux::store::EventRecord], chat: &str, root: &std::path::Path) {
    let base = events[0].seq - 1;
    let records: Vec<Value> = events
        .iter()
        .map(|e| {
            let mut msg = e.msg.clone();
            if let Some(turn) = msg.get("turnSeq").and_then(Value::as_u64) {
                msg["turnSeq"] = json!(turn - base);
            }
            json!({"seq": e.seq - base, "at": e.at, "dir": e.dir, "kind": e.kind, "msg": msg})
        })
        .collect();
    // The canonical paths name the project by its real path (/private/tmp on macOS).
    let real = std::fs::canonicalize(root.join("project")).unwrap();
    let text = serde_json::to_string_pretty(&records)
        .unwrap()
        .replace(&real.to_string_lossy().into_owned(), "/home/dev/demo")
        .replace(&root.join("project").to_string_lossy().into_owned(), "/home/dev/demo")
        .replace(chat, "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a60")
        + "\n";
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../webviews/test/fixtures/adopted-codex-turn.events.json"
    );
    if std::env::var("ACPMUX_UPDATE_FIXTURES").as_deref() == Ok("1") {
        std::fs::write(path, &text).unwrap();
    } else if let Ok(stored) = std::fs::read_to_string(path) {
        // A checkout without the webviews (a crate-only build) has nothing to check.
        assert_eq!(
            stored, text,
            "the pane's fixture is stale: rerun with ACPMUX_UPDATE_FIXTURES=1"
        );
    }
}

/// An adopted Claude Code chat shows its tool calls too: a `tool_use` replays as a
/// `tool_call` and its `tool_result` settles it (an error result fails it), before the answer.
#[tokio::test]
async fn adopt_replays_a_claude_turns_tool_calls() {
    let root = std::path::PathBuf::from("/tmp")
        .join(format!("acpmux-adopt-claude-tools-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let chat = session_id();
    let file = project.join("src/lib.rs").to_string_lossy().into_owned();
    let line = |kind: &str, content: Value, at: &str| {
        json!({"type": kind, "isSidechain": false, "cwd": project, "sessionId": chat,
               "timestamp": at, "message": {"role": kind, "content": content}})
    };
    let lines = [
        line("user", json!("Rename old_helper and run the tests"), "2026-10-02T10:00:00.000Z"),
        line(
            "assistant",
            json!([{"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": {"command": "rg -n old_helper", "description": "Find uses"}}]),
            "2026-10-02T10:00:03.000Z",
        ),
        line(
            "user",
            json!([{"type": "tool_result", "tool_use_id": "toolu_1", "content": "src/lib.rs:3:fn old_helper() {}"}]),
            "2026-10-02T10:00:04.000Z",
        ),
        line(
            "assistant",
            json!([{"type": "tool_use", "id": "toolu_2", "name": "Edit", "input": {"file_path": file, "old_string": "fn old_helper() {}", "new_string": "fn new_helper() {}"}}]),
            "2026-10-02T10:00:06.000Z",
        ),
        line(
            "user",
            json!([{"type": "tool_result", "tool_use_id": "toolu_2", "content": [{"type": "text", "text": "The file has been updated."}]}]),
            "2026-10-02T10:00:07.000Z",
        ),
        line(
            "assistant",
            json!([{"type": "tool_use", "id": "toolu_3", "name": "Bash", "input": {"command": "cargo test -q"}}]),
            "2026-10-02T10:00:08.000Z",
        ),
        line(
            "user",
            json!([{"type": "tool_result", "tool_use_id": "toolu_3", "content": "error: 1 test failed", "is_error": true}]),
            "2026-10-02T10:00:30.000Z",
        ),
        line(
            "assistant",
            json!([{"type": "text", "text": "Renamed old_helper to new_helper; one test still fails."}]),
            "2026-10-02T10:00:40.000Z",
        ),
    ];
    let transcript = claude.join(format!("projects/p/{chat}.jsonl"));
    std::fs::create_dir_all(transcript.parent().unwrap()).unwrap();
    std::fs::write(&transcript, lines.iter().map(|l| format!("{l}\n")).collect::<String>())
        .unwrap();
    let (hub, mut c) = super::fork_through::claude_setup(&claude, &[]).await;

    let s = c.request(method::SESSION_NEW, adopt("claude", &chat)).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let events = replayed(&hub, &id);
    let kinds: Vec<&str> = events.iter().map(|e| e.kind.as_str()).collect();
    assert_eq!(
        kinds,
        [
            "turn_started",
            "user_message",
            "tool_call",
            "tool_call_update",
            "tool_call",
            "tool_call_update",
            "tool_call",
            "tool_call_update",
            "agent_message_chunk",
            "turn_end",
            "turn_result"
        ],
        "{events:#?}"
    );
    let calls: Vec<&Value> =
        events.iter().filter(|e| e.kind == "tool_call").map(update_of).collect();
    assert_eq!(calls[0]["kind"], "execute");
    assert_eq!(calls[0]["rawInput"]["command"], "rg -n old_helper");
    assert_eq!(calls[1]["kind"], "edit");
    assert_eq!(as_written(&calls[1]["locations"]), json!([{"path": file}]));
    let done: Vec<&Value> =
        events.iter().filter(|e| e.kind == "tool_call_update").map(update_of).collect();
    assert_eq!(done[0]["status"], "completed");
    assert_eq!(
        done[0].pointer("/content/0/content/text"),
        Some(&json!("src/lib.rs:3:fn old_helper() {}"))
    );
    assert_eq!(
        as_written(&done[1]["content"]),
        json!([{"type": "diff", "path": file, "oldText": "fn old_helper() {}", "newText": "fn new_helper() {}"}])
    );
    // src/ is not there: the canonical path is the project's real path and the rest as written.
    let real = std::fs::canonicalize(&project).unwrap().join("src/lib.rs");
    assert_eq!(done[1]["content"][0]["_meta"]["acpmux"]["canonicalPath"], json!(real));
    assert_eq!(done[2]["status"], "failed");
    assert_eq!(
        update_of(&events[8]).pointer("/content/text"),
        Some(&json!("Renamed old_helper to new_helper; one test still fails."))
    );
    let _ = std::fs::remove_dir_all(root);
}

/// A process that holds `lock` the way a running Codex holds its thread writer lock (an
/// exclusive `flock`), until it is killed; returns once the lock is held. The kernel releases
/// it when the process ends, as it does for a `codex exec` that finished.
fn writer_lock_holder(lock: &std::path::Path) -> std::process::Child {
    use std::io::BufRead;
    let script = "import fcntl, sys, time\n\
                  f = open(sys.argv[1], 'a')\n\
                  fcntl.flock(f, fcntl.LOCK_EX)\n\
                  print('locked', flush=True)\n\
                  time.sleep(60)\n";
    let mut child = std::process::Command::new("python3")
        .args(["-c", script])
        .arg(lock)
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let mut line = String::new();
    std::io::BufReader::new(child.stdout.as_mut().unwrap()).read_line(&mut line).unwrap();
    assert_eq!(line.trim(), "locked");
    child
}

/// The pid of a process that ran and exited.
fn finished_pid() -> u32 {
    let mut done = std::process::Command::new("python3").args(["-c", "pass"]).spawn().unwrap();
    let pid = done.id();
    done.wait().unwrap();
    pid
}

/// A finished CLI run (a `codex exec` that exited) reopens directly, even just after it wrote
/// its transcript and while another Codex runs in the same folder: only a holder that still runs
/// counts (hq#2569 item 7: every finished session opened behind "still open in another
/// process"). Codex's holder is its thread writer lock, which the kernel releases when the
/// writer exits; the lock file itself stays on disk.
#[tokio::test]
async fn adopt_opens_a_finished_codex_run_directly() {
    let (hub, mut c, root, project, _) = adopt_setup().await;
    let done = session_id();
    let rollout =
        root.join(format!("codex/sessions/2026/10/02/rollout-2026-10-02T11-00-00-{done}.jsonl"));
    let record = json!({"type": "session_meta", "payload": {"id": done, "cwd": project}});
    // Just written: the run ended a moment ago.
    std::fs::write(&rollout, format!("{record}\n")).unwrap();
    let lock = root.join(format!("codex/thread-writer-locks/{done}.lock"));
    std::fs::create_dir_all(lock.parent().unwrap()).unwrap();
    std::fs::write(&lock, "").unwrap();
    // Another Codex in the chat's folder, holding some other chat.
    let mut other = harness_stand_in(&root.join("bin"), "codex", &project);

    // A writer that still runs holds the lock: refused, with no command line read.
    let mut writer = writer_lock_holder(&lock);
    let refused = c.request(method::SESSION_NEW, adopt("fakecodex", &done)).await.unwrap_err();
    assert!(refused.contains("open in another process"), "{refused}");
    assert!(hub.sessions().is_empty());
    let _ = writer.kill();
    let _ = writer.wait();

    // A writer paused between the home's coordination lock and the thread lock holds only the
    // coordination lock: the chat is busy, not free.
    let mut taking = writer_lock_holder(&lock.with_file_name(".coordination.lock"));
    let refused = c.request(method::SESSION_NEW, adopt("fakecodex", &done)).await.unwrap_err();
    assert!(refused.contains("open in another process"), "{refused}");
    assert!(hub.sessions().is_empty());
    let _ = taking.kill();
    let _ = taking.wait();

    // The writer exited: the lock is released and the chat opens directly.
    let opened = c.request(method::SESSION_NEW, adopt("fakecodex", &done)).await;
    let id = opened.expect("a finished Codex run reopens directly")["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(hub.resolve(&id).unwrap().meta().agent_session_id.as_deref(), Some(done.as_str()));
    let _ = other.kill();
    let _ = other.wait();
    let _ = std::fs::remove_dir_all(root);
}

/// A Claude Code chat whose `claude` quit reopens directly, though its transcript was just
/// written and another `claude` runs in the folder. Claude Code registers each running session
/// in `<config>/sessions/<pid>.json` (pid, session id, start time) and removes the file when it
/// quits; a crash leaves it, so an entry counts only while its pid runs and started before the
/// entry was written (a reused pid does not).
#[tokio::test]
async fn adopt_opens_a_finished_claude_chat_directly() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let root = std::path::PathBuf::from("/tmp")
        .join(format!("acpmux-adopt-finished-{}", uuid::Uuid::now_v7()));
    let config_dir = root.join("claude");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fakeclaude": {
            "argv": ["python3", fake],
            "kind": "claude-stdio",
            "env": {"CLAUDE_CONFIG_DIR": config_dir},
        }},
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let chat = session_id();
    let transcript = config_dir.join(format!("projects/p/{chat}.jsonl"));
    std::fs::create_dir_all(transcript.parent().unwrap()).unwrap();
    std::fs::write(&transcript, format!("{}\n", json!({"type": "user", "cwd": project}))).unwrap();
    hub.set_harness_homes(HarnessHomes { claude: config_dir.clone(), codex: root.join("codex") });
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();
    let sessions = config_dir.join("sessions");
    std::fs::create_dir_all(&sessions).unwrap();
    let register = |pid: u32, started_at: u128| {
        let entry = json!({"pid": pid, "sessionId": chat, "cwd": project, "startedAt": started_at,
                           "kind": "interactive", "entrypoint": "cli"});
        std::fs::write(sessions.join(format!("{pid}.json")), entry.to_string()).unwrap();
    };
    let now_ms =
        || std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis();

    // Another `claude` in the chat's folder, holding some other chat.
    let mut other = harness_stand_in(&root.join("bin"), "claude", &project);
    // A `claude` that still runs this chat: refused, naming its pid.
    std::thread::sleep(Duration::from_millis(50));
    register(other.id(), now_ms());
    let refused = c.request(method::SESSION_NEW, adopt("fakeclaude", &chat)).await.unwrap_err();
    assert!(refused.contains("open in another process"), "{refused}");
    assert!(refused.contains(&other.id().to_string()), "{refused}");
    assert!(hub.sessions().is_empty());
    // The same pid with an entry older than the process: a pid reused by a later process (macOS
    // reads the start time; elsewhere the pid decides alone).
    if cfg!(target_os = "macos") {
        register(other.id(), now_ms() - 3_600_000);
        assert_eq!(acpmux::adopt_live::holder("claude", &chat, &config_dir), None);
    }
    let _ = std::fs::remove_file(sessions.join(format!("{}.json", other.id())));

    // The `claude` that ran it crashed: its entry stays, its pid is gone.
    register(finished_pid(), now_ms());
    let opened = c.request(method::SESSION_NEW, adopt("fakeclaude", &chat)).await;
    let id = opened.expect("a finished Claude Code chat reopens directly")["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(hub.resolve(&id).unwrap().meta().agent_session_id.as_deref(), Some(chat.as_str()));
    let _ = other.kill();
    let _ = other.wait();
    let _ = std::fs::remove_dir_all(root);
}
