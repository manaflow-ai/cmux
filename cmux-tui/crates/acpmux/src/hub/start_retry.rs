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
//!   whose start had not begun is queued again by the next daemon, `unstarted_prompt.rs`). Stop,
//!   the chat's stop and the shutdown wake the wait at once (`Session::start_retry_wake`). A turn
//!   the shutdown ended writes no failed end: the shutdown settles it (`Hub::shutdown_settles`).
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
        // The shutdown owns the turn from here (`shutdown.rs`): it hands it to the next daemon,
        // or Quit Everything ends it cancelled. The turn writes no end of its own.
        if self.shutting_down() {
            return Some(Some(shutdown_owns()));
        }
        if session.moving().is_some() || session.replaced.load(Ordering::SeqCst) {
            return Some(None);
        }
        None
    }
}

/// A waiting start the daemon's shutdown ended: its turn is the shutdown's to settle.
fn shutdown_owns() -> RpcError {
    super::shutdown::shutting_down_error().with_data(json!({"reason": SHUTDOWN_OWNS}))
}

const SHUTDOWN_OWNS: &str = "start_retry.shutdown";

impl Hub {
    /// Whether a turn whose agent did not start ended under the shutdown, which settles it: the
    /// shutdown took it (`settled_by_shutdown`), or ended its waiting start ([`shutdown_owns`]).
    /// Such a turn writes no failed end, so the next daemon still finds its prompt unstarted and
    /// queues it again (`unstarted_prompt.rs`).
    pub(super) fn shutdown_settles(&self, turn_id: &str, e: &RpcError) -> bool {
        let field = e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str);
        field == Some(SHUTDOWN_OWNS)
            || self.settled_by_shutdown.lock().unwrap_or_else(|e| e.into_inner()).contains(turn_id)
    }

    /// The shutdown began: every start that waits to be tried again ends its wait now.
    pub(super) fn wake_start_retries(&self) {
        for s in self.sessions() {
            s.start_retry_wake.notify_waiters();
        }
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

    /// A shutdown while a prompt's start waits to be tried again ends the wait, and the turn
    /// writes no failed end: the shutdown settles it, and the next daemon finds the prompt
    /// unstarted and queues it again (`unstarted_prompt.rs`).
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_shutdown_during_the_wait_leaves_the_turn_to_the_shutdown() {
        use crate::config::{Config, StoreMode};
        const WAIT: Duration = Duration::from_secs(30);
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let gate = std::env::temp_dir().join(format!("acpmux-retry-down-{}", uuid::Uuid::now_v7()));
        std::fs::write(&gate, b"").unwrap();
        let env = format!("FAKE_START_GATE={}", gate.display());
        let cfg = json!({"harnesses": {"fake": {"argv": ["/usr/bin/env", env, "python3", fake]}},
            "defaultHarness": "fake"});
        let mut cfg: Config = serde_json::from_value(cfg).unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        let s = hub.new_session(req).await.unwrap();
        hub.kill(&s, false).await.unwrap();
        std::fs::remove_file(&gate).unwrap();
        // A 900 ms budget waits 100 ms before its first retry.
        hub.config.write().await.agent_start_timeout_ms = Some(900);
        let run = {
            let (hub, s) = (hub.clone(), s.clone());
            let blocks = vec![json!({"type": "text", "text": "hello"})];
            tokio::spawn(async move { hub.prompt(&s, blocks, "test", false).await })
        };
        let kinds = |kind: &str| -> Vec<Value> {
            let events = hub.events(&s.id, 0, 100_000).unwrap();
            events.into_iter().filter(|e| e.kind == kind).map(|e| e.msg).collect()
        };
        let retrying = async {
            while kinds("agent_start_retrying").is_empty() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        };
        tokio::time::timeout(WAIT, retrying).await.expect("the start was never tried again");
        hub.begin_shutdown();
        let answer =
            tokio::time::timeout(WAIT, run).await.expect("the prompt never ended").unwrap();
        assert!(answer.is_err(), "{answer:?}");
        let turn = kinds("agent_start_retrying")[0]["turnId"].clone();
        let ended: Vec<_> =
            kinds("turn_result").into_iter().filter(|m| m["turnId"] == turn).collect();
        assert!(ended.is_empty(), "the turn wrote its own end under the shutdown: {ended:?}");
        assert!(kinds("turn_started").iter().all(|m| m["turnId"] != turn));
        // Still open for the shutdown to hand on or end.
        assert_eq!(s.turn().map(|t| json!(t.turn_id)), Some(turn));
        assert_eq!(kinds("agent_start_retrying").len(), 1, "a start ran after the shutdown");
        let _ = std::fs::remove_file(&gate);
    }
}
