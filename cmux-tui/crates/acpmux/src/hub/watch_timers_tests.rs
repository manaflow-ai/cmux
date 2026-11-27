use super::*;
use std::collections::BTreeSet;

fn timer(id: &str, due: u64, every: Option<u64>, end: Option<u64>) -> Watch {
    Watch {
        id: id.into(),
        to: "sink".into(),
        once: every.is_none(),
        active: true,
        due_ms: Some(due),
        every_ms: every,
        end_ms: end,
        prompt: Some(format!("wake {id}")),
        ..Default::default()
    }
}

#[test]
fn next_due_keeps_phase_on_time_and_stops_at_the_end() {
    // One-shot: done after its fire.
    assert_eq!(next_due(1_000, None, None, 1_000), None);
    // On time (or early within slack): the next period, phase kept.
    assert_eq!(next_due(1_000, Some(500), None, 1_000), Some(1_500));
    assert_eq!(next_due(1_000, Some(500), None, 400), Some(1_500));
    assert_eq!(next_due(1_000, Some(500), None, 1_499), Some(1_500));
    // Past the end: done.
    assert_eq!(next_due(1_000, Some(500), Some(1_400), 1_000), None);
    assert_eq!(next_due(1_000, Some(500), Some(1_500), 1_000), Some(1_500));
    // No overflow at the far end of time.
    assert_eq!(next_due(u64::MAX - 1, Some(500), None, u64::MAX - 1), Some(u64::MAX));
}

/// The host slept through 90 periods: the watch fires once, then reschedules from now, not 90
/// catch-up fires.
#[test]
fn a_missed_every_fires_once_and_reschedules_from_now() {
    let watches = Watches::default();
    watches.insert(timer("w", 1_000, Some(100), None)).unwrap();
    let (fired, earliest) = watches.fire_timers(10_000).unwrap();
    assert_eq!(fired, vec![prompt_id("w", 1_000)]);
    assert_eq!(earliest, Some(10_100));
    let (again, _) = watches.fire_timers(10_099).unwrap();
    assert!(again.is_empty(), "fired again in the same instant: {again:?}");
    let pending = watches.inner.lock().unwrap().saved.pending.clone();
    assert_eq!(pending.len(), 1);
}

/// Watches due within `SLACK_MS` of the earliest share one wake, at the last of them (slack
/// makes a timer later, never earlier); one past it waits for its own.
#[test]
fn timers_within_slack_coalesce_into_one_wake() {
    let watches = Watches::default();
    for (id, due) in [("a", 5_000), ("b", 5_400), ("c", 6_000), ("d", 6_001)] {
        watches.insert(timer(id, due, None, None)).unwrap();
    }
    let (none, wake) = watches.fire_timers(4_999).unwrap();
    assert!(none.is_empty(), "fired early: {none:?}");
    assert_eq!(wake, Some(6_000), "one wake for a, b and c");
    let (fired, earliest) = watches.fire_timers(6_000).unwrap();
    assert_eq!(fired, vec![prompt_id("a", 5_000), prompt_id("b", 5_400), prompt_id("c", 6_000)]);
    assert_eq!(earliest, Some(6_001));
    let q = queue(watches.inner.lock().unwrap().saved.watches.values());
    assert_eq!(q.keys().copied().collect::<Vec<_>>(), vec![6_001], "fired one-shots disarm");
}

/// Each fire's prompt id is the watch and its due time: the same on every retry and restart,
/// distinct per fire, and it is the key the wake is owed (and sent) under.
#[test]
fn prompt_ids_are_stable_per_fire_and_distinct_across_fires() {
    assert_eq!(prompt_id("w", 1_000), prompt_id("w", 1_000));
    assert_ne!(prompt_id("w", 1_000), prompt_id("w", 1_100));
    let watches = Watches::default();
    watches.insert(timer("w", 1_000, Some(100), None)).unwrap();
    watches.fire_timers(1_000).unwrap();
    watches.fire_timers(1_100).unwrap();
    let pending = watches.inner.lock().unwrap().saved.pending.clone();
    assert_eq!(
        pending.keys().cloned().collect::<BTreeSet<_>>(),
        BTreeSet::from([prompt_id("w", 1_000), prompt_id("w", 1_100)])
    );
    for (id, d) in &pending {
        assert_eq!(d.prompt_id(), id, "the outbox and the recipient's ledger key on it");
        assert_eq!(d.target, "sink");
    }
    let last = &pending[&prompt_id("w", 1_100)];
    assert_eq!(last.request.pointer("/_meta/acpmux/watchDone"), Some(&json!(false)));
}

