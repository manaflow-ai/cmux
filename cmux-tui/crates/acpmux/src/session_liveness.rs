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
            }
            Self::RECOVERED => {
                self.first_at = self.first_at.or(first);
                self.failing = false;
            }
            _ => {}
        }
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
mod tests;
