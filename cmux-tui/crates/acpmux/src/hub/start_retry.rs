//! Part of `Hub`; see `hub/mod.rs`. A prompt whose agent start missed `agentStartTimeoutMs`
//! (`agent_start did not finish within 90s`, `lifecycle.rs`) is pending, not failed: its turn
//! stays open and the same prompt's start is tried again after a wait, up to
//! [`START_RETRIES`] times. Before this the turn ended failed on the first miss and nothing sent
//! the prompt again, so a lane whose harness started slowly on a loaded machine sat idle with its
//! prompt dropped until someone noticed.
//!
//! - Only a missed deadline is retried (`data.reason` `deadline_exceeded`, `data.wait`
//!   `agent_start`). A start that failed (its harness exited, a refused key, no login) or whose
//!   harness did no work (`harness_hung`) fails at once, as before.
//! - Each try is a whole start through `child_for_since`: under the spawn lock it reaches a live
//!   agent or a still-running agent host first (`reach_or_start`), so a start that finished late
//!   is used, never doubled. A missed try's agent was ended by its deadline
//!   (`abandon_cold_start`), so none is left running.
//! - The waits double from [`first_wait`] (10, 20, 40 s at the 90 s default). One sleep per
//!   waiting turn, no timer per session.
//! - What ends the wait before its next try: a Stop of the turn (it ends cancelled), a stop,
//!   close or delete of the chat, its move to another daemon, or the daemon's shutdown (a turn
//!   whose start had not begun is queued again by the next daemon, `unstarted_prompt.rs`). Stop
//!   and the chat's stop wake the wait at once (`Session::start_retry_wake`).
//! - The log says so: `agent_start_retrying` `{turnId, promptId, attempt, of, delayMs, error}`
//!   before each wait. While it waits the row reads `starting`. When the tries run out the turn
//!   ends failed with the last deadline error, which names how many tries it took.

use super::*;
use std::time::Duration;

/// How many more times a prompt's start is tried after its first missed deadline.
pub(super) const START_RETRIES: u32 = 3;

/// The wait before the first retry: a ninth of the start budget, between 100 ms and 30 s.
fn first_wait(budget: Duration) -> Duration {
    (budget / 9).clamp(Duration::from_millis(100), Duration::from_secs(30))
}

/// Whether `e` is `agent_start`'s missed deadline (`RpcError::deadline_exceeded`).
pub(super) fn is_start_deadline(e: &RpcError) -> bool {
    let field = |k: &str| e.data.as_ref().and_then(|d| d.get(k)).and_then(Value::as_str);
    field("reason") == Some("deadline_exceeded") && field("wait") == Some("agent_start")
}

/// The row reads `starting` while the wait lasts, however it ends.
struct Waiting<'a> {
    session: &'a Session,
    events: &'a super::list_guard::Events,
}

impl<'a> Waiting<'a> {
    fn begin(session: &'a Session, events: &'a super::list_guard::Events) -> Self {
        session.start_retry_waits.store(true, Ordering::SeqCst);
        events.changed();
        Self { session, events }
    }
}

impl Drop for Waiting<'_> {
    fn drop(&mut self) {
        self.session.start_retry_waits.store(false, Ordering::SeqCst);
        self.events.changed();
    }
}

