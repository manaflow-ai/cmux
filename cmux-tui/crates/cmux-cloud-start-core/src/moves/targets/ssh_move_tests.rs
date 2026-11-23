use super::*;
use serde_json::json;

fn request(target: &str) -> SshMove {
    serde_json::from_value(json!({
        "chat": {"started": true, "session": "chat-1"},
        "target": target,
        "peers": [
            {"name": "box", "url": "ssh://box"},
            {"name": "mini", "url": "ssh://mini"},
            {"name": "relay", "url": "https://relay"}
        ]
    }))
    .unwrap()
}

#[test]
fn raw_peer_names_and_auto_use_the_existing_session_move() {
    let named = ssh_move(&request("box")).unwrap();
    assert_eq!(named.args, ["--json", "session", "move", "chat-1", "--machine", "box"]);
    assert_eq!(named.destination, "box");
    assert_eq!(named.moved, "box/chat-1");
    let auto = ssh_move(&request("auto")).unwrap();
    assert_eq!(auto.args, ["--json", "session", "move", "chat-1", "--machine", "auto"]);
    assert_eq!(auto.destination, "auto");
    assert!(auto.moved.is_empty(), "Auto cannot invent a destination route");
    for target in ["missing", "relay", "local"] {
        assert_eq!(ssh_move(&request(target)).unwrap_err(), "not_offered");
    }
}

#[test]
fn choices_are_flattened_and_passed_to_acpmux() {
    let mut request = request("auto");
    let flags: SshMove = serde_json::from_value(json!({
        "chat": {}, "afterTurn": true, "carryChanges": true, "dryRun": true
    }))
    .unwrap();
    request.after_turn = flags.after_turn;
    request.carry_changes = flags.carry_changes;
    request.dry_run = flags.dry_run;
    assert_eq!(
        &ssh_move(&request).unwrap().args[6..],
        ["--after-turn", "--carry-changes", "--dry-run"]
    );
    request.interrupt = true;
    assert_eq!(ssh_move(&request).unwrap_err(), "conflicting_options");
    request.after_turn = false;
    request.dry_run = false;
    assert_eq!(&ssh_move(&request).unwrap().args[6..], ["--interrupt", "--carry-changes"]);
    request.leave_dirty = true;
    assert_eq!(ssh_move(&request).unwrap_err(), "conflicting_options");
}

#[test]
fn remote_auto_routes_through_the_source_and_rejects_that_source_as_target() {
    let mut request = request("auto");
    request.chat.session = Some("BOX/chat-1".into());
    let call = ssh_move(&request).unwrap();
    assert_eq!(
        call.args,
        ["--json", "session", "move", "chat-1", "--machine", "auto", "--from", "box"]
    );
    request.target = Some("box".into());
    assert_eq!(ssh_move(&request).unwrap_err(), "not_offered");
    request.target = Some("mini".into());
    assert_eq!(ssh_move(&request).unwrap().moved, "mini/chat-1");
}

#[test]
fn auto_never_bypasses_chief_cloud_or_unstarted_chat_rules() {
    for chat in [
        Chat { chief: true, started: true, ..Chat::default() },
        Chat { running: Some("vm".into()), started: true, ..Chat::default() },
        Chat { elsewhere: true, started: true, ..Chat::default() },
        Chat::default(),
    ] {
        let mut request = request("auto");
        request.chat = chat;
        assert_eq!(ssh_move(&request).unwrap_err(), "not_offered");
    }
}

fn outcome(row: Value, status: i32) -> SshMoveResult {
    ssh_move_result(&serde_json::to_string_pretty(&json!({"moves": [row]})).unwrap(), "", status)
}

#[test]
fn outcome_opens_the_actual_destination_and_session_id() {
    let result = outcome(json!({"moved": true, "host": "mini", "targetSessionId": "new-chat"}), 0);
    assert!(result.moved);
    assert!(!result.needs_confirmation);
    assert_eq!(result.host.as_deref(), Some("mini"));
    assert_eq!(result.target_session_id.as_deref(), Some("new-chat"));
    assert!(result.error.is_none());
    let json = serde_json::to_value(result).unwrap();
    assert_eq!(json["targetSessionId"], "new-chat");
    assert_eq!(json["needsConfirmation"], false);
}

