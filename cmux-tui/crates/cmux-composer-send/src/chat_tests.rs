use super::*;
use std::collections::{HashMap, HashSet};

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

fn outbox() -> PromptOutbox {
    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 7);
    outbox.set_link(true);
    outbox
}

#[test]
fn every_attempt_carries_the_same_id_and_a_written_one_goes_again_as_a_resend() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    assert!(outbox.push("p1", "hi", false, t0, t0));
    let first = outbox.next_request(t0).unwrap();
    assert_eq!(first, PromptRequest { id: "p1".into(), resend: false, attempt: 1 });
    outbox.wrote("p1");
    outbox.lost("p1", t0 + ms(100));
    outbox.set_link(false);
    outbox.set_link(true);
    let second = outbox.next_request(t0 + ms(100)).unwrap();
    assert_eq!(second, PromptRequest { id: "p1".into(), resend: true, attempt: 2 });
    outbox.wrote("p1");
    assert_eq!(
        outbox.answered("p1"),
        Some(PromptDone { id: "p1".into(), outcome: PromptOutcome::Sent })
    );
    assert!(outbox.is_empty());
}

#[test]
fn a_write_that_failed_is_not_a_resend() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("p1", "hi", false, t0, t0);
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
    outbox.push("p1", "hi", true, t0, t0);
    assert!(outbox.next_request(t0).unwrap().resend);
}

#[test]
fn a_second_push_of_the_same_id_is_not_a_second_send() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    assert!(outbox.push("p1", "hi", false, t0, t0));
    assert!(!outbox.push("p1", "hi", false, t0, t0));
    assert_eq!(outbox.len(), 1);
    outbox.next_request(t0).unwrap();
    outbox.wrote("p1");
    assert!(!outbox.push("p1", "hi", false, t0, t0), "written and unanswered: still here");
    assert_eq!(outbox.next_request(t0), None);
}

#[test]
fn one_write_at_a_time_in_tap_order() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", false, t0, t0);
    outbox.push("b", "b", false, t0 + ms(1), t0 + ms(1));
    assert_eq!(outbox.next_request(t0).unwrap().id, "a");
    assert_eq!(outbox.next_request(t0), None, "b waits for a's write");
    outbox.wrote("a");
    assert_eq!(outbox.next_request(t0).unwrap().id, "b", "a's answer is not waited for");
}

#[test]
fn a_later_prompt_never_goes_before_an_earlier_unsent_one() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", false, t0, t0);
    outbox.push("b", "b", false, t0 + ms(1), t0 + ms(1));
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
        outbox.push(*id, *id, false, t0 + ms(i as u64), t0 + ms(i as u64));
    }
    outbox.next_request(t0).unwrap();
    outbox.wrote("a");
    outbox.next_request(t0).unwrap();
    outbox.wrote("b");
    // The link drops: a's and b's answers are lost; c was never written.
    outbox.set_link(false);
    outbox.lost("a", t0 + ms(10));
    outbox.lost("b", t0 + ms(10));
    assert_eq!(outbox.unwritten(), vec!["a", "b", "c"]);
    outbox.set_link(true);
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
    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 1);
    outbox.push("a", "a", false, t0, t0);
    outbox.push("b", "b", false, t0 + ms(5), t0 + ms(5));
    assert_eq!(outbox.next_request(t0 + ms(10)), None, "link down: queued");
    assert_eq!(outbox.unwritten(), vec!["a", "b"]);
    outbox.set_link(true);
    assert_eq!(outbox.next_request(t0 + ms(10)).unwrap().id, "a");
    outbox.wrote("a");
    assert_eq!(outbox.next_request(t0 + ms(10)).unwrap().id, "b");
}

