//! Part of `Hub`; see `hub/mod.rs`. A turn whose agent says nothing: a model
//! that never answers (an OpenCode free model that stalls, a provider that
//! hangs) left the chat on "Thinking" with no end and no sign why. When a
//! prompt went out and the agent sent no sign of its model at work
//! (`Session::heard`, `tap.rs` `from_the_model`: a message, thought, tool call,
//! plan, compaction or request, or a harness line only a responding model
//! produces) for `silentTurnMs` (default 90 s), the chat logs `turn_silent`
//! {turnId, silentMs, reason} once, so a client can say the model has not answered.
//! The model's first sign after it logs `turn_heard` {turnId}, which ends that
//! on every client. The agent's own bookkeeping is no answer: Codex reports its
//! turn and its usage as soon as the prompt goes out, whatever its model does.
//! Only silence from the prompt counts: an agent that answered and then works
//! quietly (a long command) is not silent.
//!
//! `reason` says why, as far as acpmux can tell, so the chat never shows a bare "No response
//! from the model yet" (Leo, 2026-11-03: "and why am i getting this"): `kind` is `retrying`
//! (the harness retries its model API: Claude Code's `api_retry`, with `attempt` and `of`),
//! `capacity` (the provider is overloaded or rate limited), `auth` (its sign-in was refused),
//! `unavailable` (the provider or its route cannot be reached), or `no_answer` (nothing says
//! why). `detail` is the harness's own line (credentials masked). The reason comes from the
//! turn's API retries and its harness's stderr since the prompt; a reason that changes while
//! the turn stays silent logs `turn_silent` again for the same turn, with the new one.
//!
//! `_acpmux/retry` with `silent: true` ends a silent turn as failed (`detail` `silent`) and sends
//! it again (`Hub::end_silent_turn`): the chat's Retry on the silent line.

use super::*;

/// How long Retry waits for the silent turn to end before it gives up (`retry.busy`).
const SILENT_END: std::time::Duration = std::time::Duration::from_secs(8);

/// Why `session`'s quiet turn is quiet (module docs): its last API retry, else the last stderr
/// line that says why, else `no_answer`.
pub(super) fn quiet_reason(session: &Session) -> Value {
    let retry = session.api_retry.lock().unwrap_or_else(|e| e.into_inner()).clone();
    if let Some(retry) = retry {
        return retry_reason(&retry);
    }
    let tail: Vec<String> =
        session.stderr_tail.lock().unwrap_or_else(|e| e.into_inner()).iter().cloned().collect();
    for line in tail.iter().rev().filter(|line| super::exit_reason::explains_exit(line)) {
        if let Some(kind) = crate::session_liveness::classify_text(line).and_then(stuck_kind) {
            return json!({"kind": kind, "detail": crate::session_liveness::redact(line)});
        }
    }
    json!({"kind": "no_answer"})
}

/// The reason one Claude Code `api_retry` line gives: `{type: "system", subtype: "api_retry",
/// attempt, max_retries, error_status, error}`.
fn retry_reason(retry: &Value) -> Value {
    let status = retry.get("error_status").and_then(Value::as_u64);
    let error = retry.get("error").and_then(Value::as_str).filter(|e| *e != "unknown");
    let text =
        format!("{} {}", status.map(|s| s.to_string()).unwrap_or_default(), error.unwrap_or(""));
    let lower = text.to_lowercase();
    let kind = if matches!(status, Some(429 | 529))
        || lower.contains("overloaded")
        || lower.contains("rate_limit")
    {
        "capacity"
    } else {
        crate::session_liveness::classify_text(&text).and_then(stuck_kind).unwrap_or("retrying")
    };
    let mut reason = json!({"kind": kind});
    if let Some(attempt) = retry.get("attempt").and_then(Value::as_u64) {
        reason.set("attempt", attempt);
    }
    if let Some(of) = retry.get("max_retries").and_then(Value::as_u64) {
        reason.set("of", of);
    }
    if !text.trim().is_empty() {
        reason.set("detail", crate::session_liveness::redact(text.trim()));
    }
    reason
}

fn stuck_kind(reason: crate::session_liveness::StuckReason) -> Option<&'static str> {
    use crate::session_liveness::StuckReason::*;
    match reason {
        Auth => Some("auth"),
        Capacity => Some("capacity"),
        HarnessUnavailable => Some("unavailable"),
        SpawnFailed => None,
    }
}

