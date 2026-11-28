use super::*;
use std::collections::{HashMap, HashSet};

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

fn done(id: &str, outcome: PromptOutcome, text: &str) -> PromptDone {
    PromptDone {
        id: id.into(),
        outcome,
        text: text.into(),
        attachments: vec![],
        cancel_uploads: vec![],
    }
}

/// The old fixed hold, which the older tests' times are written for.
const TEN: Duration = Duration::from_secs(10);

fn outbox_30s() -> PromptOutbox {
    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 7);
    outbox.set_link(true, Instant::now());
    outbox
}

fn outbox() -> PromptOutbox {
    let mut outbox = PromptOutbox::new(TEN, 7);
    outbox.set_link(true, Instant::now());
    outbox
}

#[test]
fn every_attempt_carries_the_same_id_and_a_written_one_goes_again_as_a_resend() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    assert!(outbox.push("p1", "hi", vec![], false, t0, t0));
    let first = outbox.next_request(t0).unwrap();
    assert_eq!(
        first,
        PromptRequest { id: "p1".into(), resend: false, attempt: 1, attachments: vec![] }
    );
    outbox.wrote("p1");
    outbox.lost("p1", t0 + ms(100));
    outbox.set_link(false, Instant::now());
    outbox.set_link(true, Instant::now());
    let second = outbox.next_request(t0 + ms(100)).unwrap();
    assert_eq!(
        second,
        PromptRequest { id: "p1".into(), resend: true, attempt: 2, attachments: vec![] }
    );
    outbox.wrote("p1");
    assert_eq!(outbox.answered("p1"), Some(done("p1", PromptOutcome::Sent, "hi")));
    assert!(outbox.is_empty());
}

#[test]
fn a_write_that_failed_is_not_a_resend() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("p1", "hi", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    outbox.write_failed("p1", t0);
    let again = outbox.next_request(t0 + RETRY_CAP).unwrap();
    assert!(!again.resend, "nothing was written: acpmux has nothing to check");
    assert_eq!(again.attempt, 2);
}

#[test]
fn a_prompt_sent_again_by_the_person_keeps_its_resend_flag() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("p1", "hi", vec![], true, t0, t0);
    assert!(outbox.next_request(t0).unwrap().resend);
}

#[test]
fn a_second_push_of_the_same_id_is_not_a_second_send() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    assert!(outbox.push("p1", "hi", vec![], false, t0, t0));
    assert!(!outbox.push("p1", "hi", vec![], false, t0, t0));
    assert_eq!(outbox.len(), 1);
    outbox.next_request(t0).unwrap();
    outbox.wrote("p1");
    assert!(!outbox.push("p1", "hi", vec![], false, t0, t0), "written and unanswered: still here");
    assert_eq!(outbox.next_request(t0), None);
}

#[test]
fn one_write_at_a_time_in_tap_order() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.push("b", "b", vec![], false, t0 + ms(1), t0 + ms(1));
    assert_eq!(outbox.next_request(t0).unwrap().id, "a");
    assert_eq!(outbox.next_request(t0), None, "b waits for a's write");
    outbox.wrote("a");
    assert_eq!(outbox.next_request(t0).unwrap().id, "b", "a's answer is not waited for");
}

#[test]
fn a_later_prompt_never_goes_before_an_earlier_unsent_one() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.push("b", "b", vec![], false, t0 + ms(1), t0 + ms(1));
    outbox.next_request(t0).unwrap();
    outbox.write_failed("a", t0);
    // a is backing off: b does not jump ahead.
    assert_eq!(outbox.next_request(t0 + ms(1)), None);
    let next = outbox.next_request(t0 + RETRY_CAP).unwrap();
    assert_eq!(next.id, "a");
}

#[test]
fn a_lost_earlier_prompt_goes_again_before_any_later_unwritten_one() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    for (i, id) in ["a", "b", "c"].iter().enumerate() {
        outbox.push(*id, *id, vec![], false, t0 + ms(i as u64), t0 + ms(i as u64));
    }
    outbox.next_request(t0).unwrap();
    outbox.wrote("a");
    outbox.next_request(t0).unwrap();
    outbox.wrote("b");
    // The link drops: a's and b's answers are lost; c was never written.
    outbox.set_link(false, Instant::now());
    outbox.lost("a", t0 + ms(10));
    outbox.lost("b", t0 + ms(10));
    assert_eq!(outbox.unwritten(), vec!["a", "b", "c"]);
    outbox.set_link(true, Instant::now());
    let order: Vec<(String, bool)> = std::iter::from_fn(|| {
        let r = outbox.next_request(t0 + ms(20))?;
        outbox.wrote(&r.id);
        Some((r.id, r.resend))
    })
    .collect();
    assert_eq!(
        order,
        vec![("a".into(), true), ("b".into(), true), ("c".into(), false)],
        "in tap order; only the written ones are resends"
    );
}

#[test]
fn offline_prompts_queue_and_go_in_order_once_the_link_is_back() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(TEN, 1);
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.push("b", "b", vec![], false, t0 + ms(5), t0 + ms(5));
    assert_eq!(outbox.next_request(t0 + ms(10)), None, "link down: queued");
    assert_eq!(outbox.unwritten(), vec!["a", "b"]);
    outbox.set_link(true, Instant::now());
    assert_eq!(outbox.next_request(t0 + ms(10)).unwrap().id, "a");
    outbox.wrote("a");
    assert_eq!(outbox.next_request(t0 + ms(10)).unwrap().id, "b");
}

#[test]
fn a_link_that_comes_back_skips_the_backoff() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    outbox.write_failed("a", t0);
    assert_eq!(outbox.next_request(t0 + ms(1)), None);
    outbox.set_link(false, Instant::now());
    outbox.set_link(true, Instant::now());
    assert_eq!(outbox.next_request(t0 + ms(1)).unwrap().id, "a");
}

#[test]
fn backoff_doubles_with_jitter_and_stays_under_the_cap() {
    for unit in [0.0, 0.25, 0.5, 0.999, 1.0, f64::NAN, -3.0, 9.0] {
        for attempt in 0..40 {
            let d = retry_delay(attempt, unit);
            let full = RETRY_FIRST
                .saturating_mul(1u32 << attempt.saturating_sub(1).min(16))
                .min(RETRY_CAP);
            assert!(d >= full / 2 && d <= full, "attempt {attempt} unit {unit}: {d:?} vs {full:?}");
            assert!(d <= RETRY_CAP);
        }
    }
    assert_eq!(retry_delay(1, 1.0), RETRY_FIRST);
    assert_eq!(retry_delay(1, 0.0), RETRY_FIRST / 2);
    assert_eq!(retry_delay(2, 1.0), RETRY_FIRST * 2);
    assert_eq!(retry_delay(30, 1.0), RETRY_CAP);
}

#[test]
fn the_outbox_waits_out_its_jittered_backoff() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", vec![], false, t0, t0);
    let mut now = t0;
    for failures in 1..=6u32 {
        outbox.next_request(now).unwrap();
        outbox.write_failed("a", now);
        let wait = outbox.next_wake(now).unwrap();
        let full = RETRY_FIRST.saturating_mul(1 << (failures - 1)).min(RETRY_CAP);
        assert!(wait >= full / 2 && wait <= full, "failure {failures}: {wait:?}");
        assert_eq!(outbox.next_request(now + wait - ms(1)), None, "not before the wait");
        now += wait;
        // keep it within the hold for this test
        outbox.set_hold(Duration::from_secs(3600));
    }
}

