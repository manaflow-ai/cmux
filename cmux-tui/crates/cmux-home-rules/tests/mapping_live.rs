//! `HomeAgentRunMappingTests` (CmuxNextHomeEngineTests), ported: a run's tells, spawns and reports as
//! the run's messages with its agents.

use cmux_home_rules::call;
use serde_json::{Value, json};

const FAILED: &str = "Failed";

fn mapped(steps: Value) -> Value {
    call(
        "mapping.agentRun",
        &json!({
            "conversation": "conversation-1",
            "run": {"id": "run-1", "author": "agent_mux", "status": "done", "started_at": 1000},
            "steps": steps,
            "failureLabel": FAILED,
        }),
    )
    .expect("mapping.agentRun")
}

fn messages(run: &Value) -> &Vec<Value> {
    run["messages"].as_array().expect("messages")
}

fn field(run: &Value, key: &str) -> Vec<Value> {
    messages(run).iter().map(|m| m.get(key).cloned().unwrap_or(Value::Null)).collect()
}

#[test]
fn completed_tell_with_refused_outcome_shows_reason() {
    let body = "Full message 🦀\n".repeat(100);
    for output in [
        "outcome: refused. a1 was cancelled; control(action: \"restart\", id: \"a1\") brings it back",
        "outcome: refused. a1 finished and its cloud VM vm-1 was deleted after its work was pushed; spawn a new subagent for more work",
    ] {
        let run = mapped(json!([{"id": "tool:1", "kind": "tool", "status": "done", "at": 9000,
            "tool": {"name": "mcp__optchat__tell", "input": {"id": "a1", "message": body},
                     "output": output, "started_at": 2000}}]));
        let message = &messages(&run)[0];
        assert_eq!(message["text"], json!(format!("{body}\n[{FAILED}: {output}]")));
        assert_eq!(message["peer"], "a1");
        assert_eq!(message["outgoing"], true);
        assert_eq!(message["date"], 9.0);
    }
}

#[test]
fn codex_tell_envelope_maps_only_optchat_and_retains_full_body() {
    let body = "Please verify. ".repeat(100);
    let step = |server: &str| {
        json!({"id": format!("tool:{server}"), "kind": "tool", "status": "done", "at": 5000,
            "tool": {"name": "mcp_tool_call", "input": {"server": server, "tool": "tell",
                     "arguments": {"id": "a1", "message": body}}, "output": "outcome: done. delivered"}})
    };
    let run = mapped(json!([step("optchat"), step("other-server")]));
    assert_eq!(messages(&run).len(), 1);
    assert_eq!(messages(&run)[0]["text"], json!(body));
    assert_eq!(messages(&run)[0]["peer"], "a1");
}

#[test]
fn report_uses_its_own_time_and_survives_unrelated_tool_inputs() {
    let inputs = [
        json!("command"),
        json!(42),
        json!({"id": 7, "message": [1, 2]}),
        json!({"input": "value"}),
        json!([1, 2]),
    ];
    let mut steps: Vec<Value> = inputs
        .iter()
        .enumerate()
        .map(|(index, input)| json!({"id": format!("tool:{index}"), "kind": "tool", "tool": {"name": "other", "input": input}}))
        .collect();
    steps
        .push(json!({"id": "report:a1:1", "kind": "note", "text": "[a1] Verified 🦀", "at": 7000}));
    let run = mapped(Value::Array(steps));
    assert_eq!(messages(&run).len(), 1);
    assert_eq!(messages(&run)[0]["text"], "Verified 🦀");
    assert_eq!(messages(&run)[0]["outgoing"], false);
    assert_eq!(messages(&run)[0]["date"], 7.0);
}

#[test]
fn cloud_sequence_orders_messages_without_becoming_an_update_revision() {
    let run = mapped(json!([{"id": "tool:1", "seq": 12, "kind": "tool", "status": "running",
        "tool": {"name": "tell", "input": {"id": "a1", "message": "check"}}}]));
    assert_eq!(run["revision"], 0);
    assert_eq!(messages(&run)[0]["sequence"], 12);
    assert_eq!(messages(&run)[0]["revision"], 0);
}

#[test]
fn failed_tell_without_output_is_still_marked_failed() {
    let run = mapped(json!([{"id": "tool:1", "kind": "tool", "status": "failed",
        "tool": {"name": "tell", "input": {"id": "a1", "message": "check"}}}]));
    assert_eq!(messages(&run)[0]["text"], json!(format!("check\n[{FAILED}]")));
}

