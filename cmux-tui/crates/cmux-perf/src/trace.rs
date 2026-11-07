//! The Chrome trace event format that ui.perfetto.dev opens: one JSON object,
//! `{"traceEvents": [...], "displayTimeUnit": "ms", "metadata": {...}}`.
//!
//! The phases used: `X` (a slice with its duration), `i` (an instant), `C` (a
//! counter sample; each key of `args` is one series of the track named by
//! `name` in its process) and `M` (metadata: `process_name`, `thread_name`).
//! `ts` and `dur` are microseconds; `ts` is wall clock since the Unix epoch
//! ([`crate::clock`]), the same for every source.

use std::io::Write;
use std::path::Path;

use serde::Serialize;
use serde_json::{Map, Value};

/// One trace event.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Event {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cat: Option<String>,
    pub ph: &'static str,
    pub ts: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dur: Option<i64>,
    pub pid: i64,
    pub tid: u64,
    /// The scope of an instant: `t` (its thread), `p` (its process).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub s: Option<&'static str>,
    #[serde(skip_serializing_if = "Map::is_empty")]
    pub args: Map<String, Value>,
}

impl Event {
    /// A slice from `ts` lasting `dur` µs.
    pub fn slice(name: &str, cat: &str, ts: i64, dur: i64, pid: i64, tid: u64) -> Self {
        Self {
            name: name.to_owned(),
            cat: Some(cat.to_owned()),
            ph: "X",
            ts,
            dur: Some(dur.max(0)),
            pid,
            tid,
            s: None,
            args: Map::new(),
        }
    }

    /// An instant on its thread.
    pub fn instant(name: &str, cat: &str, ts: i64, pid: i64, tid: u64) -> Self {
        Self {
            name: name.to_owned(),
            cat: Some(cat.to_owned()),
            ph: "i",
            ts,
            dur: None,
            pid,
            tid,
            s: Some("t"),
            args: Map::new(),
        }
    }

    /// A counter sample: track `name` of process `pid`, one series per key.
    pub fn counter(name: &str, ts: i64, pid: i64, series: &[(&str, f64)]) -> Self {
        let args = series.iter().map(|(key, value)| ((*key).to_owned(), rounded(*value))).collect();
        Self {
            name: name.to_owned(),
            cat: None,
            ph: "C",
            ts,
            dur: None,
            pid,
            tid: 0,
            s: None,
            args,
        }
    }

    /// `process_name` (`thread_name` with a `tid`) metadata: what Perfetto
    /// titles the process's (thread's) tracks with.
    pub fn name_of(pid: i64, tid: Option<u64>, name: &str) -> Self {
        let mut args = Map::new();
        args.insert("name".to_owned(), Value::from(name));
        Self {
            name: if tid.is_some() { "thread_name" } else { "process_name" }.to_owned(),
            cat: None,
            ph: "M",
            ts: 0,
            dur: None,
            pid,
            tid: tid.unwrap_or(0),
            s: None,
            args,
        }
    }

    pub fn with_arg(mut self, key: &str, value: impl Into<Value>) -> Self {
        self.args.insert(key.to_owned(), value.into());
        self
    }
}

/// `value` to three decimals, as JSON (a non-finite value is null).
pub fn rounded(value: f64) -> Value {
    serde_json::Number::from_f64((value * 1000.0).round() / 1000.0)
        .map_or(Value::Null, Value::Number)
}

/// The whole trace file: metadata events first, then the rest by time.
pub fn document(mut events: Vec<Event>, metadata: Value) -> Value {
    events.sort_by_key(|event| (event.ph != "M", event.ts));
    serde_json::json!({
        "traceEvents": events,
        "displayTimeUnit": "ms",
        "metadata": metadata,
    })
}

/// Writes `document` to `path` (compact: a long recording has many events).
pub fn write(path: &Path, document: &Value) -> std::io::Result<()> {
    let file = std::fs::File::create(path)?;
    let mut writer = std::io::BufWriter::new(file);
    serde_json::to_writer(&mut writer, document)?;
    writer.write_all(b"\n")?;
    writer.flush()
}
