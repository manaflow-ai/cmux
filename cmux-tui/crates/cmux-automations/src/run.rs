//! One run of an automation.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::automation::base32;

/// Where a run is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunState {
    Queued,
    Running,
    Succeeded,
    Failed,
    Skipped,
    Cancelled,
}

impl RunState {
    /// The run will not change any more.
    pub fn is_final(self) -> bool {
        matches!(
            self,
            RunState::Succeeded | RunState::Failed | RunState::Skipped | RunState::Cancelled
        )
    }

    /// The lowercase name (`succeeded`).
    pub fn name(self) -> &'static str {
        match self {
            RunState::Queued => "queued",
            RunState::Running => "running",
            RunState::Succeeded => "succeeded",
            RunState::Failed => "failed",
            RunState::Skipped => "skipped",
            RunState::Cancelled => "cancelled",
        }
    }
}

/// A run record. `runs.jsonl` holds one per line; the last line of an id wins.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Run {
    pub id: String,
    pub automation: String,
    /// `schedule` or `manual`.
    pub trigger: String,
    /// The scheduled time it stands for (schedule runs).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scheduled_at: Option<i64>,
    pub state: RunState,
    /// Why it was skipped or failed: `superseded`, `stale`, `machine_asleep`,
    /// `previous_run_running`, `exit_N`, `timeout`, `runner_died`, `start_failed`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    pub created_at: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<i64>,
    /// Seconds between the scheduled time and the start (0 when on time or manual).
    #[serde(default)]
    pub late_seconds: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    /// The machine that ran it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runner: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    /// The automation version that ran.
    #[serde(default)]
    pub version: u64,
}

fn digest_id(parts: &[&[u8]]) -> String {
    let mut hasher = Sha256::new();
    for (i, part) in parts.iter().enumerate() {
        if i > 0 {
            hasher.update([0u8]);
        }
        hasher.update(part);
    }
    format!("run_{}", base32(&hasher.finalize(), 20))
}

/// The run id of one scheduled time of one automation. Every machine and
/// every retry that sees this due time computes the same id, so it is one run.
pub fn run_id(automation: &str, scheduled_at: i64) -> String {
    digest_id(&[automation.as_bytes(), b"schedule", scheduled_at.to_string().as_bytes()])
}

/// The run id of a manual run; the same idempotency key gives the same run.
pub fn manual_run_id(automation: &str, key: &str) -> String {
    digest_id(&[automation.as_bytes(), b"manual", key.as_bytes()])
}
