//! A Claude subagent that failed on a transient upstream error is resumed (Leo, 2026-10-26:
//! "this needs to retry :("). Two of his chat's subagents ended "Subagent failed" on SR2's
//! "API Error: 503 no non-exhausted claude accounts available"; the chat's own turn did not
//! fail, so a turn retry (`auto_resume.rs`) never saw them.
//!
//! What acpmux sees: Claude Code ends a background agent with a `task_notification` (a
//! foreground one with its Agent call's error result) whose `summary` is the error and whose
//! `task_id` is the agent id SendMessage resumes it by. The translator puts both on the
//! subagent's `failed` end (`error`, `agentId`), and reports a SendMessage resume as that
//! subagent `running` again (`claude_stdio/inbound.rs`).
//!
//! - A top-level subagent that ended `failed` with an agent id and a transient error
//!   ([`super::turn_errors::transient_cause`]: capacity or transport) waits `autoResumeDelaysMs`
//!   (the turn retry's waits, staggered alike), then the parent chat gets one prompt, in the same
//!   session, that tells its agent to resume that subagent with SendMessage to its agent id, and
//!   to start a new one only when the resume fails. Its `user_message` carries
//!   `_meta.provenance = {kind: "subagent_retry", subagentId, agentId, attempt}`.
//! - A turn acpmux runs then: the prompt waits in the queue behind it, never steered in. Claude
//!   Code's own turn (one it started for a task notification, which acpmux never prompted) runs
//!   from its `system/init` to its `result` (`Session::harness_turn`); the prompt is sent only
//!   once it ended, as for a turn continuation that may still fire. The two processes share no
//!   lock: a notification turn Claude Code starts in the moment the prompt is written is the
//!   same race any person's prompt has, and the translator pairs results with prompts.
//! - Skipped on Stop or close, when the subagent runs again (resumed: its `running` update, or
//!   Claude Code's raw `task_started` for its agent id, which still comes when the translator
//!   forgot the agent) or ends, and when the chat starts another top-level subagent of the same
//!   name (replaced). A prompt that went out is taken back then: out of the queue
//!   (`queue_removed`), and refused if it would start later (`Hub::start_turn` asks
//!   [`Retries::start`], under the lock a skip takes). One that started already is the agent's
//!   to answer (it says to do nothing when the subagent already runs).
//! - Once its prompt's turn ends with the subagent still failed (the agent did not resume it),
//!   or it fails again, the next attempt waits; after the configured attempts it is given up
//!   (`exhausted`). A person's retry (`_acpmux/retry {sessionId, subagentId}`) fires a waiting
//!   attempt now, or sends one more (`subagent_retry/manual.rs`).
//! - While a retry waits, the subagent's entry in `_meta.acpmux.subagents` carries
//!   `retry: {attempt, of, reason, nextAt}` (`nextAt` in Unix ms). `retryable` says whether a
//!   person's retry can work: true while acpmux knows its agent id and the chat is open, after a
//!   Stop and after the automatic attempts are used up too; false once the chat closed, or the
//!   subagent runs again, ended, was replaced or was forgotten. The same update is logged again
//!   when the retry fires (`retry: null`), is skipped or is given up, and each step logs `subagent_retry {subagentId, agentId, attempt,
//!   of, reason, outcome, nextAt?, promptId?, skipped?}`, `outcome` one of `scheduled`, `fired`,
//!   `skipped` or `exhausted`.
//! - A wait is not persisted: a daemon restart drops it. A chat keeps at most [`MAX_FAILED`]
//!   failed subagents no retry waits for (given up or stopped, for a person's retry): past
//!   that the oldest is forgotten, checked whenever one fails, is stopped or is given up. All
//!   go at close, each entry then `retryable: false`.

use super::{Hub, PromptOptions, Session, SessionStatus};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::Notify;

/// The provenance kind of the prompt that asks for a subagent's resume.
pub const PROVENANCE_KIND: &str = "subagent_retry";

/// Longest error text quoted to the agent, in characters.
const MAX_ERROR_CHARS: usize = 300;

/// Most failed subagents a chat keeps with no retry waiting; the oldest failure goes first.
const MAX_FAILED: usize = 32;

/// The retries, and `steps`: held through each change that logs a record together with that
/// record (a failure observed, a Stop or close, a wait planned, given up, fired or skipped), so
/// the records come in the order the changes did. Taken before the state's lock, never inside.
#[derive(Default)]
pub(crate) struct Retries(Mutex<State>, Mutex<()>);

