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
//! - A Stop of the turn while a retry's start runs ends that start, as a stop of the chat ends
//!   any start (`stopped_during_retry`, raced by the cold start in `lifecycle.rs`): its agent is
//!   ended and the turn ends cancelled.
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
//!   the shutdown ended writes no failed end: the shutdown settles it
//!   (`Hub::fail_unless_shutdown_settles`), decided under the lock its sweep takes the turn under.
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
        events.row_changed(session);
        Self { session, events }
    }
}

impl Drop for Waiting<'_> {
    fn drop(&mut self) {
        self.session.start_retry_waits.store(false, Ordering::SeqCst);
        self.events.row_changed(self.session);
    }
}

/// No retry's start runs ([`Session::start_retry_cancels`]).
pub(super) const NO_RETRY: u64 = u64::MAX;

/// While a retry's start runs, a Stop of its turn ends it: the turn's Stop count is set aside
/// for `stopped_during_retry`.
struct RetryFence<'a>(&'a Session);

impl<'a> RetryFence<'a> {
    fn new(session: &'a Session, cancels: u64) -> Self {
        session.start_retry_cancels.store(cancels, Ordering::SeqCst);
        Self(session)
    }
}

impl Drop for RetryFence<'_> {
    fn drop(&mut self) {
        self.0.start_retry_cancels.store(NO_RETRY, Ordering::SeqCst);
    }
}

