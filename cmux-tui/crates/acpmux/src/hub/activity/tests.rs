use super::*;

#[test]
fn a_tool_call_names_the_activity() {
    let u = json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Run  cargo test\n-p acpmux", "status": "pending"});
    assert_eq!(activity_of(&u), Some(Activity::Tool("Run cargo test -p acpmux".into())));
}

#[test]
fn an_untitled_update_says_nothing() {
    let u = json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"});
    assert_eq!(activity_of(&u), None);
    assert_eq!(activity_of(&json!({"sessionUpdate": "agent_message_chunk"})), None);
}

#[test]
fn a_plan_names_its_step_in_progress() {
    let u = json!({"sessionUpdate": "plan", "entries": [
        {"content": "Read the brief", "status": "completed", "priority": "high"},
        {"content": "Fix send_message", "status": "in_progress", "priority": "high"},
        {"content": "Open the PR", "status": "pending", "priority": "high"},
    ]});
    assert_eq!(activity_of(&u), Some(Activity::PlanStep(Some("Fix send_message".into()))));
    let done =
        json!({"sessionUpdate": "plan", "entries": [{"content": "x", "status": "completed"}]});
    assert_eq!(activity_of(&done), Some(Activity::PlanStep(None)));
}

#[test]
fn a_tool_call_is_in_flight_until_it_completes_or_fails() {
    let mut doing = TurnActivity::default();
    doing.note_tool(&json!({"sessionUpdate": "tool_call", "toolCallId": "a", "title": "Build"}));
    doing.note_tool(&json!({"sessionUpdate": "tool_call", "toolCallId": "b", "status": "pending"}));
    assert!(doing.tool_in_flight());
    doing.note_tool(
        &json!({"sessionUpdate": "tool_call_update", "toolCallId": "a", "title": "Built"}),
    );
    doing.note_tool(
        &json!({"sessionUpdate": "tool_call_update", "toolCallId": "a", "status": "completed"}),
    );
    assert!(doing.tool_in_flight(), "b still runs");
    doing.note_tool(
        &json!({"sessionUpdate": "tool_call_update", "toolCallId": "b", "status": "failed"}),
    );
    assert!(!doing.tool_in_flight());
    // A call that starts already done is never in flight.
    doing.note_tool(
        &json!({"sessionUpdate": "tool_call", "toolCallId": "c", "status": "completed"}),
    );
    assert!(!doing.tool_in_flight());
}

#[test]
fn a_build_in_flight_is_heavy_until_it_ends() {
    let mut doing = TurnActivity::default();
    let call = |id: &str, command: &str| {
        json!({"sessionUpdate": "tool_call", "toolCallId": id, "kind": "execute",
                   "status": "in_progress", "rawInput": {"command": command}})
    };
    doing.note_tool(&call("a", "cd /w && cargo build -p acpmux"));
    doing.note_tool(&call("b", "git status"));
    let build = crate::host_load::classify_command("cargo build");
    assert_eq!(doing.open_heavy.get("a").copied(), build);
    assert!(!doing.open_heavy.contains_key("b"), "not a build or test");
    // A call named early gets its command in a later update.
    doing.note_tool(&json!({"sessionUpdate": "tool_call", "toolCallId": "c", "status": "pending"}));
    doing.note_tool(&json!({"sessionUpdate": "tool_call_update", "toolCallId": "c",
                                "rawInput": {"command": ["bash", "-lc", "go test ./..."]}}));
    assert_eq!(doing.open_heavy.get("c").copied(), crate::host_load::classify_command("go test"));
    doing.note_tool(
        &json!({"sessionUpdate": "tool_call_update", "toolCallId": "a", "status": "completed"}),
    );
    doing.note_tool(
        &json!({"sessionUpdate": "tool_call_update", "toolCallId": "c", "status": "failed"}),
    );
    assert!(doing.open_heavy.is_empty());
    // An update for a call that is not in flight adds nothing.
    doing.note_tool(&json!({"sessionUpdate": "tool_call_update", "toolCallId": "z",
                                "rawInput": {"command": "cargo test"}}));
    assert!(doing.open_heavy.is_empty());
}