#[derive(Default)]
struct State {
    /// Each chat's top-level subagents, by id, while they run, or failed and may be retried.
    subs: HashMap<String, HashMap<String, Sub>>,
    /// Retry prompts sent and not answered yet, by chat and prompt id: true once their retry
    /// was skipped, so a prompt that has not started is refused.
    sent: HashMap<(String, String), bool>,
    /// Each chat's last [`MAX_GONE`] failed subagents that can no longer be retried, oldest
    /// first, and why: what a person's retry of one answers (`manual.rs`).
    gone: HashMap<String, VecDeque<Gone>>,
}

/// A failed subagent no retry can bring back: its id, agent id and why (`resumed`, `replaced`,
/// `ended`, `forgotten` or `not_retryable`).
struct Gone {
    id: String,
    agent_id: Option<String>,
    why: &'static str,
}

/// Most subagents a chat remembers as no longer retryable.
const MAX_GONE: usize = 64;

/// Remembers in a chat's `gone` that its subagent `id` can no longer be retried, and why.
fn note_gone(gone: &mut VecDeque<Gone>, id: &str, agent_id: Option<&str>, why: &'static str) {
    gone.retain(|g| g.id != id);
    if gone.len() >= MAX_GONE {
        gone.pop_front();
    }
    gone.push_back(Gone { id: id.to_owned(), agent_id: agent_id.map(str::to_owned), why });
}

#[derive(Default)]
struct Sub {
    name: Option<String>,
    /// Attempts fired at it so far.
    attempts: usize,
    failed: Option<Failure>,
    /// The agent id of a resume only Claude Code's raw `task_started` showed (the translator
    /// forgot the agent): its raw `task_notification` then ends it here.
    raw_agent: Option<String>,
}

#[derive(Clone)]
struct Failure {
    agent_id: String,
    error: String,
    reason: &'static str,
    /// When it failed, in Unix ms.
    at: u64,
    /// Stopped or given up: no automatic attempt comes (counted against [`MAX_FAILED`]).
    idle: bool,
    wait: Option<Wait>,
}

/// One attempt, from its scheduling until its prompt's turn ends. Told apart by `wake`.
#[derive(Clone)]
struct Wait {
    attempt: usize,
    of: usize,
    next_at: u64,
    prompt_id: String,
    wake: Arc<Notify>,
    /// Its prompt went out.
    fired: bool,
}

impl Wait {
    fn is(&self, other: &Wait) -> bool {
        Arc::ptr_eq(&self.wake, &other.wake)
    }
}

/// What became of one retry, logged as its `subagent_retry` record and subagent update.
struct Step<'a> {
    outcome: &'a str,
    state: &'a str,
    retry: Value,
    retryable: bool,
    extra: Value,
}

impl Retries {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// One logged change at a time (see [`Retries`]).
    fn steps(&self) -> std::sync::MutexGuard<'_, ()> {
        self.1.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Starts the chat's turn of `prompt_id` (`start`), unless it is a retry prompt whose retry
    /// was skipped since it went out: then the refusal. Under the lock a skip takes, so a skip
    /// either comes first and the prompt never starts, or finds it started.
    pub(super) fn start(
        &self,
        session_id: &str,
        prompt_id: &str,
        start: impl FnOnce(),
    ) -> Result<(), RpcError> {
        let all = self.lock();
        if all.sent.get(&(session_id.to_owned(), prompt_id.to_owned())) == Some(&true) {
            return Err(RpcError::invalid_params(
                "subagent_retry.skipped: the subagent was resumed, replaced or stopped",
            )
            .with_data(json!({"reason": "subagent_retry.skipped"})));
        }
        start();
        Ok(())
    }
}

/// Whether the chat closes or closed: `Hub::kill` sets `closing` before it takes the retries.
fn closing(session: &Session) -> bool {
    session.closing.load(Ordering::SeqCst) || session.status() == SessionStatus::Closed
}

/// Past [`MAX_FAILED`] stopped or given-up failed subagents, the oldest ones, taken.
fn forget_oldest(subs: &mut HashMap<String, Sub>) -> Vec<(String, Failure)> {
    let mut idle: Vec<(u64, String)> = subs
        .iter()
        .filter_map(|(id, s)| Some((s.failed.as_ref().filter(|f| f.idle)?.at, id.clone())))
        .collect();
    idle.sort();
    let over = idle.len().saturating_sub(MAX_FAILED);
    idle.into_iter()
        .take(over)
        .filter_map(|(_, id)| Some((id.clone(), subs.remove(&id)?.failed?)))
        .collect()
}