#[test]
fn the_jitter_spreads_two_outboxes_apart() {
    let a: Vec<_> = (0..8).map(|_| retry_delay(3, PromptOutbox::new(TEN, 1).next_unit())).collect();
    let mut x = PromptOutbox::new(TEN, 1);
    let mut y = PromptOutbox::new(TEN, 2);
    let xs: Vec<f64> = (0..8).map(|_| x.next_unit()).collect();
    let ys: Vec<f64> = (0..8).map(|_| y.next_unit()).collect();
    assert_ne!(xs, ys);
    assert!(xs.iter().chain(&ys).all(|u| (0.0..1.0).contains(u)));
    assert!(a.windows(2).all(|w| w[0] == w[1]), "a seed is deterministic");
}

#[test]
fn past_the_hold_every_unwritten_prompt_comes_back_in_order() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(ms(10_000), 3);
    outbox.push("a", "first", vec![], false, t0, t0);
    outbox.push("b", "second", vec![], false, t0 + ms(4_000), t0 + ms(4_000));
    assert!(outbox.expire(t0 + ms(9_999)).is_empty());
    assert_eq!(outbox.next_wake(t0 + ms(9_000)), Some(ms(1_000)));
    assert_eq!(
        outbox.expire(t0 + ms(10_000)),
        vec![
            done("a", PromptOutcome::NotSent, "first"),
            done("b", PromptOutcome::NotSent, "second"),
        ],
        "b is younger, but never goes after a that did not"
    );
    assert!(outbox.is_empty());
    outbox.set_link(true, Instant::now());
    assert_eq!(outbox.next_request(t0 + ms(10_001)), None, "nothing goes behind the person's back");
}

#[test]
fn a_prompt_past_the_hold_is_never_written_even_before_expire_runs() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(ms(10_000), 3);
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.set_link(true, Instant::now());
    assert_eq!(outbox.next_request(t0 + ms(10_000)), None);
}

#[test]
fn a_written_prompt_whose_answer_was_lost_gives_up_as_maybe_sent() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "deploy", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    outbox.wrote("a");
    outbox.set_link(false, Instant::now());
    outbox.lost("a", t0 + ms(30_000));
    assert!(outbox.expire(t0 + ms(39_999)).is_empty(), "its wait starts at the drop, not the tap");
    assert_eq!(outbox.expire(t0 + ms(40_000)), vec![done("a", PromptOutcome::MaybeSent, "deploy")]);
}

#[test]
fn written_prompts_wait_for_their_answers_past_the_hold() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "long turn", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    outbox.wrote("a");
    assert!(outbox.expire(t0 + Duration::from_secs(600)).is_empty());
    assert_eq!(outbox.look("a", t0 + Duration::from_secs(600)), PromptLook::Sent);
    assert_eq!(outbox.answered("a").unwrap().outcome, PromptOutcome::Sent);
}

#[test]
fn a_completed_upload_gets_a_write_window_even_after_the_original_hold() {
    let tapped = Instant::now();
    let prepared = tapped + Duration::from_secs(90);
    let hold = Duration::from_secs(30);
    let mut outbox = PromptOutbox::new(hold, 1);
    outbox.set_link(true, tapped);
    assert!(outbox.push_prepared("first", "uploaded", false, tapped, prepared));
    assert!(outbox.expire(prepared).is_empty());
    assert_eq!(outbox.next_request(prepared).unwrap().id, "first");

    // A duplicate handoff cannot extend a second prompt that then stalls.
    assert!(outbox.push_prepared("second", "waiting", false, tapped + ms(1), prepared));
    assert!(!outbox.push_prepared(
        "second",
        "duplicate",
        false,
        tapped + ms(1),
        prepared + ms(29_999)
    ));
    assert!(outbox.expire(prepared + ms(29_999)).is_empty());
    assert_eq!(
        outbox.expire(prepared + hold),
        vec![done("second", PromptOutcome::NotSent, "waiting")]
    );
}

#[test]
fn a_prompt_sent_while_the_link_is_up_waits_from_its_tap_until_a_write_fails_and_a_held_one_from_its_hold()
 {
    let t0 = Instant::now();
    let mut outbox = outbox();
    // An upload took 3 s: tapped at t0, pushed at t0+3s, link up and nothing ahead: from the tap
    // (a prompt never written is aged by its tap) ...
    outbox.push("a", "a", vec![], false, t0, t0 + ms(3_000));
    assert_eq!(outbox.expire(t0 + ms(10_000)).len(), 1);

    // ... but once a write fails, from the failure, never the tap (#52384).
    let mut outbox = self::outbox();
    outbox.push("a", "a", vec![], false, t0, t0 + ms(3_000));
    outbox.next_request(t0 + ms(3_000)).unwrap();
    outbox.write_failed("a", t0 + ms(3_000));
    assert!(outbox.expire(t0 + ms(12_999)).is_empty());
    assert_eq!(outbox.expire(t0 + ms(13_000)).len(), 1);

    let mut outbox = PromptOutbox::new(TEN, 1);
    // Link down at the push: from the push.
    outbox.push("b", "b", vec![], false, t0, t0 + ms(3_000));
    assert!(outbox.expire(t0 + ms(12_999)).is_empty());
    assert_eq!(outbox.expire(t0 + ms(13_000)).len(), 1);
}

// HeldPromptSlowWriteTests (a): a write that took longer than the hold and then failed is held
// from its failure, not bounced as unreachable.
#[test]
fn a_write_longer_than_the_hold_that_fails_is_held_from_its_failure() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    // The write ran 25 s (a big attachment on a slow link) and failed.
    let failed = t0 + Duration::from_secs(25);
    outbox.write_failed("a", failed);
    assert!(outbox.expire(failed).is_empty(), "not bounced the moment it failed");
    assert!(outbox.expire(failed + ms(9_999)).is_empty());
    // The link comes back within the hold: it goes, nothing was given back.
    outbox.set_link(false, failed + ms(1_000));
    outbox.set_link(true, failed + ms(2_000));
    assert_eq!(outbox.next_request(failed + ms(2_000)).unwrap().id, "a");
}

// HeldPromptSlowWriteTests (b): writes that keep timing out on a ready link say nothing within
// the hold; a hold with no write getting through gives the draft back.
#[test]
fn writes_that_time_out_again_and_again_come_back_once_a_whole_hold_passes_without_a_write() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", vec![], false, t0, t0);
    let mut now = t0;
    for _ in 0..3 {
        outbox.next_request(now).unwrap();
        now += Duration::from_secs(25);
        outbox.write_failed("a", now);
        assert!(outbox.expire(now).is_empty(), "a slow failed write is not an outage");
        now += ms(2_000);
    }
    // A whole hold with no write under way: it comes back.
    let given = outbox.expire(now + TEN);
    assert_eq!(given.len(), 1);
    assert_eq!(given[0].id, "a");
}

// HeldPromptSlowWriteTests (b2): a write that fails at once on a link that still says ready,
// again and again, is aged from the first failure and moved on only by what each write took
// (nothing): its wait is never restarted, so the hold runs out.
#[test]
fn a_write_that_fails_at_once_again_and_again_still_runs_out_its_hold() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", vec![], false, t0, t0 + ms(5_000));
    let mut now = t0 + ms(5_000);
    let mut given = Vec::new();
    for _ in 0..40 {
        if let Some(request) = outbox.next_request(now) {
            assert_eq!(request.id, "a");
            outbox.write_failed("a", now);
        }
        given = outbox.expire(now);
        if !given.is_empty() {
            break;
        }
        now += ms(1_000);
    }
    assert_eq!(given.len(), 1, "the hold ran out");
    // Aged from the first failure (t0+5s), not the tap (t0), and not restarted by later failures.
    assert!(now >= t0 + ms(15_000) && now <= t0 + ms(16_000), "gave back at {:?}", now - t0);
}

