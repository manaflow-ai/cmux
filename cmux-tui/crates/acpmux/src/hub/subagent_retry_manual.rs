//! A person's retry of a failed subagent: `_acpmux/retry {sessionId, subagentId}`, `acpmux retry
//! --subagent` and the sub-session tool `retry_session {session, subagent}` (the Retry button on a
//! "Subagent failed" row; Leo, 2026-10-26: "this needs to retry :(").
//!
//! - The subagent is named by its id (its `_meta.acpmux.subagents` entry's `id`) or by its agent
//!   id. It must be one of the chat's top-level subagents that failed on a transient error with an
//!   agent id: an entry `retryable: true`.
//! - When its automatic retry waits, that attempt fires now: its prompt id and attempt, its
//!   `fired` record, and the waiting task wakes and finds it taken. Otherwise one more attempt
//!   goes now (after a Stop, once the automatic attempts are used up, or before the first wait
//!   was planned). Either way the parent chat gets the prompt the automatic retry sends, in the
//!   same session (SendMessage to the agent id, a new subagent only if that fails), with
//!   `_meta.provenance = {kind: "subagent_retry", subagentId, agentId, attempt, manual: true}`,
//!   plus `from` when a sub-session asked (checked again at dispatch, `family_dispatch_check`).
//!   Its `fired` record carries `manual: true`.
//! - It runs under the caller's rules, as `retry_turn.rs`'s does, and answers once the prompt is
//!   accepted (its turn started): `{promptId, turnId, kind: "subagent"}`, `promptId`
//!   `subagent-retry-<tool>-<attempt>-<ms>`.
//! - Refused, as the chat's turn retry is, with `retry.busy` while a turn runs (acpmux's or Claude
//!   Code's own), a prompt waits to run or is about to start, a turn continuation may still fire,
//!   the chat moves, a sub-session's run slots are full, or this subagent's retry prompt is already
//!   under way. It never queues (`PromptOptions::no_queue`): what it would wait behind, also
//!   something that took the chat between its check and its send, refuses it. A prompt refused
//!   before it was recorded gives its claim back (`unclaim`): a wait it took over waits again. With
//!   `retry.nothing_failed` when the subagent is not failed or cannot be retried, `data.why`
//!   saying why (`closed`, `running`, `resumed`, `replaced`, `ended`, `forgotten`,
//!   `not_retryable`, `skipped`), and `retry.unknown_subagent` when the chat has no such subagent.
//! - Once its turn ends with the subagent still failed, the automatic attempts go on as they
//!   would have; a subagent that had none left (stopped or given up) stays as it was.

use super::{Failure, PROVENANCE_KIND, Step, Wait, closing};
use crate::hub::auto_resume::retry_turn::{RetryBy, busy};
use crate::hub::{Hub, PromptOptions, Session};
use crate::protocol::session::{RetryKind, RetryResult};
use crate::rpc::RpcError;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::sync::Notify;

/// One attempt a person's retry claimed: fired, its prompt not sent yet.
pub(super) struct Claim {
    id: String,
    wait: Wait,
    failure: Failure,
    name: Option<String>,
    /// No automatic attempt was coming (stopped or given up): none comes after this one either.
    idle: bool,
    /// It took over the waiting automatic attempt `wait`.
    took_over: bool,
    /// The subagent's attempt count before the claim.
    attempts: usize,
}

fn nothing_failed(id: &str, why: &str) -> RpcError {
    let msg =
        format!("retry.nothing_failed: subagent {id} is not failed or cannot be retried ({why})");
    RpcError::invalid_params(msg)
        .with_data(json!({"reason": "retry.nothing_failed", "subagentId": id, "why": why}))
}

fn unknown(id: &str) -> RpcError {
    let msg = format!("retry.unknown_subagent: this chat has no subagent {id}");
    RpcError::invalid_params(msg)
        .with_data(json!({"reason": "retry.unknown_subagent", "subagentId": id}))
}

impl Hub {
    /// Retries the chat's failed subagent `subagent` now (the module doc).
    pub(crate) async fn retry_subagent(
        self: &Arc<Self>,
        session: &Arc<Session>,
        subagent: &str,
        by: RetryBy,
    ) -> Result<Value, RpcError> {
        self.retry_allowed(session, &by).await?;
        let of = self.retry_delays().await.len();
        let claim = self.claim_subagent(session, subagent, of)?;
        self.send_claim(session, subagent, claim, by).await
    }

