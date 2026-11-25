use super::{State, Timing, Verdict};
use std::time::{Duration, Instant};

fn timing() -> Timing {
    Timing::from_delays(&[10_000, 60_000, 300_000, 1_200_000])
}

#[test]
fn timing_follows_the_configured_waits() {
    let t = timing();
    assert_eq!(t.probe_base, Duration::from_secs(10));
    // The last wait is 20 min, the capacity cap 5.
    assert_eq!(t.probe_max, Duration::from_secs(300));
    assert_eq!(t.ramp_step, Duration::from_secs(5));
    let scaled = Timing::from_delays(&[200, 1_200, 6_000]);
    assert_eq!(scaled.probe_base, Duration::from_millis(200));
    assert_eq!(scaled.probe_max, Duration::from_millis(6_000));
    assert_eq!(scaled.ramp_step, Duration::from_millis(100));
    assert_eq!(t.backoff(1), Duration::from_secs(10));
    assert_eq!(t.backoff(3), Duration::from_secs(40));
    assert_eq!(t.backoff(30), Duration::from_secs(300));
}

#[test]
fn no_outage_lets_everyone_go() {
    let (mut s, t, now) = (State::default(), timing(), Instant::now());
    for i in 0..50 {
        assert_eq!(s.decide(&format!("c{i}"), now, &t), Verdict::Go(None));
    }
}

#[test]
fn an_outage_sends_one_probe_at_a_time() {
    let (mut s, t, now) = (State::default(), timing(), Instant::now());
    s.cut("a", now, &t);
    s.cut("b", now, &t);
    assert!(s.in_outage());
    let Verdict::Go(Some(n)) = s.decide("a", now, &t) else { panic!("a probes") };
    for other in ["b", "c", "d"] {
        assert_eq!(s.decide(other, now, &t), Verdict::Hold(None), "{other} holds");
    }
    // The probe is cut again: the next waits one back-off, then two.
    s.cut("a", now, &t);
    assert!(!s.probe_done(n), "the cut already took the slot");
    let at = now + Duration::from_secs(10);
    assert_eq!(s.decide("b", now, &t), Verdict::Hold(Some(at)));
    let Verdict::Go(Some(_)) = s.decide("b", at, &t) else { panic!("b probes") };
    s.cut("b", at, &t);
    assert_eq!(s.decide("c", at, &t), Verdict::Hold(Some(at + Duration::from_secs(20))));
}

#[test]
fn a_probe_that_never_reached_the_model_frees_the_slot() {
    let (mut s, t, now) = (State::default(), timing(), Instant::now());
    s.cut("a", now, &t);
    let Verdict::Go(Some(n)) = s.decide("a", now, &t) else { panic!("a probes") };
    assert_eq!(s.decide("b", now, &t), Verdict::Hold(None));
    assert!(s.probe_done(n));
    assert!(matches!(s.decide("b", now, &t), Verdict::Go(Some(_))), "b probes at once");
}

#[test]
fn recovery_releases_a_doubling_stream() {
    let (mut s, t, now) = (State::default(), timing(), Instant::now());
    s.cut("a", now, &t);
    let Verdict::Go(Some(n)) = s.decide("a", now, &t) else { panic!("a probes") };
    assert!(s.answered(now));
    assert!(!s.answered(now), "only the first answer ends it");
    assert!(!s.probe_done(n));
    // Step 0: one; step 1: two more; step 2: four more.
    let step = t.ramp_step;
    let mut released = Vec::new();
    for k in 0..4u32 {
        let at = now + step * k;
        let mut n = 0;
        while s.decide(&format!("w{k}-{n}"), at, &t) == Verdict::Go(None) {
            n += 1;
        }
        released.push(n);
    }
    assert_eq!(released, [1, 2, 4, 8]);
    // Fully open after its last step.
    let open = now + step * super::OPEN_AFTER_STEPS;
    for i in 0..2_000 {
        assert_eq!(s.decide(&format!("x{i}"), open, &t), Verdict::Go(None));
    }
}

#[test]
fn a_cut_during_recovery_holds_the_rest_again() {
    let (mut s, t, now) = (State::default(), timing(), Instant::now());
    s.cut("a", now, &t);
    let _ = s.decide("a", now, &t);
    s.answered(now);
    assert_eq!(s.decide("b", now, &t), Verdict::Go(None));
    s.cut("b", now, &t);
    assert!(s.in_outage());
    assert!(matches!(s.decide("c", now, &t), Verdict::Go(Some(_))), "c probes");
    assert_eq!(s.decide("d", now, &t), Verdict::Hold(None));
}

#[test]
fn a_hundred_waiters_spend_a_handful_of_attempts_on_a_dead_pool() {
    // 100 chats cut together; the pool stays out 10 min. Each waiter asks every 5 min at most
    // (the capacity cap) on its own; through the gate the host probes on back-off only.
    let (mut s, t, start) = (State::default(), timing(), Instant::now());
    for i in 0..100 {
        s.cut(&format!("c{i}"), start, &t);
    }
    let mut attempts = 0;
    let mut ms = 0u64;
    while ms <= 600_000 {
        let now = start + Duration::from_millis(ms);
        for i in 0..100 {
            let id = format!("c{i}");
            if let Verdict::Go(_) = s.decide(&id, now, &t) {
                attempts += 1;
                s.cut(&id, now, &t);
            }
        }
        ms += 1_000;
    }
    // 10, 20, 40, 80, 160, 300, 300 s ... after the first: about 7 in 10 min, not 200+.
    assert!(attempts <= 8, "{attempts} attempts");
}
