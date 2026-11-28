use super::*;

fn call(tool_input: Value) -> Value {
    json!({"hook_event_name": "PreToolUse", "tool_name": "Agent", "tool_input": tool_input})
}

fn model_of(answer: Option<Value>) -> Option<String> {
    answer?.pointer("/hookSpecificOutput/updatedInput/model")?.as_str().map(str::to_owned)
}

#[test]
fn an_explore_subagent_with_no_model_starts_on_sonnet() {
    let routes = routes_with(None);
    let answer =
        route_with(&call(json!({"subagent_type": "Explore", "prompt": "find x"})), &routes);
    assert_eq!(model_of(answer.clone()).as_deref(), Some("sonnet"));
    let updated = answer.unwrap();
    assert_eq!(updated.pointer("/hookSpecificOutput/updatedInput/prompt"), Some(&json!("find x")));
    assert!(updated.pointer("/hookSpecificOutput/permissionDecision").is_none());
}

#[test]
fn a_named_model_a_fork_or_an_unrouted_kind_is_left_as_it_was() {
    let routes = routes_with(None);
    for input in [
        json!({"subagent_type": "Explore", "model": "opus"}),
        json!({"subagent_type": "fork"}),
        json!({"subagent_type": "general-purpose"}),
        json!({"prompt": "no kind"}),
    ] {
        assert_eq!(route_with(&call(input.clone()), &routes), None, "{input}");
    }
    let bash = json!({"hook_event_name": "PreToolUse", "tool_name": "Bash",
        "tool_input": {"subagent_type": "Explore"}});
    assert_eq!(route_with(&bash, &routes), None);
}

#[test]
fn the_setting_adds_replaces_and_removes_routes_and_never_reaches_fable() {
    let doc = json!({"agents": {"harnessMagic": {"router": {"subagents": {
        "Plan": "haiku", "general-purpose": "claude-fable-5-2", "Explore": ""
    }}}}});
    let routes = routes_with(Some(&doc));
    assert_eq!(routes, vec![("Plan".to_owned(), "haiku".to_owned())]);
    let task = json!({"hook_event_name": "PreToolUse", "tool_name": "Task",
        "tool_input": {"subagent_type": "Plan"}});
    assert_eq!(model_of(route_with(&task, &routes)).as_deref(), Some("haiku"));
    assert!(!allowed_model("fable") && !allowed_model("Fable") && !allowed_model("inherit"));
    let forced = vec![("Explore".to_owned(), "fable".to_owned())];
    assert_eq!(route_with(&call(json!({"subagent_type": "Explore"})), &forced), None);
}

#[test]
fn it_is_off_unless_turned_on() {
    let on = json!({"agents": {"harnessMagic": {"router": {"enabled": true}}}});
    assert!(!enabled_with(None, None));
    assert!(enabled_with(Some(&on), None));
    assert!(!enabled_with(Some(&on), Some("0")));
    assert!(enabled_with(None, Some("1")));
}