#[test]
fn a_tell_keeps_its_sender_meta() {
    let run = mapped(json!([
        {"id": "tool:1", "kind": "tool", "status": "done", "at": 1000,
         "tool": {"name": "tell", "input": {"id": "a1", "message": "from the person",
                  "_meta": {"cmux": {"sender": "human:p_lawrence"}}}}},
        {"id": "tool:2", "kind": "tool", "status": "done", "at": 2000,
         "tool": {"name": "mcp_tool_call", "input": {"server": "optchat", "tool": "tell",
                  "arguments": {"id": "a1", "message": "from the Chief", "_meta": {"cmux": {"sender": "chief:agent_mux"}}}}}},
        {"id": "tool:3", "kind": "tool", "status": "done", "at": 3000,
         "tool": {"name": "tell", "input": {"id": "a1", "message": "no meta", "_meta": {"cmux": {"sender": 7}}}}},
    ]));
    assert_eq!(
        field(&run, "text"),
        [json!("from the person"), json!("from the Chief"), json!("no meta")]
    );
    assert_eq!(
        field(&run, "sender"),
        [json!("human:p_lawrence"), json!("chief:agent_mux"), Value::Null]
    );
}

#[test]
fn a_spawn_is_the_task_of_each_agent_it_started() {
    let tasks = [
        "Title: Bubble tail last only\n\nOnly the last bubble gets the tail.",
        "Title: Subagent link opens pane\n\nOpen it on the right.",
    ];
    let output = "Started a988 in /Users/me/fun/cmux.\n- a988: runs hidden.\n- a989: did not start (no PTYs)\nTell the user only what these lines say.";
    for name in ["mcp__optchat__spawn", "spawn", "optchat.spawn"] {
        let run = mapped(json!([{"id": "tool:7", "kind": "tool", "status": "done", "at": 4000,
            "tool": {"name": name, "input": {"tasks": tasks, "cwd": "~/fun/cmux"}, "output": output}}]));
        assert_eq!(field(&run, "peer"), [json!("a988"), json!("a989")], "{name}");
        assert_eq!(field(&run, "text"), [json!(tasks[0]), json!(tasks[1])]);
        assert_eq!(field(&run, "outgoing"), [json!(true), json!(true)]);
        let ids = field(&run, "id");
        assert_ne!(ids[0], ids[1]);
    }
}

#[test]
fn a_spawn_envelope_maps_and_an_unmatched_answer_maps_nothing() {
    let tasks = ["Title: One\n\nGo.", "Title: Two\n\nGo."];
    let envelope = mapped(json!([{"id": "tool:1", "kind": "tool", "status": "done",
        "tool": {"name": "mcp_tool_call", "input": {"server": "optchat", "tool": "spawn", "arguments": {"tasks": tasks}},
                 "output": "Routed: claude.\nStarted a1, a2 on the cloud VM vm-1 (acpmux peer), in /work.\n- a1: on vm-1.\n- a2: queued (cap)"}}]));
    assert_eq!(field(&envelope, "peer"), [json!("a1"), json!("a2")]);
    let running = mapped(json!([{"id": "tool:2", "kind": "tool", "status": "running",
        "tool": {"name": "spawn", "input": {"tasks": tasks}}}]));
    assert!(messages(&running).is_empty());
    let short = mapped(json!([{"id": "tool:3", "kind": "tool", "status": "done",
        "tool": {"name": "spawn", "input": {"tasks": tasks}, "output": "Started a1 in /work.\n- a1: runs hidden."}}]));
    assert!(messages(&short).is_empty());
}

#[test]
fn queued_spawns_and_tells_are_marked_queued() {
    let tasks = ["Title: One\n\nGo.", "Title: Two\n\nGo.", "Title: Three\n\nGo."];
    let output = "Queued a2.\n- a1: started\n- a2: queued (10 subagents are at work; it starts when one finishes)\n- a3: did not start (no PTYs)";
    let run = mapped(json!([
        {"id": "tool:1", "kind": "tool", "status": "done", "tool": {"name": "spawn", "input": {"tasks": tasks}, "output": output}},
        {"id": "tool:2", "kind": "tool", "status": "done",
         "tool": {"name": "tell", "input": {"id": "a2", "message": "More."}, "output": "outcome: queued. Queued for delivery to a2 (1 waiting)"}},
        {"id": "tool:3", "kind": "tool", "status": "done",
         "tool": {"name": "tell", "input": {"id": "a1", "message": "More."}, "output": "outcome: done. sent to a1"}},
    ]));
    assert_eq!(field(&run, "peer"), ["a1", "a2", "a3", "a2", "a1"].map(|p| json!(p)));
    assert_eq!(field(&run, "queued"), [false, true, false, true, false].map(|q| json!(q)));
}
