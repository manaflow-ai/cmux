//! `acp.session.fork` (the pane's "Fork from Here"): a fork through the
//! latest completed turn, advertised in `initialize`. An earlier turn forks
//! a Claude or Codex chat (session replay's Continue from here) and is
//! refused with a clear error for any other agent.

use super::*;

// Side questions fork the chat too, and share its Claude helpers.
#[path = "aside.rs"]
mod aside;
// Side sessions fork the chat too, and share its Claude helpers.
#[path = "btw.rs"]
mod btw;
// The context window a Claude chat reports, which shares these helpers too.
#[path = "context_window.rs"]
mod context_window;
// The account's plan usage limits a Claude chat reports, which share these helpers too.
#[path = "usage_limits.rs"]
mod usage_limits;
// What a Claude chat spent and holds, read from its transcript, which shares these helpers too.
#[path = "usage_stats.rs"]
mod usage_stats;
// Claude's todo list as an ACP plan, which shares these helpers too.
#[path = "todo_plan.rs"]
mod todo_plan;
// Claude's background shells ending, which share these helpers too.
#[path = "background_task.rs"]
mod background_task;
// Claude's Agent tool as a subagent session, which shares these helpers too.
#[path = "claude_subagents.rs"]
mod claude_subagents;
// Claude Code's turns of its own, which the person did not start, which share these helpers too.
#[path = "background_turns.rs"]
mod background_turns;
// Claude's "Allow for this session", which shares these helpers too.
#[path = "claude_allow_always.rs"]
mod claude_allow_always;
#[path = "claude_allow_input.rs"]
mod claude_allow_input;
// The background-process registry over Claude's shells, which shares these helpers too.
#[path = "processes.rs"]
mod processes;
// The same registry over Codex's background terminals (the fake app-server).
#[cfg(unix)]
#[path = "codex_processes.rs"]
mod codex_processes;
// Claude's skills in the slash command list, which share these helpers too.
#[path = "claude_skill_commands.rs"]
mod claude_skill_commands;
// Each chat's harness in its own cgroup scope on Linux, which shares these helpers too.
#[cfg(target_os = "linux")]
#[path = "session_scope.rs"]
mod session_scope;
// Each turn's model, tokens and cost, which share these helpers too.
#[path = "turn_usage.rs"]
mod turn_usage;

// A fork of a chat whose turn runs, which shares these helpers too.
#[path = "fork_running.rs"]
mod fork_running;

const FORK_OP: &str = "acp.session.fork";

#[tokio::test]
async fn initialize_advertises_the_fork_operation() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let init = c
        .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "pane"}}))
        .await
        .unwrap();
    let ops = init["_meta"]["acpmux"]["operations"].as_array().cloned().unwrap_or_default();
    assert!(ops.iter().any(|op| op == FORK_OP), "{ops:?}");
}

#[tokio::test]
async fn a_fork_through_the_latest_turn_opens_a_new_session_and_an_earlier_turn_is_refused() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "src"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    for text in ["first", "second"] {
        c.request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
        .unwrap();
    }
    let results: Vec<u64> = hub
        .events(&id, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "turn_result")
        .map(|e| e.seq)
        .collect();
    assert_eq!(results.len(), 2, "{results:?}");

    let earlier =
        c.request(FORK_OP, json!({"sessionId": id, "throughSeq": results[0]})).await.unwrap_err();
    assert!(earlier.contains("latest"), "{earlier}");
    let missing = c.request(FORK_OP, json!({"sessionId": id})).await.unwrap_err();
    assert!(missing.contains("throughSeq"), "{missing}");

    let f = c.request(FORK_OP, json!({"sessionId": id, "throughSeq": results[1]})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    assert_ne!(fid, id);
    let forked = hub.resolve(&fid).unwrap();
    assert_eq!(forked.meta().parent_id.as_deref(), Some(id.as_str()));
    // The session list names where the fork branched, for the pane's < 1/2 > arrows (cx-ncc.61):
    // a fork at the chat's end (this agent is not Claude) branches after the chat's last event.
    let listed = hub.session_summary(&forked);
    assert_eq!(listed["parentId"], id.as_str());
    let fork_seq = forked.meta().fork_seq.expect("a fork records where it branched");
    assert!(fork_seq >= results[1], "{fork_seq} < {}", results[1]);
    assert_eq!(listed["forkSeq"], fork_seq);
    let prompts =
        hub.events(&fid, 0, 1000).unwrap().into_iter().filter(|e| e.kind == "user_message").count();
    assert_eq!(prompts, 2, "the fork holds both turns");
    // Each copied turn ends in the fork too, or the pane shows its last
    // reply as still streaming and the chat as working.
    let ended =
        hub.events(&fid, 0, 1000).unwrap().into_iter().filter(|e| e.kind == "turn_result").count();
    assert_eq!(ended, 2, "the fork holds both turn ends");
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": fid, "prompt": [{"type": "text", "text": "third"}]}),
        )
        .await
        .unwrap();
    assert_eq!(r["stopReason"], "end_turn");
}

