//! Why a `server ensure` failed, as the app reads it: a full disk (restore
//! fuzz h2, h3), a stuck owner (the gate of "Restart cmux-tui" and the
//! unresponsive-owner watch), an owner busy at its connection limit, and how
//! one ensure's outcome moves the launcher's restart gate.

use serde::{Deserialize, Serialize};

/// Less free space than this on the state's volume reads as a full disk:
/// SQLite and the daemon's logs fail well before the last byte, so `server
/// ensure` then fails with no word about space.
pub const LOW_SPACE_BYTES: u64 = 64 << 20;

/// The words a failure caused by a full disk carries (ENOSPC, SQLITE_FULL).
const DISK_FULL_MARKERS: [&str; 5] =
    ["no space left on device", "os error 28", "enospc", "disk is full", "disk full"];

/// Whether an error's words say the disk is full.
pub fn says_disk_full(text: &str) -> bool {
    let lowered = text.to_lowercase();
    DISK_FULL_MARKERS.iter().any(|marker| lowered.contains(marker))
}

/// The app's daemon error, as far as these rules read it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorInput {
    /// `restore_timeout`, `timed_out`, `launch_failed`, `command` or `other`.
    pub kind: String,
    /// `launch_failed`: its detail.
    #[serde(default)]
    pub detail: Option<String>,
    /// `command`: its message and its `details.reason`.
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub reason: Option<String>,
    /// The error as the launcher saw it (Copy Details, `debug.daemon`).
    #[serde(default)]
    pub description: String,
}

impl ErrorInput {
    fn detail(&self) -> &str {
        self.detail.as_deref().unwrap_or_default()
    }

    /// An owner at its connection limit refused (issue 22311): it answers.
    pub fn is_busy(&self) -> bool {
        self.kind == "launch_failed" && self.detail().contains("\"server.busy\"")
    }

    /// A failure a stuck owner causes: the restore bound passed, no answer in
    /// time, no owner became ready (`server.unavailable`), or every connection
    /// refused at the limit (`server.busy`).
    pub fn is_stuck_owner(&self) -> bool {
        match self.kind.as_str() {
            "restore_timeout" | "timed_out" => true,
            "launch_failed" => {
                self.detail().contains("\"server.unavailable\"")
                    || self.detail().contains("\"server.busy\"")
            }
            _ => false,
        }
    }

    /// The daemon refused, or could not start, because the volume under its
    /// state is full.
    pub fn is_disk_full(&self) -> bool {
        match self.kind.as_str() {
            "command" => {
                self.message.as_deref().is_some_and(says_disk_full)
                    || self.reason.as_deref().is_some_and(says_disk_full)
            }
            "launch_failed" => says_disk_full(self.detail()),
            _ => false,
        }
    }
}

/// Why the last ensure failed: what the person reads beside "Restart cmux-tui".
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartFailure {
    /// `disk_full` or `failed`.
    pub kind: String,
    pub detail: String,
}

impl StartFailure {
    /// `error`'s failure; `free_bytes` is the free space on the state's volume.
    pub fn new(error: &ErrorInput, free_bytes: Option<u64>) -> Self {
        let low = free_bytes.is_some_and(|free| free < LOW_SPACE_BYTES);
        let kind = if says_disk_full(&error.description) || low { "disk_full" } else { "failed" };
        Self { kind: kind.into(), detail: error.description.clone() }
    }
}

/// How one ensure ended, for the unresponsive-owner watch.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum EnsureKind {
    /// It worked; `pid` is the owner it found or started.
    Ready {
        pid: Option<i32>,
    },
    Stuck,
    /// Refused at the connection limit: alive and answering.
    Busy,
    Failed,
}

impl EnsureKind {
    pub fn new(error: Option<&ErrorInput>, pid: Option<i32>) -> Self {
        match error {
            None => EnsureKind::Ready { pid },
            Some(e) if e.is_busy() => EnsureKind::Busy,
            Some(e) if e.is_stuck_owner() => EnsureKind::Stuck,
            Some(_) => EnsureKind::Failed,
        }
    }
}

/// The launcher's restart gate (`EnsureOutcome`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    #[serde(default)]
    pub owner_looks_stuck: bool,
    #[serde(default)]
    pub failure: Option<StartFailure>,
    /// Ensures that failed in a row since the last one that worked.
    #[serde(default)]
    pub failed_in_a_row: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Noted {
    pub state: Outcome,
    /// The gate changed: its observer runs.
    pub changed: bool,
    /// What the watch gets.
    pub watch: EnsureKind,
}

/// Records how an ensure ended (`error` none: it worked, finding `pid`).
pub fn note_outcome(
    state: &Outcome,
    error: Option<&ErrorInput>,
    pid: Option<i32>,
    free_bytes: Option<u64>,
) -> Noted {
    let stuck = error.is_some_and(ErrorInput::is_stuck_owner);
    let failure = error.map(|e| StartFailure::new(e, free_bytes));
    let failed_in_a_row =
        if failure.is_none() { 0 } else { state.failed_in_a_row.saturating_add(1) };
    let next = Outcome { owner_looks_stuck: stuck, failure, failed_in_a_row };
    Noted { changed: next != *state, state: next, watch: EnsureKind::new(error, pid) }
}
