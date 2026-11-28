use super::*;

pub(super) fn delivery(created_at: u64, projection: bool) -> Delivery {
    let mut request = json!({"sessionId": "gone/lane", "_meta": {"acpmux": {"promptId": "p"}}});
    if projection {
        request["_meta"]["acpmux"]["forwardProjection"] = json!({"text": "x"});
    }
    Delivery {
        id: "d".into(),
        target: "gone/lane".into(),
        request,
        caller: None,
        unproven_caller: None,
        not_terminal: false,
        state: State::Queued,
        attempts: 0,
        never_sent: true,
        resends: 0,
        resent_at: 0,
        relay_post: None,
        relay_unreached: false,
        direct_maybe: false,
        open_on_peer: false,
        pin: None,
        proof: None,
        error: None,
        accepted: None,
        created_at,
        updated_at: created_at,
    }
}

/// A message to a machine that stays down keeps being tried after the schedule runs out,
/// for a day, each wait twice the one before; a projection intent keeps the bounded
/// schedule.
#[test]
fn a_message_keeps_trying_for_a_day_after_the_schedule_runs_out() {
    let d = delivery(1_000, false);
    let (mut delays, mut tail) = (RETRY_DELAYS_SECS.iter(), 0);
    for want in RETRY_DELAYS_SECS {
        assert_eq!(retry_delay(&mut delays, &mut tail, &d, 2_000), Some(*want));
    }
    let last = RETRY_DELAYS_SECS.last().copied().unwrap();
    assert_eq!(retry_delay(&mut delays, &mut tail, &d, 2_000), Some(2 * last), "doubled");
    assert_eq!(retry_delay(&mut delays, &mut tail, &d, 1_000 + RETRY_FOR_MS - 1), Some(4 * last));
    assert_eq!(
        retry_delay(&mut delays, &mut tail, &d, 1_000 + RETRY_FOR_MS),
        None,
        "a day later it fails"
    );
    let intent = delivery(1_000, true);
    let (mut delays, mut tail) = (RETRY_DELAYS_SECS.iter(), 0);
    for _ in RETRY_DELAYS_SECS {
        assert!(retry_delay(&mut delays, &mut tail, &intent, 2_000).is_some());
    }
    assert_eq!(retry_delay(&mut delays, &mut tail, &intent, 2_000), None);
}

/// A message whose target never answers, tried for its whole day on the schedule (each wait
/// slept in full, `retry_sleep` cutting the last at the day's end), costs about log2 of its
/// day in attempts: 9 on the schedule and 7 doubled after it, not one every 15 minutes
/// (about 100) as before.
#[test]
fn a_never_answered_message_costs_a_logarithmic_number_of_attempts_in_its_day() {
    let d = delivery(0, false);
    let (mut delays, mut tail, mut now, mut attempts) = (RETRY_DELAYS_SECS.iter(), 0, 0, 0);
    while !expired(&d, now) {
        attempts += 1;
        let Some(secs) = retry_delay(&mut delays, &mut tail, &d, now) else { break };
        now += retry_sleep(&d, secs, now).as_millis() as u64;
    }
    assert!(attempts <= 17, "{attempts} attempts in a day");
    assert!(attempts >= RETRY_DELAYS_SECS.len(), "the schedule still runs: {attempts}");
}

/// A message's wait stops at the end of its day; a projection intent's wait is never cut,
/// even when the intent is older than a day (a restart resumed it).
#[test]
fn only_a_messages_wait_is_cut_at_the_end_of_its_day() {
    let day_end = 1_000 + RETRY_FOR_MS;
    assert_eq!(retry_sleep(&delivery(1_000, false), 900, 2_000), Duration::from_secs(900));
    assert_eq!(retry_sleep(&delivery(1_000, false), 900, day_end - 5_000), Duration::from_secs(5));
    assert_eq!(retry_sleep(&delivery(1_000, false), 900, day_end + 1), Duration::ZERO);
    assert_eq!(retry_sleep(&delivery(1_000, true), 900, day_end + 1), Duration::from_secs(900));
}

/// A message a day old is not sent (after a restart too); a projection intent is not timed.
#[test]
fn a_message_past_its_day_is_expired() {
    let d = delivery(1_000, false);
    assert!(!expired(&d, 1_000 + RETRY_FOR_MS - 1));
    assert!(expired(&d, 1_000 + RETRY_FOR_MS));
    assert!(!expired(&delivery(1_000, true), 1_000 + 10 * RETRY_FOR_MS));
}
