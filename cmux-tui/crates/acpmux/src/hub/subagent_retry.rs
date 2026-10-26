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
//! - Skipped on Stop or close, when the subagent runs again (resumed) or ends, and when the chat
//!   starts another top-level subagent of the same name (replaced). A prompt that went out and
//!   still waits in the queue is taken back then (`queue_removed`); one that started is the
//!   agent's to answer (it says to do nothing when the subagent already runs).
//! - Once its prompt's turn ends with the subagent still failed (the agent did not resume it),
//!   or it fails again, the next attempt waits; after the configured attempts it is given up
//!   (`exhausted`). A person's retry (`_acpmux/retry {sessionId, subagentId}`) comes with
//!   hb-retry-turn's handler, on top of this.
//! - While a retry waits, the subagent's entry in `_meta.acpmux.subagents` carries
//!   `retry: {attempt, of, reason, nextAt}` (`nextAt` in Unix ms), and `retryable: true` while a
//!   retry is under way. The same update is logged again when the retry fires (`retry: null`),
//!   is skipped or is given up, and each step logs `subagent_retry {subagentId, agentId, attempt,
//!   of, reason, outcome, nextAt?, promptId?, skipped?}`, `outcome` one of `scheduled`, `fired`,
//!   `skipped` or `exhausted`.
//! - A wait is not persisted: a daemon restart drops it.

use super::{Hub, PromptOptions, Session, SessionStatus};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::Notify;

/// The provenance kind of the prompt that asks for a subagent's resume.
pub const PROVENANCE_KIND: &str = "subagent_retry";

/// Longest error text quoted to the agent, in characters.
const MAX_ERROR_CHARS: usize = 300;

/// Each chat's top-level subagents, by id, while they run or wait for a retry.
#[derive(Default)]
pub(crate) struct Retries(Mutex<HashMap<String, HashMap<String, Sub>>>);

#[derive(Default)]
struct Sub {
    name: Option<String>,
    /// Attempts fired at it so far.
    attempts: usize,
    failed: Option<Failure>,
}

