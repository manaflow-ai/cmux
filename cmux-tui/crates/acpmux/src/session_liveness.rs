//! Harness failures are independent of whether the agent process is alive.
//! Three failed attempts (the original plus the first two auto-resumes, normally
//! 10 s and 60 s apart) flag an outage before the retry policy's five-minute wait.
//! No timer: turn results update this persisted projection; a success clears it.

use serde::{Deserialize, Serialize};
use serde_json::Value;

const FAILED_ATTEMPTS: u32 = 3;
/// At most this many turn results are read back to rebuild a projection an older daemon
/// never saved: a long run of failures costs one bounded read, and the rebuilt one is saved.
pub const RESTORE_RESULTS: usize = 32;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HarnessFailures {
    pub through_seq: u64,
    attempts: u32,
    since: u64,
    reason: Option<StuckReason>,
    error: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum StuckReason {
    HarnessUnavailable,
    Capacity,
    Auth,
    SpawnFailed,
}

impl HarnessFailures {
    /// No failures, with every record through `seq` already accounted for.
    pub fn after(seq: u64) -> Self {
        Self { through_seq: seq, ..Self::default() }
    }

    pub fn observe(&mut self, result: &Value, seq: u64, at: u64) {
        if seq <= self.through_seq {
            return;
        }
        self.through_seq = seq;
        let status = result["status"].as_str().unwrap_or_default();
        if status == "completed" && result["stopReason"] != "cancelled" {
            *self = Self { through_seq: seq, ..Self::default() };
            return;
        }
        let error = result["errorText"].as_str().or_else(|| result["error"].as_str()).unwrap_or("");
        let reason = (status == "failed").then(|| classify(result, error)).flatten();
        if let Some(reason) = reason {
            self.attempts = self.attempts.saturating_add(1);
            if self.attempts == FAILED_ATTEMPTS {
                self.since = at;
            }
            self.reason = Some(reason);
            // Scan before truncation so cutting a credential cannot hide its shape.
            self.error = redact(error);
        } else if self.attempts < FAILED_ATTEMPTS {
            // A different failure or cancellation breaks a not-yet-stuck streak.
            // Once stuck, only a successful turn proves recovery.
            *self = Self { through_seq: seq, ..Self::default() };
        }
    }

    pub fn stuck(&self) -> Option<(StuckReason, u64, &str)> {
        (self.attempts >= FAILED_ATTEMPTS).then_some((self.reason?, self.since, &self.error))
    }
}

fn redact(error: &str) -> String {
    // The shared scanner deliberately ignores short arbitrary tokens. Diagnostics
    // must also hide those when explicitly labelled and all URL query credentials.
    // A credential value is masked whole: a quoted one to its closing quote (escapes
    // included, or to the end when the error was cut off), else up to whitespace or a comma.
    const VALUE: &str = r#"(?:"(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?|[^\s,"']+)"#;
    static CREDENTIALS: std::sync::LazyLock<Option<regex::Regex>> = std::sync::LazyLock::new(
        || {
            regex::Regex::new(&format!(
                r#"(?i)[a-z][a-z0-9+.-]*://[^\s<>"']+|\b(?:bearer|basic)\s+{VALUE}|\b(?:[a-z_]*(?:token|secret|password|api[_-]?key))["']?\s*[:=]\s*{VALUE}"#
            ))
            .ok()
        },
    );
    let Some(pattern) = CREDENTIALS.as_ref() else { return "[redacted]".into() };
    crate::secret_scan::mask(&pattern.replace_all(error, "[redacted]")).chars().take(500).collect()
}

fn classify(result: &Value, error: &str) -> Option<StuckReason> {
    use crate::hub::turn_errors;
    use StuckReason::*;
    let m = error.to_lowercase();
    // A gateway's 503 mentioning authentication is still an unavailable harness.
    if (500..=599).any(|code| turn_errors::has_status(&m, &code.to_string())) {
        return Some(HarnessUnavailable);
    }
    // A 403 that refuses a permission or a tool use is the request's, not the harness's.
    let refused_permission = ["permission_error", "permission denied", "tool use was rejected"]
        .iter()
        .any(|marker| m.contains(marker));
    if crate::recovery::auth_kind(error).is_some()
        || turn_errors::has_status(&m, "401")
        || (turn_errors::has_status(&m, "403") && !refused_permission)
        || m.contains("authentication_error")
        || m.contains("unauthorized")
    {
        return Some(Auth);
    }
    if result["errorKind"] == crate::recovery::kind::SPAWN_FAILED {
        return Some(SpawnFailed);
    }
    if turn_errors::is_refused_request(error) {
        return None;
    }
    if turn_errors::is_capacity_error(error) || turn_errors::has_status(&m, "429") {
        return Some(Capacity);
    }
    turn_errors::is_transport_error(error).then_some(HarnessUnavailable)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn stuck_classifies_harness_failures_and_clears_only_after_success() {
        for (error, kind, reason) in [
            ("API Error: 503 authentication_failed", "", StuckReason::HarnessUnavailable),
            ("HTTP 500 Internal Server Error", "", StuckReason::HarnessUnavailable),
            ("Selected model is at capacity", "", StuckReason::Capacity),
            ("HTTP 403 Forbidden", "", StuckReason::Auth),
            ("OAuth token expired", "", StuckReason::Auth),
            ("could not launch", "spawn.failed", StuckReason::SpawnFailed),
        ] {
            let mut failures = HarnessFailures::default();
            let failed = json!({"status":"failed", "errorText":error, "errorKind":kind});
            for seq in 1..=3 {
                failures.observe(&failed, seq, seq * 100);
                assert_eq!(failures.stuck().is_some(), seq == 3, "{error}");
            }
            assert_eq!(failures.stuck().map(|s| (s.0, s.1)), Some((reason, 300)));
            failures.observe(&failed, 3, 999); // duplicate log replay
            failures.observe(&json!({"status":"cancelled"}), 4, 400);
            assert_eq!(failures.stuck().unwrap().1, 300);
            failures.observe(&json!({"status":"completed", "stopReason":"end_turn"}), 5, 500);
            assert!(failures.stuck().is_none());
        }
    }

    #[test]
    fn stuck_ignores_unrelated_errors_and_redacts_credentials() {
        for error in [
            "simulated internal error",
            "retry after 2503s",
            "tool use was rejected",
            "HTTP 403 permission denied",
            "403 permission_error: this key cannot use the model",
        ] {
            assert_eq!(classify(&json!({}), error), None);
        }
        let mut failures = HarnessFailures::default();
        let failed = json!({"status":"failed", "errorText":"HTTP 503 https://alice:password@example.com Bearer secret-token"});
        for seq in 1..=3 {
            failures.observe(&failed, seq, seq);
        }
        let error = failures.stuck().unwrap().2;
        assert!(!error.contains("password"), "{error}");
        assert!(!error.contains("secret-token"), "{error}");
        for (error, secret) in [
            (r#"HTTP 503 password="correct horse, battery staple" retry"#, "horse"),
            (r#"HTTP 503 {"api_key": "a b\"c, d"} retry"#, "c, d"),
            ("HTTP 503 secret='one two, three'", "two"),
            (r#"HTTP 401 Authorization: Bearer "abc123""#, "abc123"),
            (r#"HTTP 401 Authorization: Basic 'dXNlcjpwYXNz word'"#, "word"),
            (r#"HTTP 503 token="cut off before the quote"#, "before"),
        ] {
            let redacted = redact(error);
            assert!(!redacted.contains(secret), "{redacted}");
            assert!(redacted.starts_with("HTTP "), "{redacted}");
        }
    }
}
