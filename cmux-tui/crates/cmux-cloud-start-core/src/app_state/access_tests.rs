//! The access asks' and revokes' bookkeeping, case by case as `CloudAccessAsks` and
//! `CloudAccessRevokes` run it (the app had no unit tests of these rules).

use super::*;

fn chat(machine: &str, session: &str) -> Chat {
    Chat { machine_id: machine.into(), session: session.into() }
}

#[test]
fn a_revoke_runs_once_per_chat_until_it_answers_ok() {
    let mut revokes = Revokes::default();
    assert!(revokes.is_empty());
    revokes.add(chat("m2", "s1"));
    revokes.add(chat("m1", "s2"));
    revokes.add(chat("m1", "s1"));
    assert_eq!(
        revokes.due(0),
        [chat("m1", "s1"), chat("m1", "s2"), chat("m2", "s1")],
        "by machine, then session"
    );
    revokes.run_started(chat("m1", "s1"));
    assert!(!revokes.may_run(&chat("m1", "s1"), 0), "another run took it");
    revokes.run_ended(chat("m1", "s1"), true, 0, REVOKE_FIRST_BACKOFF_MS);
    assert!(revokes.done.contains(&chat("m1", "s1")));
    revokes.add(chat("m1", "s1"));
    assert!(!revokes.pending.contains(&chat("m1", "s1")), "revoked in this run: not again");
}

#[test]
fn a_failing_revoke_waits_twice_as_long_each_time_up_to_five_minutes() {
    let mut revokes = Revokes::default();
    let chat = chat("m", "s");
    revokes.add(chat.clone());
    let mut now = 0;
    let mut delays = vec![];
    for _ in 0..10 {
        assert!(revokes.may_run(&chat, now));
        revokes.run_started(chat.clone());
        revokes.run_ended(chat.clone(), false, now, 3_000);
        let wait = revokes.backoff[0].backoff;
        assert!(!revokes.may_run(&chat, now + wait.delay_ms - 1));
        delays.push(wait.delay_ms);
        now += wait.delay_ms;
    }
    assert_eq!(
        delays,
        [3_000, 6_000, 12_000, 24_000, 48_000, 96_000, 192_000, 300_000, 300_000, 300_000]
    );
    revokes.run_ended(chat, true, now, 3_000);
    assert!(revokes.backoff.is_empty() && revokes.is_empty());
}

#[test]
fn a_chat_with_an_answer_running_waits_and_a_late_answer_revokes_again() {
    let mut revokes = Revokes::default();
    let chat = chat("m", "s");
    revokes.add(chat.clone());
    revokes.answer_started(chat.clone());
    revokes.answer_started(chat.clone());
    assert!(revokes.due(0).is_empty());
    revokes.answer_ended(chat.clone(), true);
    assert!(revokes.due(0).is_empty(), "one answer still runs");
    revokes.answer_ended(chat.clone(), true);
    assert_eq!(revokes.due(0), std::slice::from_ref(&chat));
    revokes.run_started(chat.clone());
    revokes.run_ended(chat.clone(), true, 0, 3_000);
    assert!(revokes.is_empty());
    // An answer that ends after its chat left the machine: what it granted is revoked again,
    // with no wait left from an earlier failure.
    revokes.answer_started(chat.clone());
    revokes.answer_ended(chat.clone(), false);
    assert!(!revokes.done.contains(&chat));
    assert_eq!(revokes.due(0), [chat]);
}

#[test]
fn a_poll_stops_only_with_no_moved_chat_and_nothing_to_revoke() {
    assert_eq!(poll(false, 3, false, false, 3_000), Poll::Stop, "no CLI");
    assert_eq!(poll(true, 0, false, true, 3_000), Poll::Stop);
    assert_eq!(
        poll(true, 0, false, false, 3_000),
        Poll::Clear { wait_ms: 3_000 },
        "a revoke still waits"
    );
    assert_eq!(
        poll(true, 2, true, true, 3_000),
        Poll::Clear { wait_ms: 3_000 },
        "Cloud turned off: the cards go"
    );
    assert_eq!(poll(true, 2, false, true, 3_000), Poll::Triage);
}