    /// Sends `claim`'s prompt under the caller's rules, never queued (`PromptOptions::no_queue`),
    /// and answers once it is accepted. Refused before it is recorded, nothing went: the claim is
    /// given back ([`Hub::unclaim`]).
    pub(super) async fn send_claim(
        self: &Arc<Self>,
        session: &Arc<Session>,
        subagent: &str,
        claim: Claim,
        by: RetryBy,
    ) -> Result<Value, RpcError> {
        let mut provenance = json!({"kind": PROVENANCE_KIND, "subagentId": claim.id,
            "agentId": claim.failure.agent_id, "attempt": claim.wait.attempt, "manual": true});
        if let Some(from) = by.from {
            provenance.set("from", json!(from));
        }
        let opts = PromptOptions {
            control: by.control,
            trust_gate: by.trust_gate,
            full_access_device: by.full_access_device,
            provenance: Some(provenance),
            no_queue: true,
            ..PromptOptions::default()
        };
        let (tx, rx) = tokio::sync::oneshot::channel::<Value>();
        let accepted = Arc::new(AtomicBool::new(false));
        let seen = accepted.clone();
        let on_accepted: Box<dyn FnOnce(Value) + Send> = Box::new(move |v| {
            seen.store(true, Ordering::SeqCst);
            let _ = tx.send(v);
        });
        let (hub, s) = (self.clone(), session.clone());
        // The turn runs on, and the automatic attempts after it: only acceptance is awaited.
        let task = tokio::spawn(async move {
            let (id, wait, failure) = (&claim.id, &claim.wait, &claim.failure);
            let name = claim.name.as_deref();
            let result = hub.send_attempt(&s, id, wait, failure, name, opts, Some(on_accepted));
            let result = result.await;
            if !accepted.load(Ordering::SeqCst) {
                hub.unclaim(&s, &claim);
            } else if hub.end_attempt(&s, id, wait) {
                // Its own task: this one's result is not held up by the next attempt's wait.
                let (hub, s, id, idle) = (hub.clone(), s.clone(), id.clone(), claim.idle);
                tokio::spawn(async move { hub.after_manual(&s, &id, idle).await });
            }
            result
        });
        let accepted = match rx.await {
            Ok(v) => v,
            // Dropped before acceptance: the prompt was refused.
            Err(_) => match task.await {
                Ok(Ok(v)) => v,
                Ok(Err(e)) => {
                    let reason = e.data.as_ref().and_then(|d| d.get("reason"));
                    return Err(match reason.and_then(Value::as_str) {
                        // Stop, a resume or a replacement came before its turn started.
                        Some("subagent_retry.skipped") => nothing_failed(subagent, "skipped"),
                        _ => e,
                    });
                }
                Err(e) => return Err(RpcError::internal(e.to_string())),
            },
        };
        let prompt_id = accepted.get("promptId").and_then(Value::as_str).unwrap_or_default();
        let turn_id = accepted.get("turnId").and_then(Value::as_str).map(str::to_owned);
        let result =
            RetryResult { prompt_id: prompt_id.to_owned(), turn_id, kind: RetryKind::Subagent };
        Ok(serde_json::to_value(result).unwrap_or(Value::Null))
    }

    /// Gives back `claim`, whose prompt was refused before it was recorded, when it is still the
    /// subagent's (a Stop, a resume or a replacement since then took it): the attempt count and
    /// stop as they were, and a wait it took over waits again (a new task, `scheduled` logged),
    /// to its old time. One that had no wait yet gets its first one planned.
    fn unclaim(self: &Arc<Self>, session: &Arc<Session>, claim: &Claim) {
        let _steps = self.subagent_retries.steps();
        let rearm = {
            let mut all = self.subagent_retries.lock();
            all.sent.remove(&(session.id.clone(), claim.wait.prompt_id.clone()));
            let Some(sub) = all.subs.get_mut(&session.id).and_then(|s| s.get_mut(&claim.id)) else {
                return;
            };
            let wait = sub.failed.as_ref().and_then(|f| f.wait.as_ref());
            if !wait.is_some_and(|w| w.is(&claim.wait)) {
                return;
            }
            sub.attempts = claim.attempts;
            let Some(failure) = sub.failed.as_mut() else { return };
            failure.idle = claim.idle;
            if claim.took_over {
                let wait = Wait {
                    wake: Arc::new(Notify::new()),
                    fired: false,
                    fired_at: 0,
                    manual: false,
                    ..claim.wait.clone()
                };
                failure.wait = Some(wait.clone());
                Some((failure.clone(), wait))
            } else {
                failure.wait = None;
                None
            }
        };
        let session = session.clone();
        let (hub, id) = (self.clone(), claim.id.clone());
        let Some((failure, wait)) = rearm else {
            if claim.idle {
                // No attempt comes: its entry says this one is no longer in flight.
                self.log_entry(&session, &id, &claim.failure, "failed", Value::Null, true);
            } else {
                tokio::spawn(async move { hub.schedule_subagent_retry(&session, &id).await });
            }
            return;
        };
        let retry = json!({"attempt": wait.attempt, "of": wait.of, "reason": failure.reason,
            "nextAt": wait.next_at});
        let extra = json!({"attempt": wait.attempt, "of": wait.of, "nextAt": wait.next_at,
            "promptId": wait.prompt_id});
        let step = Step { outcome: "scheduled", state: "failed", retry, retryable: true, extra };
        self.log_step(&session, &id, &failure, step);
        let delay = wait.next_at.saturating_sub(crate::store::now_ms());
        tokio::spawn(async move { hub.run_subagent_retry(&session, &id, wait, delay).await });
    }

