//! Pending prompt identities remain owned by the session until they settle.

use super::{Hub, PromptOutcome, Session};
use crate::rpc::RpcError;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use sha2::Digest;
use std::collections::{HashSet, VecDeque};
use std::sync::Arc;

/// Settles a restored prompt's outcome once: the first settled answer stays (a decline before its
/// restored task claimed it, `queue_approve.rs`, is never replaced by that task's `withdrawn`).
pub(super) fn settle_once(outcome: &PromptOutcome, answer: Result<Value, crate::rpc::RpcError>) {
    outcome.send_if_modified(|settled| settled.is_none() && settled.replace(answer).is_none());
}

/// An adopted turn owns its prompt id until its real answer arrives. A resend then joins
/// this pending outcome instead of interpreting the open journal turn as interrupted.
pub(super) fn recover(session: &Session, prompt_id: &str) -> PromptOutcome {
    let mut ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((_, outcome)) = ledger.iter().find(|(id, _)| id == prompt_id) {
        return outcome.clone();
    }
    let outcome = Arc::new(tokio::sync::watch::channel(None).0);
    ledger.push_back((prompt_id.to_owned(), outcome.clone()));
    outcome
}

/// Only completed outcomes count against the retry cache's bound. Pending senders
/// must stay discoverable, including restored prompts whose completion looks them up.
pub(super) fn prune(ledger: &mut VecDeque<(String, PromptOutcome)>) {
    const COMPLETED_OUTCOMES: usize = 64;
    let mut excess = ledger
        .iter()
        .filter(|(_, outcome)| outcome.borrow().is_some())
        .count()
        .saturating_sub(COMPLETED_OUTCOMES);
    if excess == 0 {
        return;
    }
    ledger.retain(|(_, outcome)| {
        if excess > 0 && outcome.borrow().is_some() {
            excess -= 1;
            false
        } else {
            true
        }
    });
}

/// Reconstruct only fields the persisted outcome actually retained.
fn persisted_outcome(result: Value, settled: Value) -> Result<Value, RpcError> {
    if settled.get("status").and_then(Value::as_str) == Some("failed") {
        let code = settled.get("code").and_then(Value::as_i64).unwrap_or(-32603);
        let message = settled
            .get("error")
            .and_then(Value::as_str)
            .or_else(|| settled.get("errorText").and_then(Value::as_str))
            .unwrap_or("the original prompt failed");
        let mut data = settled.clone();
        if let (Some(data), Some(original)) =
            (data.as_object_mut(), settled.get("data").and_then(Value::as_object))
        {
            data.extend(original.clone());
        }
        return Err(RpcError::new(code, message).with_data(data));
    }
    Ok(result)
}

/// The kinds `Hub::logged_prompt_state` reads a prompt's state from: each is in
/// `INDEXED_KINDS`, so the read takes the log's copies (a test keeps them there).
pub(crate) const PROMPT_STATE_KINDS: &[&str] = &[
    "turn_stop_requested",
    "queued",
    "user_message",
    "turn_started",
    "turn_result",
    "prompt_refused",
    "queue_declined",
    "queue_removed",
    "dequeued",
];

