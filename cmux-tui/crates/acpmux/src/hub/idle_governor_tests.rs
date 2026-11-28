use super::*;
use std::time::Duration;

#[test]
fn a_background_task_keeps_the_chat_up_at_least_seven_minutes() {
    assert_eq!(period_for(NextEvent::BgTask, Duration::from_secs(120)), BG_TASK_IDLE);
    // A longer configured period is kept.
    let long = Duration::from_secs(900);
    assert_eq!(period_for(NextEvent::BgTask, long), long);
}

#[test]
fn a_far_continuation_sleeps_after_thirty_seconds() {
    assert_eq!(period_for(NextEvent::FarResume, Duration::from_secs(120)), FAR_RESUME_IDLE);
    // A shorter configured period is kept.
    let short = Duration::from_secs(5);
    assert_eq!(period_for(NextEvent::FarResume, short), short);
}

#[test]
fn nothing_known_keeps_the_configured_period() {
    let idle = Duration::from_secs(120);
    assert_eq!(period_for(NextEvent::Unknown, idle), idle);
}

#[test]
fn a_wake_names_its_sender() {
    assert_eq!(prompt_wake_cause(true, None), "person");
    assert_eq!(prompt_wake_cause(false, None), "prompt");
    let bg = json!({"kind": "notice", "bgTaskId": "t1"});
    assert_eq!(prompt_wake_cause(false, Some(&bg)), "bg-notice");
    let resume = json!({"kind": "auto_resume", "attempt": 2});
    assert_eq!(prompt_wake_cause(false, Some(&resume)), "auto_resume");
    let msg = json!({"kind": "agent_message", "from": "a"});
    assert_eq!(prompt_wake_cause(false, Some(&msg)), "agent-msg");
    let parked = json!({"kind": "rate_limit_parked"});
    assert_eq!(prompt_wake_cause(false, Some(&parked)), "rate-hold");
    let notice = json!({"kind": "notice"});
    assert_eq!(prompt_wake_cause(false, Some(&notice)), "notice");
    let resent = json!({"kind": "agent_message", "waited": true});
    assert_eq!(prompt_wake_cause(false, Some(&resent)), "outbox");
    let odd = json!({"kind": "something_new"});
    assert_eq!(prompt_wake_cause(false, Some(&odd)), "prompt");
}
