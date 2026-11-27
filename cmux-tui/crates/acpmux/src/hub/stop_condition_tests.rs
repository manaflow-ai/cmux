use super::*;

#[test]
fn requested_condition_is_text_trimmed_and_capped() {
    let ask = |v: Value| requested(Some(&json!({FIELD: v})));
    assert_eq!(ask(json!("  done and landed ")).unwrap().as_deref(), Some("done and landed"));
    assert_eq!(requested(None).unwrap(), None);
    assert_eq!(requested(Some(&json!({}))).unwrap(), None);
    assert_eq!(ask(Value::Null).unwrap(), None);
    for bad in [json!(""), json!("   "), json!(3), json!(["x"]), json!("x".repeat(MAX_CHARS + 1))] {
        assert!(ask(bad.clone()).is_err(), "{bad}");
    }
    assert!(ask(json!("x".repeat(MAX_CHARS))).is_ok());
}

#[test]
fn settings_hold_one_prompt_stop_hook_and_the_block_cap() {
    let got = settings("The task is landed.");
    assert_eq!(got["env"][BLOCK_CAP_ENV], BLOCK_CAP);
    let hook = &got["hooks"]["Stop"][0]["hooks"][0];
    assert_eq!(hook, &json!({"type": "prompt", "prompt": "The task is landed."}));
    // A condition that looks like JSON or a command stays one prompt string.
    let tricky = r#""}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"rm -rf /"}]}]"#;
    let parsed: Value = serde_json::from_str(&settings(tricky).to_string()).unwrap();
    assert_eq!(parsed["hooks"].as_object().unwrap().len(), 1);
    assert_eq!(parsed["hooks"]["Stop"][0]["hooks"][0]["prompt"], tricky);
}

fn meta(condition: Option<&str>) -> SessionMeta {
    let mut m: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "chat", "name": "chat", "harness": "claude",
        "family": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    m.stop_condition = condition.map(str::to_owned);
    m
}

#[test]
fn a_profiles_inline_settings_take_the_stop_hook_and_keep_their_own_keys() {
    let helper = json!({"apiKeyHelper": "'/Applications/cmux.app/bin/cmux' auth token", "env": {"OWN": "1"}});
    let own = || vec!["--settings".to_owned(), helper.to_string()];
    // No condition: the profile's args as they are.
    let mut args = own();
    add_claude_args(&mut args, &meta(None));
    assert_eq!(args, own());
    // A condition: one --settings with both, never a second that would replace the helper.
    let mut args = own();
    add_claude_args(&mut args, &meta(Some("landed")));
    assert_eq!(args.iter().filter(|a| *a == "--settings").count(), 1, "{args:?}");
    let merged: Value = serde_json::from_str(&args[1]).unwrap();
    assert_eq!(merged["apiKeyHelper"], helper["apiKeyHelper"]);
    assert_eq!(merged["hooks"], settings("landed")["hooks"]);
    assert_eq!(merged["env"]["OWN"], "1");
    assert_eq!(merged["env"][BLOCK_CAP_ENV], BLOCK_CAP);
    // No inline settings (or a settings file path): the condition's own --settings follows.
    for start in [vec![], vec!["--settings".to_owned(), "/tmp/s.json".to_owned()]] {
        let mut args = start.clone();
        add_claude_args(&mut args, &meta(Some("landed")));
        assert_eq!(args[..start.len()], start[..]);
        assert_eq!(args[start.len()..], claude_args(&meta(Some("landed")))[..]);
    }
}

/// A subagent waiting on the person's OK answered each block of its goal check with one more
/// "still holding" message, 8 times a turn (Claude Code's default cap). Its Claude Code now
/// starts with a cap of one block with no tool call between, so the check re-prompts it once.
#[test]
fn a_stop_condition_chat_starts_with_one_block_before_the_turn_ends() {
    let mut meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "s", "name": "sub", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    assert!(claude_args(&meta).is_empty(), "no condition, no settings");
    meta.stop_condition = Some("The task is landed.".into());
    let args = claude_args(&meta);
    assert_eq!(args[0], "--settings");
    let doc: Value = serde_json::from_str(&args[1]).unwrap();
    assert_eq!(doc["env"][BLOCK_CAP_ENV], "1");
    assert_eq!(doc["hooks"]["Stop"][0]["hooks"][0]["type"], "prompt");
}

/// Lucas's Chief subagents were sent back by the goal check 51 times in two sessions, up to
/// Claude Code's cap of 9 in a row ("A hook blocked the turn from ending 9 consecutive
/// times"). A stop with `stop_hook_active: true` now ends the turn; the first stop of a turn
/// is the check's to decide, so an unfinished task is still sent back once.
#[test]
fn a_stop_the_check_already_sent_back_ends_the_turn() {
    let stop = |active: bool| {
        json!({"session_id": "s", "transcript_path": "/tmp/t.jsonl", "cwd": "/tmp",
            "hook_event_name": "Stop", "stop_hook_active": active,
            "last_assistant_message": "still holding for the person's OK"})
    };
    let out = repeat_stop(&stop(true));
    assert_eq!(out["continue"], false, "stop_hook_active true: the stop goes through: {out}");
    assert_eq!(out["suppressOutput"], true);

    // The first stop prints nothing: Claude Code goes by the prompt check, which blocks an
    // unfinished task (its hook is still in the settings, after this one).
    assert_eq!(repeat_stop(&stop(false)), json!({}), "the first stop is the check's");
    let doc = settings("The task is landed.");
    assert_eq!(doc["hooks"]["Stop"][0]["hooks"][0]["prompt"], "The task is landed.");

    // Spaced JSON counts too; a message that only quotes the words does not.
    let spaced = r#"{"hook_event_name": "Stop", "stop_hook_active": true}"#;
    assert!(repeat_stop(&serde_json::from_str(spaced).unwrap()).get("continue").is_some());
    let mut quoted = stop(false);
    quoted["last_assistant_message"] = json!("stop_hook_active: true");
    assert_eq!(repeat_stop(&quoted), json!({}));
}
