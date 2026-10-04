//! The compactor's acpmux route against the fake acpmux port: one session
//! per node with a deny-all policy and its own required preset, in a slot
//! working directory outside the home, the size loop in the same session,
//! the session killed and its transcript deleted when the node is done or
//! failed, at most JOBS sessions across the main and fallback compactors,
//! refusals as acpmux really sends them, and the route chosen by the endpoint.

mod common;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::*;
use optchat_chief::brain::Input;
use optchat_chief::compactor::{
    AcpmuxCompactor, COMPACTOR_ARGS, CompactRoute, CompactorSpec, DENIED_TOOLS, POLICY,
    SYSTEM_FILE, Slots, cached_prompt, compact_route, compactor_preset, compactor_settings,
    compactor_spec, is_marker_limit_error, is_refusal_error, probe_models, project_dir_name,
    request_blocks, strip_preamble,
};
use optchat_chief::paths::Paths;
use optchat_core::JOBS;
use optchat_host::{
    CompactModel, CompactRequest, Config, DEFAULT_BASE_URL, Kind, NodeId, OptChat, PROBE_NODE,
    SUBROUTER_KEY, SystemClock, probe, run_node,
};
use serde_json::{Value, json};

/// What acpmux answers when Claude Code ends a turn with stop reason
/// `refusal`: a JSON-RPC error (code -32603) whose message is Claude Code's
/// result text (acpmux `claude_stdio/inbound.rs`; text from Claude Code 2.1.289).
const REFUSAL: &str = "API Error: Claude Sonnet 5.5's safeguards flagged this message (https://www.anthropic.com/legal/aup). This sometimes happens with safe, normal conversations. Claude Code can't respond to this message with Claude Sonnet 5.5.\n\nTry rephrasing the request in a new session or change your model.\n\nLearn more: https://support.claude.com";

/// One fake turn that answers `text`.
fn answer(text: &str) -> Vec<Value> {
    vec![
        json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
        update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": text}}),
        ),
        json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
    ]
}

fn spec(dir: &std::path::Path) -> CompactorSpec {
    CompactorSpec {
        name: "optchat-compact-test".into(),
        work: dir.join("work"),
        transcript_dirs: vec![dir.join("compactor-claude"), dir.join("user-claude")],
        preset: "optchat-compact-test-preset".into(),
        harness: "claude-sr".into(),
        model: Some("claude-sonnet-5-5".into()),
        effort: None,
        timeout: Duration::from_secs(30),
    }
}

fn compactor(agents: &Arc<FakeAgents>, dir: &std::path::Path) -> AcpmuxCompactor {
    AcpmuxCompactor::new(agents.clone(), spec(dir), Slots::new(JOBS))
}

fn request(i: u64) -> CompactRequest {
    CompactRequest {
        node: NodeId::new(0, i),
        system: "SYS".into(),
        context: "<chat>\nuser: hi\n</chat>".into(),
        step: format!("STEP {i}"),
        cut: None,
    }
}

fn texts(blocks: &[Value]) -> Vec<String> {
    blocks
        .iter()
        .map(|b| b["text"].as_str().unwrap_or_default().to_owned())
        .collect()
}