#[derive(Clone)]
struct Failure {
    agent_id: String,
    error: String,
    reason: &'static str,
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
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, HashMap<String, Sub>>> {
        self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
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
        let mut skipped = Vec::new();
        let mut schedule = Vec::new();
        {
            let mut all = self.subagent_retries.lock();
            let subs = all.entry(session.id.clone()).or_default();
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
                        let name = sub.name.clone();
                        // It runs again: resumed.
                        if let Some(f) = sub.failed.take() {
                            skipped.push((id.to_owned(), f, "resumed", "running", false));
                        }
                        // A new one of a failed one's name replaces it.
                        if new && name.is_some() {
                            for (other, sub) in subs.iter_mut() {
                                if other != id
                                    && sub.name == name
                                    && let Some(f) = sub.failed.take()
                                {
                                    skipped.push((other.clone(), f, "replaced", "failed", false));
                                }
                            }
                        }
                    }
                    "failed" => {
                        let mut sub = subs.remove(id).unwrap_or_default();
                        if let Some(f) = sub.failed.take() {
                            skipped.push((id.to_owned(), f, "superseded", "failed", false));
                        }
                        let error = text("error").unwrap_or_default();
                        let reason = super::turn_errors::transient_cause(error);
                        if let (Some(agent_id), Some(reason)) = (text("agentId"), reason) {
                            sub.failed = Some(Failure {
                                agent_id: agent_id.to_owned(),
                                error: error.to_owned(),
                                reason,
                                wait: None,
                            });
                            subs.insert(id.to_owned(), sub);
                            schedule.push(id.to_owned());
                        }
                    }
                    // Completed, cancelled or gone: nothing more to retry.
                    _ => {
                        if let Some(f) = subs.remove(id).and_then(|s| s.failed) {
                            skipped.push((id.to_owned(), f, "ended", state, false));
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

    /// Stop (`closed`: close) ends every retry the chat's subagents wait for, and takes back a
    /// sent one still queued.
    pub(super) fn stop_subagent_retries(&self, session: &Arc<Session>, closed: bool) {
        let waits: Vec<(String, Failure)> = {
            let mut all = self.subagent_retries.lock();
            let mut waits = Vec::new();
            if closed {
                for (id, sub) in all.remove(&session.id).into_iter().flatten() {
                    if let Some(f) = sub.failed.filter(|f| f.wait.is_some()) {
                        waits.push((id, f));
                    }
                }
            } else {
                for (id, sub) in all.get_mut(&session.id).into_iter().flatten() {
                    if let Some(f) = sub.failed.as_mut().filter(|f| f.wait.is_some()) {
                        waits.push((id.clone(), f.clone()));
                        f.wait = None;
                    }
                }
            }
            waits
        };
        let why = if closed { "closed" } else { "stopped" };
        for (id, failure) in waits {
            self.skip_wait(session, &id, failure, why, "failed", false);
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
    fn plan_retry(&self, session: &Session, id: &str, delays: &[u64]) -> Option<(Wait, u64)> {
        let (failure, wait, delay) = {
            let mut all = self.subagent_retries.lock();
            let sub = all.get_mut(&session.id)?.get_mut(id)?;
            let attempts = sub.attempts;
            let failure = sub.failed.as_mut().filter(|f| f.wait.is_none())?;
            let of = delays.len();
            let delay = match delays.get(attempts) {
                Some(&delay) => super::auto_resume::staggered(delay, &session.id),
                None => {
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
                            retryable: false,
                            extra,
                        },
                    );
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
            if session.status() == SessionStatus::Closed || session.moving().is_some() {
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
        let Some((failure, name)) = self.fire_wait(session, id, wait) else { return false };
        let extra = json!({"attempt": wait.attempt, "of": wait.of, "promptId": wait.prompt_id});
        self.log_step(
            session,
            id,
            &failure,
            Step { outcome: "fired", state: "failed", retry: Value::Null, retryable: true, extra },
        );
        let provenance = json!({"kind": PROVENANCE_KIND, "subagentId": id,
            "agentId": failure.agent_id, "attempt": wait.attempt});
        // Stop, close or a resume between the fire and the queue: taken back from the queue.
        let (hub, owner, sub, sent) = (self.clone(), session.clone(), id.to_owned(), wait.clone());
        let on_accepted: Box<dyn FnOnce(Value) + Send> = Box::new(move |accepted: Value| {
            if accepted.get("queued") == Some(&json!(true)) && !hub.is_wait(&owner, &sub, &sent) {
                tokio::spawn(async move {
                    hub.remove_queued_because(&owner, &sent.prompt_id, Some(PROVENANCE_KIND));
                });
            }
        });
        let opts = PromptOptions {
            prompt_id: Some(wait.prompt_id.clone()),
            provenance: Some(provenance),
            on_accepted: Some(on_accepted),
            ..PromptOptions::default()
        };
        let text = retry_text(name.as_deref(), &failure.agent_id, &failure.error);
        let blocks = vec![json!({"type": "text", "text": text})];
        if let Err(e) = self.prompt_with(session, blocks, "acpmux", false, opts).await {
            tracing::warn!(session = %session.id, subagent = id, "subagent retry: {}", e.message);
        }
        self.take_wait(session, id, wait).is_some()
    }

    /// Whether `wait` is still the subagent's.
    fn is_wait(&self, session: &Session, id: &str, wait: &Wait) -> bool {
        let all = self.subagent_retries.lock();
        let sub = all.get(&session.id).and_then(|s| s.get(id));
        sub.and_then(|s| s.failed.as_ref()?.wait.as_ref()).is_some_and(|w| w.is(wait))
    }

    /// Whether `wait` is still the subagent's and has not fired.
    fn still_waiting(&self, session: &Session, id: &str, wait: &Wait) -> bool {
        let all = self.subagent_retries.lock();
        let sub = all.get(&session.id).and_then(|s| s.get(id));
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
        let sub = all.get_mut(&session.id)?.get_mut(id)?;
        let failed = sub.failed.as_mut()?;
        let ours = failed.wait.as_mut().filter(|w| w.is(wait) && !w.fired)?;
        ours.fired = true;
        let failure = failed.clone();
        sub.attempts = sub.attempts.max(wait.attempt);
        Some((failure, sub.name.clone()))
    }

    /// Takes `wait`, when it is still the subagent's.
    fn take_wait(&self, session: &Session, id: &str, wait: &Wait) -> Option<Failure> {
        let mut all = self.subagent_retries.lock();
        let failed = all.get_mut(&session.id)?.get_mut(id)?.failed.as_mut()?;
        if !failed.wait.as_ref()?.is(wait) {
            return None;
        }
        let taken = failed.clone();
        failed.wait = None;
        Some(taken)
    }

    /// A wait that ends unfired (`why`), with the subagent now `state`. A fired one is skipped
    /// only when its prompt still waited in the queue, which it leaves.
    fn skip_wait(
        &self,
        session: &Arc<Session>,
        id: &str,
        failure: Failure,
        why: &str,
        state: &str,
        retryable: bool,
    ) {
        let Some(wait) = failure.wait.as_ref() else { return };
        wait.wake.notify_one();
        if wait.fired
            && !self.remove_queued_because(session, &wait.prompt_id, Some(PROVENANCE_KIND))
        {
            return;
        }
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
        let entry = json!({"id": id, "parent": null, "state": step.state,
            "agentId": failure.agent_id, "retry": step.retry, "retryable": step.retryable});
        let update = json!({"jsonrpc": "2.0", "method": crate::rpc::method::SESSION_UPDATE,
            "params": {"sessionId": session.id,
                "update": {"sessionUpdate": "subagent_state_update", "subagentSessionId": id,
                    "state": step.state},
                "_meta": {"acpmux": {"subagents": [entry]}}}});
        self.append(session, "in", "subagent_state_update", update);
        let mut msg = json!({"subagentId": id, "agentId": failure.agent_id,
            "reason": failure.reason, "outcome": step.outcome});
        if let (Some(msg), Some(extra)) = (msg.as_object_mut(), step.extra.as_object()) {
            msg.extend(extra.clone());
        }
        self.append(session, "mux", "subagent_retry", msg);
    }
}

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
}
