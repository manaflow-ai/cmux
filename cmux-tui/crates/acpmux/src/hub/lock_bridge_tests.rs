use super::*;

fn base() -> Inputs {
    Inputs {
        on: true,
        lock: Lock::Locked,
        running: 1,
        waiting: 0,
        since_running: Duration::ZERO,
        locked_for: Duration::from_secs(60),
    }
}

#[test]
fn an_idle_worker_reports_no_hold_and_no_stretch() {
    let idle = idle_state(Lock::Locked, true);
    assert_eq!(idle, json!({"lock": "locked", "on": true, "holding": false}));
    assert!(idle.get("lockedForS").is_none(), "no stretch is counted while idle: {idle}");
}

#[test]
fn holds_only_while_locked_with_a_running_turn_and_the_toggle_on() {
    assert!(holds(base()));
    assert!(!holds(Inputs { on: false, ..base() }), "off by default: the toggle decides");
    for lock in [Lock::Unlocked, Lock::Unknown, Lock::None] {
        assert!(!holds(Inputs { lock, ..base() }), "{lock:?}: only a locked screen holds");
    }
    assert!(!holds(Inputs { running: 0, ..base() }), "no turn: nothing to keep running");
}

#[test]
fn a_waiting_turn_holds_only_for_the_grace_after_the_last_running_one() {
    let waiting = Inputs { running: 0, waiting: 1, ..base() };
    assert!(holds(Inputs { since_running: Duration::from_secs(60), ..waiting }));
    assert!(
        !holds(Inputs { since_running: WAIT_GRACE, ..waiting }),
        "never indefinitely for a person"
    );
}

#[test]
fn one_locked_stretch_is_held_at_most_the_cap() {
    assert!(holds(Inputs { locked_for: CAP - Duration::from_secs(1), ..base() }));
    assert!(
        !holds(Inputs { locked_for: CAP, ..base() }),
        "a turn that never ends cannot keep the Mac up"
    );
}

/// One locked stretch, however many turns run in it (review of cmux#37239): a turn that ends
/// and another that starts while the screen stays locked do not open a new window, nor does
/// a lock read that fails. Only an unlock ends the stretch.
#[test]
fn turns_one_after_another_share_one_locked_stretch() {
    let t0 = Instant::now();
    let at = |minutes: u64| t0 + Duration::from_secs(minutes * 60);
    let mut tracker = Tracker::new(t0, Lock::Unlocked);
    assert!(holds(tracker.step(true, Lock::Locked, 1, 0, t0).unwrap()));
    assert_eq!(tracker.step(true, Lock::Locked, 0, 0, at(30)), None, "the turn ended: idle");
    let next = tracker.step(true, Lock::Locked, 1, 0, at(31)).unwrap();
    assert_eq!(next.locked_for, Duration::from_secs(31 * 60), "the same stretch: {next:?}");
    assert!(tracker.step(true, Lock::Unknown, 1, 0, at(60)).is_some());
    let late = tracker.step(true, Lock::Locked, 1, 0, at(120)).unwrap();
    assert!(!holds(late), "turn after turn cannot keep a locked Mac up past the cap: {late:?}");
    assert!(tracker.step(true, Lock::Unlocked, 1, 0, at(121)).is_some());
    let relocked = tracker.step(true, Lock::Locked, 1, 0, at(122)).unwrap();
    assert!(holds(relocked), "an unlock ends the stretch: {relocked:?}");
}

/// A daemon that restarts during a locked stretch (review of cmux#37239) does not open a
/// fresh window: it cannot know when the stretch began, so it holds nothing until it reads
/// an unlock. Restart after restart cannot keep a locked Mac up past the cap.
#[test]
fn a_daemon_that_starts_while_locked_holds_nothing_until_an_unlock() {
    let t0 = Instant::now();
    let at = |minutes: u64| t0 + Duration::from_secs(minutes * 60);
    for first in [Lock::Locked, Lock::Unknown] {
        let mut tracker = Tracker::new(t0, first);
        let locked = tracker.step(true, Lock::Locked, 1, 0, t0).unwrap();
        assert!(!holds(locked), "started {first:?}: no fresh window: {locked:?}");
        assert!(tracker.step(true, Lock::Unknown, 1, 0, at(1)).is_some());
        let still = tracker.step(true, Lock::Locked, 1, 0, at(2)).unwrap();
        assert!(!holds(still), "an unknown read is not an unlock: {still:?}");
        assert!(tracker.step(true, Lock::Unlocked, 1, 0, at(3)).is_some());
        let relocked = tracker.step(true, Lock::Locked, 1, 0, at(4)).unwrap();
        assert!(holds(relocked), "an unlock starts a stretch: {relocked:?}");
        assert_eq!(relocked.locked_for, Duration::from_secs(60), "from the unlocked read");
    }
    let mut unlocked_start = Tracker::new(t0, Lock::Unlocked);
    assert!(holds(unlocked_start.step(true, Lock::Locked, 1, 0, t0).unwrap()));
}