#[test]
fn a_link_that_comes_back_skips_the_backoff() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", false, t0, t0);
    outbox.next_request(t0).unwrap();
    outbox.write_failed("a", t0);
    assert_eq!(outbox.next_request(t0 + ms(1)), None);
    outbox.set_link(false);
    outbox.set_link(true);
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
    outbox.push("a", "a", false, t0, t0);
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
    let a: Vec<_> =
        (0..8).map(|_| retry_delay(3, PromptOutbox::new(DEFAULT_HOLD, 1).next_unit())).collect();
    let mut x = PromptOutbox::new(DEFAULT_HOLD, 1);
    let mut y = PromptOutbox::new(DEFAULT_HOLD, 2);
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
    outbox.push("a", "first", false, t0, t0);
    outbox.push("b", "second", false, t0 + ms(4_000), t0 + ms(4_000));
    assert!(outbox.expire(t0 + ms(9_999)).is_empty());
    assert_eq!(outbox.next_wake(t0 + ms(9_000)), Some(ms(1_000)));
    assert_eq!(
        outbox.expire(t0 + ms(10_000)),
        vec![
            PromptDone { id: "a".into(), outcome: PromptOutcome::NotSent { text: "first".into() } },
            PromptDone {
                id: "b".into(),
                outcome: PromptOutcome::NotSent { text: "second".into() }
            },
        ],
        "b is younger, but never goes after a that did not"
    );
    assert!(outbox.is_empty());
    outbox.set_link(true);
    assert_eq!(outbox.next_request(t0 + ms(10_001)), None, "nothing goes behind the person's back");
}

#[test]
fn a_prompt_past_the_hold_is_never_written_even_before_expire_runs() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(ms(10_000), 3);
    outbox.push("a", "a", false, t0, t0);
    outbox.set_link(true);
    assert_eq!(outbox.next_request(t0 + ms(10_000)), None);
}

#[test]
fn a_written_prompt_whose_answer_was_lost_gives_up_as_maybe_sent() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "deploy", false, t0, t0);
    outbox.next_request(t0).unwrap();
    outbox.wrote("a");
    outbox.set_link(false);
    outbox.lost("a", t0 + ms(30_000));
    assert!(outbox.expire(t0 + ms(39_999)).is_empty(), "its wait starts at the drop, not the tap");
    assert_eq!(
        outbox.expire(t0 + ms(40_000)),
        vec![PromptDone {
            id: "a".into(),
            outcome: PromptOutcome::MaybeSent { text: "deploy".into() }
        }]
    );
}

#[test]
fn written_prompts_wait_for_their_answers_past_the_hold() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "long turn", false, t0, t0);
    outbox.next_request(t0).unwrap();
    outbox.wrote("a");
    assert!(outbox.expire(t0 + Duration::from_secs(600)).is_empty());
    assert_eq!(outbox.look("a", t0 + Duration::from_secs(600)), PromptLook::Sent);
    assert_eq!(outbox.answered("a").unwrap().outcome, PromptOutcome::Sent);
}

#[test]
fn a_prompt_sent_while_the_link_is_up_waits_from_its_tap_and_a_held_one_from_its_hold() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    // An upload took 3 s: tapped at t0, pushed at t0+3s, link up and nothing ahead: from the tap.
    outbox.push("a", "a", false, t0, t0 + ms(3_000));
    outbox.next_request(t0 + ms(3_000)).unwrap();
    outbox.write_failed("a", t0 + ms(3_000));
    assert_eq!(outbox.expire(t0 + ms(10_000)).len(), 1);

    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 1);
    // Link down at the push: from the push.
    outbox.push("b", "b", false, t0, t0 + ms(3_000));
    assert!(outbox.expire(t0 + ms(12_999)).is_empty());
    assert_eq!(outbox.expire(t0 + ms(13_000)).len(), 1);
}

#[test]
fn a_refusal_gives_the_text_back_and_lets_the_next_go() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", false, t0, t0);
    outbox.push("b", "b", false, t0, t0);
    outbox.next_request(t0).unwrap();
    assert_eq!(
        outbox.refused("a"),
        Some(PromptDone { id: "a".into(), outcome: PromptOutcome::Refused { text: "a".into() } })
    );
    assert_eq!(outbox.look("a", t0), PromptLook::Failed);
    assert_eq!(outbox.next_request(t0).unwrap().id, "b");
}

