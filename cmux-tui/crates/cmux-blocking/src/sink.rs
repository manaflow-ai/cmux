//! Where stall records go. The composition root installs one sink per
//! process (the daemon's hang JSONL next to its panic log); with none
//! installed, stalls are only counted.

use std::path::PathBuf;
use std::sync::OnceLock;

use crate::BlockingRecord;

/// Receives the first stall record of each call site. Called on the stalled
/// thread, at most once per site per process.
pub trait RecordSink: Send + Sync {
    fn record(&self, record: &BlockingRecord);

    /// Receives the first slow poll of each spawn site (lab builds only,
    /// [`crate::poll_watch`]). Called on the worker that polled the task.
    #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
    fn slow_poll(&self, record: &crate::poll_watch::SlowPoll) {
        let _ = record;
    }

    /// Receives a poll watch's totals once, when it ends (lab builds only,
    /// [`crate::poll_watch::PollWatch::finish`]).
    #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
    fn slow_poll_summary(&self, summary: &crate::poll_watch::PollSummary) {
        let _ = summary;
    }
}

/// A sink was installed already; the first one stays.
#[derive(Debug, PartialEq, Eq)]
pub struct SinkAlreadyInstalled;

impl std::fmt::Display for SinkAlreadyInstalled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("a cmux-blocking record sink is already installed")
    }
}

impl std::error::Error for SinkAlreadyInstalled {}

pub(crate) static SINK: OnceLock<Box<dyn RecordSink>> = OnceLock::new();

/// Install the process's sink. Call once from the composition root.
pub fn install_sink(sink: Box<dyn RecordSink>) -> Result<(), SinkAlreadyInstalled> {
    SINK.set(sink).map_err(|_| SinkAlreadyInstalled)
}

pub(crate) fn emit(record: &BlockingRecord) {
    if let Some(sink) = SINK.get() {
        sink.record(record);
    }
}

/// Appends each record as one JSON line through `cmux_panic_log::append`
/// (owner-only file, size cap, never panics), plus the caller's fields
/// (process, pid, version), the way the panic log does.
pub struct JsonlSink {
    path: PathBuf,
    fields: cmux_panic_log::Fields,
}

impl JsonlSink {
    pub fn new(path: PathBuf, fields: cmux_panic_log::Fields) -> Self {
        Self { path, fields }
    }
}

impl JsonlSink {
    fn append(&self, record: serde_json::Map<String, serde_json::Value>) {
        let mut line = self.fields.clone();
        line.extend(record);
        let at_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| u64::try_from(since.as_millis()).unwrap_or(u64::MAX));
        line.insert("at_ms".into(), at_ms.into());
        cmux_panic_log::append(&self.path, &serde_json::Value::Object(line));
    }
}

impl RecordSink for JsonlSink {
    fn record(&self, record: &BlockingRecord) {
        self.append(record.to_fields());
    }

    #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
    fn slow_poll(&self, record: &crate::poll_watch::SlowPoll) {
        self.append(record.to_fields());
    }

    #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
    fn slow_poll_summary(&self, summary: &crate::poll_watch::PollSummary) {
        self.append(summary.to_fields());
    }
}