/// The prompt the parent's agent gets.
fn retry_text(name: Option<&str>, agent_id: &str, error: &str) -> String {
    let name = name.map(|n| format!("\"{n}\" ")).unwrap_or_default();
    let error: String = error.chars().take(MAX_ERROR_CHARS).collect();
    format!(
        "Your subagent {name}(agent id {agent_id}) failed on a transient upstream error \
         ({error}). Resume it with SendMessage to \"{agent_id}\": it picks up from its \
         transcript. Start a new subagent for its task only if that resume fails. If it is \
         already running again, or you already resumed or replaced it, do nothing."
    )
}

impl Hub {
    /// Reads one live update's subagent changes (`_meta.acpmux.subagents`, after the tap logged
    /// it): names, resumes, ends and failures of the chat's own subagents.
    pub(super) fn observe_subagents(self: &Arc<Self>, session: &Arc<Session>, events: &[Value]) {
        let _steps = self.subagent_retries.steps();
        // A chat that closes retries nothing more. Checked once, under `steps`: close then
        // either came first, or drains what this change left.
        if closing(session) {
            return;
        }
        self.observe_entries(session, events);
    }

    /// [`Hub::observe_subagents`], its caller holding `steps` and having seen the chat open.
    fn observe_entries(self: &Arc<Self>, session: &Arc<Session>, events: &[Value]) {
        let mut skipped = Vec::new();
        let mut schedule = Vec::new();
        {
            let mut all = self.subagent_retries.lock();
            let all = &mut *all;
            let subs = all.subs.entry(session.id.clone()).or_default();
            let gone = all.gone.entry(session.id.clone()).or_default();
            for e in events.iter().filter(|e| e.get("parent").is_some_and(Value::is_null)) {
                // acpmux's own retry updates (`log_step`) change nothing.
                if e.get("retryable").is_some() {
                    continue;
                }
                let text = |k: &str| e.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
                let (Some(id), Some(state)) = (text("id"), text("state")) else { continue };
                let name = text("task").or(text("name"));
                match state {
                    "running" => {
                        let new = !subs.contains_key(id);
                        let sub = subs.entry(id.to_owned()).or_default();
                        sub.name = name.map(str::to_owned).or(sub.name.take());
                        // The translator knows it: its updates end it.
                        sub.raw_agent = None;
                        let name = sub.name.clone();
                        // It runs again: resumed.
                        if let Some(f) = sub.failed.take() {
                            skipped.push((id.to_owned(), f, "resumed", "running", false));
                        }
                        // A new one of a failed one's name replaces it.
                        if new && name.is_some() {
                            let replaced: Vec<String> = subs
                                .iter()
                                .filter(|(other, s)| *other != id && s.name == name)
                                .filter(|(_, s)| s.failed.is_some())
                                .map(|(other, _)| other.clone())
                                .collect();
                            for other in replaced {
                                if let Some(f) = subs.remove(&other).and_then(|s| s.failed) {
                                    skipped.push((other, f, "replaced", "failed", false));
                                }
                            }
                        }
                    }
                    "failed" => {
                        let mut sub = subs.remove(id).unwrap_or_default();
                        // Failed again: its new failure's update follows.
                        if let Some(f) = sub.failed.take().filter(|f| f.wait.is_some()) {
                            skipped.push((id.to_owned(), f, "superseded", "failed", false));
                        }
                        let error = text("error").unwrap_or_default();
                        let reason = super::turn_errors::transient_cause(error);
                        if let (Some(agent_id), Some(reason)) = (text("agentId"), reason) {
                            sub.failed = Some(Failure {
                                agent_id: agent_id.to_owned(),
                                error: error.to_owned(),
                                reason,
                                at: crate::store::now_ms(),
                                idle: false,
                                wait: None,
                            });
                            subs.insert(id.to_owned(), sub);
                            schedule.push(id.to_owned());
                            gone.retain(|g| g.id != id);
                        } else {
                            // A bad request, a sign-in failure, or no agent id to resume it by.
                            note_gone(gone, id, text("agentId"), "not_retryable");
                        }
                    }
                    // Completed, cancelled or gone: nothing more to retry.
                    _ => {
                        match subs.remove(id).and_then(|s| s.failed) {
                            Some(f) => skipped.push((id.to_owned(), f, "ended", state, false)),
                            // Resumed earlier, it ended since.
                            None => {
                                if let Some(g) = gone.iter_mut().find(|g| g.id == id) {
                                    g.why = "ended";
                                }
                            }
                        }
                    }
                }
            }
        }
        for (id, failure, why, state, retryable) in skipped {
            self.skip_wait(session, &id, failure, why, state, retryable);
        }
        for id in schedule {
            let (hub, session) = (self.clone(), session.clone());
            tokio::spawn(async move { hub.schedule_subagent_retry(&session, &id).await });
        }
    }