#[test]
fn looks_sent_from_the_tap_retrying_after_a_quiet_threshold_failed_when_given_up() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 1);
    outbox.push("a", "a", false, t0, t0);
    assert_eq!(outbox.look("a", t0), PromptLook::Sent, "sent from the tap on");
    assert_eq!(outbox.look("a", t0 + RETRYING_AFTER - ms(1)), PromptLook::Sent);
    assert_eq!(outbox.next_look_change(t0), Some(RETRYING_AFTER));
    assert_eq!(outbox.look("a", t0 + RETRYING_AFTER), PromptLook::Retrying);
    outbox.expire(t0 + DEFAULT_HOLD);
    assert_eq!(outbox.look("a", t0 + DEFAULT_HOLD), PromptLook::Failed);
    outbox.forget("a");
    assert_eq!(outbox.look("a", t0 + DEFAULT_HOLD), PromptLook::Sent);
    assert_eq!(outbox.look("never-here", t0), PromptLook::Sent);

    // Pushed again by the person: no longer failed.
    outbox.push("b", "b", false, t0, t0);
    outbox.expire(t0 + DEFAULT_HOLD);
    assert_eq!(outbox.look("b", t0 + DEFAULT_HOLD), PromptLook::Failed);
    outbox.push("b", "b", true, t0 + DEFAULT_HOLD, t0 + DEFAULT_HOLD);
    assert_eq!(outbox.look("b", t0 + DEFAULT_HOLD), PromptLook::Sent);
}

#[test]
fn the_failed_memory_is_bounded() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 1);
    for i in 0..(FAILED_MEMORY + 10) {
        outbox.push(format!("p{i}"), "x", false, t0, t0);
    }
    outbox.expire(t0 + DEFAULT_HOLD);
    assert_eq!(outbox.failed.len(), FAILED_MEMORY);
    assert_eq!(outbox.look("p0", t0), PromptLook::Sent, "the oldest is forgotten");
    assert_eq!(outbox.look(&format!("p{}", FAILED_MEMORY + 9), t0), PromptLook::Failed);
}

#[test]
fn giving_up_from_one_prompt_takes_every_unwritten_one_after_it() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 1);
    for id in ["a", "b", "c"] {
        outbox.push(id, id, false, t0, t0);
    }
    let done: Vec<String> = outbox.give_up_from("b").into_iter().map(|d| d.id).collect();
    assert_eq!(done, vec!["b", "c"]);
    assert_eq!(outbox.unwritten(), vec!["a"]);
    assert!(outbox.give_up_from("zzz").is_empty());
}

#[test]
fn draining_hands_the_unwritten_prompts_over_with_their_taps() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 1);
    outbox.push("a", "a", false, t0, t0);
    outbox.push("b", "b", false, t0 + ms(5), t0 + ms(5));
    assert_eq!(outbox.drain_unwritten(), vec![("a".into(), t0), ("b".into(), t0 + ms(5))]);
    assert!(outbox.is_empty());
    // A next outbox (link down) that takes them over ages them from their taps.
    let mut next = PromptOutbox::new(DEFAULT_HOLD, 1);
    next.push("a", "a", false, t0, t0);
    assert_eq!(next.expire(t0 + DEFAULT_HOLD).len(), 1);
}

#[test]
fn prompts_are_placed_by_their_tap() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 1);
    outbox.push("late", "late", false, t0 + ms(10), t0 + ms(10));
    outbox.push("early", "early", false, t0, t0 + ms(10));
    assert_eq!(outbox.unwritten(), vec!["early", "late"]);
}

#[test]
fn an_answer_for_a_prompt_queued_again_still_settles_it() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    outbox.push("a", "a", false, t0, t0);
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
    mac: FakeMac,
    attempts: HashMap<String, Vec<PromptRequest>>,
}