/// The daemon restarts between arming and firing, and again after firing: the fire happens once,
/// with the same prompt id, and the next due time survives.
#[test]
fn a_restart_between_arm_and_fire_fires_exactly_once() {
    let dir = cmux_unix_socket::short_test_dir("watch-timer-restart");
    let path = dir.path().join("watches.json");
    let armed = Watches::default();
    armed.open(&path);
    armed.insert(timer("once", 2_000, None, None)).unwrap();
    armed.insert(timer("tick", 2_000, Some(5_000), Some(11_000))).unwrap();
    drop(armed);

    // Restart before it is due, then it falls due while the daemon is down.
    let after_arm = Watches::default();
    after_arm.open(&path);
    let (fired, earliest) = after_arm.fire_timers(2_200).unwrap();
    assert_eq!(fired, vec![prompt_id("once", 2_000), prompt_id("tick", 2_000)]);
    assert_eq!(earliest, Some(7_000));
    drop(after_arm);

    // Restart after the fire was saved: the wake is still owed, nothing fires twice.
    let after_fire = Watches::default();
    after_fire.open(&path);
    let (again, earliest) = after_fire.fire_timers(2_200).unwrap();
    assert!(again.is_empty(), "fired again after a restart: {again:?}");
    assert_eq!(earliest, Some(7_000));
    {
        let inner = after_fire.inner.lock().unwrap();
        assert_eq!(inner.saved.pending.len(), 2);
        let once = &inner.saved.watches["once"];
        assert!(!once.active && once.due_ms.is_none(), "a fired one-shot stays disarmed");
        let done = &inner.saved.pending[&prompt_id("once", 2_000)];
        assert_eq!(done.request.pointer("/_meta/acpmux/watchDone"), Some(&json!(true)));
    }
    // The last tick inside --until ends the watch.
    let (last, earliest) = after_fire.fire_timers(7_000).unwrap();
    assert_eq!(last, vec![prompt_id("tick", 7_000)]);
    assert_eq!(earliest, None, "12000 is past the end (11000)");
}

/// A watches file from a daemon before time watches opens, and a time watch's file keeps its
/// fields across a save.
#[test]
fn time_fields_are_optional_on_disk() {
    let old = json!({"id": "w", "to": "sink", "sessions": ["a"], "until": ["ready"],
        "matchText": null, "once": true, "caller": null, "active": true,
        "cursors": {}, "offline": []});
    let w: Watch = serde_json::from_value(old).unwrap();
    assert!(w.due_ms.is_none() && w.prompt.is_none());
    let saved = serde_json::to_value(&w).unwrap();
    assert!(saved.get("dueMs").is_none(), "a state watch writes no time fields: {saved}");
    let t = serde_json::to_value(timer("t", 9, Some(10), None)).unwrap();
    assert_eq!((t["dueMs"].clone(), t["everyMs"].clone()), (json!(9), json!(10)));
}

#[test]
fn a_fired_wake_is_no_inbox_item_so_it_wakes_an_idle_chat() {
    // The inbox files a message with no class as an FYI, and an FYI never wakes an idle chat:
    // a time watch's wake waited for the chat's next turn, up to an hour late.
    let w = Watch { caller: Some("sink".into()), ..timer("t", 1_000, None, None) };
    let d = delivery(&w, prompt_id("t", 1_000), "wake t".into(), true);
    assert!(crate::hub::inbox::watch_wake(&d.request));
    let plain = json!({"sessionId": "sink", "prompt": [], "_meta": {"acpmux": {"promptId": "p"}}});
    assert!(!crate::hub::inbox::watch_wake(&plain));
}

/// A fired one-shot stops waking its chat: the fire names the chat for the timer task to
/// recount its background waits (`background_waits.rs`), once; a fire that keeps the watch
/// live names none.
#[test]
fn a_fired_one_shot_names_its_chat_for_a_recount() {
    let watches = Watches::default();
    watches.insert(timer("once", 1_000, None, None)).unwrap();
    watches.insert(timer("tick", 1_000, Some(100), None)).unwrap();
    assert!(watches.take_recount().is_empty());
    watches.fire_timers(1_000).unwrap();
    assert_eq!(watches.take_recount(), BTreeSet::from(["sink".to_owned()]));
    assert!(watches.take_recount().is_empty(), "taken once");
    watches.fire_timers(1_100).unwrap();
    assert!(watches.take_recount().is_empty(), "the tick stays live: no change");
}