impl Hub {
    /// Read an accepted prompt without submitting another turn. An adopted active turn
    /// may have no in-memory ledger entry: its persisted completion wakes this wait.
    pub async fn prompt_outcome(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
    ) -> Result<Value, RpcError> {
        // Subscribe before reading either source so completion cannot fall in a lookup gap.
        let mut events = self.subscribe();
        self.wait_adopted(session).await;
        self.session_log(session).await;
        loop {
            let pending = session
                .prompts
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .iter()
                .find(|(id, _)| id == prompt_id)
                .map(|(_, outcome)| outcome.subscribe());
            if let Some(mut pending) = pending {
                return pending
                    .wait_for(Option::is_some)
                    .await
                    .map_err(|_| RpcError::internal("the first run of this prompt was dropped"))?
                    .clone()
                    .ok_or_else(|| RpcError::internal("prompt outcome is missing"))?;
            }
            let (result, settled) =
                self.logged_prompt_state(session, prompt_id, true).ok_or_else(|| {
                    RpcError::invalid_params("the session has no outcome for this promptId")
                        .with_data(
                            json!({"reason": "prompt_outcome_unknown", "promptId": prompt_id}),
                        )
                })?;
            if let Some(settled) = settled {
                return persisted_outcome(result?, settled);
            }
            // Only a settled outcome is an error (a decline): an unsettled one is a value.
            let result = result?;
            // finish_turn takes `turn` before awaiting its final writes, while the session
            // still says Running. A settled orphan has neither an active nor finishing turn.
            let active =
                session.turn.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(|turn| {
                    turn.prompt_id == prompt_id
                        || result.pointer("/_meta/acpmux/turnId").and_then(Value::as_str)
                            == Some(turn.turn_id.as_str())
                });
            let active = active.unwrap_or_else(|| {
                if session.status() != crate::store::SessionStatus::Running {
                    return false;
                }
                let mut latest = None;
                let _ = self.store.scan_kinds(&session.id, &["turn_started"], &mut |record| {
                    latest = record.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
                    true
                });
                latest.as_deref().is_some_and(|id| {
                    result.pointer("/_meta/acpmux/turnId").and_then(Value::as_str) == Some(id)
                })
            });
            if !active {
                // Completion may have overtaken the first log read before its status settled.
                if self
                    .logged_prompt_state(session, prompt_id, true)
                    .is_some_and(|(_, settled)| settled.is_some())
                {
                    continue;
                }
                // A compacted old failure can retain only lastTurn. Once no matching turn
                // can still finish, preserve that failure instead of returning a success.
                if let Some(last) = session.meta().last_turn.filter(|last| {
                    last.get("promptId").and_then(Value::as_str) == Some(prompt_id)
                        && last.get("status").and_then(Value::as_str) == Some("failed")
                }) {
                    return persisted_outcome(result, last);
                }
                return Ok(result);
            }
            // Only terminal/queue changes warrant another log read, never every token.
            loop {
                match events.recv().await {
                    Ok(event)
                        if event.session_id == session.id
                            && matches!(
                                event.record.kind.as_str(),
                                "turn_result"
                                    | "queue_removed"
                                    | "queued"
                                    | "dequeued"
                                    | "prompt_refused"
                                    | "status"
                            ) =>
                    {
                        break;
                    }
                    Ok(_) => {}
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => break,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                        return Err(RpcError::internal("prompt outcome event stream closed"));
                    }
                }
            }
        }
    }

    /// Whether session `session`'s log records a turn that ran `prompt_id` (its `user_message`,
    /// alone or joined with other agent messages, `digest.rs`). Blocking: it reads the log.
    pub(crate) fn ran_prompt(&self, session: &str, prompt_id: &str) -> bool {
        let names = |m: &Value| m.get("promptId").and_then(Value::as_str) == Some(prompt_id);
        let mut ran = false;
        let _ = self.store.scan_kinds(session, &["user_message"], &mut |rec| {
            let joined = rec.msg.pointer("/_meta/provenance/messages").and_then(Value::as_array);
            ran = names(&rec.msg) || joined.is_some_and(|m| m.iter().any(names));
            !ran
        });
        ran
    }

    /// Whether session `session` took prompt `prompt_id` already: its ledger holds it, or, for a
    /// `resend`, its log does (`requests.rs`: a resend whose uploads are gone still answers with
    /// its first run). Blocking: it may read the log.
    pub fn knows_prompt(&self, session: &Session, prompt_id: &str, resend: bool) -> bool {
        let ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
        let held = ledger.iter().any(|(id, _)| id == prompt_id);
        drop(ledger);
        held || (resend && self.logged_prompt(session, prompt_id).is_some())
    }

    /// Read one trigger delivery from the durable event log. This deliberately does not use
    /// `lastTurn` or the live preview: another human turn may have advanced those fields.
    pub(crate) fn trigger_delivery(&self, session: &Session, delivery: &str) -> Value {
        const MAX_REPLY: usize = 16 * 1024;
        let mut turn_id = None::<String>;
        let mut result = None::<Value>;
        let mut state = "unknown";
        let mut reply = String::new();
        let mut reply_chars = 0;
        let mut reply_open = false;
        let mut active = false;
        let mut started = false;
        let mut settled = false;
        let mut closed_window = false;
        let mut prompt_hash = None::<String>;
        let mut permissions = HashSet::<String>::new();
        let scanned = self.store.scan_strict(&session.id, 0, &mut |rec| {
            let field = |key: &str| rec.msg.get(key).and_then(Value::as_str);
            let mux = rec.dir == "mux";
            // Only daemon-authored admission records bind a delivery. A human prompt
            // or a harness event can reuse its promptId, but grants no trigger authority.
            if mux && matches!(rec.kind.as_str(), "queued" | "user_message")
                && field("promptId") == Some(delivery)
            {
                let provenance = crate::prompt_provenance::recorded(&rec.msg);
                let trusted = provenance.as_ref().is_some_and(|p| {
                    p.get("kind").and_then(Value::as_str) == Some("trigger")
                        && p.get("deliveryId").and_then(Value::as_str) == Some(delivery)
                        && p.get("session").and_then(Value::as_str) == Some(session.id.as_str())
                        && crate::prompt_provenance::of(
                            &json!({"_meta": {"acpmux": {"provenance": p}}}),
                            crate::prompt_provenance::Sender::Trigger,
                        ).is_ok()
                });
                if !started && result.is_none() && trusted {
                    if let (Some(id), Some(text)) = (field("turnId"), field("text")) {
                        let hash = format!("{:x}", sha2::Sha256::digest(text.as_bytes()));
                        if prompt_hash.as_ref().is_some_and(|prior| prior != &hash) {
                            state = "failed";
                            result = Some(json!({"status": "failed", "error": "trigger prompt changed after admission"}));
                            return false;
                        }
                        prompt_hash = Some(hash);
                        turn_id = Some(id.to_owned());
                        state = "queued";
                    }
                } else if !started && turn_id.is_some() && !trusted {
                    // A person's queue edit drops the trigger provenance. Do not
                    // attribute the edited prompt's output to the original delivery.
                    state = "failed";
                    result = Some(json!({"status": "failed", "error": "trigger prompt ownership changed"}));
                    return false;
                }
            }
            let Some(id) = turn_id.as_deref() else { return true };
            let exact = field("turnId") == Some(id);
            if mux && rec.kind == "queue_updated" && field("promptId") == Some(delivery) {
                state = "failed";
                result = Some(json!({"status": "failed", "error": "trigger prompt was edited"}));
                return false;
            }
            if mux && rec.kind == "permission_decision"
                && let Some(permission) = field("permissionId")
            {
                // Decisions omit turnId. Only IDs established by this exact turn's
                // request may settle its attention, even after another turn starts.
                permissions.remove(permission);
            }
            if closed_window { return true; }
            if mux && rec.kind == "turn_started" {
                if started && !exact {
                    active = false;
                    closed_window = true;
                    if !settled {
                        state = "failed";
                        result = Some(json!({"status": "interrupted", "turnId": id}));
                    }
                    return true;
                }
                if exact && field("promptId") == Some(delivery) && rec.msg.get("trigger").and_then(Value::as_bool) == Some(true)
                    && result.is_none()
                {
                    active = true;
                    started = true;
                    state = "running";
                } else if exact && !started {
                    state = "failed";
                    result = Some(json!({"status": "failed", "error": "trigger turn ownership changed"}));
                    return false;
                }
            }
            if mux && matches!(rec.kind.as_str(), "permission_request" | "permission_reissued")
                && exact
                && let Some(permission) = field("permissionId")
            {
                permissions.insert(permission.to_owned());
            }
            if active && rec.dir == "in"
                && rec.msg.get("method").and_then(Value::as_str) == Some("session/update")
                && rec.msg.pointer("/params/_meta/acpmux/subagent").is_none()
                && field("turnId").is_none_or(|turn| turn == id)
            {
                match rec.kind.as_str() {
                    "agent_message_chunk" if rec.msg.pointer("/params/update/sessionUpdate")
                        .and_then(Value::as_str) == Some("agent_message_chunk") => {
                        if let Some(text) = rec.msg.pointer("/params/update/content/text").and_then(Value::as_str) {
                            if !reply_open {
                                reply.clear();
                                reply_chars = 0;
                                reply_open = true;
                            }
                            let chunk: String = text.chars().take(MAX_REPLY.saturating_sub(reply_chars)).collect();
                            reply_chars += chunk.chars().count();
                            reply.push_str(&chunk);
                        }
                    }
                    "tool_call" | "tool_call_update" | "agent_thought_chunk" | "plan" => reply_open = false,
                    _ => {}
                }
            }
            if mux && exact && !settled {
                match rec.kind.as_str() {
                    "turn_end" | "turn_error" => {
                        active = false;
                        state = if rec.kind == "turn_error" { "failed" } else { "running" };
                        result = Some(rec.msg.clone());
                        // turn_result follows and carries the authoritative status;
                        // do not mistake turn_error (which has no status) for success.
                    }
                    "turn_result" => {
                        active = false;
                        settled = true;
                        state = match field("status") {
                            Some("completed") => "completed",
                            Some("attention" | "input_required" | "waiting") => "attention",
                            _ => "failed",
                        };
                        result = Some(rec.msg.clone());
                    }
                    "queue_removed" | "prompt_refused" | "turn_stop_requested" => {
                        active = false;
                        // A stop request may still receive its authoritative result.
                        settled = rec.kind != "turn_stop_requested";
                        state = "failed";
                        result = Some(rec.msg.clone());
                    }
                    _ => {}
                }
            }
            true
        });
        if scanned.is_err() {
            // A partial journal is not evidence of completion or of a safe resend.
            return json!({"delivery": delivery, "state": "failed", "error": "trigger delivery journal could not be read"});
        }
        if !permissions.is_empty() {
            state = "attention";
        }
        let mut out = json!({"delivery": delivery, "state": state});
        if let Some(id) = turn_id {
            out.set("turnId", json!(id));
        }
        if let Some(hash) = prompt_hash {
            out.set("promptHash", json!(hash));
        }
        if let Some(result) = result {
            out.set("result", result);
        }
        if !permissions.is_empty() {
            out.set("pendingPermissions", json!(permissions.len()));
        }
        if !reply.is_empty() {
            out.set("reply", json!(reply));
        }
        out
    }

    /// A prompt id the session's log already holds (`user_message` or
    /// `queued`), answered from the log: its turn's result when it ended,
    /// else `interrupted` (the daemon stopped during the turn). A durable decline remains
    /// an error after restart or eviction from the bounded in-memory outcome ledger.
    pub(super) fn logged_prompt(
        &self,
        session: &Session,
        prompt_id: &str,
    ) -> Option<Result<Value, crate::rpc::RpcError>> {
        self.logged_prompt_state(session, prompt_id, false).map(|(result, _)| result)
    }

    /// [`Self::logged_prompt`] plus a separate completion marker: the record that settled it,
    /// if one did. "Interrupted" in the value is a resend's fallback, not evidence an adopted
    /// active turn has finished. With `outcome` (`prompt_outcome`), a refusal settles the
    /// prompt as failed, a prompt logged but never started answers interrupted instead of
    /// nothing, and a compacted log falls back to `lastTurn`; a resend keeps reading neither,
    /// so it may still run a refused or unstarted prompt.
    fn logged_prompt_state(
        &self,
        session: &Session,
        prompt_id: &str,
        outcome: bool,
    ) -> Option<(Result<Value, RpcError>, Option<Value>)> {
        // Another agent's message the inbox took (`inbox.rs`): answered from its records, its
        // error kept as one for an outcome.
        if outcome {
            if let Some(answer) = self.logged_inbox_answer(session, prompt_id) {
                return Some((answer, Some(json!({}))));
            }
        } else if let Some(inbox) = self.logged_inbox(session, prompt_id) {
            return Some((Ok(inbox), None));
        }
        // The last completed turn may predate a later queued/declined incarnation reusing
        // this client id. Reconstruct the latest incarnation from its ordered durable records.
        let mut turn_id: Option<String> = None;
        let mut stopped_turns = HashSet::new();
        let mut started = false;
        let mut ended: Option<Value> = None;
        // The owner declined it (`queue_approve.rs`): its resend is told so, after a restart too.
        let mut declined = false;
        // The inbox digest that took it, once one did (`inbox_digest.rs`). Its turn is the
        // digest's only once the digest's turn starts: one that never did gave it back.
        let mut digest: Option<String> = None;
        // Every resend reads this (a team message, a watch, an outbox retry), on chats that
        // grow to a million records: the kinds below only, from the log's copies of them
        // (`store/kind_index.rs`), never the log.
        let _ = self.store.scan_kinds(&session.id, PROMPT_STATE_KINDS, &mut |rec| {
            let field = |k: &str| rec.msg.get(k).and_then(Value::as_str);
            // Admission installs the live turn before user_message is durable. Stop can
            // therefore be journaled before we learn which turn owns this prompt.
            if rec.kind == "turn_stop_requested"
                && let Some(id) = rec.msg.get("turnId").and_then(Value::as_str)
            {
                stopped_turns.insert(id.to_owned());
                // New Stop records name the accepted prompt even if the daemon died
                // before writing any user_message. Older records still join by turn ID.
                if rec.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id)
                    && !started
                    && ended.is_none()
                {
                    turn_id = Some(id.to_owned());
                }
            }
            match (rec.kind.as_str(), &turn_id) {
                // Put back after the turn it joined failed (`digest.rs` `requeue_joined`): it
                // waits again under its own turn id. Ahead of the arm below, which would take
                // the record too and keep the refused digest this prompt's.
                ("queued", Some(_))
                    if rec.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id)
                        && rec.msg.get("requeued") == Some(&Value::Bool(true)) =>
                {
                    turn_id = rec.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
                    started = false;
                    ended = None;
                    declined = false;
                    // Out of an inbox digest that failed too (`inbox_digest.rs`).
                    digest = None;
                }
                ("user_message" | "queued", _)
                    if !started
                        && ended.is_none()
                        && rec.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id) =>
                {
                    // An earlier message may be an orphan from a crash before admission.
                    // Follow this ID's later resend to the turn that actually ran it.
                    turn_id = rec.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
                    // A steer is accepted into an already-running parent turn and
                    // therefore has no turn_started of its own. Its user_message is
                    // the durable execution record for duplicate suppression.
                    started |= rec.msg.get("steer") == Some(&Value::Bool(true));
                }
                // A new incarnation under its client-chosen id, once the last one ran or left the
                // queue (a daemon whose ledger forgot it took the id as new): its records are this
                // prompt's now, so a decline of the new one is the answer (`queue_approve.rs`).
                ("queued", Some(_))
                    if rec.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id) =>
                {
                    turn_id = rec.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
                    started = false;
                    ended = None;
                    declined = false;
                    digest = None;
                }
                ("turn_started", Some(id))
                    if rec.msg.get("turnId").and_then(Value::as_str) == Some(id)
                        && rec.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id) =>
                {
                    started = true;
                }
                // A cut turn a restore settled for a resend to run whole (its prompt carried a
                // hidden context no continuation can carry: `log_load.rs` `mark_unknown_outcome`,
                // review of #37284 at 4bce04df, F1): this incarnation is over, unanswered, so a
                // resend of the id runs it again, and the run that resend starts (its own
                // `user_message` or `queued` record) is the prompt's from now on.
                ("turn_result", Some(id))
                    if rec.msg.get("turnId").and_then(Value::as_str) == Some(id)
                        && rec.msg.get(super::open_delivery::RERUN_ON_RESEND)
                            == Some(&Value::Bool(true)) =>
                {
                    turn_id = None;
                    started = false;
                    ended = None;
                    declined = false;
                    digest = None;
                }
                // Read on: a failed turn of agent messages may put it back (`requeued` below).
                ("turn_result", Some(id))
                    if rec.msg.get("turnId").and_then(Value::as_str) == Some(id) =>
                {
                    ended = Some(rec.msg);
                }
                ("prompt_refused", _)
                    if outcome
                        && rec.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id) =>
                {
                    turn_id = rec
                        .msg
                        .get("turnId")
                        .and_then(Value::as_str)
                        .map(str::to_owned)
                        .or(turn_id.take());
                    let mut failure = rec.msg;
                    failure.set("status", json!("failed"));
                    ended = Some(failure);
                    return false;
                }
                ("turn_stop_requested", Some(id))
                    if rec.msg.get("turnId").and_then(Value::as_str) == Some(id) =>
                {
                    // Stop may precede turn_started while a retry waits for startup.
                    // Its message is no longer an eligible orphan: cancellation consumed
                    // the prompt even though the harness never received it. Keep scanning
                    // so an eventual result can provide the final outcome.
                    ended = Some(json!({"stopReason": "cancelled", "status": "cancelled"}));
                }
                ("queue_declined" | "queue_removed", Some(id))
                    if rec.msg.get("turnId").and_then(Value::as_str) == Some(id) =>
                {
                    // Withdrawal is a terminal outcome even when the prompt never
                    // reached turn_started. A resend must return cancellation, or the decline.
                    // Read on: a later incarnation may reuse its id (above).
                    declined |= rec.kind == "queue_declined"
                        || rec.msg.get("reason").and_then(Value::as_str) == Some("declined");
                    started = true;
                    ended = Some(json!({"stopReason": "cancelled", "status": "withdrawn"}));
                }
                // It went in with an earlier agent message's turn (`digest.rs`): that turn's.
                ("dequeued", Some(id))
                    if rec.msg.get("turnId").and_then(Value::as_str) == Some(id)
                        && rec.msg.get("joinedTurnId").is_some_and(Value::is_string) =>
                {
                    turn_id = rec.msg["joinedTurnId"].as_str().map(str::to_owned);
                    // Joined prompts run inside the existing turn and therefore do not
                    // receive their own turn_started record.
                    started = true;
                }
                // Taken into an inbox digest (`inbox_digest.rs`): its `dequeued` record names it,
                // and so does the digest's own `queued` record, logged first.
                ("dequeued", Some(id))
                    if field("turnId") == Some(id.as_str())
                        && field("digestPromptId").is_some() =>
                {
                    digest = field("digestPromptId").map(str::to_owned);
                }
                ("queued", Some(_))
                    if digest.is_none()
                        && super::digest::inbox_digest::took(&rec.msg)
                            .iter()
                            .any(|id| id == prompt_id) =>
                {
                    digest = field("promptId").map(str::to_owned);
                }
                // The digest it went into was withdrawn before its turn: so was it.
                ("queue_removed", Some(_))
                    if digest.is_some() && field("promptId") == digest.as_deref() =>
                {
                    ended = Some(json!({"stopReason": "cancelled", "status": "withdrawn"}));
                    return false;
                }
                // The digest's turn started, as the queue's restore reads it (`queue_waiting.rs`
                // `Digests`): its `turn_started`, or its steer's `user_message` (a steer goes into
                // the turn that ran then). That turn is this prompt's.
                ("turn_started", Some(_))
                    if digest.is_some() && field("promptId") == digest.as_deref() =>
                {
                    turn_id = field("turnId").map(str::to_owned);
                    started = true;
                    ended = None;
                }
                ("user_message", Some(_))
                    if digest.is_some()
                        && field("promptId") == digest.as_deref()
                        && rec.msg.get("steer") == Some(&Value::Bool(true)) =>
                {
                    turn_id = field("turnId").map(str::to_owned);
                    started = true;
                    ended = None;
                }
                _ => {}
            }
            if ended.is_none() && turn_id.as_ref().is_some_and(|id| stopped_turns.contains(id)) {
                ended = Some(json!({"stopReason": "cancelled", "status": "cancelled"}));
            }
            true
        });
        let Some(turn_id) = turn_id else {
            return if outcome { self.last_turn_outcome(session, prompt_id) } else { None };
        };
        if declined {
            let declined = super::queue::declined_error(prompt_id, &turn_id);
            return Some((Err(declined), Some(json!({"status": "withdrawn"}))));
        }
        // A user_message is written before turn_started. A crash in that interval leaves a
        // prompt that has not run and must remain eligible for recovery/resend.
        if !started && ended.is_none() && !outcome {
            return None;
        }
        let status = ended
            .as_ref()
            .and_then(|e| e.get("status").cloned())
            .unwrap_or_else(|| json!("interrupted"));
        Some((
            Ok(json!({
                "stopReason": ended.as_ref().and_then(|e| e.get("stopReason").cloned()).unwrap_or(Value::Null),
                "_meta": {"acpmux": {"promptId": prompt_id, "turnId": turn_id, "status": status, "duplicate": true}},
            })),
            ended,
        ))
    }

    /// A prompt whose records the log no longer holds, answered from the session's `lastTurn`.
    /// lastTurn is written before turn_result and omits the original code/data, so a failed
    /// summary alone does not settle a still-finishing recovered turn.
    fn last_turn_outcome(
        &self,
        session: &Session,
        prompt_id: &str,
    ) -> Option<(Result<Value, RpcError>, Option<Value>)> {
        let last = session.meta().last_turn;
        let last = last.filter(|l| l.get("promptId").and_then(Value::as_str) == Some(prompt_id))?;
        let result = json!({
            "stopReason": last.get("stopReason").cloned().unwrap_or(Value::Null),
            "_meta": {"acpmux": {"promptId": prompt_id, "turnId": last.get("turnId"), "status": last.get("status"), "duplicate": true}},
        });
        let mut settled = Some(last.clone());
        if last.get("status").and_then(Value::as_str) == Some("failed") {
            settled = None;
            let _ = self.store.scan_kinds(&session.id, &["turn_result"], &mut |record| {
                if record.msg.get("turnId") == last.get("turnId") {
                    settled = Some(record.msg);
                }
                true
            });
        }
        Some((Ok(result), settled))
    }
}

#[cfg(test)]
mod tests;

#[cfg(test)]
#[path = "trigger_delivery_tests.rs"]
mod trigger_delivery_tests;