// ... and a write's time is added to the wait, not counted from the failure again.
#[test]
fn a_later_failed_write_moves_the_wait_on_by_what_it_took() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    outbox.write_failed("a", t0); // first failure: waits from t0
    let again = t0 + RETRY_CAP;
    outbox.next_request(again).unwrap();
    // This write took 4 s: the wait moves on by those 4 s (to t0+4s), not to the failure
    // (t0+12s): the time between the writes still counts against the hold.
    outbox.write_failed("a", again + ms(4_000));
    assert!(outbox.expire(again + ms(4_000) + ms(1_999)).is_empty());
    assert_eq!(outbox.expire(t0 + ms(4_000) + TEN).len(), 1);
}

#[test]
fn a_refusal_gives_the_text_back_and_lets_the_next_go() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.push("b", "b", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    assert_eq!(outbox.refused("a"), Some(done("a", PromptOutcome::Refused, "a")));
    assert_eq!(outbox.look("a", t0), PromptLook::Failed);
    assert_eq!(outbox.next_request(t0).unwrap().id, "b");
}

#[test]
fn looks_sent_from_the_tap_retrying_after_a_quiet_threshold_failed_when_given_up() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(TEN, 1);
    outbox.push("a", "a", vec![], false, t0, t0);
    assert_eq!(outbox.look("a", t0), PromptLook::Sent, "sent from the tap on");
    assert_eq!(outbox.look("a", t0 + RETRYING_AFTER - ms(1)), PromptLook::Sent);
    assert_eq!(outbox.next_look_change(t0), Some(RETRYING_AFTER));
    assert_eq!(outbox.look("a", t0 + RETRYING_AFTER), PromptLook::Retrying);
    outbox.expire(t0 + TEN);
    assert_eq!(outbox.look("a", t0 + TEN), PromptLook::Failed);
    outbox.forget("a");
    assert_eq!(outbox.look("a", t0 + TEN), PromptLook::Sent);
    assert_eq!(outbox.look("never-here", t0), PromptLook::Sent);

    // Pushed again by the person: no longer failed.
    outbox.push("b", "b", vec![], false, t0, t0);
    outbox.expire(t0 + TEN);
    assert_eq!(outbox.look("b", t0 + TEN), PromptLook::Failed);
    outbox.push("b", "b", vec![], true, t0 + TEN, t0 + TEN);
    assert_eq!(outbox.look("b", t0 + TEN), PromptLook::Sent);
}

#[test]
fn the_failed_memory_is_bounded() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(TEN, 1);
    for i in 0..(FAILED_MEMORY + 10) {
        outbox.push(format!("p{i}"), "x", vec![], false, t0, t0);
    }
    outbox.expire(t0 + TEN);
    assert_eq!(outbox.failed.len(), FAILED_MEMORY);
    assert_eq!(outbox.look("p0", t0), PromptLook::Sent, "the oldest is forgotten");
    assert_eq!(outbox.look(&format!("p{}", FAILED_MEMORY + 9), t0), PromptLook::Failed);
}

#[test]
fn giving_up_from_one_prompt_takes_every_unwritten_one_after_it() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(TEN, 1);
    for id in ["a", "b", "c"] {
        outbox.push(id, id, vec![], false, t0, t0);
    }
    let done: Vec<String> = outbox.give_up_from("b").into_iter().map(|d| d.id).collect();
    assert_eq!(done, vec!["b", "c"]);
    assert_eq!(outbox.unwritten(), vec!["a"]);
    assert!(outbox.give_up_from("zzz").is_empty());
}

#[test]
fn draining_hands_the_unwritten_prompts_over_with_their_taps() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(TEN, 1);
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.push("b", "b", vec![], false, t0 + ms(5), t0 + ms(5));
    assert_eq!(outbox.drain_unwritten(), vec![("a".into(), t0), ("b".into(), t0 + ms(5))]);
    assert!(outbox.is_empty());
    // A next outbox (link down) that takes them over ages them from their taps.
    let mut next = PromptOutbox::new(TEN, 1);
    next.push("a", "a", vec![], false, t0, t0);
    assert_eq!(next.expire(t0 + TEN).len(), 1);
}

#[test]
fn prompts_are_placed_by_their_tap() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(TEN, 1);
    outbox.push("late", "late", vec![], false, t0 + ms(10), t0 + ms(10));
    outbox.push("early", "early", vec![], false, t0, t0 + ms(10));
    assert_eq!(outbox.unwritten(), vec!["early", "late"]);
}

#[test]
fn an_answer_for_a_prompt_queued_again_still_settles_it() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    outbox.wrote("a");
    outbox.lost("a", t0);
    assert_eq!(outbox.answered("a").unwrap().outcome, PromptOutcome::Sent);
    assert_eq!(outbox.next_request(t0 + RETRY_CAP), None);
    assert_eq!(outbox.answered("a"), None);
}

// ---- A lossy link, seeded -------------------------------------------------------------------

/// A seeded generator for the fake link (independent of the outbox's jitter).
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    fn chance(&mut self, percent: u64) -> bool {
        self.next() % 100 < percent
    }
}

/// acpmux as the phone sees it: a `promptId` runs once (`{duplicate:true}` after), a `resend`
/// checks the log. It counts what would have been a double send without that dedupe: a second
/// delivery of an id that was not marked a resend.
#[derive(Default)]
struct FakeMac {
    ran: Vec<String>,
    ran_set: HashSet<String>,
    deliveries: HashMap<String, u32>,
    double_without_dedupe: u32,
}

impl FakeMac {
    fn deliver(&mut self, request: &PromptRequest) {
        let seen = self.deliveries.entry(request.id.clone()).or_default();
        *seen += 1;
        if *seen > 1 && !request.resend {
            self.double_without_dedupe += 1;
        }
        if self.ran_set.insert(request.id.clone()) {
            self.ran.push(request.id.clone());
        }
    }
}

struct Run {
    sent: Vec<String>,
    not_sent: Vec<String>,
    maybe_sent: Vec<String>,
    /// Cancelled by the person (back at once, or taken off the Mac's queue) or upload failed:
    /// nothing ran.
    took_back: Vec<String>,
    mac: FakeMac,
    attempts: HashMap<String, Vec<PromptRequest>>,
}

/// What the person and the files do in a run, besides tapping Send.
#[derive(Clone, Copy)]
struct Mix {
    /// Percent of sends with an attachment to upload first.
    attach: u64,
    /// Percent chance, per step, that the person cancels one pending send.
    cancel: u64,
}

const TEXT_ONLY: Mix = Mix { attach: 0, cancel: 0 };

/// `sends` prompts tapped through a link that drops (down for a while), fails writes and
/// uploads, and loses answers, at the given seed. The hold is long enough or short, per `hold`.
fn lossy_run(seed: u64, sends: usize, hold: Duration) -> Run {
    lossy_run_with(seed, sends, hold, TEXT_ONLY)
}

