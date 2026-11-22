//! Debug timing marks on the terminal create path (R81; zero-wait IX0).
//!
//! Off unless `CMUX_TUI_DEBUG_SPANS` names a file. A create starts a
//! [`Trace`] at the time its request arrived; code on the path calls
//! [`mark`] with a name, which records the time since arrival on the trace
//! installed on the current thread (and does nothing when no trace is
//! installed, as on every thread outside a create). The trace moves with
//! the create between threads ([`take`], [`install`]) and is appended to the
//! file as one JSON line when the reply is queued ([`finish`]):
//! `{"label":"new-tab","total_us":N,"marks":[["name",us],...]}`. The gap
//! before a mark is the cost of the step the mark names.

use std::borrow::Cow;
use std::cell::RefCell;
use std::io::Write;
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

/// Marks of one create, measured from the arrival of its request.
pub(crate) struct Trace {
    label: &'static str,
    start: Instant,
    marks: Vec<(Cow<'static, str>, u64)>,
}

thread_local! {
    static CURRENT: RefCell<Option<Trace>> = const { RefCell::new(None) };
}

fn sink() -> Option<&'static Mutex<std::fs::File>> {
    static SINK: OnceLock<Option<Mutex<std::fs::File>>> = OnceLock::new();
    SINK.get_or_init(|| {
        let path = std::env::var_os("CMUX_TUI_DEBUG_SPANS").filter(|path| !path.is_empty())?;
        std::fs::OpenOptions::new().create(true).append(true).open(path).ok().map(Mutex::new)
    })
    .as_ref()
}

/// Whether marks are recorded in this process.
pub(crate) fn enabled() -> bool {
    sink().is_some()
}

impl Trace {
    /// A trace for a request that arrived at `start`, or `None` when marks
    /// are off.
    pub(crate) fn start(label: &'static str, start: Instant) -> Option<Self> {
        enabled().then(|| Self { label, start, marks: Vec::new() })
    }
}

/// Make `trace` the current thread's trace.
pub(crate) fn install(trace: Option<Trace>) {
    if let Some(trace) = trace {
        CURRENT.with(|current| *current.borrow_mut() = Some(trace));
    }
}

/// Remove and return the current thread's trace.
pub(crate) fn take() -> Option<Trace> {
    if !enabled() {
        return None;
    }
    CURRENT.with(|current| current.borrow_mut().take())
}

/// Record `name` on the current thread's trace, if any.
pub(crate) fn mark(name: &'static str) {
    mark_with(|| Cow::Borrowed(name));
}

/// Record a computed name; `name` runs only when a trace is installed.
pub(crate) fn mark_with(name: impl FnOnce() -> Cow<'static, str>) {
    if !enabled() {
        return;
    }
    CURRENT.with(|current| {
        if let Ok(mut current) = current.try_borrow_mut()
            && let Some(trace) = current.as_mut()
        {
            let elapsed = trace.start.elapsed().as_micros() as u64;
            trace.marks.push((name(), elapsed));
        }
    });
}

/// Append `trace` to the marks file.
pub(crate) fn finish(trace: Option<Trace>) {
    let (Some(trace), Some(sink)) = (trace, sink()) else { return };
    let marks = trace
        .marks
        .iter()
        .map(|(name, elapsed)| serde_json::json!([name, elapsed]))
        .collect::<Vec<_>>();
    let line = serde_json::json!({
        "label": trace.label,
        "total_us": trace.start.elapsed().as_micros() as u64,
        "marks": marks,
    });
    if let Ok(mut file) = sink.lock() {
        let _ = writeln!(file, "{line}");
    }
}

/// Mark the start of every commit on a registry connection: the gap after
/// `sqlite.commit` is the commit's write and sync.
pub(crate) fn traced(connection: rusqlite::Connection) -> rusqlite::Connection {
    if enabled() {
        let _ = connection.commit_hook(Some(|| {
            mark("sqlite.commit");
            false
        }));
    }
    connection
}