    /// Claude Code's raw task lines. A `task_started` for a failed subagent's agent id is
    /// SendMessage's resume: it runs again, also when the translator forgot the agent and says
    /// nothing. For such a forgotten one, its later `task_notification` ends it here: failed
    /// (retried again when transient), or completed.
    pub(super) fn observe_task_line(self: &Arc<Self>, session: &Arc<Session>, line: &Value) {
        let text = |k: &str| line.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
        let (Some(subtype), Some(task)) = (text("subtype"), text("task_id")) else { return };
        let _steps = self.subagent_retries.steps();
        // As in `observe_subagents`: once, under `steps`.
        if closing(session) {
            return;
        }
        match subtype {
            "task_started" => {
                let resumed: Vec<(String, Failure)> = {
                    let mut all = self.subagent_retries.lock();
                    let Some(subs) = all.subs.get_mut(&session.id) else { return };
                    subs.iter_mut()
                        .filter_map(|(id, s)| {
                            let failed = s.failed.take_if(|f| f.agent_id == task)?;
                            // Until the translator says it runs (`observe_entries`).
                            s.raw_agent = Some(task.to_owned());
                            Some((id.clone(), failed))
                        })
                        .collect()
                };
                for (id, failure) in resumed {
                    self.skip_wait(session, &id, failure, "resumed", "running", false);
                }
            }
            "task_notification" => {
                let ended = {
                    let mut all = self.subagent_retries.lock();
                    let Some(subs) = all.subs.get_mut(&session.id) else { return };
                    let found = subs.iter_mut().find(|(_, s)| s.raw_agent.as_deref() == Some(task));
                    let Some((id, sub)) = found else { return };
                    sub.raw_agent = None;
                    (id.clone(), sub.name.clone())
                };
                let (id, name) = ended;
                let state = match text("status") {
                    Some("failed") => "failed",
                    Some("completed") => "completed",
                    _ => "cancelled",
                };
                let error = text("summary").unwrap_or_default();
                let transient =
                    state == "failed" && super::turn_errors::transient_cause(error).is_some();
                let none = Failure {
                    agent_id: task.to_owned(),
                    error: String::new(),
                    reason: "",
                    at: 0,
                    idle: true,
                    wait: None,
                };
                // Its end, as the translator would have said it.
                self.log_entry(session, &id, &none, state, Value::Null, transient);
                let entry = json!({"id": id, "parent": null, "state": state, "task": name,
                    "agentId": task, "error": error});
                self.observe_entries(session, &[entry]);
            }
            _ => {}
        }
    }

    /// A subagent retry's prompt about to start (`turns.rs`, holding the chat's turn slot):
    /// while Claude Code runs a turn of its own (one it started for a task notification after
    /// the prompt was queued), the prompt waits for that turn's end rather than land in it. It
    /// rechecks at each of the hub's records and goes on at that turn's `result` or the host's
    /// exit, when the retry is skipped (`Hub::start_turn` then refuses it) or when the chat
    /// closes. Any other prompt goes on at once.
    pub(super) async fn hold_retry_start(&self, session: &Session, prompt_id: &str) {
        let key = (session.id.clone(), prompt_id.to_owned());
        let mut events = self.events.subscribe();
        loop {
            let pending = self.subagent_retries.lock().sent.get(&key) == Some(&false);
            if !pending || !session.harness_turn.load(Ordering::SeqCst) || closing(session) {
                return;
            }
            if let Err(tokio::sync::broadcast::error::RecvError::Closed) = events.recv().await {
                return;
            }
        }
    }

