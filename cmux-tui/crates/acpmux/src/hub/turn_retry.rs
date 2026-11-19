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
//! failed with the 401 (`refused_retry_error`), and `finish_turn` gives it
//! the sign-in's kind and recovery text (`claude_auth.rs`, `recovery.rs`).
//!
//! A retry of a request the model API refused for a rate limit (Claude's 429,
//! `rate_limit`) is ended at the first (Leo, 2026-11-19: "I hope we aren't getting
//! the f---ing 429s anymore in our f---ing app"). Claude Code retries it 10 times over
//! about 3 minutes, and each retry sends the chat's whole context again into a limit
//! that is refusing: a 600 s storm on a coordinator chat cost 32-40 full-context
//! requests, 11-13 per failed turn (cmux#47337's harness,
//! `scripts/cmux-next/acpmux_429_storm.py`). At its first retry acpmux ends the turn
//! the same way: the turn fails with the 429 (`rate_limited_error`), whose
//! continuation and hold are acpmux's (`auto_resume.rs`, a hold where one is built),
//! one backoff for the whole chat instead of one per turn inside the agent. A wait
//! the agent took from the refusal's `retry-after` goes with the error as its
//! `retryAfterMs`; Claude Code's own first backoff (under a second) does not.

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

/// A model request Claude Code retries that acpmux ends the turn for instead (module docs).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Refusal {
    /// A 401, or Claude's `authentication_failed`: the sign-in.
    SignIn,
    /// A 429, or Claude's `rate_limit`: a rate or usage limit.
    RateLimit,
}

/// The shortest wait of Claude Code's that is the refusal's `retry-after`, not its own first
/// backoff (about 0.5 to 0.6 s at the first retry): only such a wait goes with the error.
const RETRY_AFTER_FLOOR_MS: u64 = 2_000;

impl Refusal {
    /// The refusal `retry` ([`claude_retry`]'s fields) retries, if acpmux ends its turn at all.
    fn of(retry: &Value) -> Option<Self> {
        if retry["source"] != "claude" {
            return None;
        }
        if retry["errorStatus"] == 401 || retry["error"] == "authentication_failed" {
            Some(Self::SignIn)
        } else if retry["errorStatus"] == 429 || retry["error"] == "rate_limit" {
            Some(Self::RateLimit)
        } else {
            None
        }
    }

    /// The retry at which the turn ends: a sign-in's second (its first lets a refresh through),
    /// a rate limit's first (each retry resends the whole context into the limit).
    fn end_attempt(self) -> u64 {
        match self {
            Self::SignIn => 2,
            Self::RateLimit => 1,
        }
    }

    /// The forced answer's `_meta.acpmux` key, which `finish_turn` turns into the error.
    fn meta_key(self) -> &'static str {
        match self {
            Self::SignIn => "signInRefused",
            Self::RateLimit => "rateLimited",
        }
    }
}