#[test]
fn a_node_is_built_in_one_deny_all_session_that_is_then_purged() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: pasted a deploy log")));
    let compactor = Arc::new(compactor(&agents, dir.path()));
    let config = Config {
        reporter: Arc::new(|_| {}),
        ..Config::default()
    };
    let system = config.prompt.text(&config.agent);
    let chat = OptChat::open_with(
        dir.path().join("chat"),
        config,
        compactor,
        Arc::new(SystemClock),
    )
    .unwrap();
    chat.append(Kind::User, &"deploy step; ".repeat(100))
        .unwrap();
    assert!(
        chat.settle(None, Some(WAIT)),
        "{:?}",
        chat.status().failures
    );
    assert!(
        chat.render_view()
            .text
            .contains("user: pasted a deploy log")
    );
    let inner = agents.inner.lock().unwrap();
    assert_eq!(inner.specs.len(), 1);
    let s = &inner.specs[0];
    assert_eq!(s.policy, POLICY);
    let work = std::fs::canonicalize(dir.path().join("work")).unwrap();
    assert_eq!(
        s.cwd,
        work.join("slot-0"),
        "a slot directory, its real path"
    );
    assert_eq!(s.harness, "claude-sr");
    assert_eq!(s.model.as_deref(), Some("claude-sonnet-5-5"));
    assert_eq!(
        s.preset.as_deref(),
        Some("optchat-compact-test-preset"),
        "the compactor names its own preset, which acpmux must have"
    );
    assert_eq!(s.effort, None, "no effort until it is verified live");
    assert!(s.name.starts_with("optchat-compact-test-"));
    // System text, then the context pieces, then the step (section 8's order).
    let blocks = texts(&inner.prompts[0]);
    assert_eq!(blocks[0], system);
    assert_eq!(blocks[1], "<chat>\n</chat>");
    assert!(blocks[2].contains("Compress this message into one line"));
    assert_eq!(blocks.len(), 3);
    assert_eq!(inner.ended, vec!["s1"], "the node's session is killed");
}

#[test]
fn the_size_loop_continues_in_the_same_session() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|turn, _| {
        if turn == 0 {
            answer(&"long".repeat(175))
        } else {
            answer("user: short now")
        }
    }));
    let compactor = compactor(&agents, dir.path());
    assert_eq!(
        run_node(&compactor, &request(3)).unwrap(),
        "user: short now"
    );
    let inner = agents.inner.lock().unwrap();
    assert_eq!(inner.specs.len(), 1, "one session for the node");
    assert_eq!(inner.prompts.len(), 2);
    let retry = texts(&inner.prompts[1]);
    assert_eq!(retry.len(), 1, "a retry sends only the size message");
    assert!(retry[0].starts_with("That line is 700 bytes"), "{retry:?}");
    assert_eq!(inner.ended, vec!["s1"]);
    assert_ne!(inner.prompt_ids[0], inner.prompt_ids[1]);
}

#[test]
fn a_failed_node_kills_its_session_and_a_refusal_is_reported_as_one() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("")));
    agents.inner.lock().unwrap().answer = Some(json!({"stopReason": "refusal"}));
    let compactor = compactor(&agents, dir.path());
    let error = run_node(&compactor, &request(0)).unwrap_err();
    assert!(error.refused, "{error:?}");
    assert_eq!(agents.inner.lock().unwrap().ended, vec!["s1"]);

    agents.inner.lock().unwrap().lose = true;
    let error = run_node(&compactor, &request(1)).unwrap_err();
    assert!(!error.refused);
    assert_eq!(agents.inner.lock().unwrap().ended, vec!["s1", "s2"]);
}

#[test]
fn at_most_jobs_compactor_sessions_live_at_once() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|turn, _| answer(&format!("user: node {turn}"))));
    agents.hold(true);
    let compactor = Arc::new(compactor(&agents, dir.path()));
    let extra = 3;
    let workers: Vec<_> = (0..(JOBS + extra) as u64)
        .map(|i| {
            let c = compactor.clone();
            std::thread::spawn(move || run_node(&*c, &request(i)))
        })
        .collect();
    agents.wait_prompts(JOBS);
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(
        agents.inner.lock().unwrap().specs.len(),
        JOBS,
        "the others wait for a free session slot"
    );
    agents.hold(false);
    agents.release();
    for w in workers {
        assert!(w.join().unwrap().is_ok());
    }
    let inner = agents.inner.lock().unwrap();
    assert_eq!(inner.specs.len(), JOBS + extra);
    assert_eq!(inner.ended.len(), JOBS + extra);
}