/// A Mac that locks while nothing runs (review of cmux#37239 at 1a1ebad0, F2): the worker
/// does not read while idle, so the stretch counts from its last unlocked read, and a turn
/// that starts hours into the stretch opens no fresh window.
#[test]
fn a_lock_that_began_while_idle_counts_from_the_last_unlocked_read() {
    let t0 = Instant::now();
    let at = |minutes: u64| t0 + Duration::from_secs(minutes * 60);
    let mut tracker = Tracker::new(t0, Lock::Unlocked);
    assert!(tracker.step(true, Lock::Unlocked, 1, 0, t0).is_some());
    assert_eq!(tracker.step(true, Lock::Unlocked, 0, 0, at(1)), None, "idle");
    let late = tracker.step(true, Lock::Locked, 1, 0, at(180)).unwrap();
    assert!(late.locked_for >= CAP, "the stretch began by the last unlocked read: {late:?}");
    assert!(!holds(late), "no fresh window after an idle lock: {late:?}");
    let soon = Tracker::new(t0, Lock::Unlocked).step(true, Lock::Locked, 1, 0, at(5)).unwrap();
    assert!(holds(soon), "a turn soon after the last unlocked read still holds: {soon:?}");
}

/// A daemon that starts with a waiting session restored (review of cmux#37239 at 1a1ebad0,
/// F3) has not seen a turn run, so the waiting turn gets no fresh [`WAIT_GRACE`].
#[test]
fn a_waiting_session_the_daemon_never_saw_run_gets_no_grace() {
    let t0 = Instant::now();
    let mut tracker = Tracker::new(t0, Lock::Unlocked);
    let restored = tracker.step(true, Lock::Locked, 0, 1, t0).unwrap();
    assert!(!holds(restored), "no running turn seen: no grace: {restored:?}");
    assert!(holds(tracker.step(true, Lock::Locked, 1, 0, t0).unwrap()));
    let after = tracker.step(true, Lock::Locked, 0, 1, t0 + Duration::from_secs(60)).unwrap();
    assert!(holds(after), "the grace runs from a turn it saw: {after:?}");
}

#[test]
fn the_setting_is_on_only_when_set_true_and_keep_awake_is_not_off() {
    let none = ManagedPreferences::default();
    let on = |doc: &Value| setting_on(Some(doc), &none);
    assert!(!setting_on(None, &none), "an unreadable file is off");
    assert!(!on(&json!({})), "off by default");
    assert!(!on(&json!({"sessions": {"keepAwakeWhenLocked": "yes"}})));
    assert!(on(&json!({"sessions": {"keepAwakeWhenLocked": true}})));
    assert!(on(&json!({"sessions.keepAwakeWhenLocked": true})), "the flat form too");
    let off = json!({"sessions": {"keepAwakeWhenLocked": true, "keepAwake": "off"}});
    assert!(!on(&off), "Keep Mac Awake off turns the bridge off too");
    let always = json!({"sessions": {"keepAwakeWhenLocked": true, "keepAwake": "always"}});
    assert!(on(&always));
}

/// An administrator's value (review of cmux#37239): a forced one wins over the settings
/// file, as it does for every other setting, and a recommended one only replaces the default.
#[test]
fn a_managed_value_wins_over_the_file_and_a_recommended_one_only_over_the_default() {
    let managed = |forced: Value, recommended: Value| ManagedPreferences {
        forced: serde_json::from_value(forced).unwrap(),
        recommended: serde_json::from_value(recommended).unwrap(),
    };
    let file_on = json!({"sessions": {"keepAwakeWhenLocked": true}});
    let forced_off = managed(json!({SETTING: false}), json!({}));
    assert!(!setting_on(Some(&file_on), &forced_off), "a forced off wins over the file");
    let forced_on = managed(json!({SETTING: true}), json!({}));
    assert!(setting_on(Some(&json!({})), &forced_on), "a forced on needs no file value");
    assert!(setting_on(None, &forced_on), "nor a readable file");
    let file_off = json!({"sessions": {"keepAwakeWhenLocked": false}});
    assert!(setting_on(Some(&file_off), &forced_on), "a forced on wins over the file");
    let keep_awake_off = managed(json!({"sessions.keepAwake": "off"}), json!({}));
    assert!(!setting_on(Some(&file_on), &keep_awake_off), "a forced Keep Mac Awake off");
    let recommended_on = managed(json!({}), json!({SETTING: true}));
    assert!(setting_on(Some(&json!({})), &recommended_on), "recommended replaces the default");
    assert!(!setting_on(Some(&file_off), &recommended_on), "the person's own off wins");
}

/// The worker reads again when the hold is due to end (review of cmux#37239), not up to a
/// [`TICK`] later: a hold never outlives its [`CAP`] or its [`WAIT_GRACE`].
#[test]
fn the_next_read_comes_no_later_than_the_hold_is_due_to_end() {
    assert_eq!(next_wait(base()), TICK, "far from both bounds: one tick");
    let near_cap = Inputs { locked_for: CAP - Duration::from_secs(3), ..base() };
    assert_eq!(next_wait(near_cap), Duration::from_secs(3));
    let waiting = Inputs {
        running: 0,
        waiting: 1,
        since_running: WAIT_GRACE - Duration::from_secs(2),
        ..base()
    };
    assert_eq!(next_wait(waiting), Duration::from_secs(2));
    let running = Inputs { since_running: WAIT_GRACE - Duration::from_secs(2), ..base() };
    assert_eq!(next_wait(running), TICK, "a running turn has no grace to end");
    assert_eq!(next_wait(Inputs { on: false, ..near_cap }), TICK, "no hold: one tick");
}
