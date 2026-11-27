//! The wrap-up's first answer as a harness-less suggestion (`wrap_up_suggestion.rs`), from each
//! shape a harness gives the call.
use super::*;
use serde_json::json;

const ARGS: &str = r#"{"recap":"Checked the folder: it is empty.","ask":"Should I add a README here?","actions":["Yes, add README","No thanks"]}"#;

fn args() -> Value {
    serde_json::from_str(ARGS).unwrap()
}

fn started(id: &str, title: &str, input: Value) -> Value {
    json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": title, "status": "in_progress", "rawInput": input})
}

fn ended(id: &str, status: &str) -> Value {
    json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": status})
}

#[test]
fn claude_codes_direct_call_leaves_its_first_answer() {
    let mut w = Watch::default();
    w.observe(&started("t1", "mcp__acpmux__wrap_up", args()));
    assert_eq!(w.take(), None, "nothing until the call completes");
    w.observe(&started("t1", "mcp__acpmux__wrap_up", args()));
    w.observe(&ended("t1", "completed"));
    assert_eq!(w.take().as_deref(), Some("Yes, add README"));
    assert_eq!(w.take(), None, "taken once");
}

#[test]
fn codexs_server_tool_arguments_shape_and_the_folded_name() {
    for (server, tool) in [("acpmux", "wrap_up"), ("cmux", "acpmux_wrap_up")] {
        let mut w = Watch::default();
        w.observe(&started(
            "c1",
            "Called wrap_up",
            json!({"server": server, "tool": tool, "arguments": args()}),
        ));
        w.observe(&ended("c1", "completed"));
        assert_eq!(w.take().as_deref(), Some("Yes, add README"), "{server}/{tool}");
    }
    // Arguments passed as a JSON string.
    let mut w = Watch::default();
    w.observe(&started(
        "c2",
        "x",
        json!({"server": "acpmux", "tool": "wrap_up", "arguments": ARGS}),
    ));
    w.observe(&ended("c2", "completed"));
    assert_eq!(w.take().as_deref(), Some("Yes, add README"));
}

#[test]
fn a_cmux_exec_script_reads_what_its_call_log_showed() {
    let script = json!({"script": format!("await cmux.acpmux_wrap_up({ARGS})")});
    let log = json!({"calls": 2, "call_log": [
        {"name": "workspace_list", "ok": true},
        {"name": "acpmux_wrap_up", "ok": true, "shown": args()},
    ]});
    let mut w = Watch::default();
    w.observe(&started("e1", "mcp__cmux__cmux_exec", script.clone()));
    w.observe(&json!({
        "sessionUpdate": "tool_call_update", "toolCallId": "e1", "status": "completed",
        "content": [{"type": "content", "content": {"type": "text", "text": log.to_string()}}],
    }));
    assert_eq!(w.take().as_deref(), Some("Yes, add README"));
    // A script that never named the wrap-up is not watched.
    let mut w = Watch::default();
    w.observe(&started(
        "e2",
        "mcp__cmux__cmux_exec",
        json!({"script": "await cmux.workspace_list()"}),
    ));
    w.observe(&json!({"sessionUpdate": "tool_call_update", "toolCallId": "e2", "status": "completed", "rawOutput": log}));
    assert_eq!(w.take(), None);
}

#[test]
fn no_suggestion_from_a_failed_call_a_recap_alone_or_other_tools() {
    let mut w = Watch::default();
    w.observe(&started("f1", "mcp__acpmux__wrap_up", args()));
    w.observe(&ended("f1", "failed"));
    assert_eq!(w.take(), None);
    // A recap with no question, and a question with no answers (the box's own Yes / Not now).
    for input in [json!({"recap": "Done."}), json!({"recap": "Done.", "ask": "Open a PR?"})] {
        let mut w = Watch::default();
        w.observe(&started("f2", "mcp__acpmux__wrap_up", input));
        w.observe(&ended("f2", "completed"));
        assert_eq!(w.take(), None);
    }
    let mut w = Watch::default();
    w.observe(&started("f3", "mcp__acpmux__read_file", args()));
    w.observe(&ended("f3", "completed"));
    assert_eq!(w.take(), None);
}

#[test]
fn the_last_completed_wrap_up_wins_and_a_turn_end_clears_running_calls() {
    let mut w = Watch::default();
    w.observe(&started("a", "mcp__acpmux__wrap_up", args()));
    w.observe(&ended("a", "completed"));
    w.observe(&started(
        "b",
        "mcp__acpmux__wrap_up",
        json!({"recap": "r", "ask": "Ship it?", "actions": ["Ship it"]}),
    ));
    w.observe(&ended("b", "completed"));
    w.observe(&started("c", "mcp__acpmux__wrap_up", args()));
    assert_eq!(w.take().as_deref(), Some("Ship it"));
    // The running call `c` belonged to the ended turn.
    w.observe(&ended("c", "completed"));
    assert_eq!(w.take(), None);
}

#[test]
fn the_update_names_its_source_for_the_gate() {
    let u = update("Yes, add README");
    assert_eq!(u["sessionUpdate"], "prompt_suggestion");
    assert_eq!(u["suggestion"], "Yes, add README");
    assert_eq!(u.pointer("/_meta/acpmux/source").and_then(Value::as_str), Some(SOURCE));
    let mut gate = crate::suggestion_gate::Gate::default();
    let mut gated = u.clone();
    crate::suggestion_gate::gate_update(&mut gate, "s", "codex", &mut gated);
    assert_eq!(
        gated["suggestion"], "Yes, add README",
        "a new source starts at the prior and shows"
    );
    // Taking it counts for `codex/wrap_up`.
    assert_eq!(gate.prompted("s", "Yes, add README", false), Some(true));
    assert!(gate.tally("codex/wrap_up").taken > 0.0);
}

#[test]
fn a_later_recap_alone_takes_back_an_earlier_ask() {
    let mut w = Watch::default();
    w.observe(&started("a", "mcp__acpmux__wrap_up", args()));
    w.observe(&ended("a", "completed"));
    w.observe(&started("b", "mcp__acpmux__wrap_up", json!({"recap": "Done after all."})));
    w.observe(&ended("b", "completed"));
    assert_eq!(w.take(), None);
}

#[test]
fn a_completion_that_names_the_call_without_its_input_keeps_the_input() {
    let mut w = Watch::default();
    w.observe(&started("a", "mcp__acpmux__wrap_up", args()));
    w.observe(&json!({"sessionUpdate": "tool_call_update", "toolCallId": "a", "title": "wrap_up", "status": "completed"}));
    assert_eq!(w.take().as_deref(), Some("Yes, add README"));
    let mut w = Watch::default();
    w.observe(&started("b", "mcp__acpmux__wrap_up", args()));
    w.observe(&json!({"sessionUpdate": "tool_call_update", "toolCallId": "b", "title": "mcp__acpmux__wrap_up", "status": "completed"}));
    assert_eq!(w.take().as_deref(), Some("Yes, add README"));
}
