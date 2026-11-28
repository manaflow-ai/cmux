use super::*;
use serde_json::json;
use tokio::sync::Semaphore;

#[test]
fn a_cancel_frees_the_slot_at_once_and_the_late_answer_is_not_sent() {
    let slots = Arc::new(Semaphore::new(2));
    let gauge = Arc::new(AtomicUsize::new(0));
    let flights = InFlight::counted(gauge.clone());
    let first =
        flights.begin(&json!(1), "m", Some(slots.clone().try_acquire_owned().unwrap()), None);
    let second =
        flights.begin(&json!(2), "m", Some(slots.clone().try_acquire_owned().unwrap()), None);
    assert_eq!((slots.available_permits(), gauge.load(Ordering::Relaxed)), (0, 2));
    assert_eq!(flights.cancel(&json!(1)).map(|(m, _)| m).as_deref(), Some("m"));
    assert_eq!(slots.available_permits(), 1, "freed by the cancel");
    assert!(!flights.finish(&first), "its answer is not sent");
    assert!(flights.finish(&second));
    assert_eq!((flights.len(), slots.available_permits()), (0, 2));
    assert_eq!(flights.cancel(&json!(2)), None, "nothing left to cancel");
    let _left = flights.begin(&json!(3), "m", None, None);
    assert_eq!(gauge.load(Ordering::Relaxed), 1);
    drop(flights);
    assert_eq!(gauge.load(Ordering::Relaxed), 0, "a closed connection leaves the count");
}

/// A request is running until its answer is taken, then answered; an id never begun is in
/// neither list; the answered list keeps the newest ANSWERED_KEPT.
#[test]
fn request_states_name_running_then_answered_and_never_an_unread_id() {
    let flights = InFlight::counted(Arc::default());
    let a = flights.begin(&json!(1), "session/prompt", None, None);
    let _b = flights.begin(&json!("b"), "_acpmux/events", None, None);
    let (mut running, answered) = flights.states();
    running.sort_by_key(|id| id.to_string());
    assert_eq!((running, answered), (vec![json!("b"), json!(1)], vec![]));
    assert!(flights.finish(&a));
    assert_eq!(flights.states(), (vec![json!("b")], vec![json!(1)]));
    assert!(flights.cancel(&json!("b")).is_some());
    assert_eq!(flights.states(), (vec![], vec![json!(1), json!("b")]));
    for n in 0..ANSWERED_KEPT as i64 {
        let ticket = flights.begin(&json!(100 + n), "m", None, None);
        assert!(flights.finish(&ticket));
    }
    let (_, answered) = flights.states();
    assert_eq!(answered.len(), ANSWERED_KEPT);
    assert_eq!(answered.first(), Some(&json!(100)), "the oldest went first");
    assert!(!answered.contains(&json!(7)), "an id never read is in neither list");
}

/// The stop takes every request in flight, each once, and refuses a later one; a drained
/// request's own late answer is not sent.
#[test]
fn the_shutdown_drain_takes_each_request_once_and_refuses_later_ones() {
    let gauge = Arc::new(AtomicUsize::new(0));
    let flights = InFlight::counted(gauge.clone());
    assert!(flights.counts_into(&gauge));
    assert!(!flights.counts_into(&Arc::default()));
    let a = flights.begin(&json!(1), "session/prompt", None, None);
    let b = flights.begin(&json!("b"), "_acpmux/sessions", None, None);
    let mut taken = flights.drain_at_shutdown();
    taken.sort_by_key(|(id, _, _)| id.to_string());
    let ids: Vec<_> = taken.iter().map(|(id, m, _)| (id.clone(), m.clone())).collect();
    assert_eq!(
        ids,
        [(json!("b"), "_acpmux/sessions".to_owned()), (json!(1), "session/prompt".to_owned())]
    );
    assert_eq!((flights.len(), gauge.load(Ordering::Relaxed)), (0, 0));
    assert!(!flights.finish(&a) && !flights.finish(&b), "the drain answered them");
    assert!(flights.drain_at_shutdown().is_empty(), "each is taken once");
    let late = flights.begin(&json!(3), "m", None, None);
    assert!(late.refused());
    assert_eq!(flights.len(), 0, "a refused request is never in flight");
}

#[test]
fn a_reused_id_keeps_its_own_slot_and_is_not_cancelled_for_the_first() {
    let flights = InFlight::default();
    let first = flights.begin(&json!("a"), "m", None, None);
    let again = flights.begin(&json!("a"), "m", None, None);
    assert!(flights.finish(&again));
    assert_eq!(flights.len(), 1);
    assert!(flights.finish(&first));
}

/// A list reply takes its entry as it is queued: a cancel after that finds nothing, and the
/// request's own finish still owns the answer it sent.
#[test]
fn a_claimed_answer_is_not_cancelled_and_still_finishes() {
    let flights = InFlight::default();
    let sent = flights.begin(&json!(1), "_acpmux/sessions", None, None);
    let lost = flights.begin(&json!(2), "_acpmux/sessions", None, None);
    assert!(flights.claim(&sent.claim().unwrap()));
    assert_eq!(flights.cancel(&json!(1)), None, "nothing left to cancel");
    assert!(flights.finish(&sent), "it sent its answer");
    assert!(flights.cancel(&json!(2)).is_some());
    assert!(!flights.claim(&lost.claim().unwrap()), "the cancel answered it");
    assert!(!flights.finish(&lost));
    assert_eq!(flights.len(), 0);
}