fn lossy_run_with(seed: u64, sends: usize, hold: Duration, mix: Mix) -> Run {
    let mut rng = Rng(seed);
    let t0 = Instant::now();
    let mut now = t0;
    let mut outbox = PromptOutbox::new(hold, seed ^ 0xA5A5);
    outbox.set_link(true, now);
    let mut mac = FakeMac::default();
    // Written prompts whose answer is on its way: (id, steps left).
    let mut answers: Vec<(String, u32)> = Vec::new();
    // Uploads under way in the uploader (started at pick time, retried by it): (id, steps left).
    let mut uploads: Vec<(String, u32)> = Vec::new();
    // `_acpmux/queue_remove` calls on their way: (id, steps left).
    let mut removes: Vec<(String, u32)> = Vec::new();
    let mut cancelled: HashSet<String> = HashSet::new();
    let mut ended: HashMap<String, PromptDone> = HashMap::new();
    let mut attempts: HashMap<String, Vec<PromptRequest>> = HashMap::new();
    let mut tapped = 0usize;
    let mut down_steps = 0u32;
    // Every end names its unfinished uploads; the driver cancels them.
    let end = |ended: &mut HashMap<String, PromptDone>,
               uploads: &mut Vec<(String, u32)>,
               done: PromptDone| {
        for id in &done.cancel_uploads {
            uploads.retain(|(u, _)| u != id);
        }
        assert!(ended.insert(done.id.clone(), done).is_none(), "ended twice");
    };
    for _step in 0..400_000 {
        if tapped == sends && outbox.is_empty() {
            break;
        }
        now += ms(1 + rng.next() % 150);
        // The link drops now and then, for up to ~6 s.
        if down_steps == 0 && rng.chance(3) {
            down_steps = 1 + (rng.next() % 60) as u32;
            outbox.set_link(false, now);
            // Every answer in flight is lost with the channel.
            for (id, _) in answers.drain(..) {
                outbox.lost(&id, now);
            }
        } else if down_steps > 0 {
            down_steps -= 1;
            if down_steps == 0 {
                outbox.set_link(true, now);
            }
        }
        if tapped < sends && rng.chance(35) {
            let id = format!("p{tapped}");
            let files = if rng.chance(mix.attach) { vec![format!("f{tapped}")] } else { vec![] };
            for file in &files {
                uploads.push((file.clone(), (rng.next() % 40) as u32));
            }
            assert!(outbox.push(id.clone(), format!("text {tapped}"), files, false, now, now));
            tapped += 1;
        }
        // The person cancels a send not ended yet, at any point.
        if tapped > 0 && rng.chance(mix.cancel) {
            let id = format!("p{}", rng.next() % tapped as u64);
            if !ended.contains_key(&id) && cancelled.insert(id.clone()) {
                match outbox.cancel(&id) {
                    Some(CancelStep::Returned(done)) => {
                        assert!(
                            !mac.deliveries.contains_key(&id),
                            "{id} came back but was written"
                        );
                        end(&mut ended, &mut uploads, done);
                    }
                    Some(CancelStep::RemoveOnMac { id }) => {
                        removes.push((id, (rng.next() % 10) as u32));
                    }
                    None => {}
                }
            }
        }
        for done in outbox.expire(now) {
            end(&mut ended, &mut uploads, done);
        }
        // The uploader moves while the link is up; it gives up on one now and then.
        let mut finished = Vec::new();
        let mut still = Vec::new();
        for (file, left) in uploads.drain(..) {
            if down_steps > 0 {
                still.push((file, left));
            } else if left > 0 {
                still.push((file, left - 1));
            } else {
                finished.push(file);
            }
        }
        uploads = still;
        for file in finished {
            if rng.chance(5) {
                if let Some(done) = outbox.upload_failed(&file, "io") {
                    end(&mut ended, &mut uploads, done);
                }
            } else {
                outbox.uploaded(&file, format!("/mac/{file}"), now);
            }
        }
        while let Some(request) = outbox.next_request(now) {
            assert!(!cancelled.contains(&request.id), "{} sent after its cancel", request.id);
            let index: usize = request.id[1..].parse().unwrap();
            let files: Vec<&str> = request.attachments.iter().map(|(_, p)| p.as_str()).collect();
            if !files.is_empty() {
                assert_eq!(files, vec![format!("/mac/f{index}")], "it goes with its upload");
            }
            attempts.entry(request.id.clone()).or_default().push(request.clone());
            match rng.next() % 100 {
                // The write fails before it reaches the Mac.
                0..=9 => outbox.write_failed(&request.id, now),
                // Written; the Mac gets it; the answer comes later (or is lost on a drop).
                _ => {
                    mac.deliver(&request);
                    outbox.wrote(&request.id);
                    answers.push((request.id.clone(), (rng.next() % 30) as u32));
                }
            }
        }
        // Answers arrive; some are lost alone (a reply timeout) without the link dropping.
        let mut still = Vec::new();
        for (id, left) in answers.drain(..) {
            if left == 0 {
                if rng.chance(8) {
                    outbox.lost(&id, now);
                } else if let Some(done) = outbox.answered(&id) {
                    end(&mut ended, &mut uploads, done);
                }
            } else {
                still.push((id, left - 1));
            }
        }
        answers = still;
        // The Mac answers a removal: it takes off its queue only what it never got.
        let mut still = Vec::new();
        for (id, left) in removes.drain(..) {
            if left > 0 {
                still.push((id, left - 1));
            } else if let Some(done) =
                outbox.remove_answered(&id, !mac.deliveries.contains_key(&id))
            {
                end(&mut ended, &mut uploads, done);
            }
        }
        removes = still;
    }
    assert_eq!(tapped, sends, "the run tapped every send");
    assert!(uploads.is_empty(), "no upload left running for a send that ended: {uploads:?}");
    assert!(outbox.is_empty(), "every send ended");
    let mut run = Run {
        sent: vec![],
        not_sent: vec![],
        maybe_sent: vec![],
        took_back: vec![],
        mac,
        attempts,
    };
    for i in 0..sends {
        let id = format!("p{i}");
        let done = ended.remove(&id).unwrap_or_else(|| panic!("{id} never ended: lost"));
        assert_eq!(done.text, format!("text {i}"), "its text comes back");
        match done.outcome {
            PromptOutcome::Sent => run.sent.push(id),
            PromptOutcome::NotSent => run.not_sent.push(id),
            PromptOutcome::MaybeSent => run.maybe_sent.push(id),
            PromptOutcome::Cancelled | PromptOutcome::UploadFailed { .. } => run.took_back.push(id),
            PromptOutcome::Refused => unreachable!("the fake Mac refuses nothing"),
        }
    }
    run
}

fn check(run: &Run, sends: usize) {
    // No double send: every attempt after one was delivered is a resend.
    assert_eq!(run.mac.double_without_dedupe, 0, "a second non-resend delivery");
    for attempts in run.attempts.values() {
        let numbers: Vec<u32> = attempts.iter().map(|r| r.attempt).collect();
        assert_eq!(numbers, (1..=attempts.len() as u32).collect::<Vec<_>>());
    }
    // No lost send: each ended Sent (and the Mac ran it), NotSent (the Mac never got it), or
    // MaybeSent (it was written), with its text.
    assert_eq!(
        run.sent.len() + run.not_sent.len() + run.maybe_sent.len() + run.took_back.len(),
        sends
    );
    for id in &run.took_back {
        assert!(!run.mac.ran_set.contains(id), "{id} came back but the Mac ran it");
    }
    for id in &run.sent {
        assert!(run.mac.ran_set.contains(id), "{id} said sent but the Mac never ran it");
    }
    for id in &run.not_sent {
        assert!(!run.mac.ran_set.contains(id), "{id} said not sent but the Mac ran it");
    }
    for id in &run.maybe_sent {
        assert!(run.mac.deliveries.contains_key(id), "{id} said maybe sent but was never written");
    }
    // Order kept across drops: the Mac first ran them in tap order, except that a prompt still
    // uploading never holds back the ones behind it (Leo, 2026-11-24: text must not queue behind
    // an upload). So a later prompt ran first only past one that carried attachments.
    let index = |id: &String| id[1..].parse::<usize>().unwrap();
    let carried = |id: &String| {
        run.attempts.get(id).is_some_and(|tries| tries.iter().any(|r| !r.attachments.is_empty()))
    };
    for (at, first) in run.mac.ran.iter().enumerate() {
        for later in run.mac.ran.iter().skip(at + 1) {
            assert!(
                index(first) < index(later) || carried(later),
                "the Mac ran {first} before {later}, which was ready: {:?}",
                run.mac.ran
            );
        }
    }
}