/// Ends when a Stop came for the turn whose retry's start runs now (`RetryFence`); never for
/// any other start. The cold start races it (`lifecycle.rs`) and ends what it started.
pub(super) async fn stopped_during_retry(session: &Session) {
    let epoch = session.start_retry_cancels.load(Ordering::SeqCst);
    if epoch == NO_RETRY {
        return std::future::pending().await;
    }
    loop {
        let woken = session.start_retry_wake.notified();
        tokio::pin!(woken);
        woken.as_mut().enable();
        if session.cancels.load(Ordering::SeqCst) != epoch {
            return;
        }
        woken.await;
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
        started: Result<Arc<ChildAgent>, RpcError>,
    ) -> Result<Arc<ChildAgent>, RpcError> {
        self.retry_late_start_with(
            session,
            stops,
            cancels,
            prompt_id,
            turn_id,
            started,
            START_RETRIES,
        )
        .await
    }

    /// [`Hub::retry_late_start`] with at most `retries` retries.
    #[allow(clippy::too_many_arguments)]
    async fn retry_late_start_with(
        self: &Arc<Self>,
        session: &Arc<Session>,
        stops: u64,
        cancels: u64,
        prompt_id: &str,
        turn_id: &str,
        mut started: Result<Arc<ChildAgent>, RpcError>,
        retries: u32,
    ) -> Result<Arc<ChildAgent>, RpcError> {
        let mut wait = first_wait(self.config.read().await.agent_start_timeout());
        let mut attempt = 0;
        loop {
            let e = match started {
                Err(e) if is_start_deadline(&e) => e,
                done => return done,
            };
            // Registered before the checks: a Stop between them and the sleep still wakes it.
            let woken = session.start_retry_wake.notified();
            tokio::pin!(woken);
            woken.as_mut().enable();
            // Before the give-up too: a shutdown that began as the last try missed its deadline
            // settles the turn, which then writes no failed end of its own.
            if let Some(end) = self.start_retry_ended(session, stops, cancels, turn_id) {
                return Err(end.unwrap_or(e));
            }
            if attempt == retries {
                return Err(gave_up(e, attempt + 1));
            }
            attempt += 1;
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
            // A Stop of the turn ends this try's start as a stop of the chat ends any start
            // (`stopped_during_retry`): no other full start runs after it.
            let _fence = RetryFence::new(session, cancels);
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
    /// Ends turn `turn_id`, whose agent did not start with `e`, failed (`fail_unstarted_turn`),
    /// unless the shutdown settles it: the shutdown took it (`settled_by_shutdown`), ended its
    /// waiting start ([`shutdown_owns`]), or began before this end. Such a turn writes no failed
    /// end, so the next daemon still finds its prompt unstarted and queues it again
    /// (`unstarted_prompt.rs`). Decided and written under the shutdown's lock, which the shutdown
    /// begins under (`start_shutdown`) and its sweep takes each turn under (`shutdown_sessions`):
    /// the end is written wholly before the shutdown began, or not at all. True when it failed
    /// the turn.
    pub(super) fn fail_unless_shutdown_settles(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
        turn_id: &str,
        e: &RpcError,
        joined: &super::digest::DigestTurn,
    ) -> bool {
        let ends = self.settled_by_shutdown.lock().unwrap_or_else(|e| e.into_inner());
        let field = e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str);
        // A Stop's own end (`stopped_before_prompt`) is written as ever: the Stop settled it.
        let began = self.shutting_down() && field != Some("stopped");
        if field == Some(SHUTDOWN_OWNS) || ends.contains(turn_id) || began {
            return false;
        }
        // Tests only: hold here, between the check and the write.
        #[cfg(test)]
        {
            let seam = self.settle_seam.lock().unwrap_or_else(|e| e.into_inner()).take();
            if let Some((arrived, release)) = seam {
                let _ = arrived.send(());
                let _ = release.blocking_recv();
            }
        }
        self.fail_unstarted_turn(session, prompt_id, turn_id, e, joined);
        drop(ends);
        true
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

    const WAIT: Duration = Duration::from_secs(30);

    /// A hub whose one chat's agent is stopped and starts only once the returned gate file
    /// exists (`FAKE_START_GATE`, removed), under a start budget of `budget_ms`.
    async fn gated(budget_ms: u64) -> (Arc<Hub>, Arc<Session>, std::path::PathBuf) {
        use crate::config::{Config, StoreMode};
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let gate = std::env::temp_dir().join(format!("acpmux-retry-{}", uuid::Uuid::now_v7()));
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
        hub.config.write().await.agent_start_timeout_ms = Some(budget_ms);
        (hub, s, gate)
    }

    fn send(hub: &Arc<Hub>, s: &Arc<Session>) -> tokio::task::JoinHandle<Result<Value, RpcError>> {
        let (hub, s) = (hub.clone(), s.clone());
        let blocks = vec![json!({"type": "text", "text": "hello"})];
        tokio::spawn(async move { hub.prompt(&s, blocks, "test", false).await })
    }

    fn kinds(hub: &Hub, s: &Session, kind: &str) -> Vec<Value> {
        let events = hub.events(&s.id, 0, 100_000).unwrap();
        events.into_iter().filter(|e| e.kind == kind).map(|e| e.msg).collect()
    }

    async fn until(what: &str, check: impl Fn() -> bool) {
        let wait = async {
            while !check() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        };
        tokio::time::timeout(WAIT, wait).await.unwrap_or_else(|_| panic!("{what}"));
    }

    /// Review finding: a Stop that came just after the wait's last check, as the retry's start
    /// began, let that whole start run on (another missed deadline, or an agent left up for a
    /// stopped turn). The Stop ends the retry's start as a stop of the chat ends any start. The
    /// 9 s budget waits 1 s before the retry; the Stop lands inside its start.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_stop_while_the_retrys_start_runs_ends_that_start() {
        let (hub, s, gate) = gated(9_000).await;
        let run = send(&hub, &s);
        until("the start was never tried again", || {
            !kinds(&hub, &s, "agent_start_retrying").is_empty()
        })
        .await;
        until("the retry's start never began", || {
            s.start_retry_cancels.load(Ordering::SeqCst) != NO_RETRY
                && s.spawn_lock.try_lock().is_err()
        })
        .await;
        let stopped_at = std::time::Instant::now();
        let _ = hub.cancel(&s).await;
        let answer =
            tokio::time::timeout(WAIT, run).await.expect("the prompt never ended").unwrap();
        let took = stopped_at.elapsed();
        let e = answer.expect_err("a stopped prompt was answered");
        assert_eq!(e.data.as_ref().map(|d| d["reason"].clone()), Some(json!("stopped")), "{e:?}");
        assert!(
            took < Duration::from_secs(5),
            "the retry's start ran on for {took:?} after the Stop"
        );
        assert_eq!(kinds(&hub, &s, "agent_start_timed_out").len(), 1, "the retry's start ran out");
        assert_eq!(kinds(&hub, &s, "agent_start_stopped").len(), 1);
        assert!(s.child.lock().await.is_none(), "the stopped start's agent was left up");
        let results = kinds(&hub, &s, "turn_result");
        assert_eq!(results.last().unwrap()["status"], "cancelled", "{results:?}");
        let _ = std::fs::remove_file(&gate);
    }

    /// Review finding: a shutdown that began after the give-up's own check, before its turn
    /// was ended, still got a failed end, which kept the next daemon from queueing the prompt
    /// again. The end is decided under the shutdown's lock, and a shutdown that began settles it.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_shutdown_after_the_give_up_check_still_settles_the_turn() {
        let (hub, s, gate) = gated(900).await;
        let late = RpcError::deadline_exceeded("agent_start", Duration::from_millis(900));
        // The give-up passed its checks (no shutdown yet), then the shutdown began.
        let e = gave_up(late, 4);
        hub.begin_shutdown();
        let joined = super::super::digest::DigestTurn::default();
        let failed = hub.fail_unless_shutdown_settles(&s, "p", "t", &e, &joined);
        assert!(!failed, "the turn was failed under the shutdown");
        let ended = kinds(&hub, &s, "turn_result");
        assert!(ended.iter().all(|m| m["turnId"] != "t"), "{ended:?}");
        // A Stop's end is still the Stop's.
        let stopped = super::super::turns::stopped_before_prompt();
        assert!(hub.fail_unless_shutdown_settles(&s, "p2", "t2", &stopped, &joined));
        let _ = std::fs::remove_file(&gate);
    }

    /// Review finding: the shutdown began under another lock than the one this end is decided
    /// under, so it could begin between the check and the failed end's write. Held between
    /// the two, the end keeps the shutdown from beginning until its write is done.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn the_shutdown_cannot_begin_between_the_check_and_the_failed_end() {
        let (hub, s, gate) = gated(900).await;
        let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
        let (release, release_rx) = tokio::sync::oneshot::channel();
        *hub.settle_seam.lock().unwrap() = Some((arrived_tx, release_rx));
        let ending = {
            let (hub, s) = (hub.clone(), s.clone());
            tokio::task::spawn_blocking(move || {
                let late = RpcError::deadline_exceeded("agent_start", Duration::from_millis(900));
                let joined = super::super::digest::DigestTurn::default();
                hub.fail_unless_shutdown_settles(&s, "p", "t", &gave_up(late, 4), &joined)
            })
        };
        tokio::time::timeout(WAIT, arrived).await.expect("the end never reached its write").ok();
        // The shutdown begins now, from another thread, while the end holds before its write.
        let (began_tx, began) = std::sync::mpsc::channel();
        let shutting = {
            let hub = hub.clone();
            std::thread::spawn(move || {
                hub.begin_shutdown();
                let _ = began_tx.send(());
            })
        };
        let began_first = began.recv_timeout(Duration::from_secs(1)).is_ok();
        release.send(()).unwrap();
        let failed = ending.await.unwrap();
        shutting.join().unwrap();
        assert!(!began_first, "the shutdown began between the check and the failed end's write");
        // Checked before the shutdown began: the turn's failure is its own, written before it.
        assert!(failed);
        let ended = kinds(&hub, &s, "turn_result");
        assert!(ended.iter().any(|m| m["turnId"] == "t" && m["status"] == "failed"), "{ended:?}");
        let _ = std::fs::remove_file(&gate);
    }

    /// Review finding: a person's prompt while a lane's retry waited made the retry's start
    /// wait on its harness with no deadline, and that wait did not race the Stop: the Stop
    /// could not end the start, and its agent stayed up. The Stop ends it however it waits.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_stop_ends_a_retrys_start_after_the_person_took_the_chat() {
        let (hub, s, gate) = gated(9_000).await;
        let run = send(&hub, &s);
        until("the start was never tried again", || {
            !kinds(&hub, &s, "agent_start_retrying").is_empty()
        })
        .await;
        // The person writes in the chat: its next start waits on its harness.
        s.person.store(true, Ordering::SeqCst);
        until("the retry's start never began", || {
            s.start_retry_cancels.load(Ordering::SeqCst) != NO_RETRY
                && s.spawn_lock.try_lock().is_err()
        })
        .await;
        let stopped_at = std::time::Instant::now();
        let _ = hub.cancel(&s).await;
        let answer = tokio::time::timeout(WAIT, run).await.expect("the Stop did not end the start");
        let took = stopped_at.elapsed();
        let e = answer.unwrap().expect_err("a stopped prompt was answered");
        assert_eq!(e.data.as_ref().map(|d| d["reason"].clone()), Some(json!("stopped")), "{e:?}");
        assert!(took < Duration::from_secs(5), "the start ran on for {took:?} after the Stop");
        assert_eq!(kinds(&hub, &s, "agent_start_stopped").len(), 1);
        assert!(s.child.lock().await.is_none(), "the stopped start's agent was left up");
        let _ = std::fs::remove_file(&gate);
    }

    /// Review finding: the last try missing its deadline as a shutdown begins gave up with a
    /// failed end, which the turn wrote before the shutdown took it, so the next daemon did not
    /// queue the prompt again. The shutdown settles it instead.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_shutdown_as_the_last_try_misses_leaves_the_turn_to_the_shutdown() {
        let (hub, s, gate) = gated(900).await;
        // Reopened, as the prompt whose start this is reopens its stopped chat.
        assert!(hub.reopen(&s, s.stops.load(Ordering::SeqCst)), "the chat did not reopen");
        hub.begin_shutdown();
        let late = RpcError::deadline_exceeded("agent_start", Duration::from_millis(900));
        let (stops, cancels) = (s.stops.load(Ordering::SeqCst), s.cancels.load(Ordering::SeqCst));
        let ended = hub.retry_late_start_with(&s, stops, cancels, "p", "t", Err(late), 0).await;
        let Err(e) = ended else { panic!("a start ran under the shutdown") };
        let joined = super::super::digest::DigestTurn::default();
        let failed = hub.fail_unless_shutdown_settles(&s, "p", "t", &e, &joined);
        assert!(!failed, "the turn wrote a failed end: {e:?}");
        let _ = std::fs::remove_file(&gate);
    }

    /// A shutdown while a prompt's start waits to be tried again ends the wait, and the turn
    /// writes no failed end: the shutdown settles it, and the next daemon finds the prompt
    /// unstarted and queues it again (`unstarted_prompt.rs`).
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_shutdown_during_the_wait_leaves_the_turn_to_the_shutdown() {
        // A 900 ms budget waits 100 ms before its first retry.
        let (hub, s, gate) = gated(900).await;
        let run = send(&hub, &s);
        let kinds = |kind: &str| kinds(&hub, &s, kind);
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

    /// Cloud chaos fault `daemon-restart-session-new` (staging, f1c3afd06): the daemon got
    /// SIGTERM while a chat's first prompt started its agent, and the prompt was answered with
    /// what the shutdown did to that start ("no agent session", "agent process closed"), which
    /// the CLI types as a non-retryable `agent_error`. The shutdown hands the turn to the next
    /// daemon, so the prompt hears that the daemon is restarting, as a restart mid-turn does.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_restart_while_the_agent_starts_answers_that_the_daemon_restarts() {
        // A 9 s budget: the start is in flight, not waiting to be tried again.
        let (hub, s, gate) = gated(9_000).await;
        let run = send(&hub, &s);
        until("the agent start never began", || {
            s.spawn_lock.try_lock().is_err() && s.child.try_lock().is_ok_and(|c| c.is_some())
        })
        .await;
        hub.shutdown_all().await;
        let answer =
            tokio::time::timeout(WAIT, run).await.expect("the prompt never ended").unwrap();
        let e = answer.expect_err("a prompt whose agent never started was answered");
        assert_eq!(e.message, crate::hub::SHUTTING_DOWN, "{e:?}");
        // The next daemon queues it again (`unstarted_prompt.rs`): no end of its own.
        let ended = kinds(&hub, &s, "turn_result");
        assert!(ended.iter().all(|m| m["status"] != "failed"), "{ended:?}");
        let _ = std::fs::remove_file(&gate);
    }
}