#[test]
fn a_failing_machine_keeps_its_cards_and_is_asked_less_often() {
    let mut asks = Asks::default();
    assert_eq!(asks.machine("m", 0, 60_000), Machine::Triage { sync: true });
    assert_eq!(
        asks.machine("m", 1_000, 60_000),
        Machine::Triage { sync: false },
        "synced a second ago"
    );
    assert_eq!(asks.triage_failed("m", Some("x"), 1_000, 3_000), 6_000);
    assert_eq!(asks.machine("m", 6_999, 60_000), Machine::Keep);
    assert_eq!(asks.machine("m", 7_000, 60_000), Machine::Triage { sync: false });
    let mut delays = vec![];
    for _ in 0..6 {
        delays.push(asks.triage_failed("m", None, 7_000, 3_000));
    }
    assert_eq!(delays, [12_000, 24_000, 48_000, 96_000, 120_000, 120_000]);
    asks.triage_ok("m");
    assert_eq!(asks.machine("m", 7_000, 60_000), Machine::Triage { sync: false });
    assert_eq!(asks.machine("m", 60_000, 60_000), Machine::Triage { sync: true });
}

#[test]
fn a_machine_without_access_requests_waits_ten_minutes() {
    let mut asks = Asks::default();
    assert_eq!(
        asks.triage_failed("old", Some(UNAVAILABLE_CODE), 0, 3_000),
        TRIAGE_UNAVAILABLE_BACKOFF_MS
    );
    assert_eq!(asks.machine("old", 599_999, 1), Machine::Keep);
}

fn listing(pairs: &[(&str, &[&str])]) -> BTreeMap<String, Vec<String>> {
    pairs
        .iter()
        .map(|(tab, ids)| ((*tab).to_owned(), ids.iter().map(|id| (*id).to_owned()).collect()))
        .collect()
}

#[test]
fn an_answered_request_shows_no_more_in_a_triage_that_began_before_it_ended() {
    let mut asks = Asks::default();
    let early = asks.begin_triage();
    asks.answer_started("r1".into());
    assert_eq!(
        asks.listed(early, listing(&[("t", &["r1", "r2"])])),
        listing(&[("t", &["r2"])]),
        "answering"
    );
    asks.answer_ended("r1");
    assert_eq!(asks.answered.get("r1"), Some(&1));
    assert_eq!(
        asks.listed(early, listing(&[("t", &["r1"])])),
        listing(&[]),
        "a tab left with none drops out"
    );
    assert!(asks.answered.contains_key("r1"), "kept for triages that began by then");
    let later = asks.begin_triage();
    assert_eq!(
        asks.listed(later, listing(&[("t", &["r1"])])),
        listing(&[("t", &["r1"])]),
        "still waiting: shown again"
    );
    assert!(asks.answered.is_empty());
}

#[test]
fn old_answers_are_forgotten_once_a_later_triage_ran() {
    let mut asks = Asks::default();
    asks.answer_started("r1".into());
    asks.answer_ended("r1");
    let first = asks.begin_triage();
    asks.listed(first, listing(&[]));
    assert!(asks.answered.is_empty(), "answered before this triage began, and not listed");
}

#[test]
fn a_failed_answer_shows_unless_its_request_changed_or_went() {
    assert!(!answer_failure_shows(true, None));
    assert!(answer_failure_shows(false, None));
    assert!(answer_failure_shows(false, Some("denied")));
    assert!(!answer_failure_shows(false, Some("request_changed")));
    assert!(!answer_failure_shows(false, Some("request_gone")));
}

#[test]
fn a_tab_shows_its_live_asks_then_one_failure_at_most_four() {
    let mut asks = Asks::default();
    asks.answer_started("r2".into());
    let listed = |ids: &[(&str, bool)]| -> Vec<Listed> {
        ids.iter().map(|(id, live)| Listed { id: (*id).into(), live: *live }).collect()
    };
    let failures = vec!["f1".to_owned(), "f2".to_owned()];
    assert_eq!(
        cards(&asks, &listed(&[("r1", true), ("r2", true), ("r3", false)]), &failures),
        ["r1", "f1"]
    );
    let many = listed(&[("a", true), ("b", true), ("c", true), ("d", true), ("e", true)]);
    assert_eq!(
        cards(&asks, &many, &failures),
        ["a", "b", "c", "d"],
        "a failure never pushes an ask past the cap"
    );
    assert!(cards(&asks, &[], &[]).is_empty());
}