#[test]
fn a_hundred_sends_through_a_lossy_link_none_doubled_none_lost() {
    // A hold longer than any outage in the run: every send ends Sent.
    let (mut resends, mut retries) = (0, 0);
    for seed in 0..64u64 {
        let run = lossy_run(seed, 100, Duration::from_secs(600));
        check(&run, 100);
        assert_eq!(run.sent.len(), 100, "seed {seed}: every send got through");
        resends += run.attempts.values().flatten().filter(|r| r.resend).count();
        retries += run.attempts.values().filter(|a| a.len() > 1).count();
    }
    // The link was lossy enough to matter: answers were lost (resends) and writes retried.
    eprintln!(
        "64 seeds x 100 sends: {resends} resends, {retries} prompts retried, 0 double, 0 lost"
    );
    assert!(resends > 100 && retries > 100, "resends {resends}, retried prompts {retries}");
}

#[test]
fn a_hundred_sends_through_a_lossy_link_with_todays_hold_none_doubled_none_lost() {
    // Today's 10 s hold with ~6 s outages and backoff: some come back, honestly marked.
    for seed in 0..64u64 {
        check(&lossy_run(seed, 100, TEN), 100);
    }
}

#[test]
fn a_short_hold_through_a_lossy_link_gives_up_honestly() {
    let mut gave_up = 0;
    for seed in 0..64u64 {
        let run = lossy_run(seed, 100, Duration::from_millis(1_500));
        check(&run, 100);
        gave_up += run.not_sent.len() + run.maybe_sent.len();
    }
    eprintln!("1.5 s hold, 64 seeds x 100 sends: {gave_up} given back honestly");
    assert!(gave_up > 0, "the short hold exercised the give-up path");
}

// ---- Attachments: one queue for text and uploads ---------------------------------------------

fn atts(ids: &[&str]) -> Vec<String> {
    ids.iter().map(|s| s.to_string()).collect()
}

#[test]
fn a_prompt_goes_only_once_its_uploads_are_done_with_their_mac_paths() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "look", atts(&["img1", "img2"]), false, t0, t0);
    assert_eq!(outbox.next_request(t0), None, "uploads first");
    outbox.uploaded("img1", "/tmp/m/img1.png", t0 + ms(10));
    assert_eq!(
        outbox.attachments("a").unwrap()[0].state,
        UploadState::Uploaded { mac_path: "/tmp/m/img1.png".into() }
    );
    assert_eq!(outbox.next_request(t0 + ms(10)), None, "img2 still uploading");
    outbox.uploaded("unknown", "/x", t0 + ms(15));
    outbox.uploaded("img2", "/tmp/m/img2.png", t0 + ms(20));
    let request = outbox.next_request(t0 + ms(20)).unwrap();
    assert_eq!(
        request.attachments,
        vec![
            ("img1".to_string(), "/tmp/m/img1.png".to_string()),
            ("img2".to_string(), "/tmp/m/img2.png".to_string())
        ]
    );
    outbox.wrote("a");
    let done = outbox.answered("a").unwrap();
    assert!(done.cancel_uploads.is_empty(), "nothing to cancel for one that went");
}

#[test]
fn a_later_text_send_never_waits_behind_an_upload() {
    // Leo's blocked send (2026-11-24): text sent while a picked video uploads goes at once; the
    // video's prompt follows once its upload is on the Mac. Base held b behind a's upload.
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "photo", atts(&["big"]), false, t0, t0);
    assert!(outbox.push("b", "and this", vec![], false, t0 + ms(1), t0 + ms(1)), "never blocked");
    assert_eq!(outbox.next_request(t0 + ms(2)).unwrap().id, "b", "b does not wait for a's upload");
    outbox.wrote("b");
    assert_eq!(outbox.answered("b").unwrap().outcome, PromptOutcome::Sent);
    assert_eq!(outbox.unwritten(), vec!["a"]);
    // A long upload is not a wait for the link: nothing gives up while it runs.
    assert!(outbox.expire(t0 + Duration::from_secs(60)).is_empty());
    assert_eq!(outbox.look("a", t0 + Duration::from_secs(60)), PromptLook::Sent);
    assert_eq!(outbox.next_wake(t0 + Duration::from_secs(60)), None, "the upload's end wakes it");
    let now = t0 + Duration::from_secs(60);
    assert_eq!(outbox.next_request(now), None, "a still uploading");
    outbox.uploaded("big", "/m/big", now);
    assert_eq!(outbox.next_request(now).unwrap().id, "a");
}

#[test]
fn ready_prompts_still_go_in_tap_order_behind_an_upload() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "video", atts(&["v"]), false, t0, t0);
    outbox.push("b", "one", vec![], false, t0 + ms(1), t0 + ms(1));
    outbox.push("c", "two", vec![], false, t0 + ms(2), t0 + ms(2));
    assert_eq!(outbox.next_request(t0 + ms(3)).unwrap().id, "b");
    outbox.wrote("b");
    assert_eq!(outbox.next_request(t0 + ms(3)).unwrap().id, "c");
}

#[test]
fn a_failed_upload_gives_its_prompt_up_naming_the_other_uploads_to_cancel() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "pics", atts(&["x", "y", "z"]), false, t0, t0);
    outbox.push("b", "after", vec![], false, t0 + ms(1), t0 + ms(1));
    outbox.uploaded("z", "/m/z", t0);
    let done = outbox.upload_failed("x", "disk full").unwrap();
    assert_eq!(done.outcome, PromptOutcome::UploadFailed { reason: "disk full".into() });
    assert_eq!(done.text, "pics");
    assert_eq!(done.attachments[0].state, UploadState::Failed { reason: "disk full".into() });
    assert_eq!(done.cancel_uploads, atts(&["y"]), "y still runs: cancel it; z is done");
    assert_eq!(outbox.look("a", t0), PromptLook::Failed);
    assert_eq!(outbox.upload_failed("y", "late"), None, "a late report is ignored");
    assert_eq!(outbox.next_request(t0 + ms(2)).unwrap().id, "b", "the next send goes on");
}

#[test]
fn a_drop_mid_upload_starts_the_hold_from_the_drop() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "pic", atts(&["x"]), false, t0, t0);
    outbox.push("b", "b", vec![], false, t0, t0);
    outbox.set_link(false, t0 + ms(30_000));
    assert!(outbox.expire(t0 + ms(39_999)).is_empty());
    let back = outbox.expire(t0 + ms(40_000));
    assert_eq!(back.len(), 2, "both waited the hold for the link");
    assert_eq!(back[0].cancel_uploads, atts(&["x"]), "its upload is cancelled with it");
}

// ---- Cancel, edit, retry now, delete ---------------------------------------------------------

