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

impl Hub {
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
