//! The hand's idle stops (`Agents::idle_stops`): no periodic sweep, one deadline per
//! session, and a failed stop tried again only at its retry time. Paused tokio time; the
//! session's daemon connection is closed, so each stop fails at once and leaves its
//! `retry_at`, which shows when the stop was tried.

use super::{Agents, IDLE_STOP_RETRY, Session, idle_deadline};
use crate::client::Client;
use std::time::Duration;
use tokio::time::{Instant, sleep, sleep_until};

const LIMIT: Duration = Duration::from_secs(30 * 60);
/// Within this of the deadline counts as on time (the timer wheel rounds to its tick).
const TICK: Duration = Duration::from_secs(1);

fn agents_with(id: &str, busy: bool) -> (Agents, tokio::sync::mpsc::Receiver<serde_json::Value>) {
    let agents = Agents::default();
    let (sink, events) = tokio::sync::mpsc::channel(8);
    let session = Session {
        cwd: "/".into(),
        client: Client::closed_for_test(),
        route: None,
        sink,
        last: Instant::now(),
        busy,
        retry_at: None,
    };
    agents.sessions.lock().unwrap().insert(id.to_owned(), session);
    (agents, events)
}

fn start(agents: &Agents) -> tokio::task::JoinHandle<()> {
    let agents = agents.clone();
    tokio::spawn(async move { agents.idle_stops(LIMIT).await })
}

fn retry_at(agents: &Agents, id: &str) -> Option<Instant> {
    agents.sessions.lock().unwrap().get(id).and_then(|s| s.retry_at)
}

/// A stop tried at `at` leaves `retry_at` one retry later.
fn tried_at(agents: &Agents, id: &str) -> Option<Instant> {
    retry_at(agents, id).map(|retry| retry - IDLE_STOP_RETRY)
}

#[test]
fn a_running_turn_has_no_idle_deadline() {
    assert_eq!(idle_deadline(true, Instant::now(), None, LIMIT), None);
}

#[test]
fn an_idle_session_is_due_one_limit_after_its_last_activity() {
    let last = Instant::now();
    assert_eq!(idle_deadline(false, last, None, LIMIT), Some(last + LIMIT));
}

#[test]
fn a_failed_stop_is_due_again_at_its_retry_not_at_once() {
    let last = Instant::now();
    let retry = last + LIMIT + Duration::from_secs(60);
    assert_eq!(idle_deadline(false, last, Some(retry), LIMIT), Some(retry));
    // Activity after the failure moves the deadline past the retry.
    let later = retry + Duration::from_secs(1);
    assert_eq!(idle_deadline(false, later, Some(retry), LIMIT), Some(later + LIMIT));
}

#[tokio::test(start_paused = true)]
async fn a_running_turn_is_never_stopped_for_idleness() {
    let (agents, _events) = agents_with("s", true);
    let task = start(&agents);
    sleep(LIMIT * 3).await;
    assert_eq!(retry_at(&agents, "s"), None, "a stop was tried while the turn ran");
    assert!(agents.sessions.lock().unwrap().contains_key("s"));
    task.abort();
}

#[tokio::test(start_paused = true)]
async fn a_turn_end_while_waiting_arms_the_stop_at_last_activity_plus_the_limit() {
    let (agents, _events) = agents_with("s", true);
    let task = start(&agents);
    // The task waits for a turn's end: every turn runs.
    sleep(Duration::from_secs(5)).await;
    agents.touch("s", Some(false));
    let last = Instant::now();
    sleep_until(last + LIMIT - TICK).await;
    assert_eq!(retry_at(&agents, "s"), None, "a stop was tried before the limit");
    sleep_until(last + LIMIT + TICK).await;
    let tried = tried_at(&agents, "s").expect("no stop was tried at the limit");
    assert!(tried >= last + LIMIT && tried < last + LIMIT + TICK, "tried {:?} late", tried - last);
    task.abort();
}

#[tokio::test(start_paused = true)]
async fn a_failed_stop_is_not_tried_again_before_its_retry_time() {
    let (agents, _events) = agents_with("s", false);
    let last = Instant::now();
    let task = start(&agents);
    sleep_until(last + LIMIT + TICK).await;
    let first = retry_at(&agents, "s").expect("no stop was tried at the limit");
    sleep_until(first - TICK).await;
    assert_eq!(retry_at(&agents, "s"), Some(first), "the stop went again before its retry time");
    sleep_until(first + TICK).await;
    let second = tried_at(&agents, "s").expect("the stop was not tried again");
    assert!(second >= first && second < first + TICK, "retried {:?} late", second - first);
    assert!(agents.sessions.lock().unwrap().contains_key("s"), "a failed stop dropped the session");
    task.abort();
}