#[test]
fn cancel_mid_upload_frees_the_composer_immediately() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "with pic", atts(&["x"]), false, t0, t0);
    let step = outbox.cancel("a").unwrap();
    let CancelStep::Returned(done) = step else { panic!("never left: back at once, got {step:?}") };
    assert_eq!(done.outcome, PromptOutcome::Cancelled);
    assert_eq!(done.text, "with pic");
    assert_eq!(done.attachments.len(), 1, "its attachments come back too");
    assert_eq!(done.cancel_uploads, atts(&["x"]), "the driver cancels the upload");
    assert!(outbox.is_empty());
    // The upload's late reports are moot.
    outbox.uploaded("x", "/m/x", t0);
    assert_eq!(outbox.upload_failed("x", "cancelled"), None);
    assert_eq!(outbox.next_request(t0), None);
    assert_eq!(outbox.look("a", t0), PromptLook::Sent, "not failed: the person took it back");
}

#[test]
fn cancel_of_a_queued_or_backing_off_send_returns_it_and_the_rest_keep_order() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    for id in ["a", "b", "c"] {
        outbox.push(id, id, vec![], false, t0, t0);
    }
    outbox.next_request(t0).unwrap();
    outbox.write_failed("a", t0);
    let Some(CancelStep::Returned(done)) = outbox.cancel("a") else { panic!() };
    assert_eq!(done.text, "a");
    let Some(CancelStep::Returned(_)) = outbox.cancel("c") else { panic!() };
    assert_eq!(outbox.unwritten(), vec!["b"]);
    assert_eq!(outbox.next_request(t0).unwrap().id, "b");
    assert_eq!(outbox.cancel("zzz"), None);
}

#[test]
fn cancel_of_a_written_send_asks_the_mac_to_remove_it_and_never_sends_it_again() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "deploy", vec![], false, t0, t0);
    outbox.push("b", "b", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    outbox.wrote("a");
    assert_eq!(outbox.cancel("a"), Some(CancelStep::RemoveOnMac { id: "a".into() }));
    outbox.lost("a", t0);
    assert_eq!(outbox.next_request(t0).unwrap().id, "b", "a is never sent again");
    assert_eq!(outbox.unwritten(), Vec::<String>::new());
    assert_eq!(outbox.remove_answered("a", true).unwrap().outcome, PromptOutcome::Cancelled);

    // Too late: the Mac already ran it.
    outbox.push("c", "rm", vec![], false, t0, t0);
    outbox.wrote("b");
    outbox.next_request(t0).unwrap();
    outbox.wrote("c");
    outbox.cancel("c");
    let done = outbox.remove_answered("c", false).unwrap();
    assert_eq!(done.outcome, PromptOutcome::MaybeSent);
    assert_eq!(done.text, "rm");
}

#[test]
fn cancel_during_the_write_or_after_a_lost_answer_goes_through_the_mac() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    assert_eq!(outbox.cancel("a"), Some(CancelStep::RemoveOnMac { id: "a".into() }), "writing");
    outbox.wrote("a");
    assert_eq!(outbox.next_request(t0), None);
    // Its turn ended before the removal: it ran.
    assert_eq!(outbox.answered("a").unwrap().outcome, PromptOutcome::Sent);
    assert_eq!(outbox.remove_answered("a", true), None);

    outbox.push("b", "b", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    outbox.wrote("b");
    outbox.lost("b", t0);
    assert_eq!(
        outbox.cancel("b"),
        Some(CancelStep::RemoveOnMac { id: "b".into() }),
        "may be on the Mac"
    );
    assert!(outbox.expire(t0 + Duration::from_secs(600)).is_empty(), "cancelling is not given up");
}

#[test]
fn edit_of_an_unsent_prompt_replaces_text_and_attachments_in_its_place() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "old", atts(&["x", "y"]), false, t0, t0);
    outbox.push("b", "b", vec![], false, t0 + ms(1), t0 + ms(1));
    outbox.uploaded("x", "/m/x", t0);
    assert_eq!(
        outbox.edit("a", "a2", "new", atts(&["x", "z"]), t0 + ms(5)),
        Some(EditStep::Edited { cancel_uploads: atts(&["y"]) }),
        "y was dropped mid-upload: cancel it"
    );
    assert_eq!(outbox.unwritten(), vec!["a", "b"], "same id, same place");
    let a = outbox.attachments("a").unwrap();
    assert_eq!(a[0].state, UploadState::Uploaded { mac_path: "/m/x".into() }, "x kept its upload");
    assert_eq!(a[1], Attachment { id: "z".into(), state: UploadState::Pending });
    let r = outbox.next_request(t0 + ms(5)).unwrap();
    assert_eq!(r.id, "b", "b is ready: it does not wait while z uploads");
    outbox.wrote("b");
    outbox.uploaded("y", "/m/y", t0 + ms(5));
    assert_eq!(outbox.attachments("a").unwrap().len(), 2, "a dropped upload's end is ignored");
    outbox.uploaded("z", "/m/z", t0 + ms(6));
    let r = outbox.next_request(t0 + ms(6)).unwrap();
    assert_eq!((r.id.as_str(), r.attachments.len()), ("a", 2));
    outbox.wrote("a");
    assert_eq!(outbox.answered("a").unwrap().text, "new");
}

#[test]
fn edit_of_a_send_that_may_be_written_is_a_new_prompt_in_its_place_and_says_so() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "old", vec![], false, t0, t0);
    outbox.push("b", "b", vec![], false, t0 + ms(1), t0 + ms(1));
    outbox.next_request(t0).unwrap();
    outbox.wrote("a");
    assert_eq!(
        outbox.edit("a", "a2", "new", vec![], t0 + ms(2)),
        Some(EditStep::Replaced { remove: "a".into(), cancel_uploads: vec![] })
    );
    assert_eq!(outbox.unwritten(), vec!["a2", "b"], "the edit keeps a's place, before b");
    let r = outbox.next_request(t0 + ms(2)).unwrap();
    assert_eq!((r.id.as_str(), r.resend), ("a2", false), "a new prompt, not a resend");
    assert_eq!(outbox.remove_answered("a", true).unwrap().outcome, PromptOutcome::Cancelled);
    assert_eq!(outbox.edit("zzz", "q", "x", vec![], t0), None);
    assert_eq!(
        outbox.edit("b", "b", "x", vec![], t0),
        Some(EditStep::Edited { cancel_uploads: vec![] })
    );
    outbox.wrote("a2");
    outbox.next_request(t0 + ms(3)).unwrap();
    outbox.wrote("b");
    assert_eq!(outbox.edit("b", "a2", "x", vec![], t0), None, "the new id must be new");
}

#[test]
fn retry_now_skips_the_backoff_and_restarts_the_hold() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    outbox.write_failed("a", t0);
    assert_eq!(outbox.next_request(t0 + ms(1)), None);
    assert!(outbox.retry_now("a", t0 + ms(9_000)));
    assert_eq!(outbox.next_request(t0 + ms(12_000)).unwrap().id, "a", "its hold restarted");
    assert!(!outbox.retry_now("a", t0), "being written: nothing to hurry");
    assert!(!outbox.retry_now("zzz", t0));
}

#[test]
fn delete_cancels_and_leaves_no_failed_mark() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(TEN, 1);
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.expire(t0 + TEN);
    assert_eq!(outbox.look("a", t0), PromptLook::Failed);
    assert_eq!(outbox.delete("a"), None, "already given up: only its mark goes");
    assert_eq!(outbox.look("a", t0), PromptLook::Sent);
    outbox.push("b", "b", atts(&["x"]), false, t0, t0);
    let Some(CancelStep::Returned(done)) = outbox.delete("b") else { panic!() };
    assert_eq!(done.cancel_uploads, atts(&["x"]));
    assert!(outbox.is_empty());
}