    /// Stop (`closed`: close) ends every retry the chat's subagents wait for, and takes back a
    /// sent one still queued.
    pub(super) fn stop_subagent_retries(&self, session: &Arc<Session>, closed: bool) {
        let _steps = self.subagent_retries.steps();
        let waits: Vec<(String, Failure)> = {
            let mut all = self.subagent_retries.lock();
            let mut waits = Vec::new();
            if closed {
                all.gone.remove(&session.id);
                // Every failure goes, waiting or not: each entry then says it can't be retried.
                for (id, sub) in all.subs.remove(&session.id).into_iter().flatten() {
                    if let Some(f) = sub.failed {
                        waits.push((id, f));
                    }
                }
            } else {
                // Waiting, or failed a moment ago with its first wait not planned yet.
                for (id, sub) in all.subs.get_mut(&session.id).into_iter().flatten() {
                    if let Some(f) = sub.failed.as_mut().filter(|f| !f.idle) {
                        waits.push((id.clone(), f.clone()));
                        f.wait = None;
                        f.idle = true;
                    }
                }
            }
            waits
        };
        let why = if closed { "closed" } else { "stopped" };
        for (id, failure) in waits {
            // After a Stop a person can still retry it; not after close.
            self.skip_wait(session, &id, failure, why, "failed", !closed);
        }
        if !closed {
            self.forget_past_limit(session);
        }
    }

    /// Forgets the chat's oldest failures past [`MAX_FAILED`] no retry waits for: each entry
    /// then says it can't be retried. The caller holds `steps`.
    fn forget_past_limit(&self, session: &Arc<Session>) {
        let forgotten = match self.subagent_retries.lock().subs.get_mut(&session.id) {
            Some(subs) => forget_oldest(subs),
            None => return,
        };
        for (id, failure) in forgotten {
            self.skip_wait(session, &id, failure, "forgotten", "failed", false);
        }
    }

    /// Schedules the first attempt at a failed subagent and runs it, and the ones after it.
    async fn schedule_subagent_retry(self: &Arc<Self>, session: &Arc<Session>, id: &str) {
        let delays = self.retry_delays().await;
        if let Some((wait, delay)) = self.plan_retry(session, id, &delays) {
            self.run_subagent_retry(session, id, wait, delay).await;
        }
    }

    /// `autoResumeDelaysMs`, or the default waits.
    async fn retry_delays(&self) -> Vec<u64> {
        let delays = self.config.read().await.auto_resume_delays_ms.clone();
        delays.unwrap_or_else(|| super::auto_resume::DEFAULT_DELAYS_MS.to_vec())
    }

    /// Records the next attempt's wait and logs it (`scheduled`, or `exhausted` past the
    /// configured attempts): the wait and its delay in ms.
    fn plan_retry(&self, session: &Arc<Session>, id: &str, delays: &[u64]) -> Option<(Wait, u64)> {
        let _steps = self.subagent_retries.steps();
        if closing(session) {
            return None;
        }
        let (failure, wait, delay) = {
            let mut all = self.subagent_retries.lock();
            let sub = all.subs.get_mut(&session.id)?.get_mut(id)?;
            let attempts = sub.attempts;
            let failure = sub.failed.as_mut().filter(|f| f.wait.is_none() && !f.idle)?;
            let of = delays.len();
            let delay = match delays.get(attempts) {
                Some(&delay) => super::auto_resume::staggered(delay, &session.id),
                None => {
                    failure.idle = true;
                    let failure = failure.clone();
                    drop(all);
                    let extra = json!({"attempt": attempts, "of": of});
                    self.log_step(
                        session,
                        id,
                        &failure,
                        Step {
                            outcome: "exhausted",
                            state: "failed",
                            retry: Value::Null,
                            // The automatic attempts end; a person's retry still works.
                            retryable: true,
                            extra,
                        },
                    );
                    self.forget_past_limit(session);
                    return None;
                }
            };
            let next_at = crate::store::now_ms() + delay;
            let tool = id.rsplit('/').next().unwrap_or(id);
            let wait = Wait {
                attempt: attempts + 1,
                of,
                next_at,
                prompt_id: format!("subagent-retry-{tool}-{}-{next_at}", attempts + 1),
                wake: Arc::new(Notify::new()),
                fired: false,
            };
            failure.wait = Some(wait.clone());
            (failure.clone(), wait, delay)
        };
        let retry = json!({"attempt": wait.attempt, "of": wait.of, "reason": failure.reason,
            "nextAt": wait.next_at});
        let extra = json!({"attempt": wait.attempt, "of": wait.of, "nextAt": wait.next_at,
            "promptId": wait.prompt_id});
        self.log_step(
            session,
            id,
            &failure,
            Step { outcome: "scheduled", state: "failed", retry, retryable: true, extra },
        );
        Some((wait, delay))
    }

