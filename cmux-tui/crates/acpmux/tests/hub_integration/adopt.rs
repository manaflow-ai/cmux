use super::*;
use acpmux::adopt::HarnessHomes;

/// A new agent session id for one test. The live-use check reads every
/// process's command line on the machine, and a test's fake harness (`claude
/// --resume <id> --fork-session`, `codex resume <id>`) runs outside any
/// `acpmux` process, so a test that adopts an id another test (in this run,
/// in another binary, or in another checkout's run on the same builder)
/// keeps on a live command line is refused as "open in another process".
/// A fixed id per test is not enough across concurrent runs: each test makes
/// its own.
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

    // Under /tmp: a harness stand-in's path is read from `ps` split on spaces, and a worker's
    // temp dir may have one (`/Library/Application Support/...`).
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
    // Written long ago: a transcript written in the last minutes is a chat
    // still live elsewhere (the live-use tests).
    backdate(&rollout);
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

/// Sets `file`'s modification time an hour back.
fn backdate(file: &std::path::Path) {
    let hour_ago = std::time::SystemTime::now() - Duration::from_secs(3600);
    std::fs::File::options().write(true).open(file).unwrap().set_modified(hour_ago).unwrap();
}

/// A running process named like a harness (`python3 <dir>/<name>`, a script
/// that sleeps), which names no session. A recent write counts as live only
/// while some harness runs, so a test that expects "written" starts one
/// rather than depend on what else runs on the builder. A copied `sleep`
/// would not do: a multicall coreutils exits on an unknown argv[0].
/// It runs in `cwd`, the chat's folder: only a harness there can hold the chat open.
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

/// A recent write is live only while a harness outside acpmux runs: with
/// none, the chat's harness has ended (Lawrence P0 2026-10-11); an unreadable
/// process table keeps the write live (fails closed); harnesses under an
/// `acpmux` process are its own.
#[test]
fn a_recent_write_is_live_only_while_a_harness_runs() {
    use acpmux::adopt_live::{LiveUse, Proc, live_use};
    let root = std::env::temp_dir().join(format!("acpmux-adopt-live-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let transcript = root.join("chat.jsonl");
    std::fs::write(&transcript, "{}\n").unwrap();
    let now = std::time::SystemTime::now() + Duration::from_secs(5);
    let id = session_id();
    let proc = |pid, ppid, command: &str| Proc { pid, ppid, command: command.to_owned() };
    let shell = proc(10, 1, "/bin/zsh -l");
    let recent = |procs: &[Proc]| {
        matches!(live_use(&id, &transcript, None, procs, now), Some(LiveUse::RecentWrite { .. }))
    };
    assert!(!recent(std::slice::from_ref(&shell)));
    assert!(recent(&[shell.clone(), proc(11, 10, "/opt/homebrew/bin/codex")]));
    assert!(recent(&[shell.clone(), proc(11, 10, "node /usr/local/bin/claude --verbose")]));
    assert!(recent(&[]));
    let ours =
        [shell.clone(), proc(20, 1, "/Applications/x/acpmux daemon"), proc(21, 20, "claude")];
    assert!(!recent(&ours));
    backdate(&transcript);
    assert!(!recent(&[shell, proc(11, 10, "codex")]));
    let _ = std::fs::remove_dir_all(root);
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

/// A chat still live in another process (a terminal running
/// `codex resume <id>`, a transcript written minutes ago) is not adopted
/// silently: two harnesses resuming one conversation fork it. `ifLive:
/// "open"` adopts it anyway; only Claude Code chats fork on adopt.
#[tokio::test]
async fn adopt_refuses_a_chat_live_in_another_process() {
    let (hub, mut c, root, project, _) = adopt_setup().await;
    // Its own chat: the process below names it.
    let live = session_id();
    let rollout =
        root.join(format!("codex/sessions/2026/10/02/rollout-2026-10-02T10-00-00-{live}.jsonl"));
    let record = json!({"type": "session_meta", "payload": {"id": live, "cwd": project}});
    std::fs::write(&rollout, format!("{record}\n")).unwrap();
    backdate(&rollout);
    // python3, not `sh -c "sleep 60"`: sh execs a lone command, and the
    // process the adopt then reads in `ps` is a bare `sleep 60`.
    let mut other = std::process::Command::new("python3")
        .args(["-c", "import time; time.sleep(60)", "codex", "resume", live.as_str()])
        .spawn()
        .unwrap();
    let refused = c.request(method::SESSION_NEW, adopt("fakecodex", &live)).await.unwrap_err();
    assert!(refused.contains("open in another process"), "{refused}");
    assert!(refused.contains(&other.id().to_string()), "{refused}");
    let fork =
        c.request(method::SESSION_NEW, adopt_if_live("fakecodex", &live, Some("fork"))).await;
    assert!(fork.unwrap_err().contains("only Claude Code chats fork"));
    assert!(hub.sessions().is_empty());
    let _ = other.kill();
    let _ = other.wait();

    // No process names it, but its transcript was just written while a
    // Codex harness runs.
    let mut harness = harness_stand_in(&root.join("bin"), "codex", &project);
    std::fs::File::options()
        .write(true)
        .open(&rollout)
        .unwrap()
        .set_modified(std::time::SystemTime::now())
        .unwrap();
    let recent = c.request(method::SESSION_NEW, adopt("fakecodex", &live)).await.unwrap_err();
    assert!(recent.contains("written"), "{recent}");
    assert!(hub.sessions().is_empty());
    let _ = harness.kill();
    let _ = harness.wait();

    let opened =
        c.request(method::SESSION_NEW, adopt_if_live("fakecodex", &live, Some("open"))).await;
    let id = opened.unwrap()["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(hub.resolve(&id).unwrap().meta().agent_session_id.as_deref(), Some(live.as_str()));
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
    // Under /tmp: a harness stand-in's path is read from `ps` split on spaces, and a worker's
    // temp dir may have one (`/Library/Application Support/...`).
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

    // Just written while a Claude Code harness runs: live.
    let mut harness = harness_stand_in(&root.join("bin"), "claude", &project);
    let refused = c.request(method::SESSION_NEW, adopt("fakeclaude", &fork_id)).await.unwrap_err();
    assert!(refused.contains("written"), "{refused}");
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
    backdate(&rollout);

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
        edit["locations"],
        json!([{"path": changelog, "line": 1}, {"path": cargo, "line": 1}])
    );
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
    let text = serde_json::to_string_pretty(&records)
        .unwrap()
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
    backdate(&transcript);
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
    assert_eq!(calls[1]["locations"], json!([{"path": file}]));
    let done: Vec<&Value> =
        events.iter().filter(|e| e.kind == "tool_call_update").map(update_of).collect();
    assert_eq!(done[0]["status"], "completed");
    assert_eq!(
        done[0].pointer("/content/0/content/text"),
        Some(&json!("src/lib.rs:3:fn old_helper() {}"))
    );
    assert_eq!(
        done[1]["content"],
        json!([{"type": "diff", "path": file, "oldText": "fn old_helper() {}", "newText": "fn new_helper() {}"}])
    );
    assert_eq!(done[2]["status"], "failed");
    assert_eq!(
        update_of(&events[8]).pointer("/content/text"),
        Some(&json!("Renamed old_helper to new_helper; one test still fails."))
    );
    let _ = std::fs::remove_dir_all(root);
}
