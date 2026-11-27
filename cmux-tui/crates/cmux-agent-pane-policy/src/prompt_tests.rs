use super::*;
use serde_json::json;

#[test]
fn truncation_counts_swift_characters_without_splitting_graphemes() {
    for grapheme in ["e\u{301}", "👩🏽‍💻", "🇺🇸", "\r\n"] {
        assert_eq!(cut(&grapheme.repeat(3), 3), grapheme.repeat(3));
        assert_eq!(cut(&grapheme.repeat(4), 3), format!("{}…", grapheme.repeat(2)));
        assert_eq!(scrub(&grapheme.repeat(SCRUB_WINDOW + 1), true), grapheme.repeat(SCRUB_WINDOW));
    }
    // Combining accents stay invisible to the character budget in both field names and values.
    let key = "e\u{301}".repeat(40);
    let value = "e\u{301}".repeat(200);
    let input = Map::from_iter([(key.clone(), Value::String(value.clone()))]);
    assert_eq!(input_summary(&input), Some(json!({"fields": {key: value}, "truncated": false})));
}

#[test]
fn scrubs_secret_shapes_and_limits_prefix() {
    assert_eq!(scrub("token: abcdefghijklmnop", false), "token: [redacted]");
    assert_eq!(scrub("Bearer abcdef", false), "Bearer [redacted]");
    assert_eq!(scrub("x\u{200b}y", false), "x\u{200b}y");
    assert_eq!(scrub(&"a".repeat(SCRUB_WINDOW + 4), true).chars().count(), SCRUB_WINDOW);
}

#[test]
fn scrubs_each_existing_secret_shape_and_preserves_public_text() {
    for secret in [
        "-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----",
        "-----BEGIN RSA PRIVATE KEY-----\nunfinished",
        "eyJabcdefgh.abcdEFGH1234.abcdEFGH1234",
        "sk-abcdefghijklmnop",
        "pk-abcdefghijklmnop",
        "rk-abcdefghijklmnop",
        "ghp_abcdefghijklmnopqrst",
        "github_pat_abcdefghijklmnopqrst",
        "glpat-abcdefghijklmnop",
        "xoxb-1234567890",
        "AKIA0123456789ABCDEF",
        "AIzaabcdefghijklmnopqrstuvwxyz1234",
        "npm_abcdefghijklmnopqrstuvwxyz1234",
        "https://name:password@",
    ] {
        assert_eq!(scrub(secret, false), REDACTED, "{secret}");
    }
    for text in ["api_key = abcdef", "password: abcdef", "Authorization: Bearer abcdef"] {
        let shown = scrub(text, false);
        assert!(shown.contains(REDACTED), "{text}");
        assert!(!shown.contains("abcdef"), "{text}");
    }
    assert_eq!(scrub("echo 'hello world' /tmp/readme", false), "echo 'hello world' /tmp/readme");
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
fn input_summary_matches_swift_env_cast_semantics() {
    for env in [Value::Null, json!("hidden"), json!(["hidden"])] {
        let input = Map::from_iter([(String::from("env"), env)]);
        assert_eq!(input_summary(&input), Some(json!({"fields": {}, "truncated": true})));
    }
    assert_eq!(input_summary(&Map::from_iter([(String::from("env"), json!({}))])), None);
    let input = Map::from_iter([(String::from("env"), json!({"TOKEN": "hidden"}))]);
    assert_eq!(input_summary(&input), Some(json!({"fields": {}, "truncated": true})));
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

#[test]
fn options_preserve_uniqueness_and_never_recover_a_malformed_list() {
    let allow = json!({"kind": "allow_once", "optionId": "allow"});
    let deny = json!({"kind": "reject_once", "optionId": "deny"});
    assert_eq!(option(true, &[allow.clone(), allow.clone()]), None);
    assert_eq!(option(true, &[allow.clone(), Value::Null]), None);
    assert_eq!(
        always_option(&[json!({"kind": "allow_always", "optionId": "always"}), json!(1)]),
        None
    );
    let malformed = json!({"options": [allow, deny, null]});
    assert!(!is_tool_permission(malformed.as_object().unwrap()));
    let denied =
        [json!({"kind": "reject_once"}), json!({"kind": "reject_always", "optionId": "never"})];
    assert_eq!(option(false, &denied).as_deref(), Some("never"));
    assert_eq!(once_option(false, &denied), None);
    assert_eq!(option(true, &[json!({"kind": "allow_always", "optionId": "always"})]), None);
}

#[test]
fn explicit_null_command_is_shown_and_missing_command_is_absent() {
    assert_eq!(shown_command(None), None);
    assert_eq!(shown_command(Some(&Value::Null)).as_deref(), Some("null"));
    for marker in [Value::Null, json!(false), json!("question"), json!({})] {
        let request = json!({"toolCall": {"_meta": {"acpmux": {"question": marker}}}});
        assert!(is_question(request.as_object().unwrap()));
        assert!(!is_tool_permission(request.as_object().unwrap()));
    }
}
