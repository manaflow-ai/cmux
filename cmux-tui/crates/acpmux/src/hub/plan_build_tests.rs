use super::*;

fn ask(tool: Value) -> Value {
    json!({"sessionId": "s", "toolCall": tool, "options": [
        {"optionId": "yes", "name": "Yes", "kind": "allow_once"},
        {"optionId": "no", "name": "No", "kind": "reject_once"},
    ]})
}

#[test]
fn the_plan_is_read_as_the_card_reads_it() {
    let exit_plan = ask(json!({"kind": "switch_mode", "rawInput": {"plan": "  Step one  "},
        "_meta": {"claude": {"tool": "ExitPlanMode"}}}));
    assert_eq!(plan_of(&exit_plan).as_deref(), Some("Step one"));
    let attached =
        ask(json!({"kind": "other", "_meta": {"acpmux": {"plan": {"markdown": "From file"}}}}));
    assert_eq!(plan_of(&attached).as_deref(), Some("From file"));
    let from_text = ask(json!({"kind": "switch_mode", "content": [
        {"type": "content", "content": {"type": "text", "text": "A"}},
        {"type": "diff", "path": "x"},
        {"type": "content", "content": {"type": "text", "text": " B "}},
    ]}));
    assert_eq!(plan_of(&from_text).as_deref(), Some("A\n\nB"));
    let command = ask(json!({"kind": "execute", "rawInput": {"plan": "not a plan ask"}}));
    assert_eq!(plan_of(&command), None);
    let empty = ask(json!({"kind": "switch_mode", "rawInput": {"plan": "  "}}));
    assert_eq!(plan_of(&empty), None);
}

#[test]
fn options_and_harnesses() {
    let a = ask(json!({}));
    assert_eq!(option_of(&a, "allow_once").as_deref(), Some("yes"));
    assert_eq!(option_of(&a, "reject_once").as_deref(), Some("no"));
    assert_eq!(option_of(&a, "allow_always"), None);
    assert_eq!(compare_harnesses("claude"), ["claude", "codex"]);
    assert_eq!(compare_harnesses("claude-work"), ["claude-work", "codex"]);
    assert_eq!(compare_harnesses("codex"), ["codex", "claude"]);
    assert_eq!(Target::parse("compare"), Some(Target::Compare));
    assert_eq!(Target::parse("cloud"), None);
}

#[test]
fn the_build_prompt_carries_the_plan() {
    let one = build_prompt("1. Do it", "shop", Target::Worktree);
    assert!(one.ends_with("\n\n1. Do it") && one.contains("\"shop\""), "{one}");
    assert!(!one.contains("Another agent"));
    assert!(build_prompt("p", "shop", Target::Compare).contains("Another agent"));
}

#[test]
fn a_build_is_done_only_once_a_turn_ended_and_none_waits() {
    assert_eq!(build_status(SessionStatus::Ready, None, false), "working");
    assert_eq!(build_status(SessionStatus::Idle, Some("completed"), true), "working");
    assert_eq!(build_status(SessionStatus::Idle, Some("completed"), false), "done");
    assert_eq!(build_status(SessionStatus::Running, Some("completed"), false), "working");
    assert_eq!(build_status(SessionStatus::Closed, None, false), "closed");
    // A build whose turn failed or was stopped, its agent ready again, is not done.
    assert_eq!(build_status(SessionStatus::Ready, Some("failed"), false), "failed");
    assert_eq!(build_status(SessionStatus::Ready, Some(""), false), "failed");
    assert_eq!(build_status(SessionStatus::Idle, Some("cancelled"), false), "closed");
}

#[test]
fn numstat_counts_and_caps_the_list() {
    let mut change = Change::default();
    parse_numstat("3\t1\tsrc/a.rs\n-\t-\tlogo.png\nbroken line\n", &mut change);
    assert_eq!((change.added, change.removed), (3, 1));
    assert_eq!(change.files, vec![("src/a.rs".into(), 3, 1), ("logo.png".into(), 0, 0)]);
    let mut many = Change::default();
    for i in 0..(MAX_FILES + 5) {
        many.push(format!("f{i}"), 1, 0);
    }
    assert_eq!((many.files.len(), many.more, many.added), (MAX_FILES, 5, (MAX_FILES + 5) as u64));
}