    /// Runs `wait`, and the attempts after it while its prompt's turn ends with the subagent
    /// still failed (the agent did not resume it).
    async fn run_subagent_retry(
        self: &Arc<Self>,
        session: &Arc<Session>,
        id: &str,
        mut wait: Wait,
        mut delay: u64,
    ) {
        while self.attempt_retry(session, id, &wait, delay).await {
            let delays = self.retry_delays().await;
            let Some((next, next_delay)) = self.plan_retry(session, id, &delays) else {
                return;
            };
            (wait, delay) = (next, next_delay);
        }
    }

    /// Waits out `delay` (or a wake), and Claude Code's own turn, then sends the prompt and
    /// waits for its turn. True when that turn ended with the subagent still failed.
    async fn attempt_retry(
        self: &Arc<Self>,
        session: &Arc<Session>,
        id: &str,
        wait: &Wait,
        delay: u64,
    ) -> bool {
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_millis(delay)) => {}
            _ = wait.wake.notified() => {}
        }
        // Subscribed before the check: no change between them is missed.
        let mut events = self.events.subscribe();
        loop {
            if !self.still_waiting(session, id, wait) {
                return false; // Skipped, and logged, by what took it.
            }
            if closing(session) || session.moving().is_some() {
                let _steps = self.subagent_retries.steps();
                if let Some(f) = self.take_wait(session, id, wait) {
                    self.skip_wait(session, id, f, "closed", "failed", false);
                }
                return false;
            }
            // Claude Code's own turn (no acpmux turn shows it), or a turn continuation that may
            // still fire. A turn acpmux runs is not waited for: the prompt queues behind it.
            let own_turn = session.harness_turn.load(Ordering::SeqCst) && session.turn().is_none();
            if !own_turn && !self.continuation_pending(session) {
                break;
            }
            // Its end is a record (`turn_result`, the harness's `result`, an exit): checked
            // again at each of the hub's records, or when Stop, close or a resume wakes it.
            tokio::select! {
                got = events.recv() => {
                    if matches!(got, Err(tokio::sync::broadcast::error::RecvError::Closed)) {
                        return false;
                    }
                }
                _ = wait.wake.notified() => {}
            }
        }
        drop(events);
        let fired = {
            let _steps = self.subagent_retries.steps();
            let fired = self.fire_wait(session, id, wait);
            if let Some((failure, _)) = &fired {
                let extra =
                    json!({"attempt": wait.attempt, "of": wait.of, "promptId": wait.prompt_id});
                let retry = Value::Null;
                let step =
                    Step { outcome: "fired", state: "failed", retry, retryable: true, extra };
                self.log_step(session, id, failure, step);
            }
            fired
        };
        let Some((failure, name)) = fired else { return false };
        let provenance = json!({"kind": PROVENANCE_KIND, "subagentId": id,
            "agentId": failure.agent_id, "attempt": wait.attempt});
        let opts = PromptOptions { provenance: Some(provenance), ..PromptOptions::default() };
        let result =
            self.send_attempt(session, id, wait, &failure, name.as_deref(), opts, None).await;
        if let Err(e) = result {
            tracing::warn!(session = %session.id, subagent = id, "subagent retry: {}", e.message);
        }
        self.end_attempt(session, id, wait)
    }

    /// The sent `wait`'s prompt answered: no longer refused at its start. Whether the wait is
    /// still the subagent's (its turn ended with it still failed), taken.
    fn end_attempt(&self, session: &Session, id: &str, wait: &Wait) -> bool {
        let sent = (session.id.clone(), wait.prompt_id.clone());
        self.subagent_retries.lock().sent.remove(&sent);
        self.take_wait(session, id, wait).is_some()
    }

    /// Sends fired `wait`'s prompt under `opts` (its rules and provenance) and waits for its
    /// turn, telling `accepted` once the prompt is recorded: the prompt's outcome.
    #[allow(clippy::too_many_arguments)]
    async fn send_attempt(
        self: &Arc<Self>,
        session: &Arc<Session>,
        id: &str,
        wait: &Wait,
        failure: &Failure,
        name: Option<&str>,
        mut opts: PromptOptions,
        accepted: Option<Box<dyn FnOnce(Value) + Send>>,
    ) -> Result<Value, RpcError> {
        // Stop, close or a resume between the fire and the queue: taken back from the queue.
        let (hub, owner, sub, sent) = (self.clone(), session.clone(), id.to_owned(), wait.clone());
        let on_accepted: Box<dyn FnOnce(Value) + Send> = Box::new(move |v: Value| {
            if v.get("queued") == Some(&json!(true)) && !hub.is_wait(&owner, &sub, &sent) {
                tokio::spawn(async move {
                    hub.remove_queued_because(&owner, &sent.prompt_id, Some(PROVENANCE_KIND));
                });
            }
            if let Some(accepted) = accepted {
                accepted(v);
            }
        });
        opts.prompt_id = Some(wait.prompt_id.clone());
        opts.on_accepted = Some(on_accepted);
        let text = retry_text(name, &failure.agent_id, &failure.error);
        let blocks = vec![json!({"type": "text", "text": text})];
        self.prompt_with(session, blocks, "acpmux", false, opts).await
    }

    /// Whether `wait` is still the subagent's.
    fn is_wait(&self, session: &Session, id: &str, wait: &Wait) -> bool {
        let all = self.subagent_retries.lock();
        let sub = all.subs.get(&session.id).and_then(|s| s.get(id));
        sub.and_then(|s| s.failed.as_ref()?.wait.as_ref()).is_some_and(|w| w.is(wait))
    }

    /// Whether `wait` is still the subagent's and has not fired.
    fn still_waiting(&self, session: &Session, id: &str, wait: &Wait) -> bool {
        let all = self.subagent_retries.lock();
        let sub = all.subs.get(&session.id).and_then(|s| s.get(id));
        sub.and_then(|s| s.failed.as_ref()?.wait.as_ref()).is_some_and(|w| w.is(wait) && !w.fired)
    }

    /// Marks `wait` fired and counts its attempt: the failure and the subagent's name. None when
    /// it is no longer the subagent's, or fired already.
    fn fire_wait(
        &self,
        session: &Session,
        id: &str,
        wait: &Wait,
    ) -> Option<(Failure, Option<String>)> {
        let mut all = self.subagent_retries.lock();
        let all = &mut *all;
        let sub = all.subs.get_mut(&session.id)?.get_mut(id)?;
        let failed = sub.failed.as_mut()?;
        let ours = failed.wait.as_mut().filter(|w| w.is(wait) && !w.fired)?;
        ours.fired = true;
        let failure = failed.clone();
        sub.attempts = sub.attempts.max(wait.attempt);
        all.sent.insert((session.id.clone(), wait.prompt_id.clone()), false);
        Some((failure, sub.name.clone()))
    }

    /// Takes `wait`, when it is still the subagent's.
    fn take_wait(&self, session: &Session, id: &str, wait: &Wait) -> Option<Failure> {
        let mut all = self.subagent_retries.lock();
        let failed = all.subs.get_mut(&session.id)?.get_mut(id)?.failed.as_mut()?;
        if !failed.wait.as_ref()?.is(wait) {
            return None;
        }
        let taken = failed.clone();
        failed.wait = None;
        Some(taken)
    }

    /// A failure acpmux stops retrying (`why`), with the subagent now `state`. A sent prompt
    /// that has not started is refused from now on and leaves the queue; one that started, or a
    /// failure no retry waited for, only gets its entry's `retryable` updated.
    fn skip_wait(
        &self,
        session: &Arc<Session>,
        id: &str,
        failure: Failure,
        why: &'static str,
        state: &str,
        retryable: bool,
    ) {
        // Closed, the chat answers for all; superseded, its new failure follows.
        if !retryable && why != "closed" && why != "superseded" {
            let mut all = self.subagent_retries.lock();
            let gone = all.gone.entry(session.id.clone()).or_default();
            note_gone(gone, id, Some(&failure.agent_id), why);
        }
        let skipped = failure.wait.as_ref().filter(|wait| {
            wait.wake.notify_one();
            if !wait.fired {
                return true;
            }
            let started = {
                let mut all = self.subagent_retries.lock();
                let key = (session.id.clone(), wait.prompt_id.clone());
                let unanswered = all.sent.get_mut(&key).map(|skip| *skip = true);
                unanswered.is_none()
                    || session.turn().is_some_and(|t| t.prompt_id == wait.prompt_id)
            };
            if !started {
                self.remove_queued_because(session, &wait.prompt_id, Some(PROVENANCE_KIND));
            }
            !started
        });
        let Some(wait) = skipped else {
            self.log_entry(session, id, &failure, state, Value::Null, retryable);
            return;
        };
        let extra = json!({"attempt": wait.attempt, "of": wait.of, "skipped": why});
        self.log_step(
            session,
            id,
            &failure,
            Step { outcome: "skipped", state, retry: Value::Null, retryable, extra },
        );
    }

    /// Logs one step: the subagent's update with its retry state, then `subagent_retry`.
    fn log_step(&self, session: &Session, id: &str, failure: &Failure, step: Step<'_>) {
        self.log_entry(session, id, failure, step.state, step.retry, step.retryable);
        let mut msg = json!({"subagentId": id, "agentId": failure.agent_id,
            "reason": failure.reason, "outcome": step.outcome});
        if let (Some(msg), Some(extra)) = (msg.as_object_mut(), step.extra.as_object()) {
            msg.extend(extra.clone());
        }
        self.append(session, "mux", "subagent_retry", msg);
    }

    /// Logs the subagent's update with its retry state.
    fn log_entry(
        &self,
        session: &Session,
        id: &str,
        failure: &Failure,
        state: &str,
        retry: Value,
        retryable: bool,
    ) {
        let entry = json!({"id": id, "parent": null, "state": state,
            "agentId": failure.agent_id, "retry": retry, "retryable": retryable});
        let update = json!({"jsonrpc": "2.0", "method": crate::rpc::method::SESSION_UPDATE,
            "params": {"sessionId": session.id,
                "update": {"sessionUpdate": "subagent_state_update", "subagentSessionId": id,
                    "state": state},
                "_meta": {"acpmux": {"subagents": [entry]}}}});
        self.append(session, "in", "subagent_state_update", update);
    }
}