/// `sends` prompts tapped through a link that drops (down for a while), fails writes, and loses
/// answers, at the given seed. The hold is long enough or short, per `hold`.
fn lossy_run(seed: u64, sends: usize, hold: Duration) -> Run {
    let mut rng = Rng(seed);
    let t0 = Instant::now();
    let mut now = t0;
    let mut outbox = PromptOutbox::new(hold, seed ^ 0xA5A5);
    outbox.set_link(true);
    let mut mac = FakeMac::default();
    // Written prompts whose answer is on its way: (id, steps left).
    let mut answers: Vec<(String, u32)> = Vec::new();
    let mut ended: HashMap<String, PromptOutcome> = HashMap::new();
    let mut attempts: HashMap<String, Vec<PromptRequest>> = HashMap::new();
    let mut tapped = 0usize;
    let mut down_steps = 0u32;
    for _step in 0..200_000 {
        if tapped == sends && outbox.is_empty() {
            break;
        }
        now += ms(1 + rng.next() % 150);
        // The link drops now and then, for up to ~6 s.
        if down_steps == 0 && rng.chance(3) {
            down_steps = 1 + (rng.next() % 60) as u32;
            outbox.set_link(false);
            // Every answer in flight is lost with the channel.
            for (id, _) in answers.drain(..) {
                outbox.lost(&id, now);
            }
        } else if down_steps > 0 {
            down_steps -= 1;
            if down_steps == 0 {
                outbox.set_link(true);
            }
        }
        if tapped < sends && rng.chance(35) {
            let id = format!("p{tapped}");
            assert!(outbox.push(id.clone(), format!("text {tapped}"), false, now, now));
            tapped += 1;
        }
        for done in outbox.expire(now) {
            assert!(ended.insert(done.id.clone(), done.outcome).is_none(), "ended twice");
        }
        while let Some(request) = outbox.next_request(now) {
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
                    assert!(ended.insert(done.id.clone(), done.outcome).is_none(), "ended twice");
                }
            } else {
                still.push((id, left - 1));
            }
        }
        answers = still;
    }
    assert_eq!(tapped, sends, "the run tapped every send");
    assert!(outbox.is_empty(), "every send ended");
    let mut run = Run { sent: vec![], not_sent: vec![], maybe_sent: vec![], mac, attempts };
    for i in 0..sends {
        let id = format!("p{i}");
        match ended.remove(&id).unwrap_or_else(|| panic!("{id} never ended: lost")) {
            PromptOutcome::Sent => run.sent.push(id),
            PromptOutcome::NotSent { text } => {
                assert_eq!(text, format!("text {i}"), "its text comes back");
                run.not_sent.push(id);
            }
            PromptOutcome::MaybeSent { text } => {
                assert_eq!(text, format!("text {i}"));
                run.maybe_sent.push(id);
            }
            PromptOutcome::Refused { .. } => unreachable!("the fake Mac refuses nothing"),
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
    assert_eq!(run.sent.len() + run.not_sent.len() + run.maybe_sent.len(), sends);
    for id in &run.sent {
        assert!(run.mac.ran_set.contains(id), "{id} said sent but the Mac never ran it");
    }
    for id in &run.not_sent {
        assert!(!run.mac.ran_set.contains(id), "{id} said not sent but the Mac ran it");
    }
    for id in &run.maybe_sent {
        assert!(run.mac.deliveries.contains_key(id), "{id} said maybe sent but was never written");
    }
    // Order kept across drops: the Mac first ran them in tap order.
    let index = |id: &String| id[1..].parse::<usize>().unwrap();
    assert!(
        run.mac.ran.windows(2).all(|w| index(&w[0]) < index(&w[1])),
        "the Mac ran them out of tap order: {:?}",
        run.mac.ran
    );
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
    assert!(resends > 100 && retries > 100, "resends {resends}, retried prompts {retries}");
}

#[test]
fn a_hundred_sends_through_a_lossy_link_with_todays_hold_none_doubled_none_lost() {
    // Today's 10 s hold with ~6 s outages and backoff: some come back, honestly marked.
    for seed in 0..64u64 {
        check(&lossy_run(seed, 100, DEFAULT_HOLD), 100);
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
    assert!(gave_up > 0, "the short hold exercised the give-up path");
}
