use super::*;

fn idle(minutes_away: f64) -> IdleFacts {
    IdleFacts {
        enabled: true,
        idle_minutes: 15.0,
        input_idle_seconds: Some(minutes_away * 60.0),
        unsent_drafts: Some(0),
        ..IdleFacts::default()
    }
}

/// Away 15 minutes, no draft: it installs.
#[test]
fn installs_after_the_idle_time_with_nothing_running() {
    assert_eq!(
        decide(&idle(15.0)),
        Decision { install: true, hold: None, away: Some(Away::Idle { seconds: 900.0 }) }
    );
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

/// The input check comes first: the app need not read the drafts while the person is at the Mac.
#[test]
fn recent_input_wins_over_unknown_drafts() {
    let facts = IdleFacts { unsent_drafts: None, ..idle(1.0) };
    assert!(matches!(decide(&facts).hold, Some(Hold::NotIdle { .. })));
}

/// A running agent turn does not hold it (Leo's agents are always mid-turn): the turn runs in the
/// daemon, which the relaunch leaves running. An old app's `runningTurns` field is ignored.
#[test]
fn a_running_turn_does_not_hold_it() {
    let request: IdleFacts = serde_json::from_value(serde_json::json!({
        "enabled": true, "idleMinutes": 15, "inputIdleSeconds": 900, "runningTurns": 3, "unsentDrafts": 0
    }))
    .unwrap();
    assert!(decide(&request).install);
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
    let draft =
        serde_json::to_value(decide(&IdleFacts { unsent_drafts: Some(1), ..idle(20.0) })).unwrap();
    assert_eq!(draft, serde_json::json!({ "install": false, "hold": { "reason": "unsentDraft" } }));
    let go = serde_json::to_value(decide(&idle(20.0))).unwrap();
    assert_eq!(
        go,
        serde_json::json!({ "install": true, "hold": null, "away": { "kind": "idle", "seconds": 1200.0 } })
    );
    let locked =
        serde_json::to_value(decide(&IdleFacts { screen_locked: Some(true), ..idle(0.0) }))
            .unwrap();
    assert_eq!(
        locked,
        serde_json::json!({ "install": true, "hold": null, "away": { "kind": "screenLocked" } })
    );
    let backoff = serde_json::to_value(decide(&IdleFacts {
        declined_installs: 1,
        seconds_since_decline: Some(20.0),
        ..idle(20.0)
    }))
    .unwrap();
    assert_eq!(
        backoff,
        serde_json::json!({ "install": false, "hold": { "reason": "backoff", "secondsLeft": 40.0 } })
    );
    let request: IdleFacts = serde_json::from_value(serde_json::json!({
        "enabled": true, "idleMinutes": 15, "inputIdleSeconds": 901.5, "unsentDrafts": 0
    }))
    .unwrap();
    assert!(decide(&request).install);
}

/// Away is host_presence.py's: a locked screen is away at once, whatever the idle time says.
#[test]
fn a_locked_screen_is_away_at_once() {
    for idle_s in [Some(0.0), Some(5.0), None, Some(f64::NAN)] {
        let facts =
            IdleFacts { input_idle_seconds: idle_s, screen_locked: Some(true), ..idle(0.0) };
        let decision = decide(&facts);
        assert!(decision.install, "{facts:?}");
        assert_eq!(decision.away, Some(Away::ScreenLocked));
    }
}

/// An unlocked or unread screen leaves it to the idle time; no reading of either is never away.
#[test]
fn an_unlocked_or_unread_screen_needs_the_idle_time() {
    for locked in [Some(false), None] {
        let recent = IdleFacts { screen_locked: locked, ..idle(1.0) };
        assert!(matches!(decide(&recent).hold, Some(Hold::NotIdle { .. })), "{recent:?}");
        let unread = IdleFacts { input_idle_seconds: None, screen_locked: locked, ..idle(0.0) };
        assert_eq!(decide(&unread).hold, Some(Hold::Unknown), "{unread:?}");
    }
}

/// The away reading by itself: host_presence.py's verdict table.
#[test]
fn the_away_reading() {
    assert_eq!(away(Some(600.0), Some(false), 600.0), Ok(Away::Idle { seconds: 600.0 }));
    assert_eq!(away(Some(599.0), Some(false), 600.0), Err(Some(1.0)));
    assert_eq!(away(Some(10.0), Some(true), 600.0), Ok(Away::ScreenLocked));
    assert_eq!(away(None, Some(true), 600.0), Ok(Away::ScreenLocked));
    assert_eq!(away(None, Some(false), 600.0), Err(None));
    assert_eq!(away(None, None, 600.0), Err(None));
    assert_eq!(away(Some(-1.0), None, 600.0), Err(None));
}

/// Locked still waits for an unsent draft, and for unknown drafts.
#[test]
fn locked_still_waits_for_drafts() {
    let locked = |f: IdleFacts| IdleFacts { screen_locked: Some(true), ..f };
    assert_eq!(
        decide(&locked(IdleFacts { unsent_drafts: Some(1), ..idle(0.0) })).hold,
        Some(Hold::UnsentDraft)
    );
    assert_eq!(
        decide(&locked(IdleFacts { unsent_drafts: None, ..idle(0.0) })).hold,
        Some(Hold::Unknown)
    );
}

/// The backoff after a declined install doubles from a minute and stops at an hour.
#[test]
fn the_retry_backoff_doubles_and_caps() {
    assert_eq!(retry_after_seconds(0), 0.0);
    assert_eq!(retry_after_seconds(1), 60.0);
    assert_eq!(retry_after_seconds(2), 120.0);
    assert_eq!(retry_after_seconds(3), 240.0);
    assert_eq!(retry_after_seconds(6), 1920.0);
    assert_eq!(retry_after_seconds(7), 3600.0);
    assert_eq!(retry_after_seconds(u32::MAX), 3600.0);
}

/// A declined install holds the next try for the backoff, then lets it go; an unread time waits it all.
#[test]
fn a_declined_install_backs_off() {
    let declined = |n: u32, since: Option<f64>| IdleFacts {
        declined_installs: n,
        seconds_since_decline: since,
        ..idle(20.0)
    };
    assert_eq!(decide(&declined(2, Some(30.0))).hold, Some(Hold::Backoff { seconds_left: 90.0 }));
    assert!(decide(&declined(2, Some(120.0))).install);
    assert_eq!(decide(&declined(1, None)).hold, Some(Hold::Backoff { seconds_left: 60.0 }));
    // At the Mac, it says so first: the backoff is only news once the person is away.
    let at_mac = IdleFacts { input_idle_seconds: Some(0.0), ..declined(3, Some(0.0)) };
    assert!(matches!(decide(&at_mac).hold, Some(Hold::NotIdle { .. })));
}

/// The next check: the last plus the interval, now when it is due or there was none, none when off.
#[test]
fn the_next_check_time() {
    assert_eq!(next_check_in(Some(600.0), 3600.0), Some(3000.0));
    assert_eq!(next_check_in(Some(7200.0), 3600.0), Some(0.0));
    assert_eq!(next_check_in(None, 3600.0), Some(0.0));
    assert_eq!(next_check_in(Some(f64::NAN), 3600.0), Some(0.0));
    assert_eq!(next_check_in(Some(10.0), 0.0), None);
    assert_eq!(next_check_in(Some(10.0), f64::INFINITY), None);
}
