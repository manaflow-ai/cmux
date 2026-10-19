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
    let now_ms = || {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis()
    };

    // Another `claude` in the chat's folder, holding some other chat.
    let mut other = harness_stand_in(&root.join("bin"), "claude", &project);
    // A `claude` that still runs this chat: refused, naming its pid.
    std::thread::sleep(Duration::from_millis(50));
    register(other.id(), now_ms());
    let refused = c.request(method::SESSION_NEW, adopt("fakeclaude", &chat)).await.unwrap_err();
    assert!(refused.contains("open in another process"), "{refused}");
    assert!(refused.contains(&other.id().to_string()), "{refused}");
    assert!(hub.sessions().is_empty());
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
