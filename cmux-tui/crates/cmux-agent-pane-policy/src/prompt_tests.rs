use super::*;
use serde_json::json;

#[test]
fn scrubs_secret_shapes_and_limits_prefix() {
    assert_eq!(scrub("token: abcdefghijklmnop", false), "token: [redacted]");
    assert_eq!(scrub("Bearer abcdef", false), "Bearer [redacted]");
    assert_eq!(scrub("x\u{200b}y", false), "x\u{200b}y");
    assert_eq!(scrub(&"a".repeat(SCRUB_WINDOW + 4), true).chars().count(), SCRUB_WINDOW);
}

#[test]
fn renders_commands_and_invisible_scalars() {
    assert_eq!(
        shown_command(Some(&json!(["bash", "-lc", "rm -rf ~"]))),
        Some("bash -lc 'rm -rf ~'".into())
    );
    assert_eq!(shown_command(Some(&json!(["bash", 1]))), Some("[\"bash\",1]".into()));
    assert_eq!(visible("a\u{200b}\u{202e}b"), "a<U+200B><U+202E>b");
}

#[test]
fn input_summary_hides_env_and_marks_redaction_or_overflow() {
    let input =
        json!({"env": {"TOKEN": "secret"}, "cwd": "/tmp", "pattern": "token: abcdefghijklmnop"});
    let summary = input_summary(input.as_object().unwrap()).unwrap();
    assert_eq!(summary["truncated"], true);
    assert_eq!(summary["fields"]["pattern"], "token: [redacted]");
    assert!(summary["fields"].get("env").is_none());
}

#[test]
fn option_and_request_read_are_fail_closed() {
    let offered = vec![
        json!({"kind": "allow_once", "optionId": "a"}),
        json!({"kind": "reject_once", "optionId": "d"}),
    ];
    assert_eq!(option(true, &offered).as_deref(), Some("a"));
    assert_eq!(option(false, &offered).as_deref(), Some("d"));
    let request = json!({"toolCall": {"title": "Run", "rawInput": {"command": ["echo", "hi"]}, "_meta": {}}, "options": offered});
    let read = read(&request).unwrap();
    assert_eq!(read["is_question"], false);
    assert_eq!(read["is_tool_permission"], true);
    assert_eq!(read["summary"], "Run\necho hi");
}