#[test]
fn a_plan_only_in_the_acp_subject_is_read_too() {
    let ask = json!({"sessionId": "s", "subject": {"type": "tool_call", "toolCall": {
        "kind": "switch_mode", "rawInput": {"plan": "Step one"}}}});
    assert_eq!(plan_of(&ask).as_deref(), Some("Step one"));
    let command = json!({"sessionId": "s", "subject": {"type": "command", "toolCall": {
        "kind": "switch_mode", "rawInput": {"plan": "Step one"}}}});
    assert_eq!(plan_of(&command), None, "only a tool call subject");
}

#[test]
fn one_build_call_holds_an_approval_at_a_time() {
    let first = claim("s-claim", "p1").expect("the first call holds it");
    let second = claim("s-claim", "p1").expect_err("a second call is refused");
    assert_eq!(
        second.data.as_ref().and_then(|d| d.get("reason")),
        Some(&json!("plan_build.in_progress"))
    );
    assert!(claim("s-claim", "p2").is_ok(), "another approval is free");
    drop(first);
    assert!(claim("s-claim", "p1").is_ok(), "released when the call ends");
}

#[test]
fn an_edited_plan_goes_back_as_the_agents_input() {
    let mut exit_plan = ask(json!({"kind": "switch_mode",
        "rawInput": {"plan": "1. Old step", "other": 1},
        "_meta": {"claude": {"tool": "ExitPlanMode"}}}));
    // Not edited: the input goes back as the agent sent it.
    assert_eq!(edited_input(&exit_plan), None);
    edit_plan(&mut exit_plan, "  1. New step\n2. Added step  ").unwrap();
    let input = edited_input(&exit_plan).unwrap();
    assert_eq!(input, json!({"plan": "1. New step\n2. Added step", "other": 1}));
    // The card and a build elsewhere read the edit too.
    assert_eq!(plan_of(&exit_plan).as_deref(), Some("1. New step\n2. Added step"));
    assert_eq!(exit_plan["toolCall"]["_meta"]["claude"]["tool"], "ExitPlanMode");
    // Empty, oversized, or not Claude Code's ExitPlanMode: refused, nothing changes.
    assert!(edit_plan(&mut exit_plan, "   ").is_err());
    assert!(edit_plan(&mut exit_plan, &"x".repeat(MAX_EDITED_PLAN + 1)).is_err());
    assert_eq!(plan_of(&exit_plan).as_deref(), Some("1. New step\n2. Added step"));
    let mut grok = ask(json!({"kind": "switch_mode", "rawInput": {"plan": "p"}}));
    let refused = edit_plan(&mut grok, "q").unwrap_err();
    assert!(refused.message.contains("only a Claude Code"), "{}", refused.message);
    assert_eq!(edited_input(&grok), None);
    let mut no_input = ask(json!({"kind": "switch_mode",
        "_meta": {"claude": {"tool": "ExitPlanMode"}}}));
    assert!(edit_plan(&mut no_input, "q").is_err());
}

#[test]
fn an_allowed_plan_is_kept_as_approved_with_its_edit() {
    let mut exit_plan = ask(json!({"kind": "switch_mode",
        "rawInput": {"plan": "1. Old step"},
        "_meta": {"claude": {"tool": "ExitPlanMode"}}}));
    let kept = approved_plan(&exit_plan, "p1").unwrap();
    assert_eq!(
        (kept.markdown.as_str(), kept.edited, kept.permission_id.as_str()),
        ("1. Old step", false, "p1")
    );
    edit_plan(&mut exit_plan, "1. New step").unwrap();
    let kept = approved_plan(&exit_plan, "p1").unwrap();
    assert_eq!((kept.markdown.as_str(), kept.edited), ("1. New step", true));
    // Grok's plan is kept too; an ask that approves no plan is not.
    let grok = ask(json!({"kind": "switch_mode", "rawInput": {"plan": "p"}}));
    assert_eq!(approved_plan(&grok, "g").map(|p| p.markdown).as_deref(), Some("p"));
    assert_eq!(
        approved_plan(&ask(json!({"kind": "execute", "rawInput": {"command": "ls"}})), "x"),
        None
    );
}