#[test]
fn tool_calls_past_the_cap_stay_in_flight_only_until_they_end() {
    let mut doing = TurnActivity::default();
    let n = MAX_OPEN_TOOLS + 3;
    for i in 0..n {
        let id = format!("t{i}");
        doing.note_tool(&json!({"sessionUpdate": "tool_call", "toolCallId": id}));
        doing.note_tool(&json!({
            "sessionUpdate": "tool_call_update", "toolCallId": id, "status": "in_progress"
        }));
    }
    for i in 0..n {
        assert!(doing.tool_in_flight(), "t{i} and later still run");
        doing.note_tool(&json!({
            "sessionUpdate": "tool_call_update", "toolCallId": format!("t{i}"),
            "status": "completed"
        }));
    }
    assert!(!doing.tool_in_flight());
}

#[test]
fn a_turn_stalls_when_its_model_is_quiet_with_no_tool_in_flight() {
    let after = Some(600_000);
    // Heard a minute ago: not stalled.
    assert_eq!(stalled_since(1_000, 2_000_000, false, 2_060_000, after), None);
    // Quiet ten minutes: stalled since it was last heard.
    assert_eq!(stalled_since(1_000, 2_000_000, false, 2_600_000, after), Some(2_000_000));
    // Never heard: quiet since the prompt.
    assert_eq!(stalled_since(1_000, 0, false, 601_000, after), Some(1_000));
    // Heard only in an earlier turn: quiet since this turn's prompt.
    assert_eq!(stalled_since(5_000, 4_000, false, 300_000, after), None);
    // A tool call in flight (a long build) never stalls, and 0 turns it off.
    assert_eq!(stalled_since(1_000, 0, true, 99_000_000, after), None);
    assert_eq!(stalled_since(1_000, 0, false, 99_000_000, None), None);
}

#[test]
fn a_secret_in_a_tool_title_or_plan_step_is_masked() {
    // A fake key, assembled so no file holds one.
    let key = format!("AKIA{}", "Q7ZJ4XK2MD5P3WRT");
    let mut doing = TurnActivity::default();
    doing.note(&json!({"sessionUpdate": "tool_call", "toolCallId": "t1",
                           "title": format!("curl -H 'x-key: {key}' https://example.com")}));
    doing.note(&json!({"sessionUpdate": "plan", "entries": [
            {"content": format!("log in with {key}"), "status": "in_progress"}]}));
    let (activity, step) = (doing.activity.unwrap(), doing.plan_step.unwrap());
    assert!(activity.starts_with("curl -H") && !activity.contains(&key), "{activity}");
    assert!(step.starts_with("log in with") && !step.contains(&key), "{step}");
    // Masked before the cut: a key straddling it leaves no head.
    let pad = "x ".repeat((ACTIVITY_CHARS - 10) / 2);
    let u = json!({"sessionUpdate": "tool_call", "title": format!("{pad}{key}")});
    let cut = format!("{:?}", activity_of(&u));
    assert!(cut.contains('…') && !cut.contains("AKIAQ7"), "{cut}");
}

#[test]
fn a_long_title_is_cut() {
    let u = json!({"sessionUpdate": "tool_call", "title": "x".repeat(500)});
    let Some(Activity::Tool(t)) = activity_of(&u) else { panic!() };
    assert_eq!(t.chars().count(), ACTIVITY_CHARS + 1);
}

#[test]
fn the_doing_line_joins_step_and_tool() {
    assert_eq!(
        doing_line(Some("Fix it"), Some("Edit a.rs")).as_deref(),
        Some("Fix it · Edit a.rs")
    );
    assert_eq!(doing_line(Some("Fix it"), None).as_deref(), Some("Fix it"));
    assert_eq!(doing_line(None, Some("Edit a.rs")).as_deref(), Some("Edit a.rs"));
    assert_eq!(doing_line(Some("same"), Some("same")).as_deref(), Some("same"));
    assert_eq!(doing_line(None, None), None);
}
