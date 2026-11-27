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

/// Its harness's own command sandbox (`hub/harness_sandbox.rs`), projected from the mux
/// `harness_sandbox_failed` and `harness_sandbox_recovered` records and saved with the session,
/// so a restart keeps it: when it first refused a command, kept for good, and whether it
/// refuses them now.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HarnessSandbox {
    pub first_at: Option<u64>,
    pub failing: bool,
    pub error: Option<String>,
    pub remote: bool,
}

impl HarnessSandbox {
    pub const FAILED: &str = "harness_sandbox_failed";
    pub const RECOVERED: &str = "harness_sandbox_recovered";

    pub fn is_none(&self) -> bool {
        self == &Self::default()
    }

    /// A mux record of `kind` appended at `at`; every other kind changes nothing.
    pub fn observe(&mut self, kind: &str, msg: &Value, at: u64) {
        let first = msg.get("firstAt").and_then(Value::as_u64);
        match kind {
            Self::FAILED => {
                self.first_at = self.first_at.or(first).or(Some(at));
                self.failing = true;
                self.error = msg.get("error").and_then(Value::as_str).map(redact);
                self.remote = msg.get("remote").and_then(Value::as_bool).unwrap_or(false);
            }
            Self::RECOVERED => {
                self.first_at = self.first_at.or(first);
                self.failing = false;
                self.error = None;
                self.remote = false;
            }
            _ => {}
        }
    }
}

/// An agent's explicit blocked result, not an incidental mention of a blocker.
/// Keep this separate from process/turn failure: the harness may have ended normally.
pub fn blocked_reply(reply: &str) -> Option<&str> {
    let mut lines = reply.lines().map(str::trim).filter(|line| !line.is_empty());
    let line = lines.next()?.trim_matches(['#', '*', ' ']);
    if matches!(line, "BLOCKED" | "Blocked") {
        return Some(lines.next().unwrap_or(line));
    }
    let tail = line.strip_prefix("BLOCKED:").or_else(|| line.strip_prefix("Blocked:"))?;
    Some(tail.trim_start_matches(['*', ' ']))
}

pub fn sandbox_failed(summary: &Value) -> bool {
    summary["harnessSandboxFailing"] == true
}

pub fn blocked(summary: &Value) -> bool {
    summary["preview"].as_str().and_then(blocked_reply).is_some()
}

pub fn failure_error(summary: &Value) -> Value {
    if sandbox_failed(summary) {
        summary["harnessSandboxError"].clone()
    } else {
        summary["lastTurn"]["errorText"]
            .as_str()
            .or_else(|| summary["preview"].as_str().and_then(blocked_reply))
            .map_or(Value::Null, |error| Value::String(error.to_owned()))
    }
}

#[cfg(test)]
mod blocked_reply_tests {
    use super::{blocked_reply, failure_error, sandbox_failed};
    use serde_json::json;

    #[test]
    fn only_an_explicit_blocked_result_changes_the_row() {
        assert_eq!(blocked_reply("**BLOCKED:** cannot create .git"), Some("cannot create .git"));
        assert_eq!(blocked_reply("## BLOCKED\n\ncannot create .git"), Some("cannot create .git"));
        assert_eq!(blocked_reply("**BLOCKED**"), Some("BLOCKED"));
        assert_eq!(
            blocked_reply("Blocked: broker unavailable\nNext step: retry"),
            Some("broker unavailable")
        );
        let mut row = serde_json::json!({"status": "idle", "preview": "BLOCKED: cannot write .git", "lastTurn": {"status": "completed"}});
        assert_eq!(crate::hub::views::status_indicator(&row), Some("failed"));
        assert_eq!(crate::hub::views::lane(&row)["error"], "cannot write .git");
        row["status"] = serde_json::json!("running");
        assert_eq!(crate::hub::views::status_indicator(&row), Some("working"));
        for reply in [
            "Fixed the blocked request",
            "Not blocked: ready",
            "> BLOCKED: quoted log",
            "Tests pass\nBLOCKED: quoted fixture",
        ] {
            assert_eq!(blocked_reply(reply), None, "{reply}");
        }
    }

    #[test]
    fn failure_projection_preserves_sandbox_reason_and_blocked_reply() {
        let sandbox =
            json!({"harnessSandboxFailing": true, "harnessSandboxError": "bwrap unavailable"});
        assert!(sandbox_failed(&sandbox));
        assert_eq!(failure_error(&sandbox), json!("bwrap unavailable"));

        let blocked = json!({"preview": "BLOCKED: cannot create .git", "lastTurn": {}});
        assert!(!sandbox_failed(&blocked));
        assert_eq!(failure_error(&blocked), json!("cannot create .git"));
    }
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
#[path = "session_liveness_tests.rs"]
mod tests;
