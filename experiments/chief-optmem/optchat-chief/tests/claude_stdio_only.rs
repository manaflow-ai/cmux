//! The Chief answers only through acpmux's own Claude Code adapter (kind
//! `claude-stdio`): a Claude harness acpmux reports as an ACP adapter is
//! refused for turns and compactor nodes, whatever its profile is named,
//! and the harness kind and command land in the trace.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::acpmux::Family;
use optchat_chief::compactor::{AcpmuxCompactor, CompactorSpec, Slots};
use optchat_chief::harness_gate::{Route, admit, admit_profile};
use optchat_chief::trace::Trace;
use optchat_core::JOBS;
use optchat_host::{CompactModel, CompactRequest, NodeId};
use serde_json::{Value, json};

fn trace_events(dir: &std::path::Path) -> Vec<Value> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let text = std::fs::read_to_string(entry.path()).unwrap();
        out.extend(
            text.lines()
                .map(|l| serde_json::from_str::<Value>(l).unwrap()),
        );
    }
    out
}

#[test]
fn the_reserved_names_are_routes_to_claude_stdio_profiles() {
    assert_eq!(Route::of("claude-sr"), Some(Route::Subrouter));
    assert_eq!(Route::of("claude"), Some(Route::Direct));
    assert_eq!(Route::of("codex"), None);
    let sr = admit(&catalog(), "claude-sr").unwrap();
    assert_eq!(
        (sr.profile.as_str(), sr.kind.as_str(), sr.argv0.as_str()),
        ("claude-sr", "claude-stdio", "/Users/cmux/bin/sr")
    );
    let direct = admit(&catalog(), "claude").unwrap();
    assert_eq!(
        (direct.profile.as_str(), direct.kind.as_str()),
        ("claude", "claude-stdio")
    );
    // Codex is not Claude: admitted as acpmux reports it.
    let codex = admit(&catalog(), "codex").unwrap();
    assert_eq!((codex.kind.as_str(), codex.family), ("acp", Family::Codex));
}

#[test]
fn an_acp_adapter_under_a_reserved_name_is_refused() {
    // Lawrence's laptop on 2026-10-05: both names run claude-acp.
    for name in ["claude-sr", "claude"] {
        let e = admit(&acpx_catalog(), name).unwrap_err();
        assert!(e.contains("claude-stdio"), "{e}");
        assert!(e.contains("is kind acp"), "{e}");
        assert!(e.contains("claude-acp"), "{e}");
    }
    // Asked for by its exact profile name, a Claude ACP adapter is refused too.
    let e = admit_profile(&acpx_catalog(), "claude-sr").unwrap_err();
    assert!(e.contains("claude-stdio"), "{e}");
}

#[test]
fn the_route_is_found_by_kind_and_command_not_by_name() {
    // A user profile named claude-sr runs an ACP adapter; another profile
    // runs our adapter through `sr claude proxy`.
    let answer = json!({"harnesses": {
        "claude-sr": {"argv": ["/x/claude-acp"], "family": "claude"},
        "pool": {"kind": "claude-stdio", "argv": ["/usr/local/bin/subrouter", "claude", "proxy"]},
        "claude": {"kind": "claude-stdio", "argv": ["/x/sr", "claude", "proxy"]},
    }});
    let a = admit(&answer, "claude-sr").unwrap();
    assert_eq!(
        (a.requested.as_str(), a.profile.as_str()),
        ("claude-sr", "claude")
    );
    assert_eq!(a.argv0, "/x/sr");
    // `claude` asks for the `claude` executable: an sr profile named
    // claude is not the direct route.
    let e = admit(&answer, "claude").unwrap_err();
    assert!(e.contains("`claude`"), "{e}");
    // An unavailable launcher never serves.
    let answer = json!({"harnesses": {
        "claude-sr": {"kind": "claude-stdio", "argv": ["/x/sr", "claude", "proxy"], "unavailable": "proxy setup failed"},
    }});
    assert!(admit(&answer, "claude-sr").is_err());
}

#[test]
fn a_claude_family_harness_of_another_name_must_be_claude_stdio() {
    let answer = json!({"harnesses": {
        "work": {"argv": ["/opt/claude-code-acp"], "family": "claude"},
        "mine": {"kind": "claude-stdio", "argv": ["/opt/cc"]},
    }});
    assert!(admit(&answer, "work").is_err());
    let mine = admit(&answer, "mine").unwrap();
    assert_eq!(
        (mine.kind.as_str(), mine.argv0.as_str()),
        ("claude-stdio", "/opt/cc")
    );
    assert!(admit(&answer, "missing").is_err());
}

fn traced_harness() -> (Harness, std::path::PathBuf) {
    let mut h = Harness::new(default_script());
    let traces = h.dir.path().join("traces");
    h.brain.set_trace(Trace::open(&traces, false).unwrap());
    h.connect();
    (h, traces)
}

