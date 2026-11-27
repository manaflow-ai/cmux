use super::*;

fn config(text: &str) -> Config {
    Config::parse(text).expect("parses")
}

fn bash(command: &str) -> Value {
    json!({"session_id": "s1", "cwd": "/tmp/build-checkout", "hook_event_name": "PreToolUse",
           "tool_name": "Bash", "tool_input": {"command": command}})
}

const RULES: &str = r#"{"rules": [
  {"name": "heavy", "events": ["PreToolUse"], "tools": "Bash", "screen": "cargo|pytest",
   "command": ["true"], "env": ["PATH", "B"]},
  {"name": "all", "events": ["PostToolUse"], "command": "true", "every_s": 300, "env": ["A", "B"]},
  {"name": "mon", "events": ["PreToolUse"], "tools": "Monitor|Bash", "command": ["true"], "timeout_s": 40}
]}"#;

#[test]
fn a_rule_runs_only_for_its_event_tool_and_screen() {
    let c = config(RULES);
    let heavy = &c.rules[0];
    assert!(heavy.applies("PreToolUse", &bash("cargo test")));
    assert!(!heavy.applies("PreToolUse", &bash("git status")));
    assert!(!heavy.applies("PostToolUse", &bash("cargo test")));
    let mut read = bash("cargo test");
    read["tool_name"] = json!("Read");
    assert!(!heavy.applies("PreToolUse", &read), "tools is a whole-name match");
    let mut bashful = bash("cargo test");
    bashful["tool_name"] = json!("Bashful");
    assert!(!heavy.applies("PreToolUse", &bashful));
}

#[test]
fn a_screen_never_reads_the_envelope() {
    let c = config(
        r#"{"rules": [{"name": "b", "events": ["PreToolUse"], "screen": "build",
                                   "command": ["true"]}]}"#,
    );
    // "build" is in the cwd only
    assert!(!c.rules[0].applies("PreToolUse", &bash("ls")));
    assert!(c.rules[0].applies("PreToolUse", &bash("make build")));
    let prompt =
        json!({"hook_event_name": "UserPromptSubmit", "prompt": "please build", "cwd": "/x"});
    let c2 = config(
        r#"{"rules": [{"name": "b", "events": ["UserPromptSubmit"], "screen": "build",
                                    "command": ["true"]}]}"#,
    );
    assert!(c2.rules[0].applies("UserPromptSubmit", &prompt));
}

#[test]
fn the_entry_matcher_is_the_rules_tools_or_every_tool() {
    let c = config(RULES);
    assert_eq!(c.matcher("PreToolUse").as_deref(), Some("Bash|Monitor|Bash"));
    assert_eq!(c.matcher("PostToolUse"), None);
    assert_eq!(c.events(), vec!["PreToolUse", "PostToolUse"]);
    assert_eq!(c.env_names(), vec!["A", "B", "PATH"]);
    assert_eq!(c.longest("PreToolUse"), Duration::from_secs(40));
    assert_eq!(c.listen, DEFAULT_LISTEN);
    assert_eq!(c.rules[1].argv, vec!["sh", "-c", "true"]);
}

#[test]
fn a_bad_rule_names_itself() {
    for (text, want) in [
        (
            r#"{"rules": [{"name": "x", "events": ["PreToolUse"], "screen": "(", "command": ["t"]}]}"#,
            "\"x\": screen",
        ),
        (r#"{"rules": [{"name": "y", "events": [], "command": ["t"]}]}"#, "\"y\": no events"),
        (
            r#"{"rules": [{"name": "z", "events": ["Stop"], "command": []}]}"#,
            "\"z\": an empty command",
        ),
        (
            r#"{"rules": [{"name": "w", "events": ["Stop"], "command": ["t"], "timeout_s": 0}]}"#,
            "\"w\": timeout_s",
        ),
    ] {
        let err = Config::parse(text).expect_err(text);
        assert!(err.contains(want), "{err}");
    }
}

#[test]
fn every_s_runs_once_per_session_in_its_period() {
    let c = config(RULES);
    let rule = &c.rules[1];
    let mut t = Throttle::default();
    let t0 = Instant::now();
    assert!(t.take(rule, "s1", t0));
    assert!(!t.take(rule, "s1", t0 + Duration::from_secs(299)));
    assert!(t.take(rule, "s2", t0 + Duration::from_secs(1)), "per session");
    assert!(t.take(rule, "s1", t0 + Duration::from_secs(300)));
    assert!(t.take(&c.rules[0], "s1", t0), "no every_s: always");
    assert!(t.take(&c.rules[0], "s1", t0));
}

fn ok(stdout: &str) -> Ran {
    Ran { code: Some(0), stdout: stdout.into(), stderr: String::new() }
}

#[test]
fn the_first_refusal_is_the_answer_with_the_contexts_before_it() {
    let deny = r#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"no"}}"#;
    let tip =
        r#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"a tip"}}"#;
    let allow =
        r#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}"#;
    let a =
        answer("PreToolUse", &[ok(tip), ok(allow), ok(deny), ok(r#"{"systemMessage":"later"}"#)]);
    assert_eq!(a["hookSpecificOutput"]["permissionDecision"], "deny");
    assert_eq!(a["hookSpecificOutput"]["permissionDecisionReason"], "no");
    assert_eq!(a["hookSpecificOutput"]["additionalContext"], "a tip");
    assert!(a.get("systemMessage").is_none(), "nothing after the refusal");
}

#[test]
fn exit_two_refuses_and_other_failures_add_nothing() {
    let two = Ran { code: Some(2), stdout: String::new(), stderr: "too heavy\n".into() };
    let a = answer("PreToolUse", &[two.clone()]);
    assert_eq!(a["hookSpecificOutput"]["permissionDecision"], "deny");
    assert_eq!(a["hookSpecificOutput"]["permissionDecisionReason"], "too heavy");
    let b = answer("Stop", &[two]);
    assert_eq!(b, json!({"decision": "block", "reason": "too heavy"}));
    let failed =
        Ran { code: Some(1), stdout: r#"{"decision":"block"}"#.into(), stderr: "x".into() };
    let late = Ran::default();
    assert_eq!(answer("PreToolUse", &[failed, late]), json!({}));
}

#[test]
fn contexts_join_and_plain_text_counts_only_where_command_hooks_take_it() {
    let c1 = r#"{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"one"}}"#;
    let c2 = r#"{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"two"}}"#;
    let a = answer("PostToolUse", &[ok(c1), ok("plain"), ok(""), ok(c2)]);
    assert_eq!(a["hookSpecificOutput"]["additionalContext"], "one\n\ntwo");
    assert_eq!(a["hookSpecificOutput"]["hookEventName"], "PostToolUse");
    let p = answer("UserPromptSubmit", &[ok("the time is now")]);
    assert_eq!(p["hookSpecificOutput"]["additionalContext"], "the time is now");
    assert_eq!(answer("Stop", &[ok("transcript only")]), json!({}));
}

#[test]
fn an_updated_input_passes_through() {
    let rw = r#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"x &"}}}"#;
    let a = answer("PreToolUse", &[ok(rw)]);
    assert_eq!(a["hookSpecificOutput"]["updatedInput"]["command"], "x &");
}
