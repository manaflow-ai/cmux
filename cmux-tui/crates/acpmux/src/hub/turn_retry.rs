//! Part of `Hub`; see `hub/mod.rs`. A turn whose model request failed and
//! that its harness tries again: Claude Code's `system/api_retry` lines
//! (`attempt` of `max_retries`, `error`, `error_status`, `retry_delay_ms`),
//! and Codex's stream errors with `willRetry` (`stream.rs`). Clients drew the
//! turn as "Thinking" for every retry (Leo, 2026-11-03, on "Thinking 7m 49s"
//! from a chat whose model gateway was down: "i feel like this mac session
//! just keeps "thinking""). Each retry logs `turn_retrying` {turnId, attempt,
//! maxRetries?, error?, errorStatus?, retryDelayMs?, source}, so a client can
//! say the model cannot be reached instead. The model's next sign logs
//! `turn_heard` (`silent_turn.rs`), which ends it; a retry that runs out ends
//! the turn failed, as before.
//!
//! A retry of a request the model API refused for its sign-in (Claude's 401,
//! `authentication_failed`) does not wait that long. Claude Code retries it on
//! its whole backoff, about 160 s over 10 retries, and only then fails the turn
//! with the 401 the person needs to see (cloud-chaos staging run 42292894478:
//! seven retries, then the relay gave up, and no sign-in error ever showed).
//! Its first retry lets an OAuth refresh or a token that is a moment late
//! (cmux#28111) go through. At the second, acpmux ends the turn as the stalled
//! end does (`stalled_turn.rs`): the agent gets the cancel, the turn ends
//! failed with the 401 (`sign_in_refused_error`), and `finish_turn` gives it
//! the sign-in's kind and recovery text (`claude_auth.rs`, `recovery.rs`).

use super::*;
use cmux_json::JsonSet as _;

/// The fields of Claude Code's raw `system/api_retry` line a client shows.
pub(super) fn claude_retry(line: &Value) -> Value {
    let mut out = serde_json::Map::new();
    out.insert("source".into(), json!("claude"));
    if let Some(n) = line.get("attempt").and_then(Value::as_u64) {
        out.insert("attempt".into(), json!(n));
    }
    if let Some(n) = line.get("max_retries").and_then(Value::as_u64) {
        out.insert("maxRetries".into(), json!(n));
    }
    if let Some(n) = line.get("retry_delay_ms").and_then(Value::as_u64) {
        out.insert("retryDelayMs".into(), json!(n));
    }
    if let Some(n) = line.get("error_status").and_then(Value::as_u64) {
        out.insert("errorStatus".into(), json!(n));
    }
    if let Some(e) =
        line.get("error").and_then(Value::as_str).filter(|e| !e.is_empty() && *e != "unknown")
    {
        out.insert("error".into(), json!(e));
    }
    Value::Object(out)
}

/// The fields of a Codex stream error that will be retried: its message
/// ("Reconnecting... 2/5"), whose trailing count is the attempt, and the HTTP
/// status its `codexErrorInfo` names.
pub(super) fn codex_retry(err: &Value) -> Value {
    let mut out = serde_json::Map::new();
    out.insert("source".into(), json!("codex"));
    let message = err.get("message").and_then(Value::as_str).unwrap_or("");
    if let Some((attempt, max)) = attempt_of(message) {
        out.insert("attempt".into(), json!(attempt));
        out.insert("maxRetries".into(), json!(max));
    } else if let Some(n) = message
        .strip_prefix("Reconnecting")
        .and_then(|rest| rest.split_whitespace().last())
        .and_then(|n| n.parse::<u64>().ok())
    {
        // Older Codex counts with no bound: "Reconnecting... 1".
        out.insert("attempt".into(), json!(n));
    }
    if let Some(status) = http_status(err.get("codexErrorInfo").unwrap_or(&Value::Null)) {
        out.insert("errorStatus".into(), json!(status));
    }
    let detail = err
        .get("additionalDetails")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .or_else(|| Some(message).filter(|m| !m.is_empty() && !m.starts_with("Reconnecting")));
    if let Some(d) = detail {
        out.insert("error".into(), json!(d));
    }
    Value::Object(out)
}

/// The last `N/M` in `text` ("Reconnecting... 2/5"), with `0 < N <= M`.
fn attempt_of(text: &str) -> Option<(u64, u64)> {
    text.split(|c: char| c.is_whitespace() || c == '(' || c == ')' || c == '…').rev().find_map(
        |word| {
            let (a, b) = word.trim_end_matches(['.', ',', ';', ':']).split_once('/')?;
            let (a, b) = (a.parse::<u64>().ok()?, b.parse::<u64>().ok()?);
            (a > 0 && a <= b).then_some((a, b))
        },
    )
}

/// An HTTP status anywhere in Codex's `codexErrorInfo` (`{"responseStreamDisconnected":
/// {"httpStatusCode": 502}}`).
fn http_status(info: &Value) -> Option<u64> {
    match info {
        Value::Object(map) => map
            .iter()
            .find_map(|(k, v)| if k == "httpStatusCode" { v.as_u64() } else { http_status(v) }),
        _ => None,
    }
}