#[test]
fn a_turn_on_an_acp_adapter_is_refused_in_the_chat_and_the_trace() {
    let (mut h, traces) = traced_harness();
    h.agents.inner.lock().unwrap().catalog = Some(acpx_catalog());
    h.say("user_local", "hi");
    h.settle();
    assert!(
        h.agents.inner.lock().unwrap().specs.is_empty(),
        "no session starts on a refused harness"
    );
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1, "{sends:?}");
    assert!(sends[0].1.contains("refused"), "{sends:?}");
    assert!(sends[0].1.contains("claude-stdio"), "{sends:?}");
    let events = trace_events(&traces);
    let refused: Vec<&Value> = events
        .iter()
        .filter(|e| e["ev"] == "harness.refused")
        .collect();
    assert_eq!(refused.len(), 1, "{events:?}");
    assert_eq!(refused[0]["role"], "turn");
    assert_eq!(refused[0]["harness"], "claude-sr");
    let end = events.iter().find(|e| e["ev"] == "turn.end").unwrap();
    assert_eq!(end["status"], "refused");
}

#[test]
fn a_turn_records_the_harness_kind_and_command() {
    let (mut h, traces) = traced_harness();
    h.say("user_local", "hi");
    h.settle();
    let specs = h.agents.inner.lock().unwrap().specs.clone();
    assert_eq!(specs[0].harness, "claude-sr");
    let events = trace_events(&traces);
    let end = events.iter().find(|e| e["ev"] == "turn.end").unwrap();
    assert_eq!(end["status"], "ok");
    assert_eq!(end["harness_kind"], "claude-stdio");
    assert_eq!(end["harness_argv0"], "/Users/cmux/bin/sr");
    assert_eq!(end["harness_profile"], "claude-sr");
}

#[test]
fn a_turn_asks_acpmux_for_the_matching_profile_by_its_own_name() {
    let (mut h, _traces) = traced_harness();
    h.agents.inner.lock().unwrap().catalog = Some(json!({"harnesses": {
        "claude-sr": {"argv": ["/x/claude-acp"], "family": "claude"},
        "pool": {"kind": "claude-stdio", "argv": ["/x/sr", "claude", "proxy"]},
    }}));
    h.say("user_local", "hi");
    h.settle();
    let specs = h.agents.inner.lock().unwrap().specs.clone();
    assert_eq!(specs.len(), 1);
    assert_eq!(specs[0].harness, "pool");
}

#[test]
fn a_session_acpmux_moved_onto_an_acp_adapter_is_ended_and_refused() {
    let (mut h, traces) = traced_harness();
    {
        let mut inner = h.agents.inner.lock().unwrap();
        // acpmux resolved the request to another profile (a family
        // preference) that runs an ACP adapter.
        inner.catalog = Some(json!({"harnesses": {
            "claude-sr": {"kind": "claude-stdio", "argv": ["/x/sr", "claude", "proxy"]},
            "claude-acp": {"argv": ["/x/claude-acp"], "family": "claude"},
        }}));
        inner.session_harness = Some("claude-acp".into());
    }
    h.say("user_local", "hi");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert!(inner.prompts.is_empty(), "nothing is prompted on it");
    assert_eq!(inner.ended, vec!["s1"]);
    drop(inner);
    let sends = h.owner.lock().unwrap().sends();
    assert!(sends[0].1.contains("refused"), "{sends:?}");
    let events = trace_events(&traces);
    assert!(
        events.iter().any(|e| e["ev"] == "harness.refused"),
        "{events:?}"
    );
}

fn compactor_spec(dir: &std::path::Path) -> CompactorSpec {
    CompactorSpec {
        name: "optchat-compact-test".into(),
        work: dir.join("work"),
        transcript_dirs: vec![dir.join("compactor-claude")],
        preset: "optchat-compact-test-preset".into(),
        harness: "claude-sr".into(),
        family: Family::Claude,
        codex_home: dir.join("codex"),
        model: Some("claude-sonnet-5-5".into()),
        effort: None,
        timeout: Duration::from_secs(30),
        chief: "h0me".into(),
    }
}

#[test]
fn a_compactor_node_on_an_acp_adapter_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let agents = FakeAgents::new(default_script());
    agents.inner.lock().unwrap().catalog = Some(acpx_catalog());
    let compactor = Arc::new(AcpmuxCompactor::new(
        agents.clone(),
        compactor_spec(dir.path()),
        Slots::new(JOBS),
    ));
    let request = CompactRequest {
        node: NodeId::new(0, 1),
        system: "SYS".into(),
        context: "<chat>\nuser: hi\n</chat>".into(),
        step: "STEP".into(),
        cut: None,
    };
    let e = compactor.call(&request, &[]).unwrap_err();
    assert!(e.to_string().contains("claude-stdio"), "{e}");
    assert!(agents.inner.lock().unwrap().specs.is_empty());
}
