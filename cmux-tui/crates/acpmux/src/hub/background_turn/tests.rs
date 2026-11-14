use super::*;

fn chunk(id: &str, text: &str) -> Value {
    json!({"sessionUpdate": "agent_message_chunk", "messageId": id,
               "content": {"type": "text", "text": text}})
}

#[test]
fn quiet_is_one_short_line_with_no_question_or_link() {
    assert!(is_quiet("Nothing new for you yet."));
    assert!(is_quiet("  Still waiting on CI.\n"));
    assert!(is_quiet(""));
    assert!(!is_quiet("Should I merge #12?"));
    assert!(!is_quiet("Merged: https://github.com/o/r/pull/1"));
    assert!(!is_quiet("Line one.\nLine two."));
    assert!(!is_quiet(&"a".repeat(SHORT_LINE + 1)));
}

#[test]
fn a_task_notification_turn_is_bracketed_and_quiet() {
    let mut b = BackgroundTurns::default();
    assert!(b.on_line("claude.system.task_notification", &json!({}), false, 1).is_empty());
    assert!(b.on_line("claude.system.init", &json!({}), false, 2).is_empty());
    let started = b.on_update(&chunk("m1", "Nothing new "), false, 0);
    // A notification of a task this daemon never heard start: a result, acpmux cannot say more.
    assert_eq!(
        started,
        Some(json!({"state": "started", "id": "bg-2", "trigger": "task_notification",
                        "cause": {"kind": "unknown", "status": "completed", "weight": "result"}}))
    );
    assert_eq!(b.on_update(&chunk("m1", "for you yet."), false, 0), None);
    assert!(b.owns_message("m1"));
    let ended = b.on_line("claude.result.success", &json!({}), false, 5);
    assert_eq!(
        ended,
        [json!({"state": "ended", "id": "bg-2", "trigger": "task_notification",
                    "quiet": true, "reason": "result"})]
    );
    // The next one, with nothing before it, is the system's; a long reply is not quiet.
    b.on_line("claude.system.init", &json!({}), false, 6);
    b.on_update(&chunk("m2", "Merged #1.\nThe nightly is green."), false, 0);
    let ended = b.on_line("claude.result.success", &json!({}), false, 9);
    assert_eq!(ended[0]["trigger"], "system");
    assert_eq!(ended[0]["quiet"], false);
}

#[test]
fn a_task_notification_turn_names_its_cause() {
    let mut b = BackgroundTurns::default();
    let task = json!({"task_id": "t1", "subagent_type": "general-purpose"});
    // Started during the person's turn: still heard.
    b.on_line("claude.system.task_started", &task, true, 1);
    let note = json!({"task_id": "t1", "tool_use_id": "toolu_1", "status": "completed",
                          "summary": "The agent is waiting on its own background work."});
    b.on_line("claude.system.task_notification", &note, false, 2);
    b.on_line("claude.system.init", &json!({}), false, 3);
    let started = b.on_update(&chunk("m1", "."), false, 0).unwrap();
    assert_eq!(
        started["cause"],
        json!({"kind": "subagent", "status": "interim", "weight": "silent",
                   "origin": "toolu_1", "summary": "The agent is waiting on its own background work."})
    );
    b.on_line("claude.result.success", &json!({}), false, 5);
    // A notification the person's turn consumed is no later turn's cause.
    b.on_line("claude.system.task_notification", &note, true, 6);
    b.on_line("claude.system.init", &json!({}), false, 7);
    assert!(b.on_update(&chunk("m2", "Hi"), false, 0).unwrap().get("cause").is_none());
}

#[test]
fn a_scheduled_wakeup_is_named() {
    let mut b = BackgroundTurns::default();
    b.on_line("claude.command_lifecycle", &json!({"state": "started"}), false, 1);
    b.on_line("claude.system.init", &json!({}), false, 2);
    let started = b.on_update(&json!({"sessionUpdate": "tool_call"}), false, 0).unwrap();
    assert_eq!(started["trigger"], "scheduled");
}

#[test]
fn a_turn_acpmux_started_is_never_a_background_one() {
    let mut b = BackgroundTurns::default();
    b.on_line("claude.system.task_notification", &json!({}), true, 1);
    assert!(b.on_line("claude.system.init", &json!({}), true, 2).is_empty());
    assert_eq!(b.on_update(&chunk("m1", "Done."), true, 0), None);
    assert!(!b.owns_message("m1"));
    assert!(b.on_line("claude.result.success", &json!({}), true, 4).is_empty());
}

#[test]
fn an_init_with_no_work_after_it_is_no_turn() {
    // Claude Code's system/init at its start, before any prompt.
    let mut b = BackgroundTurns::default();
    b.on_line("claude.system.init", &json!({}), false, 1);
    assert_eq!(b.end("prompt"), None);
    assert_eq!(b.on_update(&chunk("m1", "Hi"), true, 0), None);
    assert!(b.on_line("claude.result.success", &json!({}), true, 3).is_empty());
}

#[test]
fn work_with_no_turn_after_a_restart_is_a_background_turn() {
    // The daemon restarted mid-turn: no system/init, but the model works with no acpmux turn.
    let mut b = BackgroundTurns::default();
    let started = b.on_update(&chunk("m1", "Still waiting."), false, 7).unwrap();
    assert_eq!(started["trigger"], "system");
    assert_eq!(started["id"], "bg-7");
    assert!(b.owns_message("m1"));
    let ended = b.on_line("claude.result.success", &json!({}), false, 9);
    assert_eq!(ended[0]["quiet"], true);
}

#[test]
fn a_reply_past_the_kept_text_is_never_quiet() {
    let mut b = BackgroundTurns::default();
    b.on_update(&chunk("m1", &"\u{1F600}".repeat(SHORT_LINE)), false, 1).unwrap();
    b.on_update(&chunk("m1", "Done"), false, 0);
    let ended = b.on_line("claude.result.success", &json!({}), false, 3);
    assert_eq!(ended[0]["quiet"], false);
}

#[test]
fn a_prompt_ends_the_running_one() {
    let mut b = BackgroundTurns::default();
    b.on_line("claude.system.init", &json!({}), false, 1);
    b.on_update(&chunk("m1", "Looking"), false, 0).unwrap();
    let ended = b.end("prompt").unwrap();
    assert_eq!(ended["reason"], "prompt");
    // Its result, now the prompt's turn's, ends nothing more.
    assert!(b.on_line("claude.result.success", &json!({}), true, 3).is_empty());
}
