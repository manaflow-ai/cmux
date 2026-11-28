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

// RFD 0158 §15, harness magic `continue` (cmux#59633).
/// `continue` is opt-in: off with no setting, on with `true`, and the kill switch wins.
#[test]
fn continue_is_off_unless_asked_for_and_the_kill_switch_wins() {
    let on = json!({"agents": {"harnessMagic": {"continue": {"enabled": true}}}});
    let off = json!({"agents": {"harnessMagic": {"continue": {"enabled": false}}}});
    assert!(!continue_enabled_in(None, None));
    assert!(!continue_enabled_in(None, Some(&json!({}))));
    assert!(!continue_enabled_in(None, Some(&off)));
    assert!(continue_enabled_in(None, Some(&on)));
    assert!(!continue_enabled_in(Some("0"), Some(&on)));
    assert!(continue_enabled_in(Some("1"), None));
    assert_eq!(crate::hub::harness_magic::env_key(CONTINUE_FEATURE), "ACPMUX_HM_CONTINUE");
    assert_eq!(crate::hub::harness_magic::setting_key(CONTINUE_FEATURE), CONTINUE_SETTING);
}

fn stop(active: bool) -> Value {
    json!({"hook_event_name": "Stop", "stop_hook_active": active, "cwd": "/tmp"})
}

/// While the work moves between stops the check is asked again; a stop with nothing changed
/// ends the turn (the spin guard), and so does a stop with no fingerprint (fail open to the
/// one-continuation rule).
#[test]
fn continue_sends_a_moving_turn_on_and_ends_a_spinning_one() {
    let mut c = Continuation::default();
    assert_eq!(c.on_stop(&stop(false), Some(1)), json!({}), "the first stop is the check's");
    assert_eq!(c.on_stop(&stop(true), Some(2)), json!({}), "work moved: the check again");
    assert_eq!(c.on_stop(&stop(true), Some(3)), json!({}));
    let spun = c.on_stop(&stop(true), Some(3));
    assert_eq!(spun["continue"], false, "{spun}");
    assert!(spun["stopReason"].as_str().unwrap().starts_with("No file or commit changed"));
    let counts = c.turn_ended();
    assert_eq!(counts, ContinueCounters { continued: 2, spin_stopped: 1, ..Default::default() });
    assert_eq!(
        counts.to_json(),
        json!({"continued": 2, "spinStopped": 1, "budgetStopped": 0, "unreadStopped": 0})
    );
    assert_eq!(c.turn_ended(), ContinueCounters::default(), "a new turn starts at zero");

    // No fingerprint, before or now: the turn ends as it would without the feature.
    assert_eq!(c.on_stop(&stop(false), None), json!({}));
    assert_eq!(c.on_stop(&stop(true), Some(5))["continue"], false);
    assert_eq!(c.on_stop(&stop(false), Some(5)), json!({}));
    assert_eq!(c.on_stop(&stop(true), None)["continue"], false);
    assert_eq!(c.turn_ended().unread_stopped, 2);
}

/// A turn whose work keeps moving still ends at the soft budget: [`SOFT_BUDGET`]
/// continuations, Claude Code's own default cap.
#[test]
fn continue_ends_a_moving_turn_at_its_soft_budget() {
    let mut c = Continuation::default();
    assert_eq!(c.on_stop(&stop(false), Some(0)), json!({}));
    let mut sent_on = 0;
    for n in 1..=SOFT_BUDGET as u64 + 3 {
        let out = c.on_stop(&stop(true), Some(n));
        if out.get("continue").is_some() {
            assert!(out["stopReason"].as_str().unwrap().contains("budget"), "{out}");
            break;
        }
        sent_on += 1;
    }
    assert_eq!(sent_on, SOFT_BUDGET - 1, "the stop after the budget's last continuation ends");
    let counts = c.turn_ended();
    assert_eq!((counts.continued, counts.budget_stopped), (u64::from(SOFT_BUDGET) - 1, 1));
}

/// The fingerprint moves on an edit, on a second edit of a file already modified, on a new
/// file and on a commit, and stays put when nothing changed. Outside a repository: none.
#[test]
fn the_worktree_fingerprint_moves_with_files_and_commits() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let git = |args: &[&str]| {
        let ok = std::process::Command::new("git")
            .arg("-C")
            .arg(root)
            .args(["-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"])
            .args(args)
            .output()
            .unwrap()
            .status
            .success();
        assert!(ok, "git {args:?}");
    };
    assert_eq!(worktree_fingerprint(root), None, "not a repository");
    git(&["init", "-q"]);
    std::fs::write(root.join("a.txt"), "one\n").unwrap();
    git(&["add", "a.txt"]);
    git(&["commit", "-q", "-m", "one"]);
    let clean = worktree_fingerprint(root).expect("a repository with a commit");
    assert_eq!(worktree_fingerprint(root), Some(clean), "nothing changed");
    std::fs::write(root.join("a.txt"), "two\n").unwrap();
    let edited = worktree_fingerprint(root).unwrap();
    assert_ne!(edited, clean);
    std::fs::write(root.join("a.txt"), "three, longer\n").unwrap();
    let edited_again = worktree_fingerprint(root).unwrap();
    assert_ne!(edited_again, edited, "the same ` M` line, a different file");
    std::fs::write(root.join("b.txt"), "new\n").unwrap();
    let added = worktree_fingerprint(root).unwrap();
    assert_ne!(added, edited_again);
    git(&["add", "-A"]);
    git(&["commit", "-q", "-m", "two"]);
    let committed = worktree_fingerprint(root).unwrap();
    assert_ne!(committed, added);
    assert_ne!(committed, clean);
}