#[test]
fn the_probe_builds_one_node_through_acpmux() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: ping")));
    let compactor = compactor(&agents, dir.path());
    assert_eq!(probe(&compactor, "SYS").unwrap(), "user: ping");
    let inner = agents.inner.lock().unwrap();
    assert_eq!(inner.specs[0].name, "optchat-compact-test-probe");
    assert_eq!(inner.ended, vec!["s1"]);
    drop(inner);
    let _ = PROBE_NODE;
}

#[test]
fn request_blocks_keep_the_cache_shape() {
    let line = format!("{}\n", "x".repeat(99));
    let mut context = String::from("<chat>\n");
    for _ in 0..1_100 {
        context.push_str(&line);
    }
    context.push_str("</chat>");
    let r = CompactRequest {
        context: context.clone(),
        ..request(0)
    };
    let blocks = texts(&request_blocks(&r));
    assert_eq!(blocks[0], "SYS");
    assert_eq!(blocks.len(), 1 + 4 + 1, "system, four context pieces, step");
    assert_eq!(blocks[1..5].concat(), context);
    assert_eq!(blocks[5], "STEP 0");
}

#[test]
fn the_route_is_acpmux_on_the_subrouter_and_the_api_on_a_configured_endpoint() {
    let config = |base: &str, key: &str| Config {
        base_url: base.into(),
        api_key: key.into(),
        ..Config::default()
    };
    let sub = config(DEFAULT_BASE_URL, SUBROUTER_KEY);
    assert_eq!(compact_route(None, &sub), Ok(CompactRoute::Acpmux));
    let sub_with_key = config(&format!("{DEFAULT_BASE_URL}/"), "sk-mine");
    assert_eq!(compact_route(None, &sub_with_key), Ok(CompactRoute::Acpmux));
    let keyless = config("https://api.anthropic.com", SUBROUTER_KEY);
    assert_eq!(compact_route(None, &keyless), Ok(CompactRoute::Acpmux));
    let real = config("https://api.anthropic.com", "sk-real");
    assert_eq!(compact_route(None, &real), Ok(CompactRoute::Api));
    assert_eq!(compact_route(Some("api"), &sub), Ok(CompactRoute::Api));
    assert_eq!(
        compact_route(Some("acpmux"), &real),
        Ok(CompactRoute::Acpmux)
    );
    assert!(compact_route(Some("bogus"), &sub).is_err());
}

#[test]
fn a_notice_is_posted_once_when_the_conversation_is_known() {
    let mut h = Harness::new(default_script());
    let notice = || Input::Notice {
        key: "notice:compactor:1".into(),
        text: "The memory compactor cannot build summaries".into(),
    };
    h.brain.step(notice());
    assert!(
        h.owner.lock().unwrap().sends().is_empty(),
        "no conversation yet"
    );
    h.connect();
    h.brain.step(notice());
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(
        sends,
        vec![(
            "notice:compactor:1".to_owned(),
            "The memory compactor cannot build summaries".to_owned()
        )]
    );
}

// Audit round 3, M2: acpmux reports a refused Claude turn as a JSON-RPC
// error carrying Claude Code's text, never as `{stopReason: "refusal"}`.
#[test]
fn a_refusal_as_acpmux_sends_it_is_classified_as_refused() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("")));
    agents.inner.lock().unwrap().answer_error = Some(REFUSAL.into());
    let compactor = compactor(&agents, dir.path());
    let error = run_node(&compactor, &request(0)).unwrap_err();
    assert!(error.refused, "{error:?}");
    assert_eq!(agents.inner.lock().unwrap().ended, vec!["s1"]);

    agents.inner.lock().unwrap().answer_error =
        Some("Claude AI usage limit reached|1759600000".into());
    let error = run_node(&compactor, &request(1)).unwrap_err();
    assert!(
        !error.refused,
        "a usage limit is retried, not refused: {error:?}"
    );
}