#[test]
fn a_hundred_sends_with_uploads_and_cancels_through_a_lossy_link_none_doubled_none_lost() {
    let (mut uploads, mut took_back, mut sent) = (0, 0, 0);
    for seed in 0..64u64 {
        let run =
            lossy_run_with(seed, 100, Duration::from_secs(600), Mix { attach: 30, cancel: 4 });
        check(&run, 100);
        uploads += run.attempts.values().filter(|a| !a[0].attachments.is_empty()).count();
        took_back += run.took_back.len();
        sent += run.sent.len();
    }
    eprintln!(
        "64 seeds x 100 sends: {uploads} with uploads, {took_back} cancelled or upload failed, {sent} sent, 0 double, 0 lost"
    );
    assert!(uploads > 500 && took_back > 100 && sent > 3_000, "{uploads} {took_back} {sent}");
}

#[test]
fn uploads_and_cancels_with_todays_hold_none_doubled_none_lost() {
    for seed in 0..64u64 {
        check(&lossy_run_with(seed, 100, TEN, Mix { attach: 30, cancel: 4 }), 100);
    }
}

// Leo, 2026-11-24: "10s timeout for messages being sendable is a shame. if it's making good
// progress, it should be allowed to keep going?" The hold is a stall bound, not a deadline.

#[test]
fn a_prompt_queued_behind_a_slow_write_keeps_going_while_the_link_makes_progress() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.push("b", "b", vec![], false, t0 + ms(1), t0 + ms(1));
    assert_eq!(outbox.next_request(t0).unwrap().id, "a", "a's write is under way, slowly");
    for second in 1..=60 {
        outbox.progressed(t0 + Duration::from_secs(second));
        assert!(
            outbox.expire(t0 + Duration::from_secs(second) + ms(500)).is_empty(),
            "b is given up at {second}s though the link is moving"
        );
    }
    outbox.wrote("a");
    outbox.progressed(t0 + Duration::from_secs(61));
    assert_eq!(outbox.next_request(t0 + Duration::from_secs(61)).unwrap().id, "b");
}

#[test]
fn a_stall_with_no_progress_still_gives_up_after_the_hold() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.push("b", "b", vec![], false, t0 + ms(1), t0 + ms(1));
    outbox.next_request(t0).unwrap();
    outbox.progressed(t0 + ms(9_000));
    assert!(outbox.expire(t0 + ms(18_999)).is_empty(), "the stall began at the last progress");
    assert_eq!(outbox.next_wake(t0 + ms(9_000)), Some(TEN));
    assert_eq!(outbox.expire(t0 + ms(19_001)), vec![done("b", PromptOutcome::NotSent, "b")]);
}

#[test]
fn other_traffic_does_not_keep_a_prompt_whose_own_write_fails() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    outbox.write_failed("a", t0 + ms(100));
    outbox.progressed(t0 + ms(9_000));
    assert_eq!(outbox.expire(t0 + TEN + ms(100)).len(), 1, "its own writes are not moving");
}

#[test]
fn an_upload_taking_chunks_keeps_its_prompt_and_a_stalled_one_gives_up() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(TEN, 7);
    outbox.push("v", "video", vec!["u1".into()], false, t0, t0);
    for second in 1..=30 {
        outbox.upload_progressed("u1", t0 + Duration::from_secs(second));
        assert!(outbox.expire(t0 + Duration::from_secs(second) + ms(500)).is_empty());
    }
    assert!(outbox.expire(t0 + ms(39_999)).is_empty());
    assert_eq!(outbox.expire(t0 + ms(40_000)).len(), 1, "no chunk for the hold: a stall");
}

// A send's quiet window and the Mac's "not now" (Leo, 2026-11-24: "10s timeout for messages being
// sendsble is a shame. if it's making good progress, it shiukd be allowed to keep going?").

#[test]
fn a_send_that_keeps_making_progress_is_never_failed_by_a_fixed_ten_seconds() {
    let t0 = Instant::now();
    let mut outbox = outbox_30s();
    assert_eq!(DEFAULT_HOLD, Duration::from_secs(30), "a quiet window, not the old fixed 10 s");
    outbox.push("a", "first", vec![], false, t0, t0);
    outbox.push("b", "second", vec![], false, t0, t0);
    assert_eq!(outbox.next_request(t0).unwrap().id, "a", "a is under way; b waits its turn");
    // Something is heard from the Mac every 20 s (more than the old 10 s apart): b is moving.
    for step in 1..=6u64 {
        let at = t0 + Duration::from_secs(20 * step);
        outbox.progressed(at);
        assert!(
            outbox.expire(at + Duration::from_secs(19)).is_empty(),
            "step {step}: still moving"
        );
    }
    // Quiet for the whole 30 s window: only now is it given back.
    let quiet = t0 + Duration::from_secs(20 * 6 + 30);
    assert!(outbox.expire(quiet - ms(1)).is_empty());
    let back: Vec<_> = outbox.expire(quiet).into_iter().map(|d| d.id).collect();
    assert_eq!(back, vec!["b"]);
}