    /// Claims an attempt at the chat's failed subagent `subagent` (by id or agent id): its waiting
    /// one, taken over, or a new one, fired and logged (`fired`, `manual: true`). Refused as the
    /// module doc says.
    pub(super) fn claim_subagent(
        &self,
        session: &Session,
        subagent: &str,
        of: usize,
    ) -> Result<Claim, RpcError> {
        let _steps = self.subagent_retries.steps();
        if closing(session) {
            return Err(nothing_failed(subagent, "closed"));
        }
        let busy_now = session.turn().is_some()
            || session.queue().iter().any(|q| !q.aside())
            || session.harness_turn.load(Ordering::SeqCst)
            || self.continuation_pending(session)
            || session.moving().is_some();
        let claim = {
            let mut all = self.subagent_retries.lock();
            let all = &mut *all;
            let subs = all.subs.get_mut(&session.id);
            let named = |id: &str, agent: Option<&str>| id == subagent || agent == Some(subagent);
            let found = subs.and_then(|subs| {
                subs.iter_mut().find(|(id, s)| {
                    let agent = s.failed.as_ref().map(|f| f.agent_id.as_str());
                    named(id.as_str(), agent.or(s.raw_agent.as_deref()))
                })
            });
            let gone = all.gone.get(&session.id).into_iter().flatten();
            let gone = gone.rev().find(|g| named(&g.id, g.agent_id.as_deref())).map(|g| g.why);
            let Some((id, sub)) = found else {
                return Err(match gone {
                    Some(why) => nothing_failed(subagent, why),
                    None => unknown(subagent),
                });
            };
            let (attempts, name) = (sub.attempts, sub.name.clone());
            let Some(failure) = sub.failed.as_mut() else {
                // It runs: resumed after it failed, or it never failed.
                return Err(nothing_failed(subagent, gone.unwrap_or("running")));
            };
            if busy_now || failure.wait.as_ref().is_some_and(|w| w.fired) {
                return Err(busy());
            }
            let idle = failure.idle;
            let took_over = failure.wait.is_some();
            let wait = failure.wait.get_or_insert_with(|| {
                let next_at = crate::store::now_ms();
                let tool = id.rsplit('/').next().unwrap_or(id);
                let attempt = attempts + 1;
                Wait {
                    attempt,
                    of,
                    next_at,
                    prompt_id: format!("subagent-retry-{tool}-{attempt}-{next_at}"),
                    wake: Arc::new(Notify::new()),
                    fired: false,
                    fired_at: 0,
                    manual: false,
                }
            });
            wait.fired = true;
            wait.fired_at = crate::store::now_ms();
            wait.manual = true;
            let wait = wait.clone();
            // In flight, it is no failure a Stop already ended (`stop_subagent_retries`).
            failure.idle = false;
            let failure = failure.clone();
            sub.attempts = attempts.max(wait.attempt);
            let claim = Claim { id: id.clone(), wait, failure, name, idle, took_over, attempts };
            all.sent.insert((session.id.clone(), claim.wait.prompt_id.clone()), false);
            claim
        };
        let wait = &claim.wait;
        let extra = json!({"attempt": wait.attempt, "of": wait.of, "promptId": wait.prompt_id,
            "manual": true});
        let step =
            Step { outcome: "fired", state: "failed", retry: Value::Null, retryable: true, extra };
        self.log_step(session, &claim.id, &claim.failure, step);
        // The waiting task wakes and finds its attempt taken (`still_waiting`).
        if claim.took_over {
            wait.wake.notify_one();
        }
        Ok(claim)
    }

    /// A person's attempt whose turn ended with the subagent still failed: the automatic attempts
    /// go on, unless none was coming before it (`idle`).
    async fn after_manual(self: &Arc<Self>, session: &Arc<Session>, id: &str, idle: bool) {
        if !idle {
            return self.schedule_subagent_retry(session, id).await;
        }
        let _steps = self.subagent_retries.steps();
        let failure = {
            let mut all = self.subagent_retries.lock();
            let sub = all.subs.get_mut(&session.id).and_then(|s| s.get_mut(id));
            match sub.and_then(|s| s.failed.as_mut()).filter(|f| f.wait.is_none()) {
                Some(failure) => {
                    failure.idle = true;
                    failure.clone()
                }
                None => return,
            }
        };
        // Its attempt is over: its entry says so.
        self.log_entry(session, id, &failure, "failed", Value::Null, true);
        self.forget_past_limit(session);
    }
}