/// A hub whose default agent is a Claude stdio profile keeping Claude Code's
/// own store layout under `claude` (fake_claude.py with CLAUDE_CONFIG_DIR).
pub(super) async fn claude_setup(
    claude: &std::path::Path,
    env: &[(&str, &str)],
) -> (Arc<Hub>, TestClient) {
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let mut env: BTreeMap<String, String> =
        env.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
    env.insert("CLAUDE_CONFIG_DIR".to_owned(), claude.to_string_lossy().into_owned());
    let profile = HarnessProfile {
        kind: acpmux::config::HarnessKind::ClaudeStdio,
        argv: vec!["python3".into(), fake_claude.into()],
        env,
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([("claude".to_owned(), profile)]),
        default_harness: Some("claude".into()),
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

/// What the session's agent conversation holds: fake_claude.py and
/// fake_agent.py's Codex store answer "history-probe" with the prompts in
/// their stored transcript.
async fn claude_history(hub: &Arc<Hub>, c: &mut TestClient, id: &str) -> Value {
    let before = hub.events(id, 0, 10_000).unwrap().last().map_or(0, |e| e.seq);
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "history-probe"}]}),
    )
    .await
    .unwrap();
    let text: String = hub
        .events(id, before, 10_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "agent_message_chunk")
        .filter_map(|e| e.msg.pointer("/params/update/content/text").and_then(Value::as_str))
        .collect();
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{e}: {text}"))
}

/// Session replay's Continue from here: a Claude chat forks through an
/// earlier turn. The fork's chat shows that turn and no later one, its
/// Claude conversation remembers only the prompts up to it, and the source
/// chat's conversation is untouched.
#[tokio::test]
async fn a_claude_chat_forks_through_an_earlier_turn_holding_only_the_history_before_it() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-at-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "src"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    for text in ["first", "second"] {
        c.request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
        .unwrap();
    }
    let results: Vec<u64> = hub
        .events(&id, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "turn_result")
        .map(|e| e.seq)
        .collect();
    assert_eq!(results.len(), 2, "{results:?}");

    let f = c.request(FORK_OP, json!({"sessionId": id, "throughSeq": results[0]})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    let count = |kind: &str| {
        hub.events(&fid, 0, 1000).unwrap().into_iter().filter(|e| e.kind == kind).count()
    };
    let chat = (count("user_message"), count("turn_result"));
    let fork = claude_history(&hub, &mut c, &fid).await;
    let source = claude_history(&hub, &mut c, &id).await;
    assert_eq!(chat, (1, 1), "the fork's chat holds the first turn only");
    assert_eq!(fork["prompts"], json!(["first"]), "{fork}");
    assert_eq!(fork["sessions"].as_array().map(Vec::len), Some(1), "one conversation id: {fork}");
    assert_ne!(fork["sessions"], source["sessions"], "the fork is its own conversation");
    assert_eq!(source["prompts"], json!(["first", "second"]), "{source}");
    let _ = std::fs::remove_dir_all(&root);
}

/// Fork Conversation (`acp.session.fork`) answers as soon as its chat is made: its agent starts after, so
/// a slow harness start (Claude takes seconds) never holds Fork Conversation
/// (NIGHTLY 2026-10-29: 12-16 s with nothing on screen). A prompt to the fork
/// waits for that start and is answered.
#[tokio::test]
async fn a_claude_fork_answers_before_its_agent_has_started() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-fast-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[("FAKE_CLAUDE_INIT_DELAY_MS", "3000")]).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "src"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "first"}]}),
    )
    .await
    .unwrap();

    let started = std::time::Instant::now();
    let f = c.request(FORK_OP, json!({"sessionId": id, "live": true})).await.unwrap();
    let took = started.elapsed();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    assert!(
        took < std::time::Duration::from_millis(1500),
        "the fork waited {took:?} for its agent"
    );
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": fid, "prompt": [{"type": "text", "text": "second"}]}),
        )
        .await
        .unwrap();
    assert_eq!(r["stopReason"], "end_turn");
    // The fork's agent holds the chat's turn, then its own (a forked Claude process is primed
    // with one line at its start, as before).
    let fork = claude_history(&hub, &mut c, &fid).await;
    let prompts: Vec<&str> = fork["prompts"]
        .as_array()
        .map(|p| {
            p.iter()
                .filter_map(Value::as_str)
                .filter(|p| !p.starts_with("This session was just forked"))
                .collect()
        })
        .unwrap_or_default();
    assert_eq!(prompts, ["first", "second"], "{fork}");
    let _ = std::fs::remove_dir_all(&root);
}