impl Hub {
    /// Claude Code retries a model request the API refused for its sign-in or a rate limit
    /// (module docs): at [`Refusal::end_attempt`], `session`'s turn ends failed with that
    /// refusal.
    pub(super) fn end_refused_retry(&self, session: &Arc<Session>, retry: &Value) {
        let attempt = retry["attempt"].as_u64().unwrap_or(0);
        let Some(refusal) = Refusal::of(retry) else { return };
        if attempt < refusal.end_attempt() {
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
                session.refused_retry_turn.lock().unwrap_or_else(|e| e.into_inner());
            if scheduled.as_deref() == Some(turn.turn_id.as_str()) {
                return;
            }
            *scheduled = Some(turn.turn_id.clone());
        }
        match refusal {
            Refusal::SignIn => {
                tracing::warn!(session = %session.id, turn = %turn.turn_id, attempt, "the model API refused the agent's sign-in: ending its turn")
            }
            Refusal::RateLimit => {
                tracing::warn!(session = %session.id, turn = %turn.turn_id, attempt, "the model API refused the agent for a rate limit: ending its turn for acpmux's backoff")
            }
        }
        let mut detail = json!({"attempt": attempt, "errorStatus": retry.get("errorStatus"),
            "error": retry.get("error")});
        if refusal == Refusal::RateLimit {
            detail.set("maxRetries", json!(retry.get("maxRetries")));
            if let Some(ms) =
                retry["retryDelayMs"].as_u64().filter(|ms| *ms >= RETRY_AFTER_FLOOR_MS)
            {
                detail.set("retryAfterMs", json!(ms));
            }
        }
        let mut acpmux = serde_json::Map::new();
        acpmux.insert(refusal.meta_key().to_owned(), detail);
        let answer = json!({"stopReason": "cancelled", "_meta": {"acpmux": acpmux}});
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
            // end, should its request be refused too.
            let mut scheduled =
                session.refused_retry_turn.lock().unwrap_or_else(|e| e.into_inner());
            if scheduled.as_deref() == Some(turn_id.as_str()) {
                *scheduled = None;
            }
        });
    }

    /// The error a turn acpmux ended at a refused retry fails with (`finish_turn`), from its
    /// forced answer: for a sign-in, Claude's own 401 words, which `claude_auth` explains and
    /// `recovery` types; for a rate limit, a 429 `turn_errors` reads as a limit, whose
    /// continuation `auto_resume` schedules, after the `retry-after` the agent was told.
    pub(super) fn refused_retry_error(answer: &Value) -> Option<RpcError> {
        if let Some(refused) = answer.pointer("/_meta/acpmux/signInRefused") {
            let attempt = refused["attempt"].as_u64().unwrap_or(0);
            let status = refused["errorStatus"].as_u64().unwrap_or(401);
            let text = format!(
                "Failed to authenticate. API Error: {status} authentication_error (the model API \
                 refused the agent's sign-in {attempt} times; acpmux ended the turn instead of \
                 waiting out the agent's retries)"
            );
            return Some(
                RpcError::new(-32000, text)
                    .with_data(json!({"detail": "sign_in_refused", "attempt": attempt})),
            );
        }
        let limited = answer.pointer("/_meta/acpmux/rateLimited")?;
        let status = limited["errorStatus"].as_u64().unwrap_or(429);
        let left = match limited["maxRetries"].as_u64() {
            Some(n) => format!("up to {n} more times"),
            None => "again".to_owned(),
        };
        let text = format!(
            "API Error: {status} rate_limit_error (the model API refused the request for a rate \
             limit; acpmux ended the turn at the agent's first retry instead of letting it resend \
             the whole conversation {left}, and goes on after its own backoff)"
        );
        let mut data = json!({"detail": "rate_limited", "attempt": limited["attempt"]});
        if let Some(ms) = limited["retryAfterMs"].as_u64() {
            data.set("retryAfterMs", json!(ms));
        }
        Some(RpcError::new(-32000, text).with_data(data))
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
mod tests {
    use super::*;
    use crate::hub::{Control, NewRequest, TurnInfo};

    #[test]
    fn only_a_claude_retry_of_a_refused_sign_in_or_rate_limit_ends_its_turn() {
        let claude = |status: u64, error: &str| {
            claude_retry(&json!({"attempt": 3, "max_retries": 10,
            "error_status": status, "error": error}))
        };
        assert_eq!(Refusal::of(&claude(401, "authentication_failed")), Some(Refusal::SignIn));
        assert_eq!(Refusal::of(&claude(403, "authentication_failed")), Some(Refusal::SignIn));
        assert_eq!(Refusal::of(&claude(503, "server_error")), None);
        assert_eq!(Refusal::of(&claude(529, "overloaded")), None);
        assert_eq!(Refusal::of(&claude(429, "rate_limit")), Some(Refusal::RateLimit));
        assert_eq!(Refusal::of(&claude(0, "rate_limit")), Some(Refusal::RateLimit));
        let codex = codex_retry(&json!({"message": "Reconnecting... 3/5",
            "codexErrorInfo": {"responseStreamDisconnected": {"httpStatusCode": 401}}}));
        assert_eq!(Refusal::of(&codex), None, "Codex's own retries are its to end");
    }

    /// A session of a test hub whose turn `turn-1` runs, and a refused retry at `attempt`.
    async fn running_turn() -> (Arc<Hub>, Arc<Session>) {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut cfg: crate::config::Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"}))
        .unwrap();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        let session = hub.new_session(req).await.unwrap();
        *session.turn.lock().unwrap() =
            Some(TurnInfo::prompted("person", "hi", "turn-1", "p-1", Control::Local));
        (hub, session)
    }

    fn refused(attempt: u64) -> Value {
        claude_retry(&json!({"attempt": attempt, "max_retries": 10, "error_status": 401,
            "error": "authentication_failed"}))
    }

    /// The first refused retry may be a sign-in being refreshed: it ends nothing. The second
    /// ends the turn.
    #[tokio::test]
    async fn a_refused_sign_in_ends_its_turn_at_the_second_retry() {
        let (hub, session) = running_turn().await;
        hub.end_refused_retry(&session, &refused(1));
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        assert!(session.steer_end.borrow().is_none(), "the first refused retry ends nothing");
        hub.end_refused_retry(&session, &refused(2));
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        let ended = session.steer_end.borrow().clone();
        let (_, answer) = ended.expect("the second refused retry ends the turn");
        assert_eq!(answer.pointer("/_meta/acpmux/signInRefused/attempt"), Some(&json!(2)));
    }

    /// The end at the third retry, then the fourth: one end, the third's (review F2).
    #[tokio::test]
    async fn a_refused_sign_in_schedules_one_end_per_turn() {
        let (hub, session) = running_turn().await;
        hub.end_refused_retry(&session, &refused(3));
        hub.end_refused_retry(&session, &refused(4));
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        let ended = session.steer_end.borrow().clone();
        let (turn, answer) = ended.expect("the turn ends");
        assert_eq!(turn, "turn-1");
        assert_eq!(answer.pointer("/_meta/acpmux/signInRefused/attempt"), Some(&json!(3)));
    }

    /// A new agent for the turn (a failover keeps the turn id) before the end runs: the end is
    /// not carried out on it (review F1).
    #[tokio::test]
    async fn a_refused_sign_in_end_spares_the_turns_next_agent() {
        let (hub, session) = running_turn().await;
        hub.end_refused_retry(&session, &refused(3));
        hub.hold_stalled_count(&session);
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        assert!(session.steer_end.borrow().is_none(), "the next agent's turn is not ended");
        // That agent's own refused retries still end the turn.
        hub.end_refused_retry(&session, &refused(3));
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        let end = session.steer_end.borrow().clone();
        assert_eq!(
            end.map(|(turn, _)| turn).as_deref(),
            Some("turn-1"),
            "the next agent's refusal ends it"
        );
    }

    #[test]
    fn a_refused_sign_in_fails_typed_as_signed_out() {
        let answer = json!({"stopReason": "cancelled", "_meta": {"acpmux": {"signInRefused":
            {"attempt": 3, "errorStatus": 401, "error": "authentication_failed"}}}});
        let mut e = Hub::refused_retry_error(&answer).unwrap();
        crate::recovery::annotate(&mut e, None);
        assert_eq!(
            e.data.as_ref().unwrap()["errorKind"],
            crate::recovery::kind::AUTH_SIGNED_OUT,
            "{e:?}"
        );
        assert!(Hub::refused_retry_error(&json!({"stopReason": "cancelled"})).is_none());
    }

    fn limited(attempt: u64, delay_ms: u64) -> Value {
        claude_retry(&json!({"attempt": attempt, "max_retries": 10, "error_status": 429,
            "error": "rate_limit", "retry_delay_ms": delay_ms}))
    }

    /// A rate limit ends the turn at Claude Code's first retry, before the retry resends the
    /// whole conversation (module docs): one end per turn, carrying no `retryAfterMs` for
    /// Claude Code's own first backoff.
    #[tokio::test]
    async fn a_rate_limit_ends_its_turn_at_the_first_retry() {
        let (hub, session) = running_turn().await;
        hub.end_refused_retry(&session, &limited(1, 611));
        hub.end_refused_retry(&session, &limited(2, 1149));
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        let (turn, answer) = session.steer_end.borrow().clone().expect("the first retry ends it");
        assert_eq!(turn, "turn-1");
        let meta = answer.pointer("/_meta/acpmux/rateLimited").unwrap();
        assert_eq!(meta["attempt"], 1);
        assert!(meta.get("retryAfterMs").is_none(), "{meta}");
    }

    /// The error a rate-limited end fails with is a limit (`turn_errors`), which acpmux's own
    /// continuation picks up, and carries the refusal's `retry-after` the agent took.
    #[test]
    fn a_rate_limited_end_fails_as_a_limit_with_its_retry_after() {
        let (hub_answer, plain) = {
            let with = json!({"stopReason": "cancelled", "_meta": {"acpmux": {"rateLimited":
                {"attempt": 1, "errorStatus": 429, "error": "rate_limit", "maxRetries": 10,
                 "retryAfterMs": 60000}}}});
            let without = json!({"stopReason": "cancelled", "_meta": {"acpmux": {"rateLimited":
                {"attempt": 1, "errorStatus": 429, "error": "rate_limit"}}}});
            (Hub::refused_retry_error(&with).unwrap(), Hub::refused_retry_error(&without).unwrap())
        };
        for e in [&hub_answer, &plain] {
            assert!(crate::turn_errors::is_limit_error(&e.message), "{}", e.message);
            assert!(
                crate::turn_errors::resume_cause(&e.message, &e.message).is_some(),
                "{}",
                e.message
            );
        }
        assert_eq!(hub_answer.data.as_ref().unwrap()["retryAfterMs"], 60000);
        let now = 1_000_000;
        assert_eq!(
            super::super::auto_resume::reset_hint::error_reset_at(hub_answer.data.as_ref(), now),
            Some(now + 60000)
        );
        assert!(plain.data.as_ref().unwrap().get("retryAfterMs").is_none());
    }

    /// A retry Claude Code waits a `retry-after` for carries it on the forced answer.
    #[tokio::test]
    async fn a_rate_limit_end_carries_the_retry_after_the_agent_took() {
        let (hub, session) = running_turn().await;
        hub.end_refused_retry(&session, &limited(1, 60_000));
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        let (_, answer) = session.steer_end.borrow().clone().expect("ended");
        assert_eq!(answer.pointer("/_meta/acpmux/rateLimited/retryAfterMs"), Some(&json!(60000)));
    }

    #[test]
    fn claude_line_keeps_what_a_client_shows() {
        let line = json!({"type": "system", "subtype": "api_retry", "attempt": 7, "max_retries": 10,
            "retry_delay_ms": 75000, "error_status": 503, "error": "server_error"});
        assert_eq!(
            claude_retry(&line),
            json!({"source": "claude", "attempt": 7, "maxRetries": 10, "retryDelayMs": 75000,
                "errorStatus": 503, "error": "server_error"})
        );
        let bare = json!({"attempt": 1, "max_retries": 10, "error": "unknown"});
        assert_eq!(
            claude_retry(&bare),
            json!({"source": "claude", "attempt": 1, "maxRetries": 10})
        );
    }

    #[test]
    fn codex_error_reads_its_count_and_status() {
        let err = json!({"message": "Reconnecting... 2/5", "willRetry": true,
            "codexErrorInfo": {"responseStreamDisconnected": {"httpStatusCode": 502}},
            "additionalDetails": "stream disconnected before completion"});
        assert_eq!(
            codex_retry(&err),
            json!({"source": "codex", "attempt": 2, "maxRetries": 5, "errorStatus": 502,
                "error": "stream disconnected before completion"})
        );
        let plain = json!({"message": "stream error: connection reset", "willRetry": true});
        assert_eq!(
            codex_retry(&plain),
            json!({"source": "codex", "error": "stream error: connection reset"})
        );
        let bare = json!({"message": "Reconnecting... 1", "willRetry": true});
        assert_eq!(codex_retry(&bare), json!({"source": "codex", "attempt": 1}));
    }

    #[test]
    fn attempt_is_the_last_count() {
        assert_eq!(attempt_of("Reconnecting... 2/5"), Some((2, 5)));
        assert_eq!(attempt_of("retrying (3/10)…"), Some((3, 10)));
        assert_eq!(attempt_of("see /v1/responses"), None);
        assert_eq!(attempt_of("6/5"), None);
    }
}