#[test]
fn refusal_texts() {
    assert!(is_refusal_error(REFUSAL));
    assert!(is_refusal_error(
        "API Error: Claude Code is unable to respond to this request, which appears to violate our Usage Policy (https://www.anthropic.com/legal/aup). Please double press esc to edit your last message or start a new session for Claude Code to assist with a different task."
    ));
    assert!(is_refusal_error(
        "API Error: Claude can't help with this. Start a new session. Learn more: https://www.anthropic.com/legal/aup"
    ));
    assert!(!is_refusal_error(
        "Claude AI usage limit reached|1759600000"
    ));
    assert!(!is_refusal_error(
        "agent process closed (claude-sr): proxy down"
    ));
    assert!(!is_refusal_error("API Error: 529 overloaded"));
}

#[test]
fn a_refused_node_is_built_by_the_fallback_compactor() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: built by the fallback")));
    agents.inner.lock().unwrap().answer_error = Some(REFUSAL.into());
    let slots = Slots::new(JOBS);
    let main = Arc::new(AcpmuxCompactor::new(
        agents.clone(),
        spec(dir.path()),
        slots.clone(),
    ));
    let fallback = Arc::new(AcpmuxCompactor::new(
        agents.clone(),
        CompactorSpec {
            model: Some("claude-sonnet-5".into()),
            ..spec(dir.path())
        },
        slots,
    ));
    let chat = OptChat::open_with_fallback(
        dir.path().join("chat"),
        Config {
            reporter: Arc::new(|_| {}),
            ..Config::default()
        },
        main,
        Some(fallback),
        Arc::new(SystemClock),
    )
    .unwrap();
    chat.append(Kind::User, &"a long message; ".repeat(60))
        .unwrap();
    assert!(
        chat.settle(None, Some(WAIT)),
        "{:?}",
        chat.status().failures
    );
    assert!(
        chat.render_view()
            .text
            .contains("user: built by the fallback")
    );
    let inner = agents.inner.lock().unwrap();
    assert_eq!(inner.specs[1].model.as_deref(), Some("claude-sonnet-5"));
}

// Audit round 3, m4: the start-up probe checks the fallback model too.
#[test]
fn the_probe_checks_the_fallback_model_too() {
    let dir = tempfile::tempdir().unwrap();
    let good = FakeAgents::new(Box::new(|_, _| answer("user: ping")));
    let bad = FakeAgents::new(Box::new(|_, _| answer("")));
    bad.inner.lock().unwrap().answer_error = Some("model claude-sonnet-5 not found".into());
    let main = compactor(&good, dir.path());
    let fallback = compactor(&bad, dir.path());
    assert_eq!(probe_models(&main, None, "SYS"), Ok("user: ping".into()));
    let error = probe_models(&main, Some(&fallback as &dyn CompactModel), "SYS").unwrap_err();
    assert!(error.contains("fallback"), "{error}");
    assert!(error.contains("not found"), "{error}");
}

/// A Claude Code `system/init` as acpmux records it.
fn init(tools: Value, mcp: Value) -> Value {
    update(
        "session_info_update",
        json!({"title": null, "_meta": {"claude": {"tools": tools, "mcp_servers": mcp, "model": "claude-sonnet-5-5"}}}),
    )
}

// Audit round 3, M3 and m4: the probe fails when the compactor session
// offers a tool or an MCP server.
#[test]
fn the_probe_fails_when_the_compactor_session_has_tools_or_mcp_servers() {
    let dir = tempfile::tempdir().unwrap();
    let with = |tools: Value, mcp: Value| {
        let agents = FakeAgents::new(Box::new(move |_, _| {
            let mut events = vec![init(tools.clone(), mcp.clone())];
            events.extend(answer("user: ping"));
            events
        }));
        probe(&compactor(&agents, dir.path()), "SYS")
    };
    assert_eq!(with(json!([]), json!([])), Ok("user: ping".into()));
    let error = with(json!(["AskUserQuestion", "Read"]), json!([])).unwrap_err();
    assert!(error.message.contains("AskUserQuestion"), "{error:?}");
    let error = with(
        json!([]),
        json!([{"name": "github", "status": "connected"}]),
    )
    .unwrap_err();
    assert!(error.message.contains("github"), "{error:?}");
}

