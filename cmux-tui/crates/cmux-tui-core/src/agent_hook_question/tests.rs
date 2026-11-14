use super::*;

/// Claude Code fires PreToolUse (with `tool_use_id`) then PermissionRequest (without
/// it, seen live in 2.1.309) for one AskUserQuestion. The second keeps the first's
/// tool use id, so the phone matches an answer to that very question.
#[test]
fn the_second_hook_keeps_the_first_hooks_tool_use_id() {
    let first = json!({"harness":"claude","tool_use_id":"toolu_A","questions":[{"question":"Which?","options":[]}]});
    let mut second = json!({"harness":"claude","questions":[{"question":"Which?","options":[]}]});
    carry_tool_use_id(&mut second, Some(&first));
    assert_eq!(second["tool_use_id"], "toolu_A");
    // Another question keeps none; one with its own id keeps its own.
    let mut other = json!({"harness":"claude","questions":[{"question":"Other?","options":[]}]});
    carry_tool_use_id(&mut other, Some(&first));
    assert!(other.get("tool_use_id").is_none());
    let mut own = json!({"harness":"claude","tool_use_id":"toolu_B","questions":[{"question":"Which?","options":[]}]});
    carry_tool_use_id(&mut own, Some(&first));
    assert_eq!(own["tool_use_id"], "toolu_B");
}

fn claude(event: &str) -> Value {
    json!({
        "session_id": "s1",
        "hook_event_name": event,
        "tool_name": "AskUserQuestion",
        "tool_use_id": "toolu_1",
        "tool_input": {"questions": [
            {"question": "Which branch\u{202e}?", "header": "Branch", "multiSelect": false,
             "options": [{"label": "main", "description": "the default"}, {"label": "dev"}, {"label": "release"}]},
            {"question": "Which checks?", "header": "Checks", "multiSelect": true,
             "options": [{"label": "lint"}, {"label": "tests"}]}
        ]}
    })
}

#[test]
fn claude_ask_user_question_is_kept_cleaned() {
    let kept: Value = serde_json::from_str(
        &agent_hook_live_question("PreToolUse", &claude("PreToolUse")).unwrap(),
    )
    .unwrap();
    assert_eq!(kept["harness"], "claude");
    assert_eq!(kept["tool_use_id"], "toolu_1");
    let first = &kept["questions"][0];
    // Bidi controls are dropped from shown text.
    assert_eq!(first["question"], "Which branch?");
    assert_eq!(first["header"], "Branch");
    assert_eq!(first["multiSelect"], false);
    assert_eq!(first["options"][0], json!({"label":"main","description":"the default"}));
    assert_eq!(first["options"].as_array().unwrap().len(), 3);
    assert_eq!(kept["questions"][1]["multiSelect"], true);
    assert!(agent_hook_live_question("PermissionRequest", &claude("PermissionRequest")).is_some());
}

#[test]
fn codex_request_user_input_is_kept_with_ids() {
    let native = json!({"tool_name":"request_user_input","tool_input":{"questions":[
        {"id":"deploy","header":"Deploy","question":"Deploy now?","isOther":true,"options":[{"label":"yes"},{"label":"no"}]}
    ]}});
    let kept: Value =
        serde_json::from_str(&agent_hook_live_question("PreToolUse", &native).unwrap()).unwrap();
    assert_eq!(kept["harness"], "codex");
    assert_eq!(kept["questions"][0]["id"], "deploy");
    assert_eq!(kept["questions"][0]["isOther"], true);
}

#[test]
fn other_tools_events_and_empty_questions_are_not_questions() {
    let mut bash = claude("PreToolUse");
    bash["tool_name"] = json!("Bash");
    assert!(agent_hook_live_question("PreToolUse", &bash).is_none());
    assert!(agent_hook_live_question("PostToolUse", &claude("PostToolUse")).is_none());
    let empty =
        json!({"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"  "}]}});
    assert!(agent_hook_live_question("PreToolUse", &empty).is_none());
}

#[test]
fn bounds_hold() {
    let many: Vec<Value> = (0..10)
            .map(|i| json!({"question": "q".repeat(5000), "header": "h".repeat(500),
                "options": (0..20).map(|j| json!({"label": format!("{i}-{j}-{}", "l".repeat(500)), "description": "d".repeat(5000)})).collect::<Vec<_>>()}))
            .collect();
    let native = json!({"tool_name":"AskUserQuestion","tool_input":{"questions":many}});
    let text = agent_hook_live_question("PreToolUse", &native).unwrap();
    assert!(text.len() <= MAX_QUESTION_JSON_BYTES, "{}", text.len());
    let kept: Value = serde_json::from_str(&text).unwrap();
    // Too big with descriptions: they go first, then the last questions.
    assert!(kept["questions"][0]["options"][0].get("description").is_none());
    let count = kept["questions"].as_array().unwrap().len();
    assert!((1..=MAX_QUESTIONS).contains(&count), "{count}");
    assert_eq!(kept["questions"][0]["options"].as_array().unwrap().len(), MAX_OPTIONS);
    assert_eq!(kept["questions"][0]["question"].as_str().unwrap().chars().count(), QUESTION_CHARS);
}

#[test]
fn kept_question_refuses_anything_but_a_question() {
    assert!(kept_question("not json").is_none());
    assert!(kept_question(r#"{"questions":[]}"#).is_none());
    assert!(kept_question(&"x".repeat(MAX_QUESTION_JSON_BYTES + 1)).is_none());
    assert!(
        kept_question(r#"{"harness":"claude","questions":[{"question":"q","options":[]}]}"#)
            .is_some()
    );
}
