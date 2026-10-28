//! One process's trace state as the daemon's `trace-start`, `trace-stop` and
//! `trace-status` report it: the daemon's own, a
//! terminal host's (its `TraceControlAck`) and acpmux's (`_acpmux/trace`).

use std::path::PathBuf;

use cmux_trace::{Status, TraceError};
use serde_json::{Value, json};

/// What one process answered.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct TraceReport {
    pub(crate) pid: u32,
    pub(crate) state: Result<TracedState, TraceError>,
}

/// A process whose tracer runs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct TracedState {
    pub(crate) recording: bool,
    /// None before the first start, or when its file could not be mapped.
    pub(crate) recording_path: Option<PathBuf>,
    pub(crate) recording_bytes: u64,
    pub(crate) records_dropped: u64,
}

impl TracedState {
    pub(crate) fn of(status: &Status) -> Self {
        Self {
            recording: status.recording,
            recording_path: status.recording_path.clone(),
            recording_bytes: status.recording_bytes,
            records_dropped: status.records_dropped,
        }
    }
}

impl TraceReport {
    /// This process's answer to one control call.
    pub(crate) fn of_this_process(outcome: Result<Status, TraceError>) -> Self {
        Self {
            pid: std::process::id(),
            state: outcome.as_ref().map(TracedState::of).map_err(|e| *e),
        }
    }

    /// The JSON fields of this report (`state`, then the state's own).
    pub(crate) fn json_fields(&self) -> Value {
        match &self.state {
            Ok(traced) => json!({
                "pid": self.pid,
                "state": if traced.recording { "recording" } else { "idle" },
                "recording_path": traced.recording_path,
                "recording_bytes": traced.recording_bytes,
                "records_dropped": traced.records_dropped,
            }),
            Err(error) => json!({
                "pid": self.pid,
                "state": "error",
                "error": trace_error_code(*error),
            }),
        }
    }
}

impl TraceReport {
    /// The report [`Self::json_fields`] wrote (acpmux's answer).
    pub(crate) fn from_json(value: &Value) -> Option<Self> {
        let pid = u32::try_from(value.get("pid")?.as_u64()?).ok()?;
        let state = match value.get("state")?.as_str()? {
            state @ ("recording" | "idle") => Ok(TracedState {
                recording: state == "recording",
                recording_path: value
                    .get("recording_path")
                    .and_then(Value::as_str)
                    .map(PathBuf::from),
                recording_bytes: value.get("recording_bytes")?.as_u64()?,
                records_dropped: value.get("records_dropped")?.as_u64()?,
            }),
            "error" => Err(trace_error_of_code(value.get("error")?.as_str()?)?),
            _ => return None,
        };
        Some(Self { pid, state })
    }
}

/// The wire code of `error` (`_acpmux/trace` and the daemon's reply).
pub(crate) fn trace_error_code(error: TraceError) -> &'static str {
    match error {
        TraceError::NotInitialized => "not_initialized",
        TraceError::AlreadyRecording => "already_recording",
        TraceError::NotRecording => "not_recording",
    }
}

/// The error a wire code names.
pub(crate) fn trace_error_of_code(code: &str) -> Option<TraceError> {
    Some(match code {
        "not_initialized" => TraceError::NotInitialized,
        "already_recording" => TraceError::AlreadyRecording,
        "not_recording" => TraceError::NotRecording,
        _ => return None,
    })
}