// Audit round 3, M5: one host.log line per node with its token use.
#[test]
fn each_node_logs_its_seconds_and_token_use() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: hi")));
    agents.inner.lock().unwrap().answer = Some(json!({
        "stopReason": "end_turn",
        "_meta": {"claude": {"subtype": "success", "cost_usd": 0.081, "num_turns": 1, "usage": {
            "input_tokens": 3, "cache_creation_input_tokens": 21000,
            "cache_read_input_tokens": 9000, "output_tokens": 40
        }}}
    }));
    let lines = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink = lines.clone();
    let compactor = compactor(&agents, dir.path()).with_log(Arc::new(move |l: &str| {
        sink.lock().unwrap().push(l.to_owned())
    }));
    run_node(&compactor, &request(4)).unwrap();
    let lines = lines.lock().unwrap();
    let line = lines
        .iter()
        .find(|l| l.contains("4+1"))
        .expect("a node line");
    for part in [
        "uncached 3",
        "cache write 21000",
        "cache read 9000",
        "output 40",
        "$0.081",
    ] {
        assert!(line.contains(part), "{part} in {line}");
    }
}

// Audit round 3, m3: the main and fallback compactors share one gate.
#[test]
fn main_and_fallback_compactors_share_jobs_slots() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|turn, _| answer(&format!("user: node {turn}"))));
    agents.hold(true);
    let slots = Slots::new(JOBS);
    let a = Arc::new(AcpmuxCompactor::new(
        agents.clone(),
        spec(dir.path()),
        slots.clone(),
    ));
    let b = Arc::new(AcpmuxCompactor::new(
        agents.clone(),
        spec(dir.path()),
        slots,
    ));
    let workers: Vec<_> = (0..(JOBS + 4) as u64)
        .map(|i| {
            let c = if i % 2 == 0 { a.clone() } else { b.clone() };
            std::thread::spawn(move || run_node(&*c, &request(i)))
        })
        .collect();
    agents.wait_prompts(JOBS);
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(agents.inner.lock().unwrap().specs.len(), JOBS);
    let cwds: std::collections::BTreeSet<_> = agents
        .inner
        .lock()
        .unwrap()
        .specs
        .iter()
        .map(|s| s.cwd.clone())
        .collect();
    assert_eq!(
        cwds.len(),
        JOBS,
        "each live session has its own slot directory"
    );
    agents.hold(false);
    agents.release();
    for w in workers {
        assert!(w.join().unwrap().is_ok());
    }
}

// Audit round 3, M6: the node's Claude Code transcript is deleted with it.
#[test]
fn a_finished_node_deletes_its_claude_code_transcript() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_owned();
    let made = Arc::new(Mutex::new(None));
    let seen = made.clone();
    let agents = FakeAgents::new(Box::new(move |_, _| {
        // Claude Code writes the transcript under the config's projects/.
        let cwd = std::fs::canonicalize(root.join("work").join("slot-0")).unwrap();
        let project = root
            .join("compactor-claude")
            .join("projects")
            .join(project_dir_name(&cwd));
        std::fs::create_dir_all(&project).unwrap();
        std::fs::write(project.join("abc.jsonl"), "{}\n").unwrap();
        *seen.lock().unwrap() = Some(project);
        answer("user: hi")
    }));
    run_node(&compactor(&agents, dir.path()), &request(0)).unwrap();
    let project = made.lock().unwrap().clone().unwrap();
    assert!(!project.exists(), "{} is left", project.display());
}

