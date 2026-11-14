use super::*;

#[test]
fn a_sleep_is_the_wall_clock_running_ahead_of_the_monotonic_one() {
    let start = tokio::time::Instant::now();
    let mut watch = SleepWatch::new(1_000_000, start);
    // Awake: both clocks moved 5 s.
    assert_eq!(watch.check_at(1_005_000, start + Duration::from_secs(5)), None);
    // Scheduling noise under the slack is no sleep.
    assert_eq!(watch.check_at(1_015_000, start + Duration::from_secs(9)), None);
    // Asleep for 10 minutes: the wall clock moved 10 min 5 s, the monotonic one 5 s.
    let slept = watch.check_at(1_620_000, start + Duration::from_secs(14));
    assert_eq!(slept, Some(Duration::from_secs(600)));
    // The watch counts from the wake on.
    assert_eq!(watch.check_at(1_625_000, start + Duration::from_secs(19)), None);
}

#[test]
fn an_unforced_reconnect_keeps_a_ready_link_and_a_young_handshake() {
    let young = Duration::from_secs(30);
    let mut link = Link::default();
    assert!(!link.keeps_on_reconnect(1_000, young), "a link that never opened is replaced");
    link.opened(1_000);
    assert!(link.keeps_on_reconnect(20_000, young), "a handshake 19 s old is left to finish");
    assert!(!link.keeps_on_reconnect(40_000, young), "a handshake 39 s old may never finish");
    link.ready(40_000);
    link.overdue();
    assert!(link.keeps_on_reconnect(500_000, young), "a ready link slow to answer is kept");
    link.down(600_000, STABLE);
    assert!(!link.keeps_on_reconnect(600_001, young), "a link that is down is replaced");
}

#[test]
fn a_wall_clock_set_back_is_no_sleep() {
    let start = tokio::time::Instant::now();
    let mut watch = SleepWatch::new(2_000_000, start);
    assert_eq!(watch.check_at(1_000_000, start + Duration::from_secs(5)), None);
    assert_eq!(watch.check_at(1_005_000, start + Duration::from_secs(10)), None);
}

#[test]
fn a_write_during_a_wake_probe_gives_up_at_the_probes_deadline() {
    let now = std::time::Instant::now();
    let budget = Duration::from_secs(80);
    assert_eq!(write_deadline(now, budget, None), now + budget);
    let probe = now + WAKE_PROBE;
    assert_eq!(write_deadline(now, budget, Some(probe)), probe);
    // A probe further off than the budget leaves the budget.
    assert_eq!(
        write_deadline(now, Duration::from_secs(5), Some(probe)),
        now + Duration::from_secs(5)
    );
}

const STABLE: Duration = Duration::from_secs(60);

#[test]
fn a_link_goes_connected_then_reconnecting_then_connected() {
    let mut link = Link::default();
    assert_eq!(link.state(), PeerState::Connecting);
    link.opened(1_000);
    assert_eq!(link.state(), PeerState::Degraded, "handshaking");
    link.ready(2_000);
    assert_eq!(link.state(), PeerState::Connected);
    link.overdue();
    assert_eq!(link.state(), PeerState::Degraded, "a ping went unanswered");
    link.heard(3_000);
    assert_eq!(link.state(), PeerState::Connected);
    assert!(!link.down(10_000, STABLE), "ready 8s: not stable");
    assert_eq!(link.state(), PeerState::Reconnecting);
    assert_eq!((link.last_seen, link.down_since, link.attempts), (Some(3_000), Some(10_000), 1));
    link.down(40_000, STABLE);
    assert_eq!(link.state(), PeerState::Reconnecting, "attempts go on");
    assert_eq!((link.down_since, link.attempts), (Some(10_000), 2), "down since the first");
    link.opened(50_000);
    link.ready(51_000);
    assert_eq!(link.state(), PeerState::Connected);
    assert_eq!((link.down_since, link.attempts), (None, 0));
    assert!(link.down(51_000 + 61_000, STABLE), "ready 61s: stable");
}

#[test]
fn a_peer_never_reached_is_offline_and_a_saved_one_is_reconnecting() {
    let mut link = Link::default();
    link.down(1_000, STABLE);
    assert_eq!(link.state(), PeerState::Offline);
    let mut saved = Link::default();
    saved.seed(Some(500));
    assert_eq!(saved.state(), PeerState::Reconnecting);
    saved.down(1_000, STABLE);
    assert_eq!(saved.state(), PeerState::Reconnecting);
    saved.seed(Some(1));
    assert_eq!(saved.last_seen, Some(500), "a seed never overrides what this run saw");
}

