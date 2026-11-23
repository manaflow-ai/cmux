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
    /// `schedule`, `manual` or `watch`.
    pub trigger: String,
    /// What the trigger saw (a watch's lines, `run --event`), cut at 16 KiB.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub event: Option<String>,
    /// Watch events the guardrails dropped before this run started.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub dropped: u64,
    /// The scheduled time it stands for (schedule runs).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scheduled_at: Option<i64>,
    pub state: RunState,
    /// Why it was skipped or failed: `superseded`, `stale`, `machine_asleep`,
    /// `previous_run_running`, `cooldown`, `cap_reached`, `condition_false`,
    /// `condition_exit_N`, `condition_timeout`, `exit_N`, `timeout`,
    /// `runner_died`, `start_failed`.
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
    /// 0 for a first try; N for the Nth automatic retry of a run whose
    /// process could not start ([`is_retryable`]).
    #[serde(default, skip_serializing_if = "is_zero_u32")]
    pub attempt: u32,
    /// The run this one retries.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_of: Option<String>,
}

fn is_zero_u32(n: &u32) -> bool {
    *n == 0
}

/// Automatic retries of one run, at most.
pub const MAX_RETRIES: u32 = 3;
/// The wait before retry N+1, after the failure it retries.
pub const RETRY_BACKOFF_SECONDS: [i64; MAX_RETRIES as usize] = [30, 120, 480];
/// A start failure older than this is history, never retried (a runner that
/// upgrades does not replay last week).
pub const RETRY_WINDOW_SECONDS: i64 = 3_600;

/// Whether a failure is the machine's, not the run's: its process could not
/// start (`start_failed`) or its body could not be spawned (`error: ...`).
/// Only those are retried; a body that ran and failed is the person's to see,
/// and a run whose runner died may have done part of its work.
pub fn is_retryable(reason: &str) -> bool {
    reason.starts_with("start_failed") || reason.starts_with("error:")
}

/// The id of retry `attempt` of run `of`: the same retry is one run however
/// often a tick sees it due.
pub fn retry_run_id(of: &str, attempt: u32) -> String {
    digest_id(&[of.as_bytes(), b"retry", attempt.to_string().as_bytes()])
}

/// Failed runs that finished after `seen_at` (unix seconds): what the
/// Automations page marks unread and the sidebar counts.
pub fn unread_failures(runs: &[Run], seen_at: i64) -> usize {
    runs.iter()
        .filter(|r| r.state == RunState::Failed && r.finished_at.unwrap_or(r.created_at) > seen_at)
        .count()
}

fn is_zero(n: &u64) -> bool {
    *n == 0
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

/// The run id of a watch event; `key` is unique per event (its time and a
/// counter).
pub fn event_run_id(automation: &str, key: &str) -> String {
    digest_id(&[automation.as_bytes(), b"watch", key.as_bytes()])
}

/// The run id of a manual run; the same idempotency key gives the same run.
pub fn manual_run_id(automation: &str, key: &str) -> String {
    digest_id(&[automation.as_bytes(), b"manual", key.as_bytes()])
}