// Live check 2026-10-04: `sr claude proxy` resets CLAUDE_CONFIG_DIR to
// ~/.claude, so the transcript lands there and the compactor config's user
// settings are never read; only the cwd's project settings are.
#[test]
fn the_transcript_is_deleted_from_the_users_claude_home_too() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_owned();
    let made = Arc::new(Mutex::new(None));
    let seen = made.clone();
    let agents = FakeAgents::new(Box::new(move |_, _| {
        let cwd = std::fs::canonicalize(root.join("work").join("slot-0")).unwrap();
        let project = root
            .join("user-claude")
            .join("projects")
            .join(project_dir_name(&cwd));
        std::fs::create_dir_all(&project).unwrap();
        std::fs::write(project.join("abc.jsonl"), "{}\n").unwrap();
        *seen.lock().unwrap() = Some(project);
        answer("user: hi")
    }));
    run_node(&compactor(&agents, dir.path()), &request(0)).unwrap();
    let project = made.lock().unwrap().clone().unwrap();
    assert!(!project.exists(), "{} is left", project.display());
}

#[test]
fn each_slot_directory_carries_the_deny_settings_as_project_settings() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: hi")));
    run_node(&compactor(&agents, dir.path()), &request(0)).unwrap();
    let cwd = agents.inner.lock().unwrap().specs[0].cwd.clone();
    let settings: Value =
        serde_json::from_slice(&std::fs::read(cwd.join(".claude").join("settings.json")).unwrap())
            .unwrap();
    assert_eq!(settings, compactor_settings());
    assert_eq!(settings["disableAllHooks"], true);
}

#[test]
fn project_dir_names_follow_claude_code() {
    assert_eq!(
        project_dir_name(std::path::Path::new(
            "/private/var/folders/x_y/T/optchat-compact-1a/slot-0"
        )),
        "-private-var-folders-x-y-T-optchat-compact-1a-slot-0"
    );
}

// Audit round 3, m5: Claude Code or the model may put a lead-in before the line.
#[test]
fn a_lead_in_before_the_line_is_dropped() {
    assert_eq!(
        strip_preamble("Here is the line:\nuser: asked X"),
        "user: asked X"
    );
    assert_eq!(
        strip_preamble("Here's the compressed line:\n\nuser: asked X"),
        "user: asked X"
    );
    assert_eq!(strip_preamble("user: asked X"), "user: asked X");
    assert_eq!(strip_preamble("user: a: b\nc"), "user: a: b\nc");
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("Here is the line:\nuser: ping")));
    assert_eq!(
        probe(&compactor(&agents, dir.path()), "SYS").unwrap(),
        "user: ping"
    );
}

