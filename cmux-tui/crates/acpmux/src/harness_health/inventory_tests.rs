use super::*;

#[test]
fn cmux_next_harness_inventory_preserves_release_version_tokens() {
    for version in ["1.2", "1.2.3", "v1.2.3", "1.2.3-beta-1.2+build.5"] {
        assert_eq!(safe_version(Some(version)), Some(version));
    }
    for value in ["1.2.3 private@example.test", "1.2.3\n", "token", "1.2.3+", "1.2.3/secret"] {
        assert_eq!(safe_version(Some(value)), None);
    }
    assert_eq!(safe_version(None), None);
}

fn cached(program: &str, channel: &str, package: Value, path: Value) -> HarnessHealth {
    serde_json::from_value(json!({
        "id":"codex", "program":program, "path":path, "channel":channel,
        "package":package, "version":"1.2.3", "outdated":false,
        "auth":"unknown", "checkedAt":123
    }))
    .unwrap()
}

#[test]
fn cmux_next_harness_inventory_family_uses_the_recorded_executable_and_package() {
    for (program, channel, package, expected) in [
        ("/private/claude", "standalone", Value::Null, "claude"),
        ("codex", "npm", json!("@manaflow-ai/codex"), "codex"),
        ("custom-name", "npm", json!("@openai/codex"), "codex"),
        ("custom-name", "brewCask", json!("claude-code"), "claude"),
        ("gemini", "standalone", Value::Null, "gemini"),
        ("opencode2", "standalone", Value::Null, "opencode"),
        ("pi", "npm", json!("@earendil-works/pi-coding-agent"), "pi"),
        ("chief", "standalone", Value::Null, "chief"),
        ("amp", "standalone", Value::Null, "amp"),
        ("copilot", "standalone", Value::Null, "copilot"),
        ("cursor-agent", "standalone", Value::Null, "cursor"),
    ] {
        let row = cached(program, channel, package, json!("/private/checked-executable"));
        let result = view(&[row], &json!({"view":"inventory"})).unwrap();
        assert_eq!(result["harnesses"][0]["family"], expected, "{program}");
        assert!(result["harnesses"][0].get("program").is_none());
        assert!(result["harnesses"][0].get("package").is_none());
    }
}

#[test]
fn cmux_next_harness_inventory_family_leaves_wrappers_and_conflicts_unknown() {
    for (program, channel, package, path) in [
        ("npx", "npm", json!("@openai/codex"), json!("/bin/npx")),
        ("codex-acp", "npm", json!("@openai/codex"), json!("/bin/codex-acp")),
        ("npx", "launcher", json!("@openai/codex"), json!("/bin/npx")),
        ("codex-acp", "npm", json!("@zed-industries/codex-acp"), json!("/bin/codex-acp")),
        ("pi-acp", "standalone", Value::Null, json!("/bin/pi-acp")),
        ("claude-custom", "standalone", Value::Null, json!("/bin/claude-custom")),
        ("codex", "missing", Value::Null, Value::Null),
        ("codex", "standalone", Value::Null, Value::Null),
        ("codex", "npm", json!("@anthropic-ai/claude-code"), json!("/bin/codex")),
        ("private-wrapper", "standalone", json!("@openai/codex"), json!("/bin/private-wrapper")),
    ] {
        let result =
            view(&[cached(program, channel, package, path)], &json!({"view":"inventory"})).unwrap();
        assert_eq!(result["harnesses"][0]["family"], Value::Null, "{program}");
    }
}