#[test]
fn a_not_now_refusal_is_retried_with_backoff_and_never_given_back() {
    let t0 = Instant::now();
    let mut outbox = outbox_30s();
    outbox.push("p", "hi", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    outbox.wrote("p");
    let mut now = t0;
    let mut waits = Vec::new();
    // A just-restarted acpmux answers "not now" nine times over a minute and a half.
    for _ in 0..9 {
        let step = outbox.refusal("p", true, now).expect("held");
        let Refusal::Retry { retry_in, .. } = step else {
            panic!("a not-now is not final: {step:?}")
        };
        waits.push(retry_in.as_secs());
        assert_eq!(outbox.look("p", now), PromptLook::Retrying);
        assert_eq!(outbox.retry_in("p", now), Some(retry_in));
        assert_eq!(outbox.next_request(now + retry_in - ms(1)), None, "waits its backoff");
        assert!(outbox.expire(now + retry_in).is_empty(), "not given back");
        now += retry_in;
        let again = outbox.next_request(now).expect("goes again");
        assert_eq!(again.id, "p");
        assert!(again.resend, "an attempt was written before");
        outbox.wrote("p");
    }
    assert_eq!(waits, vec![1, 2, 4, 8, 16, 30, 30, 30, 30], "1 s doubling, capped at 30 s");
    assert!(now - t0 > Duration::from_secs(10), "well past the old fixed 10 s");
    assert_eq!(
        outbox.answered("p"),
        Some(done("p", PromptOutcome::Sent, "hi")),
        "and it was taken"
    );
}

#[test]
fn only_a_real_refusal_fails_and_a_not_now_that_never_ends_is_final_after_the_patience() {
    let t0 = Instant::now();
    let mut outbox = outbox_30s();
    outbox.push("real", "a", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    assert_eq!(
        outbox.refusal("real", false, t0),
        Some(Refusal::Final(done("real", PromptOutcome::Refused, "a")))
    );
    assert_eq!(outbox.look("real", t0), PromptLook::Failed);

    outbox.push("busy", "b", vec![], false, t0, t0);
    let mut now = t0;
    loop {
        if outbox.next_request(now).is_some() {
            outbox.wrote("busy");
        }
        match outbox.refusal("busy", true, now).unwrap() {
            Refusal::Retry { retry_in, .. } => now += retry_in,
            Refusal::Final(done) => {
                assert_eq!(done.outcome, PromptOutcome::Refused);
                assert!(now - t0 >= REFUSAL_PATIENCE, "only after {REFUSAL_PATIENCE:?}");
                break;
            }
        }
        assert!(now - t0 < REFUSAL_PATIENCE + Duration::from_secs(60), "ends");
    }
}

#[test]
fn a_transient_refusal_is_told_by_origin_code_or_reason() {
    for (origin, code, reason) in [
        (Some("native"), None, None),
        (None, Some("timed_out"), None),
        (None, None, Some("session.starting")),
        (None, None, Some("hub.busy")),
        (None, Some("not_ready"), None),
        (None, None, Some("Restarting")),
        (None, None, Some("host.unavailable")),
        (None, None, Some("draining")),
    ] {
        assert!(is_transient_refusal(origin, code, reason), "{origin:?} {code:?} {reason:?}");
    }
    for (origin, code, reason) in [
        (None, None, None),
        (Some("acpmux"), Some("-32602"), Some("prompt.invalid")),
        (None, None, Some("remote.full_access_required")),
        (None, Some("permission_denied"), Some("permission.person_required")),
    ] {
        assert!(!is_transient_refusal(origin, code, reason), "{origin:?} {code:?} {reason:?}");
    }
}

#[test]
fn the_macs_resend_notices_drive_the_look_and_the_end() {
    let t0 = Instant::now();
    let mut outbox = outbox_30s();
    outbox.push("p", "hi", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    outbox.wrote("p");
    let retrying = ResendState::parse("retrying", Some(4_000)).unwrap();
    assert_eq!(retrying, ResendState::Retrying { retry_in: Some(ms(4_000)) });
    assert_eq!(outbox.resend_notice("p", retrying, t0 + ms(10)), None);
    assert_eq!(outbox.look("p", t0 + ms(10)), PromptLook::Retrying);
    assert_eq!(outbox.retry_in("p", t0 + ms(10)), Some(ms(4_000)));
    assert_eq!(
        outbox.next_request(t0 + Duration::from_secs(60)),
        None,
        "the Mac's outbox resends it"
    );
    assert_eq!(
        outbox.resend_notice("p", ResendState::parse("sent", None).unwrap(), t0 + ms(5_000)),
        None
    );
    assert_eq!(outbox.look("p", t0 + ms(5_000)), PromptLook::Sent);
    assert_eq!(outbox.resend_notice("p", ResendState::Accepted, t0 + ms(5_001)), None);
    assert_eq!(outbox.retry_in("p", t0 + ms(5_001)), None);
    assert_eq!(ResendState::parse("bogus", None), None);

    outbox.push("q", "no", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    assert_eq!(
        outbox.resend_notice("q", ResendState::Refused, t0),
        Some(done("q", PromptOutcome::Refused, "no")),
        "a refusal for good fails it"
    );
}

// ---- Every pending send has an exit (`pending`) ------------------------------------------------
//
// Leo, 2026-11-24: "i also couldnt cancel out of the send. i need to be able to do that otherwise
// i cant edit or anything to retry or delete and remove." The outbox could cancel, edit, retry and
// delete, but the chat drew no row for a waiting text prompt and offered nothing once a prompt
// left its upload: `pending` is the rows and the actions each one has.

#[test]
fn a_send_cancelled_mid_send_at_any_stage_leaves_nothing_pending() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(TEN, 7);
    outbox.set_link(false, t0);

    // Offline, a text prompt waits: no row at the tap, a row with Stop once it waits.
    outbox.push("a", "deploy it", vec![], false, t0, t0);
    let rows = outbox.pending(t0 + ms(500));
    assert_eq!(rows.len(), 1);
    assert!(!rows[0].shown, "a prompt that goes at once draws no row");
    let rows = outbox.pending(t0 + ms(3_000));
    assert!(rows[0].shown, "waiting for the link: its row shows, with Stop");
    assert_eq!(rows[0].look, PromptLook::Retrying);
    assert!(!rows[0].can_send_now, "the link is down: Send now would do nothing");
    let Some(CancelStep::Returned(done)) = outbox.cancel("a") else { panic!("never left") };
    assert_eq!((done.outcome, done.text.as_str()), (PromptOutcome::Cancelled, "deploy it"));
    assert!(outbox.pending(t0 + ms(3_000)).is_empty());

    // Mid-upload: shown from the tap, Stop cancels the upload.
    outbox.set_link(true, t0 + ms(3_000));
    outbox.push("b", "look", atts(&["x"]), false, t0 + ms(3_000), t0 + ms(3_000));
    let rows = outbox.pending(t0 + ms(3_000));
    assert!(rows[0].shown && rows[0].attachments == atts(&["x"]));
    let Some(CancelStep::Returned(done)) = outbox.cancel("b") else { panic!("never left") };
    assert_eq!(done.cancel_uploads, atts(&["x"]));
    assert!(outbox.pending(t0 + ms(3_000)).is_empty());

    // Mid-write: Stop goes through the Mac, and its row says so until the Mac answers.
    outbox.push("c", "rm -rf build", vec![], false, t0 + ms(3_000), t0 + ms(3_000));
    assert_eq!(outbox.next_request(t0 + ms(3_000)).unwrap().id, "c");
    assert_eq!(outbox.cancel("c"), Some(CancelStep::RemoveOnMac { id: "c".into() }));
    let rows = outbox.pending(t0 + ms(3_000));
    assert!(rows[0].stopping && rows[0].shown && !rows[0].can_send_now);
    assert_eq!(outbox.remove_answered("c", true).unwrap().outcome, PromptOutcome::Cancelled);
    assert!(outbox.pending(t0 + ms(3_000)).is_empty());
    assert_eq!(outbox.next_request(t0 + ms(60_000)), None, "a stopped send never goes again");
}

#[test]
fn a_failed_send_is_edited_and_retried_now_and_goes_with_the_edit() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "teh fix", vec![], false, t0, t0);
    outbox.next_request(t0).unwrap();
    outbox.write_failed("a", t0);

    let t = t0 + ms(3_000);
    let rows = outbox.pending(t);
    assert!(rows[0].shown, "a failed write's row shows while it backs off");
    assert_eq!(rows[0].look, PromptLook::Retrying);
    assert!(rows[0].can_send_now, "the link is up: Send now is offered");

    assert_eq!(
        outbox.edit("a", "a2", "the fix", vec![], t),
        Some(EditStep::Edited { cancel_uploads: vec![] }),
        "never written: edited in place, same id"
    );
    assert!(outbox.retry_now("a", t));
    let request = outbox.next_request(t).expect("Send now: it goes at once");
    assert_eq!((request.id.as_str(), request.attempt, request.resend), ("a", 2, false));
    assert_eq!(outbox.pending(t)[0].text, "the fix", "it goes with the edit");
    outbox.wrote("a");
    assert_eq!(outbox.answered("a").unwrap().outcome, PromptOutcome::Sent);
    assert!(outbox.pending(t).is_empty());

    // Delete: gone with no text back, from a waiting send too.
    outbox.push("b", "never mind", vec![], false, t, t);
    outbox.next_request(t).unwrap();
    outbox.write_failed("b", t);
    let Some(CancelStep::Returned(_)) = outbox.delete("b") else { panic!("never left") };
    assert!(outbox.pending(t + ms(3_000)).is_empty());
    assert_eq!(outbox.look("b", t + ms(3_000)), PromptLook::Sent, "nothing failed is left to show");
}