// Audit round 3, M1, M3, M6 and m5: the compactor's own configuration.
#[test]
fn the_compactor_has_its_own_isolated_configuration() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let paths = Paths::new(&home);
    let preset = compactor_preset(&paths, &home, "claude-sr");
    assert!(
        preset.name.starts_with("optchat-compact-"),
        "{}",
        preset.name
    );
    assert!(preset.name.ends_with(&optchat_chief::paths::home_id(&home)));
    assert_eq!(
        preset.env["CLAUDE_CONFIG_DIR"],
        paths.compactor_config.display().to_string()
    );
    assert_ne!(paths.compactor_config, paths.claude_config);
    assert_eq!(preset.env["CLAUDE_CODE_DISABLE_CLAUDE_MDS"], "1");
    assert_eq!(preset.env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"], "1");
    let settings = compactor_settings();
    let deny: Vec<&str> = settings["permissions"]["deny"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    for tool in [
        "AskUserQuestion",
        "EnterPlanMode",
        "ExitPlanMode",
        "Bash",
        "Read",
        "Task",
    ] {
        assert!(deny.contains(&tool), "{tool} denied");
        assert!(DENIED_TOOLS.contains(&tool));
    }
    assert_eq!(settings["cleanupPeriodDays"], 1);
    assert_eq!(settings["autoMemoryEnabled"], false);
    let spec = compactor_spec(&paths, &home, "claude-sr", "claude-sonnet-5-5");
    assert_eq!(spec.effort, None);
    assert_eq!(spec.preset, preset.name);
    assert!(spec.transcript_dirs.contains(&paths.compactor_config));
    assert!(
        spec.transcript_dirs.len() >= 2,
        "the user's Claude home too: sr resets CLAUDE_CONFIG_DIR"
    );
    assert!(
        !spec.work.starts_with(&home),
        "the compactor's cwd is outside the home: {}",
        spec.work.display()
    );
}

/// A `<chat>` context of `lines` 100-byte lines (about `lines * 100` characters).
fn chat_of(lines: usize) -> String {
    let line = format!("{}\n", "x".repeat(99));
    let mut context = String::from("<chat>\n");
    for _ in 0..lines {
        context.push_str(&line);
    }
    context.push_str("</chat>");
    context
}

fn markers(blocks: &[Value]) -> Vec<usize> {
    blocks
        .iter()
        .enumerate()
        .filter(|(_, b)| b.get("cache_control").is_some())
        .map(|(i, _)| i)
        .collect()
}

/// What Claude Code answers through acpmux when the request has more than
/// four cache breakpoints (checked live: Claude Code uses three itself).
const MARKER_LIMIT: &str = "API Error: 400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"A maximum of 4 blocks with cache_control may be provided. Found 5.\"}}";

// Solution 1 of the cache research: the system text plus the view up to the
// first mark (50k) is the session's system prompt (a file the preset's args
// name), the rest of the view follows as blocks with ONE marker at the last
// mark (100k), then the step.
#[test]
fn with_preset_args_the_view_head_is_the_system_prompt_and_one_marker_sits_at_100k() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: a line")));
    agents.inner.lock().unwrap().preset_args = true;
    let compactor = compactor(&agents, dir.path());
    let context = chat_of(1_100);
    let marks = optchat_core::cache_marks(&context);
    assert_eq!(marks.len(), 3, "50k, 80k and 100k");
    let r = CompactRequest {
        context: context.clone(),
        ..request(0)
    };
    assert_eq!(run_node(&compactor, &r).unwrap(), "user: a line");
    let inner = agents.inner.lock().unwrap();
    // The session's system prompt file: system text, then view[..50k].
    let system = inner.systems[0]
        .clone()
        .expect("system.md written before the session");
    assert_eq!(system, format!("SYS\n\n{}", &context[..marks[0]]));
    let blocks = &inner.prompts[0];
    let t = texts(blocks);
    assert_eq!(t.len(), 4, "50k-80k, 80k-100k, 100k-end, step: {t:?}");
    assert_eq!(t[..3].concat(), context[marks[0]..]);
    assert_eq!(t[1].len() + t[0].len(), marks[2] - marks[0]);
    assert_eq!(t[3], "STEP 0");
    assert_eq!(
        markers(blocks),
        vec![1],
        "one marker, on the piece that ends at 100k"
    );
    assert_eq!(blocks[1]["cache_control"], json!({"type": "ephemeral"}));
    // The file holds the chat's text: gone with the node.
    let slot = inner.specs[0].cwd.clone();
    drop(inner);
    assert!(
        !slot.join(SYSTEM_FILE).exists(),
        "system.md removed when the node ends"
    );
}

#[test]
fn the_marker_sits_at_the_last_mark_that_exists() {
    // 50k and 80k only: the marker goes on the piece that ends at 80k.
    let context = chat_of(900);
    assert_eq!(optchat_core::cache_marks(&context).len(), 2);
    let r = CompactRequest {
        context: context.clone(),
        ..request(0)
    };
    let p = cached_prompt(&r, true);
    assert_eq!(markers(&p.blocks), vec![0]);
    assert_eq!(texts(&p.blocks).len(), 3);
    // Only 50k: everything after it follows unmarked (the system prompt is
    // Claude Code's own breakpoint).
    let r = CompactRequest {
        context: chat_of(600),
        ..request(0)
    };
    let p = cached_prompt(&r, true);
    assert!(markers(&p.blocks).is_empty());
    assert_eq!(texts(&p.blocks).len(), 2);
    // No mark: the system prompt is the system text alone.
    let p = cached_prompt(&request(0), true);
    assert_eq!(p.system, "SYS");
    assert_eq!(
        texts(&p.blocks),
        vec!["<chat>\nuser: hi\n</chat>", "STEP 0"]
    );
    // Without the marker the blocks are the same text.
    let r = CompactRequest {
        context: chat_of(1_100),
        ..request(0)
    };
    let (with, without) = (cached_prompt(&r, true), cached_prompt(&r, false));
    assert_eq!(texts(&with.blocks), texts(&without.blocks));
    assert!(markers(&without.blocks).is_empty());
}