/// A plain `session/fork` still answers once its agent has started: its callers (a terminal's
/// fork, side questions) read the fork's agent session id, model and env from the answer.
#[tokio::test]
async fn a_plain_session_fork_answers_once_its_agent_has_started() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-plain-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "src"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "first"}]}),
    )
    .await
    .unwrap();
    let f = c.request(method::SESSION_FORK, json!({"sessionId": id, "cwd": cwd()})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    assert!(hub.resolve(&fid).unwrap().meta().agent_session_id.is_some(), "{f}");
    let _ = std::fs::remove_dir_all(&root);
}

/// A Claude chat with no turn has no conversation for `--resume --fork-session`
/// to copy: its fork is refused with a reason, and no chat is made (the
/// fork matrix found the fork made, then failing with "No conversation found").
#[tokio::test]
async fn a_fork_of_a_claude_chat_with_no_turn_is_refused_and_makes_no_chat() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-empty-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "empty"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let before = c.request(method::SESSION_LIST, json!({})).await.unwrap()["sessions"]
        .as_array()
        .map(Vec::len);
    let err = c
        .request(method::SESSION_FORK, json!({"sessionId": id, "cwd": cwd()}))
        .await
        .expect_err("an empty chat has nothing to fork");
    assert!(err.contains("no turn"), "{err}");
    let after = c.request(method::SESSION_LIST, json!({})).await.unwrap()["sessions"]
        .as_array()
        .map(Vec::len);
    assert_eq!(before, after, "a refused fork makes no chat");
    // After a turn the same chat forks, and the fork answers.
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "first"}]}),
    )
    .await
    .unwrap();
    let f = c.request(method::SESSION_FORK, json!({"sessionId": id, "cwd": cwd()})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    // A whole-chat Claude fork that starts without its new conversation id
    // learns it from a first turn acpmux sends (`hub/lifecycle.rs`); whether
    // that turn runs depends on when Claude Code reports its id, so it is
    // left out here. The fork holds the chat's own turn.
    let history = claude_history(&hub, &mut c, &fid).await;
    let prompts: Vec<&Value> = history["prompts"]
        .as_array()
        .unwrap_or_else(|| panic!("{history}"))
        .iter()
        .filter(|p| *p != "This session was just forked. Reply with exactly: ready")
        .collect();
    assert_eq!(prompts, [&json!("first")], "{history}");
    let _ = std::fs::remove_dir_all(&root);
}

/// The cut follows Claude's transcript, not a count of the chat's prompts: a
/// prompt Claude never stored (its launcher died) does not move it, so the
/// fork through the turn after it holds that turn and no later one.
#[tokio::test]
async fn a_claude_fork_through_a_turn_after_a_failed_one_holds_that_turn_and_no_later_one() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-at-{}", uuid::Uuid::now_v7()));
    let (claude, die) = (root.join("claude"), root.join("die"));
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) =
        claude_setup(&claude, &[("FAKE_CLAUDE_DIE_IF", &die.to_string_lossy())]).await;
    // The turn whose agent dies stays failed: no continuation runs before "second".
    hub.config.write().await.auto_resume_delays_ms = Some(vec![]);
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "src"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = |text: &str| json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
    c.request(method::SESSION_PROMPT, prompt("first")).await.unwrap();
    std::fs::write(&die, "").unwrap();
    hub.detach_child(&hub.resolve(&id).unwrap()).await;
    let _ = c.request(method::SESSION_PROMPT, prompt("lost")).await;
    std::fs::remove_file(&die).unwrap();
    hub.detach_child(&hub.resolve(&id).unwrap()).await;
    for text in ["second", "third"] {
        c.request(method::SESSION_PROMPT, prompt(text)).await.unwrap();
    }
    let events = hub.events(&id, 0, 1000).unwrap();
    let second = events
        .iter()
        .position(|e| e.kind == "user_message" && e.msg["text"] == "second")
        .unwrap_or_else(|| panic!("no second prompt: {events:?}"));
    let through = events[second..].iter().find(|e| e.kind == "turn_result").unwrap().seq;

    let f = c.request(FORK_OP, json!({"sessionId": id, "throughSeq": through})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    let fork = claude_history(&hub, &mut c, &fid).await;
    assert_eq!(fork["prompts"], json!(["first", "second"]), "{fork}");
    let _ = std::fs::remove_dir_all(&root);
}