/// The retry at which a model request refused for its sign-in ends the turn (module docs).
const SIGN_IN_REFUSED_END_ATTEMPT: u64 = 2;

/// Whether `retry` ([`claude_retry`]'s fields) is Claude Code retrying a request the model API
/// refused for its sign-in: a 401, or Claude's `authentication_failed`.
fn sign_in_refused(retry: &Value) -> bool {
    retry["source"] == "claude"
        && (retry["errorStatus"] == 401 || retry["error"] == "authentication_failed")
}

impl Hub {
    /// Claude Code retries a model request the API refused for its sign-in (module docs): at the
    /// [`SIGN_IN_REFUSED_END_ATTEMPT`]th retry, `session`'s turn ends failed with that refusal.
    pub(super) fn end_sign_in_refused(&self, session: &Arc<Session>, retry: &Value) {
        let attempt = retry["attempt"].as_u64().unwrap_or(0);
        if !sign_in_refused(retry) || attempt < SIGN_IN_REFUSED_END_ATTEMPT {
            return;
        }
        // Read first, after the tap counted this retry's line (`heard_now`) and before the turn
        // and its marker: a new agent for the turn (a failover keeps its id), or the model
        // answering, at any point after it moves it, and the end is not carried out
        // (`stalled_gen`, as the stalled end).
        let generation = session.stalled_gen.load(Ordering::SeqCst);
        let Some(turn) = session.turn() else { return };
        // A turn a Stop ends needs no end of its own.
        if super::cancel::is_stopping(session, &turn.turn_id) {
            return;
        }
        // Once per turn: its later retries schedule no second cancel and no second end.
        {
            let mut scheduled =
                session.sign_in_refused_turn.lock().unwrap_or_else(|e| e.into_inner());
            if scheduled.as_deref() == Some(turn.turn_id.as_str()) {
                return;
            }
            *scheduled = Some(turn.turn_id.clone());
        }
        tracing::warn!(session = %session.id, turn = %turn.turn_id, attempt, "the model API refused the agent's sign-in: ending its turn");
        let answer = json!({"stopReason": "cancelled", "_meta": {"acpmux": {"signInRefused": {
            "attempt": attempt, "errorStatus": retry.get("errorStatus"), "error": retry.get("error")}}}});
        let session = session.clone();
        let turn_id = turn.turn_id;
        // Off the tap, as the stalled end: the agent of this very turn gets the cancel (bounded),
        // then the turn ends whether it answered or not.
        tokio::spawn(async move {
            let ours = |s: &Session| {
                s.stalled_gen.load(Ordering::SeqCst) == generation
                    && s.turn().is_some_and(|t| t.turn_id == turn_id)
            };
            let _ = tokio::time::timeout(super::stalled_turn::CANCEL_SEND, async {
                let child = session.child.lock().await.clone();
                if ours(&session)
                    && let (Some(child), Some(sid)) = (child, session.meta().agent_session_id)
                {
                    let _ = child.notify(method::SESSION_CANCEL, json!({"sessionId": sid})).await;
                }
            })
            .await;
            if ours(&session) {
                session.steer_end.send_replace(Some((turn_id, answer)));
                return;
            }
            // Not carried out (a failover keeps the turn's id): the turn's next agent gets its own
            // end, should its sign-in be refused too.
            let mut scheduled =
                session.sign_in_refused_turn.lock().unwrap_or_else(|e| e.into_inner());
            if scheduled.as_deref() == Some(turn_id.as_str()) {
                *scheduled = None;
            }
        });
    }

    /// The error a turn ended for a refused sign-in fails with (`finish_turn`), from its forced
    /// answer: Claude's own 401 words, which `claude_auth` explains and `recovery` types.
    pub(super) fn sign_in_refused_error(answer: &Value) -> Option<RpcError> {
        let refused = answer.pointer("/_meta/acpmux/signInRefused")?;
        let attempt = refused["attempt"].as_u64().unwrap_or(0);
        let status = refused["errorStatus"].as_u64().unwrap_or(401);
        let text = format!(
            "Failed to authenticate. API Error: {status} authentication_error (the model API \
             refused the agent's sign-in {attempt} times; acpmux ended the turn instead of waiting \
             out the agent's retries)"
        );
        Some(
            RpcError::new(-32000, text)
                .with_data(json!({"detail": "sign_in_refused", "attempt": attempt})),
        )
    }

    /// `session`'s harness retries its turn's model request (module docs): logs `turn_retrying`
    /// and marks the turn silent, so its model's next sign logs `turn_heard`.
    pub(super) fn turn_retrying(&self, session: &Session, mut retry: Value) {
        let Some(turn) = session.turn() else { return };
        // Held while it logs, as `watch_silent_turn` does, so a sign the tap counts meanwhile
        // finds the retry to end.
        let mut silent = session.silent_turn.lock().unwrap_or_else(|e| e.into_inner());
        retry.set("turnId", json!(turn.turn_id));
        self.append(session, "mux", "turn_retrying", retry);
        *silent = Some(turn.turn_id);
    }
}

#[cfg(test)]
mod tests;