#[test]
fn too_many_cache_breakpoints_retry_once_without_the_marker_and_say_so() {
    assert!(is_marker_limit_error(MARKER_LIMIT));
    assert!(!is_marker_limit_error("API Error: 529 overloaded"));
    assert!(!is_marker_limit_error(REFUSAL));
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: a line")));
    {
        let mut inner = agents.inner.lock().unwrap();
        inner.preset_args = true;
        inner.answer_error = Some(MARKER_LIMIT.into());
    }
    let lines = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink = lines.clone();
    let compactor = compactor(&agents, dir.path()).with_log(Arc::new(move |l: &str| {
        sink.lock().unwrap().push(l.to_owned())
    }));
    let r = CompactRequest {
        context: chat_of(1_100),
        ..request(0)
    };
    // One call: the refused prompt, then a fresh session without the marker.
    assert_eq!(compactor.call(&r, &[]).unwrap().text, "user: a line");
    {
        let inner = agents.inner.lock().unwrap();
        assert_eq!(inner.prompts.len(), 2);
        assert_eq!(markers(&inner.prompts[0]), vec![1]);
        assert!(markers(&inner.prompts[1]).is_empty());
        assert_eq!(texts(&inner.prompts[0]), texts(&inner.prompts[1]));
        assert_eq!(inner.ended, vec!["s1"], "the refused session is gone");
        assert_eq!(inner.systems[1], inner.systems[0], "same system prompt");
    }
    compactor.end(&r);
    assert!(
        lines
            .lock()
            .unwrap()
            .iter()
            .any(|l| l.contains("cache_control") && l.contains("without")),
        "{:?}",
        lines.lock().unwrap()
    );
    // Later nodes skip the marker instead of failing first.
    assert_eq!(run_node(&compactor, &request(1)).unwrap(), "user: a line");
    let r2 = CompactRequest {
        context: chat_of(1_100),
        ..request(2)
    };
    assert_eq!(run_node(&compactor, &r2).unwrap(), "user: a line");
    let inner = agents.inner.lock().unwrap();
    assert!(markers(inner.prompts.last().unwrap()).is_empty());
    assert_eq!(inner.prompts.len(), 4);
}

#[test]
fn without_preset_args_the_old_layout_stays() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(Box::new(|_, _| answer("user: a line")));
    let compactor = compactor(&agents, dir.path());
    let r = CompactRequest {
        context: chat_of(1_100),
        ..request(0)
    };
    run_node(&compactor, &r).unwrap();
    let inner = agents.inner.lock().unwrap();
    assert_eq!(inner.systems[0], None, "no system prompt file");
    assert_eq!(inner.prompts[0], request_blocks(&r));
    assert!(markers(&inner.prompts[0]).is_empty());
}

#[test]
fn the_compactor_preset_names_the_system_prompt_file_and_no_tools() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("mux");
    let paths = Paths::new(&home);
    let preset = compactor_preset(&paths, &home, "claude-sr");
    assert_eq!(
        preset.args,
        vec![
            "--system-prompt-file",
            "${cwd}/system.md",
            "--tools",
            "",
            "--strict-mcp-config",
            "--no-session-persistence",
        ]
    );
    assert_eq!(preset.args, COMPACTOR_ARGS);
    assert_eq!(SYSTEM_FILE, "system.md");
    // Claude Code flags mean nothing to another harness.
    assert!(compactor_preset(&paths, &home, "codex").args.is_empty());
}