/// Turns a fork inherited keep the times they happened: forking the fork
/// through one of them holds that turn and no later one.
#[tokio::test]
async fn a_fork_of_a_claude_fork_through_an_inherited_turn_holds_that_turn_and_no_later_one() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-at-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "src"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let say =
        |id: &str, text: &str| json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
    for text in ["first", "second", "third"] {
        c.request(method::SESSION_PROMPT, say(&id, text)).await.unwrap();
    }
    let results = |id: &str| -> Vec<u64> {
        hub.events(id, 0, 1000)
            .unwrap()
            .into_iter()
            .filter(|e| e.kind == "turn_result")
            .map(|e| e.seq)
            .collect()
    };
    let f =
        c.request(FORK_OP, json!({"sessionId": id, "throughSeq": results(&id)[1]})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, say(&fid, "fresh")).await.unwrap();

    let g = c
        .request(FORK_OP, json!({"sessionId": fid, "throughSeq": results(&fid)[0]}))
        .await
        .unwrap();
    let gid = g["sessionId"].as_str().unwrap().to_owned();
    let fork = claude_history(&hub, &mut c, &gid).await;
    assert_eq!(fork["prompts"], json!(["first"]), "{fork}");
    let _ = std::fs::remove_dir_all(&root);
}

/// A Claude conversation that starts after the turn (Claude started fresh
/// on a failover) cannot be forked through it: the fork is refused instead
/// of resuming a conversation with none of the chat's turns.
#[tokio::test]
async fn a_claude_fork_through_a_turn_its_conversation_does_not_hold_is_refused() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-at-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "src"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    for text in ["first", "second"] {
        c.request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
        .unwrap();
    }
    // The conversation now begins at the second prompt.
    let sid = hub.resolve(&id).unwrap().meta().agent_session_id.unwrap();
    let file = claude.join("projects").join("p").join(format!("{sid}.jsonl"));
    let kept: Vec<String> = std::fs::read_to_string(&file)
        .unwrap()
        .lines()
        .skip_while(|line| !line.contains("\"second\""))
        .map(str::to_owned)
        .collect();
    std::fs::write(&file, kept.join("\n") + "\n").unwrap();
    let first = hub
        .events(&id, 0, 1000)
        .unwrap()
        .into_iter()
        .find(|e| e.kind == "turn_result")
        .unwrap()
        .seq;

    let refused = c.request(FORK_OP, json!({"sessionId": id, "throughSeq": first})).await;
    assert!(refused.is_err(), "{refused:?}");
    let _ = std::fs::remove_dir_all(&root);
}

/// A hub whose default agent is Codex (profile `codex`) keeping Codex's own
/// rollout store under `codex` (fake_agent.py's FAKE_CODEX_STORE).
async fn codex_setup(codex: &std::path::Path) -> (Arc<Hub>, TestClient) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = HarnessProfile {
        kind: acpmux::config::HarnessKind::Acp,
        argv: vec!["python3".into(), fake.into()],
        env: BTreeMap::from([
            ("CODEX_HOME".to_owned(), codex.to_string_lossy().into_owned()),
            ("FAKE_CODEX_STORE".to_owned(), "1".to_owned()),
        ]),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([("codex".to_owned(), profile)]),
        default_harness: Some("codex".into()),
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

/// Fork from Here on an earlier turn of a Codex chat (cx-a7r): the fork's
/// chat shows that turn and no later one, its Codex conversation remembers
/// only the prompts up to it, and the source chat's conversation is untouched.
#[tokio::test]
async fn a_codex_chat_forks_through_an_earlier_turn_holding_only_the_history_before_it() {
    let root = std::env::temp_dir().join(format!("acpmux-codex-fork-at-{}", uuid::Uuid::now_v7()));
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
    for text in ["first", "second"] {
        c.request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
        .unwrap();
    }
    let results: Vec<u64> = hub
        .events(&id, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "turn_result")
        .map(|e| e.seq)
        .collect();
    assert_eq!(results.len(), 2, "{results:?}");

    let f = c.request(FORK_OP, json!({"sessionId": id, "throughSeq": results[0]})).await;
    let fid = f.unwrap_or_else(|e| panic!("an earlier Codex turn forks: {e}"))["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let count = |kind: &str| {
        hub.events(&fid, 0, 1000).unwrap().into_iter().filter(|e| e.kind == kind).count()
    };
    let chat = (count("user_message"), count("turn_result"));
    let fork = claude_history(&hub, &mut c, &fid).await;
    let source = claude_history(&hub, &mut c, &id).await;
    assert_eq!(chat, (1, 1), "the fork's chat holds the first turn only");
    assert_eq!(fork["prompts"], json!(["first"]), "{fork}");
    assert_eq!(fork["sessions"].as_array().map(Vec::len), Some(1), "one conversation id: {fork}");
    assert_ne!(fork["sessions"], source["sessions"], "the fork is its own conversation");
    assert_eq!(source["prompts"], json!(["first", "second"]), "{source}");
    let _ = std::fs::remove_dir_all(&root);
}