impl Hub {
    /// Watches `session`'s turn `turn_id`, whose prompt goes out now (module docs).
    pub(super) async fn watch_silent_turn(self: &Arc<Self>, session: &Arc<Session>, turn_id: &str) {
        // What explained an earlier turn's silence is not this one's.
        *session.api_retry.lock().unwrap_or_else(|e| e.into_inner()) = None;
        *session.silent_reason.lock().unwrap_or_else(|e| e.into_inner()) = None;
        let Some(after) = self.config.read().await.silent_turn() else { return };
        let heard = session.heard.load(Ordering::SeqCst);
        let hub = self.clone();
        let session = session.clone();
        let turn_id = turn_id.to_owned();
        tokio::spawn(async move {
            tokio::time::sleep(after).await;
            // Held while it logs, so a sign the tap counts meanwhile finds the silence to end.
            let mut silent = session.silent_turn.lock().unwrap_or_else(|e| e.into_inner());
            if session.turn().is_some_and(|t| t.turn_id == turn_id)
                && session.heard.load(Ordering::SeqCst) == heard
            {
                let reason = quiet_reason(&session);
                tracing::warn!(session = %session.id, turn = %turn_id, %reason, "the agent has said nothing since the prompt");
                let silent_ms = u64::try_from(after.as_millis()).unwrap_or(u64::MAX);
                *session.silent_reason.lock().unwrap_or_else(|e| e.into_inner()) =
                    Some(reason.clone());
                hub.append(
                    &session,
                    "mux",
                    "turn_silent",
                    json!({"turnId": turn_id, "silentMs": silent_ms, "reason": reason}),
                );
                *silent = Some(turn_id);
            }
        });
    }

    /// The harness said something that may say why its turn is quiet (an API retry, a stderr
    /// line): a silent turn whose reason it changes logs `turn_silent` again (module docs).
    pub(super) fn quiet_changed(&self, session: &Session) {
        let silent = session.silent_turn.lock().unwrap_or_else(|e| e.into_inner());
        let Some(turn_id) = silent.as_ref() else { return };
        if !session.turn().is_some_and(|t| &t.turn_id == turn_id) {
            return;
        }
        let reason = quiet_reason(session);
        {
            let mut last = session.silent_reason.lock().unwrap_or_else(|e| e.into_inner());
            if last.as_ref() == Some(&reason) {
                return;
            }
            *last = Some(reason.clone());
        }
        let silent_ms = self.quiet_ms(session);
        self.append(
            session,
            "mux",
            "turn_silent",
            json!({"turnId": turn_id, "silentMs": silent_ms, "reason": reason}),
        );
    }

    /// How long `session`'s turn has been quiet, in ms (as `settle_stalled_turns` counts it).
    fn quiet_ms(&self, session: &Session) -> u64 {
        let heard = session.heard_at.load(Ordering::Relaxed);
        (self.clock_now() as i64).saturating_sub(heard).max(0) as u64 / 1_000_000
    }

    /// Claude Code retries its model API (`claude.system.api_retry`): the turn's quiet reason.
    pub(super) fn note_api_retry(&self, session: &Session, params: &Value) {
        *session.api_retry.lock().unwrap_or_else(|e| e.into_inner()) = Some(params.clone());
        self.quiet_changed(session);
    }

    /// The tap heard `session`'s model: a turn that logged `turn_silent` logs `turn_heard`.
    pub(super) fn heard_after_silence(&self, session: &Session) {
        // The model answers: an API retry before it no longer says anything of this turn.
        *session.api_retry.lock().unwrap_or_else(|e| e.into_inner()) = None;
        let Some(turn_id) = session.silent_turn.lock().unwrap_or_else(|e| e.into_inner()).take()
        else {
            return;
        };
        *session.silent_reason.lock().unwrap_or_else(|e| e.into_inner()) = None;
        if session.turn().is_some_and(|t| t.turn_id == turn_id) {
            self.append(session, "mux", "turn_heard", json!({"turnId": turn_id}));
        }
    }

    /// `_acpmux/retry` `silent`: ends `session`'s silent turn as failed (`detail` `silent`), the
    /// way a stalled turn ends (`stalled_turn.rs`: the agent gets the cancel, then the forced
    /// end), and returns once it has ended, so the retry finds a failed turn to send again. A
    /// chat whose running turn is not silent is `retry.busy`, as any retry over a running turn.
    pub(crate) async fn end_silent_turn(&self, session: &Arc<Session>) -> Result<(), RpcError> {
        let Some(turn_id) = session.silent_turn.lock().unwrap_or_else(|e| e.into_inner()).clone()
        else {
            return Err(super::auto_resume::retry_turn::busy());
        };
        if !session.turn().is_some_and(|t| t.turn_id == turn_id) {
            return Err(super::auto_resume::retry_turn::busy());
        }
        let silent_ms = self.quiet_ms(session);
        let _ = tokio::time::timeout(std::time::Duration::from_secs(5), async {
            let child = session.child.lock().await.clone();
            if let (Some(child), Some(sid)) = (child, session.meta().agent_session_id) {
                let _ = child.notify(method::SESSION_CANCEL, json!({"sessionId": sid})).await;
            }
        })
        .await;
        if session.turn().is_some_and(|t| t.turn_id == turn_id) {
            let answer =
                json!({"stopReason": "cancelled", "_meta": {"acpmux": {"silentMs": silent_ms}}});
            session.steer_end.send_replace(Some((turn_id, answer)));
        }
        // The turn holds the turn lock until it has ended and its failure is written.
        match tokio::time::timeout(SILENT_END, session.turn_lock.lock()).await {
            Ok(_ended) => Ok(()),
            Err(_) => Err(super::auto_resume::retry_turn::busy()),
        }
    }
}