#[test]
fn running_and_dirty_are_one_confirmable_preflight() {
    let row = json!({"moved": false, "error": "its turn is running", "errorCode": "running_turn",
        "preflight": {"running": true, "dirty": true}});
    let result = outcome(row, 1);
    assert!(result.needs_confirmation);
    assert_eq!(result.preflight, Some(Preflight { running: true, dirty: Some(true) }));
    assert_eq!(result.error_code.as_deref(), Some("running_turn"));
    let dirty = outcome(
        json!({"error": "uncommitted changes", "errorCode": "dirty_worktree",
        "preflight": {"running": false, "dirty": true}}),
        1,
    );
    assert!(dirty.needs_confirmation);
    for row in [
        json!({"errorCode": "running_turn", "preflight": {"running": true, "dirty": null}}),
        json!({"errorCode": "dirty_worktree", "preflight": {"running": false, "dirty": false}}),
        json!({"error": "missing origin", "preflight": {"running": false, "dirty": true}}),
    ] {
        assert!(!outcome(row, 1).needs_confirmation);
    }
}

#[test]
fn dry_run_success_and_failed_execution_never_report_a_move() {
    let ready = outcome(json!({"dryRun": true, "moved": false}), 0);
    assert!(ready.ready);
    assert!(!ready.moved);
    assert!(ready.error.is_none());
    assert!(!outcome(json!({"moved": true}), 1).moved);
    assert!(!outcome(json!({"moved": true, "error": "failed"}), 0).moved);
    let error = ssh_move_result("", r#"{"error":{"message":"unknown peer"}}"#, 1);
    assert_eq!(error.error.as_deref(), Some("unknown peer"));
}

#[test]
fn a_run_opens_the_session_the_move_reported() {
    let moved = |session: &str| SshMoveRun::Moved { session: session.to_owned() };
    let done = outcome(json!({"moved": true, "host": "mini", "targetSessionId": "new"}), 0);
    assert_eq!(ssh_move_run("box/chat-1", "box", false, &done), moved("mini/new"));
    assert_eq!(ssh_move_run("", "auto", false, &done), moved("mini/new"));
    assert_eq!(ssh_move_run("chat-1", "local", false, &done), moved("new"));
    let bare = outcome(json!({"moved": true, "targetSessionId": "new"}), 0);
    assert_eq!(ssh_move_run("box/chat-1", "box", false, &bare), moved("new"));
    let old = outcome(json!({"moved": true, "host": "mini", "targetSessionId": ""}), 0);
    assert_eq!(ssh_move_run("box/chat-1", "box", false, &old), moved("box/chat-1"));
    let lost = SshMoveRun::Failed { message: "Move did not report its destination.".to_owned() };
    assert_eq!(ssh_move_run("", "auto", false, &bare), lost);
    assert_eq!(ssh_move_run("", "auto", false, &old), lost);
}

#[test]
fn a_run_asks_once_fails_with_the_moves_words_and_a_dry_run_moves_nothing() {
    let running = outcome(
        json!({"error": "its turn is running", "errorCode": "running_turn",
        "preflight": {"running": true, "dirty": false}}),
        1,
    );
    assert_eq!(
        ssh_move_run("box/chat-1", "box", false, &running),
        SshMoveRun::NeedsConfirmation { code: "running_turn".to_owned(), dirty: Some(false) }
    );
    let failed = ssh_move_result("", r#"{"error":{"message":"unknown peer"}}"#, 1);
    assert_eq!(
        ssh_move_run("box/chat-1", "box", false, &failed),
        SshMoveRun::Failed { message: "unknown peer".to_owned() }
    );
    let ready = outcome(json!({"dryRun": true, "moved": false}), 0);
    assert_eq!(
        ssh_move_run("box/chat-1", "box", true, &ready),
        SshMoveRun::Moved { session: "box/chat-1".to_owned() }
    );
    assert_eq!(
        ssh_move_run("", "auto", true, &ready),
        SshMoveRun::Moved { session: String::new() }
    );
    assert_eq!(
        ssh_move_run("box/chat-1", "box", false, &ready),
        SshMoveRun::Failed { message: String::new() },
        "a dry run's answer is no move unless the request was one"
    );
    let json =
        serde_json::to_value(SshMoveRun::NeedsConfirmation { code: "x".into(), dirty: None })
            .unwrap();
    assert_eq!(json, json!({"kind": "needs_confirmation", "code": "x", "dirty": null}));
}
