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

fn outbox() -> PromptOutbox {
    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 7);
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
    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 1);
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
fn a_prompt_sent_while_the_link_is_up_waits_from_its_tap_and_a_held_one_from_its_hold() {
    let t0 = Instant::now();
    let mut outbox = outbox();
    // An upload took 3 s: tapped at t0, pushed at t0+3s, link up and nothing ahead: from the tap.
    outbox.push("a", "a", vec![], false, t0, t0 + ms(3_000));
    outbox.next_request(t0 + ms(3_000)).unwrap();
    outbox.write_failed("a", t0 + ms(3_000));
    assert_eq!(outbox.expire(t0 + ms(10_000)).len(), 1);

    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 1);
    // Link down at the push: from the push.
    outbox.push("b", "b", vec![], false, t0, t0 + ms(3_000));
    assert!(outbox.expire(t0 + ms(12_999)).is_empty());
    assert_eq!(outbox.expire(t0 + ms(13_000)).len(), 1);
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
    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 1);
    outbox.push("a", "a", vec![], false, t0, t0);
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
    outbox.push("b", "b", vec![], false, t0, t0);
    outbox.expire(t0 + DEFAULT_HOLD);
    assert_eq!(outbox.look("b", t0 + DEFAULT_HOLD), PromptLook::Failed);
    outbox.push("b", "b", vec![], true, t0 + DEFAULT_HOLD, t0 + DEFAULT_HOLD);
    assert_eq!(outbox.look("b", t0 + DEFAULT_HOLD), PromptLook::Sent);
}

#[test]
fn the_failed_memory_is_bounded() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 1);
    for i in 0..(FAILED_MEMORY + 10) {
        outbox.push(format!("p{i}"), "x", vec![], false, t0, t0);
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
    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 1);
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.push("b", "b", vec![], false, t0 + ms(5), t0 + ms(5));
    assert_eq!(outbox.drain_unwritten(), vec![("a".into(), t0), ("b".into(), t0 + ms(5))]);
    assert!(outbox.is_empty());
    // A next outbox (link down) that takes them over ages them from their taps.
    let mut next = PromptOutbox::new(DEFAULT_HOLD, 1);
    next.push("a", "a", vec![], false, t0, t0);
    assert_eq!(next.expire(t0 + DEFAULT_HOLD).len(), 1);
}

#[test]
fn prompts_are_placed_by_their_tap() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 1);
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
    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 1);
    outbox.push("a", "a", vec![], false, t0, t0);
    outbox.expire(t0 + DEFAULT_HOLD);
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
        check(&lossy_run_with(seed, 100, DEFAULT_HOLD, Mix { attach: 30, cancel: 4 }), 100);
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
    assert_eq!(outbox.next_wake(t0 + ms(9_000)), Some(DEFAULT_HOLD));
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
    assert_eq!(outbox.expire(t0 + DEFAULT_HOLD).len(), 1, "its own writes are not moving");
}

#[test]
fn an_upload_taking_chunks_keeps_its_prompt_and_a_stalled_one_gives_up() {
    let t0 = Instant::now();
    let mut outbox = PromptOutbox::new(DEFAULT_HOLD, 7);
    outbox.push("v", "video", vec!["u1".into()], false, t0, t0);
    for second in 1..=30 {
        outbox.upload_progressed("u1", t0 + Duration::from_secs(second));
        assert!(outbox.expire(t0 + Duration::from_secs(second) + ms(500)).is_empty());
    }
    assert!(outbox.expire(t0 + ms(39_999)).is_empty());
    assert_eq!(outbox.expire(t0 + ms(40_000)).len(), 1, "no chunk for the hold: a stall");
}