#[path = "subagent_retry_manual.rs"]
mod manual;

#[cfg(test)]
#[path = "subagent_retry_tests.rs"]
mod race_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_prompt_names_the_agent_and_says_to_resume_it() {
        let text = retry_text(Some("Push relay"), "a8e1b68b93aac9d16", "API Error: 503");
        assert!(text.contains("\"Push relay\" (agent id a8e1b68b93aac9d16)"), "{text}");
        assert!(text.contains("SendMessage to \"a8e1b68b93aac9d16\""), "{text}");
        assert!(text.contains("only if that resume fails"), "{text}");
        let long = "x".repeat(1000);
        assert!(retry_text(None, "a", &long).len() < 700);
    }

    /// A retry prompt skipped after it went out never starts; others start, the same prompt
    /// id in another chat too.
    #[test]
    fn a_skipped_retry_prompt_never_starts() {
        let retries = Retries::default();
        let key = ("s1".to_owned(), "p".to_owned());
        retries.lock().sent.insert(key.clone(), false);
        let mut started = false;
        retries.start("s1", "p", || started = true).unwrap();
        assert!(started);
        retries.lock().sent.insert(key, true);
        let mut again = false;
        let refused = retries.start("s1", "p", || again = true).unwrap_err();
        assert!(!again);
        assert_eq!(refused.data.unwrap()["reason"], "subagent_retry.skipped");
        retries.start("s1", "other", || {}).unwrap();
        let mut elsewhere = false;
        retries.start("s2", "p", || elsewhere = true).unwrap();
        assert!(elsewhere, "another chat's prompt of the same id starts");
    }

    /// Past the limit the oldest stopped or given-up failures go; a waiting one stays.
    #[test]
    fn failed_subagents_past_the_limit_forget_only_the_oldest() {
        let failed = |at: u64, waiting: bool| Sub {
            failed: Some(Failure {
                agent_id: format!("a{at}"),
                error: String::new(),
                reason: "capacity",
                at,
                idle: !waiting,
                wait: waiting.then(|| Wait {
                    attempt: 1,
                    of: 1,
                    next_at: 0,
                    prompt_id: String::new(),
                    wake: Arc::new(Notify::new()),
                    fired: false,
                }),
            }),
            ..Sub::default()
        };
        let mut subs: HashMap<String, Sub> = HashMap::new();
        subs.insert("waiting".into(), failed(0, true));
        for at in 1..=(MAX_FAILED as u64 + 2) {
            subs.insert(format!("s{at}"), failed(at, false));
        }
        let mut gone: Vec<String> =
            forget_oldest(&mut subs).into_iter().map(|(id, _)| id).collect();
        gone.sort();
        assert_eq!(gone, ["s1", "s2"]);
        assert_eq!(subs.len(), MAX_FAILED + 1);
        assert!(subs.contains_key("waiting"));
        assert!(forget_oldest(&mut subs).is_empty());
    }
}
