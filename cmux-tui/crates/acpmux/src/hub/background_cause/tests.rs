use super::*;

fn started(id: &str, extra: Value) -> Value {
    let mut line = json!({"subtype": "task_started", "task_id": id, "description": "x"});
    for (k, v) in extra.as_object().unwrap() {
        line[k] = v.clone();
    }
    line
}

fn cause_of(start: Option<Value>, status: &str, summary: &str) -> Value {
    let mut c = Causes::default();
    if let Some(line) = start {
        c.on_line("claude.system.task_started", &line);
    }
    c.on_line(
        "claude.system.task_notification",
        &json!({"task_id": "t1", "tool_use_id": "toolu_1", "status": status, "summary": summary}),
    );
    c.take().unwrap()
}

#[test]
fn a_subagents_final_report_is_a_result_and_its_interim_stop_is_silent() {
    let agent = || Some(started("t1", json!({"subagent_type": "general-purpose"})));
    let c = cause_of(agent(), "completed", "Merged #12.");
    assert_eq!(c["kind"], "subagent");
    assert_eq!(c["weight"], "result");
    assert_eq!(c["origin"], "toolu_1");
    let c = cause_of(agent(), "completed", "The agent is waiting on its own background work.");
    assert_eq!((c["status"].as_str(), c["weight"].as_str()), (Some("interim"), Some("silent")));
    assert_eq!(cause_of(agent(), "completed", "Its result may be interim.")["weight"], "silent");
    assert_eq!(cause_of(agent(), "failed", "")["weight"], "failure");
    assert_eq!(cause_of(agent(), "stopped", "")["weight"], "silent");
}

#[test]
fn a_step_a_subagent_ran_is_silent_unless_it_failed() {
    let step = || Some(started("t1", json!({"owned_by_subagent": true})));
    let c = cause_of(step(), "completed", "Commit and push");
    assert_eq!((c["kind"].as_str(), c["weight"].as_str()), (Some("subagent_step"), Some("silent")));
    assert_eq!(cause_of(step(), "failed", "")["weight"], "failure");
}

#[test]
fn a_background_command_that_exited_is_a_result_a_stop_is_silent_a_failure_shows() {
    let shell = || Some(started("t1", json!({"is_backgrounded": true})));
    let c = cause_of(shell(), "completed", "Background command \"x\" completed (exit code 0)");
    assert_eq!((c["kind"].as_str(), c["weight"].as_str()), (Some("shell"), Some("result")));
    assert_eq!(cause_of(shell(), "stopped", "")["weight"], "silent");
    assert_eq!(cause_of(shell(), "killed", "")["weight"], "silent");
    assert_eq!(cause_of(shell(), "failed", "exit code 1")["weight"], "failure");
}

#[test]
fn a_monitor_tick_is_silent_unless_it_failed() {
    let monitor = || Some(started("t1", json!({"task_type": "monitor"})));
    let c = cause_of(monitor(), "completed", "");
    assert_eq!((c["kind"].as_str(), c["weight"].as_str()), (Some("monitor"), Some("silent")));
    assert_eq!(cause_of(monitor(), "failed", "")["weight"], "failure");
}

#[test]
fn a_failure_that_also_says_interim_still_shows_and_a_local_monitor_is_a_monitor() {
    let agent = || Some(started("t1", json!({"subagent_type": "general-purpose"})));
    assert_eq!(cause_of(agent(), "failed", "Its result may be interim.")["weight"], "failure");
    let local = || Some(started("t1", json!({"task_type": "local_monitor"})));
    let c = cause_of(local(), "completed", "");
    assert_eq!((c["kind"].as_str(), c["weight"].as_str()), (Some("monitor"), Some("silent")));
}

#[test]
fn a_task_never_heard_starting_is_a_result_and_its_failure_shows() {
    let c = cause_of(None, "completed", "");
    assert_eq!((c["kind"].as_str(), c["weight"].as_str()), (Some("unknown"), Some("result")));
    assert_eq!(cause_of(None, "failed", "")["weight"], "failure");
    assert_eq!(cause_of(None, "completed", "may be interim")["weight"], "silent");
}

#[test]
fn the_heaviest_notification_before_a_turn_names_its_cause() {
    let mut c = Causes::default();
    c.on_line("claude.system.task_started", &started("a", json!({"owned_by_subagent": true})));
    c.on_line("claude.system.task_started", &started("b", json!({"is_backgrounded": true})));
    let note = |id: &str, status: &str| json!({"task_id": id, "status": status, "tool_use_id": id});
    c.on_line("claude.system.task_notification", &note("b", "failed"));
    c.on_line("claude.system.task_notification", &note("a", "completed"));
    let cause = c.take().unwrap();
    assert_eq!((cause["weight"].as_str(), cause["origin"].as_str()), (Some("failure"), Some("b")));
    // Taken: the next turn starts from nothing.
    assert_eq!(c.take(), None);
}

#[test]
fn every_kind_has_a_row_for_every_status_it_can_end_with() {
    for kind in ["subagent", "subagent_step", "monitor", "shell", "unknown"] {
        for status in ["completed", "failed", "stopped", "killed", "interim"] {
            let w = weight(kind, status);
            assert_eq!(w == Weight::Failure, status == "failed", "{kind} {status}");
        }
    }
}
