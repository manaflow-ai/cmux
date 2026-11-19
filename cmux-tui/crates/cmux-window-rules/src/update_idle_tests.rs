use super::*;

fn idle(minutes_away: f64) -> IdleFacts {
    IdleFacts {
        enabled: true,
        idle_minutes: 15.0,
        input_idle_seconds: Some(minutes_away * 60.0),
        running_turns: Some(0),
        unsent_drafts: Some(0),
    }
}

/// Away 15 minutes, no turn, no draft: it installs.
#[test]
fn installs_after_the_idle_time_with_nothing_running() {
    assert_eq!(decide(&idle(15.0)), Decision { install: true, hold: None });
    assert!(decide(&idle(90.0)).install);
}

/// Off by default: a default request never installs.
#[test]
fn the_setting_off_never_installs() {
    let facts = IdleFacts { enabled: false, ..idle(600.0) };
    assert_eq!(decide(&facts).hold, Some(Hold::Off));
    assert_eq!(decide(&IdleFacts::default()).hold, Some(Hold::Off));
}

/// Input within the idle time holds it, and says how long is left.
#[test]
fn recent_input_holds_with_the_time_left() {
    assert_eq!(decide(&idle(10.0)).hold, Some(Hold::NotIdle { seconds_left: 300.0 }));
}

/// The input check comes first: the app need not read the agents while the person is at the Mac.
#[test]
fn recent_input_wins_over_unknown_agents() {
    let facts = IdleFacts { running_turns: None, unsent_drafts: None, ..idle(1.0) };
    assert!(matches!(decide(&facts).hold, Some(Hold::NotIdle { .. })));
}

/// Never mid-turn: a running agent turn holds it however long the person is away.
#[test]
fn a_running_turn_holds_it() {
    let facts = IdleFacts { running_turns: Some(1), ..idle(600.0) };
    assert_eq!(decide(&facts).hold, Some(Hold::AgentWorking));
}

/// Never over an unsent message.
#[test]
fn an_unsent_draft_holds_it() {
    let facts = IdleFacts { unsent_drafts: Some(2), ..idle(600.0) };
    assert_eq!(decide(&facts).hold, Some(Hold::UnsentDraft));
}

/// Unknown is unsafe: no input reading, or no answer from the daemon, holds it.
#[test]
fn unknown_facts_hold_it() {
    for facts in [
        IdleFacts { input_idle_seconds: None, ..idle(600.0) },
        IdleFacts { input_idle_seconds: Some(f64::NAN), ..idle(600.0) },
        IdleFacts { running_turns: None, ..idle(600.0) },
        IdleFacts { unsent_drafts: None, ..idle(600.0) },
    ] {
        assert_eq!(decide(&facts).hold, Some(Hold::Unknown), "{facts:?}");
    }
}

/// A setting below a minute (or not a number) counts as one minute, never as "install at once".
#[test]
fn the_idle_time_is_at_least_a_minute() {
    assert_eq!(idle_seconds(0.0), 60.0);
    assert_eq!(idle_seconds(-5.0), 60.0);
    assert_eq!(idle_seconds(f64::NAN), 60.0);
    assert_eq!(idle_seconds(15.0), 900.0);
    let facts = IdleFacts { idle_minutes: 0.0, input_idle_seconds: Some(30.0), ..idle(0.0) };
    assert_eq!(decide(&facts).hold, Some(Hold::NotIdle { seconds_left: 30.0 }));
}

/// The wire shape the app decodes.
#[test]
fn the_reply_wire_shape() {
    let held = serde_json::to_value(decide(&idle(14.0))).unwrap();
    assert_eq!(
        held,
        serde_json::json!({ "install": false, "hold": { "reason": "notIdle", "secondsLeft": 60.0 } })
    );
    let working =
        serde_json::to_value(decide(&IdleFacts { running_turns: Some(3), ..idle(20.0) })).unwrap();
    assert_eq!(
        working,
        serde_json::json!({ "install": false, "hold": { "reason": "agentWorking" } })
    );
    let go = serde_json::to_value(decide(&idle(20.0))).unwrap();
    assert_eq!(go, serde_json::json!({ "install": true, "hold": null }));
    let request: IdleFacts = serde_json::from_value(serde_json::json!({
        "enabled": true, "idleMinutes": 15, "inputIdleSeconds": 901.5, "runningTurns": 0, "unsentDrafts": 0
    }))
    .unwrap();
    assert!(decide(&request).install);
}