impl Hub {
    /// `started`, the first start of turn `turn_id`'s agent, or when it missed its deadline the
    /// start tried again after a wait (the module doc). `stops` and `cancels` are the chat's
    /// stop and Stop counts when the prompt came.
    pub(super) async fn retry_late_start(
        self: &Arc<Self>,
        session: &Arc<Session>,
        stops: u64,
        cancels: u64,
        prompt_id: &str,
        turn_id: &str,
        mut started: Result<Arc<ChildAgent>, RpcError>,
    ) -> Result<Arc<ChildAgent>, RpcError> {
        let mut wait = first_wait(self.config.read().await.agent_start_timeout());
        let mut attempt = 0;
        loop {
            let e = match started {
                Err(e) if is_start_deadline(&e) => e,
                done => return done,
            };
            if attempt == START_RETRIES {
                return Err(gave_up(e, attempt + 1));
            }
            attempt += 1;
            // Registered before the checks: a Stop between them and the sleep still wakes it.
            let woken = session.start_retry_wake.notified();
            tokio::pin!(woken);
            woken.as_mut().enable();
            if let Some(end) = self.start_retry_ended(session, stops, cancels, turn_id) {
                return Err(end.unwrap_or(e));
            }
            let delay_ms = u64::try_from(wait.as_millis()).unwrap_or(u64::MAX);
            tracing::warn!(session = %session.id, attempt, delay_ms, "agent start missed its deadline; trying again: {}", e.message);
            self.append(
                session,
                "mux",
                "agent_start_retrying",
                json!({"turnId": turn_id, "promptId": prompt_id, "attempt": attempt, "of": START_RETRIES, "delayMs": delay_ms, "error": e.message}),
            );
            {
                let _waiting = Waiting::begin(session, &self.events);
                tokio::select! {
                    () = tokio::time::sleep(wait) => {}
                    () = woken => {}
                }
            }
            if let Some(end) = self.start_retry_ended(session, stops, cancels, turn_id) {
                return Err(end.unwrap_or(e));
            }
            wait = wait.saturating_mul(2);
            started = Box::pin(self.child_for_since(session, stops)).await;
        }
    }

    /// Why a waiting start is not tried again, if it is not: `Some(Some(e))` ends the turn with
    /// `e`, `Some(None)` with the last deadline error.
    fn start_retry_ended(
        &self,
        session: &Session,
        stops: u64,
        cancels: u64,
        turn_id: &str,
    ) -> Option<Option<RpcError>> {
        // A Stop of the turn: it ends cancelled, as one during any start does.
        if session.cancels.load(Ordering::SeqCst) != cancels
            || super::cancel::is_stopping(session, turn_id)
        {
            return Some(Some(super::turns::stopped_before_prompt()));
        }
        if session.stops.load(Ordering::SeqCst) != stops
            || session.status() == SessionStatus::Closed
            || session.purged.load(Ordering::SeqCst)
        {
            return Some(Some(super::lifecycle::stopped_while_starting()));
        }
        if self.shutting_down() {
            return Some(Some(super::shutdown::shutting_down_error()));
        }
        if session.moving().is_some() || session.replaced.load(Ordering::SeqCst) {
            return Some(None);
        }
        None
    }
}

/// The last deadline error once the tries ran out: it says how many there were.
fn gave_up(mut e: RpcError, tries: u32) -> RpcError {
    e.message.push_str(&format!("; its start was tried {tries} times"));
    if let Some(data) = e.data.as_mut().and_then(Value::as_object_mut) {
        data.insert("tries".into(), json!(tries));
    }
    e
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_waits_scale_with_the_start_budget() {
        assert_eq!(first_wait(Duration::from_secs(90)), Duration::from_secs(10));
        assert_eq!(first_wait(Duration::from_millis(300)), Duration::from_millis(100));
        assert_eq!(first_wait(Duration::from_secs(3600)), Duration::from_secs(30));
    }

    #[test]
    fn only_a_missed_start_deadline_is_retried() {
        let late = RpcError::deadline_exceeded("agent_start", Duration::from_secs(90));
        assert!(is_start_deadline(&late));
        assert!(!is_start_deadline(&RpcError::deadline_exceeded("session/load", Duration::ZERO)));
        assert!(!is_start_deadline(&RpcError::internal("agent process closed")));
        let gave_up = gave_up(late, 4);
        assert!(gave_up.message.contains("agent_start did not finish within"), "{gave_up:?}");
        assert!(gave_up.message.ends_with("tried 4 times"), "{gave_up:?}");
    }
}
