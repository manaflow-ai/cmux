//! The hang log of cmux's background processes: one JSON line per watched
//! scope that ran past its hang tier, with the stack of the thread that ran
//! it, next to the panic log.
//!
//! The watcher that finds the hung scope and takes the stack is the
//! process's one request watchdog (cmux-tui-core
//! `server/request_watchdog.rs`, Chrome's HangWatcher in
//! base/threading/hang_watcher.cc). This module is only where its records
//! go: the process installs one sink, like the panic hook ([`install`]),
//! and the watchdog thread calls [`write`] once per hang. Before install a
//! record goes nowhere.

use std::path::PathBuf;
use std::sync::OnceLock;

/// Where records go: the watchdog thread calls it once per hang.
pub type HangSink = Box<dyn Fn(serde_json::Value) + Send + Sync>;

/// A sink that appends each record, with `fields`, to the JSONL at `path`
/// (owner-only, never through a link, at most [`crate::MAX_LOG_BYTES`]).
pub fn file_sink(path: PathBuf, fields: crate::Fields) -> HangSink {
    Box::new(move |record| {
        let serde_json::Value::Object(record) = record else { return };
        let mut line = fields.clone();
        line.extend(record);
        crate::append(&path, &serde_json::Value::Object(line));
    })
}

static INSTALLED: OnceLock<HangSink> = OnceLock::new();

/// Make `sink` the process's hang log, as [`crate::install`] makes the panic
/// hook. A second install is refused and returns its sink.
pub fn install(sink: HangSink) -> Result<(), HangSink> {
    INSTALLED.set(sink)
}

/// Whether the process has a hang log.
pub fn installed() -> bool {
    INSTALLED.get().is_some()
}

/// Write `record` to the process's hang log; nothing before [`install`].
pub fn write(record: serde_json::Value) {
    if let Some(sink) = INSTALLED.get() {
        sink(record);
    }
}
