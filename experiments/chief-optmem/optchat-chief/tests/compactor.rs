//! The compactor's acpmux route against the fake acpmux port: one session
//! per node with a deny-all policy in the compactor's own directory, the
//! size loop in the same session, the session killed when the node is done
//! or failed, at most JOBS sessions, and the route chosen by the endpoint.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::brain::Input;
use optchat_chief::compactor::{
    AcpmuxCompactor, CompactRoute, CompactorSpec, POLICY, compact_route, request_blocks,
};
use optchat_core::JOBS;
use optchat_host::{
    CompactRequest, Config, DEFAULT_BASE_URL, Kind, NodeId, OptChat, PROBE_NODE, SUBROUTER_KEY,
    SystemClock, probe, run_node,
};
use serde_json::{Value, json};

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
        cwd: dir.join("compactor"),
        harness: "claude-sr".into(),
        model: Some("claude-sonnet-5-5".into()),
        effort: Some("medium".into()),
        timeout: Duration::from_secs(30),
        jobs: JOBS,
    }
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
    let compactor = Arc::new(AcpmuxCompactor::new(agents.clone(), spec(dir.path())));
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
    assert_eq!(s.cwd, dir.path().join("compactor"));
    assert_eq!(s.harness, "claude-sr");
    assert_eq!(s.model.as_deref(), Some("claude-sonnet-5-5"));
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
    let compactor = AcpmuxCompactor::new(agents.clone(), spec(dir.path()));
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
    let compactor = AcpmuxCompactor::new(agents.clone(), spec(dir.path()));
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
    let compactor = Arc::new(AcpmuxCompactor::new(agents.clone(), spec(dir.path())));
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
    let compactor = AcpmuxCompactor::new(agents.clone(), spec(dir.path()));
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
