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
        relay_post: None,
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
/// for a day; a projection intent keeps the bounded schedule.
#[test]
fn a_message_keeps_trying_for_a_day_after_the_schedule_runs_out() {
    let d = delivery(1_000, false);
    let mut delays = RETRY_DELAYS_SECS.iter();
    for want in RETRY_DELAYS_SECS {
        assert_eq!(retry_delay(&mut delays, &d, 2_000), Some(*want));
    }
    let last = RETRY_DELAYS_SECS.last().copied();
    assert_eq!(retry_delay(&mut delays, &d, 2_000), last, "still within the day");
    assert_eq!(retry_delay(&mut delays, &d, 1_000 + RETRY_FOR_MS - 1), last);
    assert_eq!(retry_delay(&mut delays, &d, 1_000 + RETRY_FOR_MS), None, "a day later it fails");
    let intent = delivery(1_000, true);
    let mut delays = RETRY_DELAYS_SECS.iter();
    for _ in RETRY_DELAYS_SECS {
        assert!(retry_delay(&mut delays, &intent, 2_000).is_some());
    }
    assert_eq!(retry_delay(&mut delays, &intent, 2_000), None);
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