#[test]
fn retry_parking_survives_cache_seed_and_ends_at_a_successful_handshake() {
    let mut link = Link::default();
    let mut backoff = Backoff::default();
    let day = 86_400_000;
    link.seed(Some(1_000));
    assert!(link.retry_delay(&mut backoff, 1_000 + day, 0.0) <= Backoff::CAP);
    link.seed_outage(Some(1_000));
    assert!(link.retry_delay(&mut backoff, 1_000 + day - 1, 0.0) <= Backoff::CAP);
    assert_eq!(link.retry_delay(&mut backoff, 1_000 + day, 0.0), Duration::from_secs(3_600));
    assert_eq!(link.retry_delay(&mut backoff, 1_000 + day, 1.0), Duration::from_secs(3_660));
    link.opened(day + 2_000);
    link.down(day + 2_001, STABLE);
    assert!(link.retry_delay(&mut backoff, day + 2_001, 0.0) >= Duration::from_secs(3_600));
    link.opened(day + 3_000);
    link.ready(day + 3_001);
    link.down(day + 3_002, STABLE);
    assert!(link.retry_delay(&mut backoff, day + 3_002, 0.0) <= Backoff::CAP);
}

#[test]
fn parked_schedule_retains_only_the_remaining_wait_and_recovery_clears_it() {
    let now = 86_400_001;
    let mut link = Link::default();
    link.seed_outage(Some(0));
    let delay = link.schedule_retry(&mut Backoff::default(), now, 0.0);
    assert_eq!(delay, Duration::from_secs(3_600));
    assert_eq!(link.parked_retry_wait(now + 120_000), Some(Duration::from_secs(3_480)));
    assert_eq!(link.parked_retry_wait(now + 3_600_000), None);
    assert_eq!(
        link.parked_retry_wait(0),
        Some(Duration::from_secs(3_660)),
        "clock correction is bounded"
    );
    link.opened(now + 2_000);
    link.ready(now + 2_001);
    assert_eq!(link.next_retry_at, None);
    assert_eq!(link.parked_retry_wait(now + 2_001), None);
}

#[test]
fn backoff_doubles_within_jittered_bounds_up_to_the_cap() {
    let mut low = Backoff::default();
    let mut high = Backoff::default();
    let mut step = Backoff::BASE;
    for _ in 0..12 {
        let (lo, hi) = (low.next(0.0), high.next(0.999_999));
        assert_eq!(lo, step / 2);
        assert!(hi <= step && hi > step.mul_f64(0.99), "{hi:?} for {step:?}");
        step = (step * 2).min(Backoff::CAP);
    }
    assert_eq!(low.next(0.0), Backoff::CAP / 2, "capped, never zero");
    assert!(high.next(1.0) <= Backoff::CAP);
    low.reset();
    assert_eq!(low.next(0.0), Backoff::BASE / 2);
    let j = jitter();
    assert!((0.0..1.0).contains(&j));
}

#[test]
fn a_wanted_peer_retries_within_seconds_however_long_the_backoff_grew() {
    // The schedule a failed handshake starts: 0.25-0.5 s, 0.5-1 s, 1-2 s, 2-4 s, ...
    let mut backoff = Backoff::default();
    let steps: Vec<_> = (0..4).map(|_| backoff.next(0.999_999)).collect();
    for (step, cap) in steps.iter().zip([500, 1_000, 2_000, 4_000]) {
        assert!(*step <= Duration::from_millis(cap), "{steps:?}");
    }
    assert_eq!(Backoff::wanted(Duration::from_millis(300), 0.0), Duration::from_millis(300));
    for _ in 0..12 {
        let delay = backoff.next(0.999_999);
        let wanted = Backoff::wanted(delay, 0.999_999);
        assert!(wanted <= Backoff::WANTED_CAP && wanted <= delay, "{wanted:?} for {delay:?}");
    }
    assert_eq!(Backoff::wanted(Backoff::CAP, 0.0), Backoff::WANTED_CAP / 2, "never zero");
    let parked = Duration::from_secs(3_600);
    assert!(Backoff::wanted(parked, 1.0) <= Backoff::WANTED_CAP, "a parked peer too");
}

#[test]
fn the_unreachable_error_names_the_state_age_and_last_error() {
    let mut link = Link::default();
    link.opened(0);
    link.ready(0);
    link.down(1_000, STABLE);
    let e = unreachable_error("huge-blue", &link, Some("connect timed out"), 40_000);
    assert!(e.message.contains("huge-blue (reconnecting, last seen 40s ago: connect timed out)"));
    assert!(e.message.contains("acpmux machine ls"));
    let data = e.data.unwrap();
    assert_eq!(data["reason"], "peer_unreachable");
    assert_eq!(data["retryable"], true);
    assert_eq!(data["try"], "acpmux machine ls");
    assert_eq!(data["peerState"], "reconnecting");
    assert_eq!(data["lastSeen"], 0);
    let never = describe("gone", &Link::default(), None, 5);
    assert_eq!(never, "gone (connecting, never reached)");
}

#[test]
fn host_ls_labels_old_and_new_daemons() {
    assert_eq!(state_label(&json!({"connected": true}), 0), "connected");
    assert_eq!(state_label(&json!({"connected": false}), 0), "offline");
    let down = json!({"connected": false, "state": "reconnecting", "lastSeen": 1_000});
    assert_eq!(state_label(&down, 181_000), "reconnecting (seen 3m ago)");
    assert_eq!(ago(59_000), "59s");
    assert_eq!(ago(3 * 3_600_000), "3h");
}

#[tokio::test(start_paused = true)]
async fn a_late_answering_peer_gets_more_silence_and_gives_it_back_once_calm() {
    let t = LinkTimings::default();
    let mut budget = SilenceBudget::new(&t);
    let start = tokio::time::Instant::now();
    let secs = Duration::from_secs;
    assert_eq!(budget.current(), secs(6));
    budget.answered_after(secs(2), start);
    assert_eq!(budget.current(), secs(6), "an answer within half the budget changes nothing");
    budget.answered_after(secs(5), start);
    assert_eq!(budget.current(), secs(10), "twice the late gap");
    budget.dropped(start);
    budget.opened(start + t.connect + secs(1));
    assert_eq!(budget.current(), secs(10), "a peer gone for longer than a connect was gone");
    budget.dropped(start);
    budget.opened(start + secs(1));
    assert_eq!(budget.current(), secs(20), "one that opens straight back was slow: doubled");
    budget.opened(start + secs(2));
    assert_eq!(budget.current(), secs(20), "once per drop");
    for _ in 0..4 {
        budget.dropped(start);
        budget.opened(start);
    }
    assert_eq!(budget.current(), SilenceBudget::CAP, "never past the old 80 s");
    // Calm: answers 3 s apart, then a step down each `stable_after`, to the start.
    budget.answered_after(secs(3), start);
    budget.settle(start + t.stable_after - secs(1));
    assert_eq!(budget.current(), SilenceBudget::CAP, "not calm for long enough yet");
    let mut at = start + t.stable_after;
    budget.settle(at);
    assert_eq!(budget.current(), secs(40));
    for want in [20, 10, 6, 6] {
        at += t.stable_after;
        budget.settle(at);
        assert_eq!(budget.current(), secs(want));
    }
    // A step down never goes under twice the longest gap meanwhile.
    budget.answered_after(secs(9), at);
    assert_eq!(budget.current(), secs(18));
    budget.answered_after(secs(8), at);
    budget.settle(at + t.stable_after);
    assert_eq!(budget.current(), secs(16));
}

#[test]
fn a_set_ping_interval_keeps_the_silence_budget_fixed() {
    let t = LinkTimings {
        ping_every: Duration::from_secs(5),
        fixed_silence: true,
        ..LinkTimings::default()
    };
    let mut budget = SilenceBudget::new(&t);
    let now = tokio::time::Instant::now();
    budget.answered_after(Duration::from_secs(14), now);
    budget.dropped(now);
    budget.opened(now);
    assert_eq!(budget.current(), Duration::from_secs(15));
    let slow = LinkTimings { ping_every: Duration::from_secs(40), ..LinkTimings::default() };
    assert_eq!(SilenceBudget::new(&slow).current(), Duration::from_secs(120), "over the cap");
}

#[test]
fn env_sets_the_connect_handshake_and_ping_deadlines() {
    let t = LinkTimings::default();
    assert_eq!(t.silence_budget(), Duration::from_secs(6));
    assert_eq!(t.send, Duration::from_secs(80));
    assert!(t.connect >= Duration::from_secs(30) && t.handshake >= t.connect);
}
