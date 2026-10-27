//! The panic log of cmux's background processes.
//!
//! A detached daemon (the session owner, the acpmux daemon) has no stdio a
//! person sees, so the default panic message goes nowhere or into a log no
//! one reads: the acpmux sort panic of 2026-10-14 ended one request task and
//! left only two lines in `daemon.log`. [`install`] adds a panic hook that
//! appends one JSON line per panic to a file (message, location, thread,
//! backtrace, plus the caller's fields) and then runs the previous hook, so
//! a process that catches and recovers from a panic keeps doing so. The
//! cmux-next app reads new lines and sends them to Sentry under the user's
//! telemetry choice (`RustPanicForwarder`).
//!
//! Each line is a JSON object with these keys, plus every key in `fields`:
//! `message`, `location` (`file:line:col`), `thread`, `at_ms`, `test`
//! (true for a debug test panic, which the app never sends) and
//! `backtrace` (at most [`MAX_BACKTRACE_BYTES`]), and `crash_keys` (the
//! process's [`crash_keys`] at the panic) when any key is set. Once the
//! process's trace black box runs (`cmux_trace::init_blackbox`), a line also
//! has its `role` and `uptime_ms` (since that start), and a panic inside
//! `cmux_trace::trace_scope!`s has `scopes` (their names, innermost first) and
//! `scope_depth` (how many were open, those past the names too) ([`trace_context`]).
//!
//! The hang log beside it ([`hang`]) gets one JSON line per watched scope
//! that runs past its hang deadline, with the hung thread's stack.
//!
//! [`Supervisor`] runs long-lived threads and tasks under a declared failure
//! policy ([`Fatal`] by default, [`Restart`] for state-private workers) and a
//! [`ShutdownBehavior`]; a fatal failure adds a `"kind": "supervised_exit"`
//! line and ends the process.

pub mod crash_keys;
pub mod hang;

use std::io::Write;
use std::path::{Path, PathBuf};

mod supervise;

pub use supervise::{
    ExitProcess, Failure, FailureSink, Fatal, FatalReason, FatalReport, PoisonProbe, Restart,
    SUPERVISED_FATAL_EXIT_CODE, ShutdownBehavior, ShutdownReport, StopToken, SuperviseError,
    Supervisor, WorkerHandle, WorkerOutcome,
};

/// Largest backtrace kept per line.
pub const MAX_BACKTRACE_BYTES: usize = 16 * 1024;
/// The log stops growing at this size; the app reads it from its own offset.
pub const MAX_LOG_BYTES: u64 = 1024 * 1024;

/// Fields every line carries besides the panic itself (process, pid, version).
pub type Fields = serde_json::Map<String, serde_json::Value>;

/// Install a hook that appends each panic to `path`, then runs the previous
/// hook. `is_test_thread` marks lines from a debug test trigger (`"test": true`).
pub fn install(path: PathBuf, fields: Fields, is_test_thread: fn(&str) -> bool) {
    install_with_opener(move || open_append(&path), fields, is_test_thread);
}

/// Install the hook with a caller-owned secure opener. A daemon whose state
/// has an ownership/DACL policy can enforce it on the exact handle written by
/// the panic hook instead of validating a pathname separately.
pub fn install_with_opener(
    opener: impl Fn() -> std::io::Result<std::fs::File> + Send + Sync + 'static,
    fields: Fields,
    is_test_thread: fn(&str) -> bool,
) {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let thread = std::thread::current().name().unwrap_or("unnamed").to_string();
        let message = supervise::payload_text(info.payload());
        let location = info.location().map(ToString::to_string).unwrap_or_default();
        let backtrace = std::backtrace::Backtrace::force_capture().to_string();
        let test = is_test_thread(&thread);
        let mut line = record(&fields, &message, &location, &thread, test, backtrace);
        let keys = crash_keys::snapshot();
        if let serde_json::Value::Object(object) = &mut line {
            if !keys.is_empty() {
                object.insert("crash_keys".into(), keys.to_json());
            }
            object.extend(trace_context(
                cmux_trace::process_role(),
                cmux_trace::process_uptime_ns(),
                &cmux_trace::scope_stack(),
            ));
        }
        append_opened(&opener, &line);
        previous(info);
    }));
}

/// One log line's JSON: `fields` plus the panic's own keys (which win).
pub fn record(
    fields: &Fields,
    message: &str,
    location: &str,
    thread: &str,
    test: bool,
    mut backtrace: String,
) -> serde_json::Value {
    if backtrace.len() > MAX_BACKTRACE_BYTES {
        let mut end = MAX_BACKTRACE_BYTES;
        while !backtrace.is_char_boundary(end) {
            end -= 1;
        }
        backtrace.truncate(end);
    }
    let at_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis())
        .unwrap_or_default();
    let mut line = fields.clone();
    line.insert("message".into(), message.into());
    line.insert("location".into(), location.into());
    line.insert("thread".into(), thread.into());
    line.insert("at_ms".into(), serde_json::json!(at_ms));
    line.insert("test".into(), test.into());
    line.insert("backtrace".into(), backtrace.into());
    serde_json::Value::Object(line)
}

/// The trace keys of a panic line: `role` and `uptime_ms` when the process
/// traces, `scopes` (innermost first) and `scope_depth` when the panicking
/// thread had scopes open. The hook reads them on the panicking thread.
pub fn trace_context(
    role: Option<cmux_trace::Role>,
    uptime_ns: Option<u64>,
    scopes: &cmux_trace::ScopeStack,
) -> Fields {
    let mut context = Fields::new();
    if let Some(role) = role {
        context.insert("role".into(), role.as_str().into());
    }
    if let Some(uptime_ns) = uptime_ns {
        context.insert("uptime_ms".into(), (uptime_ns / 1_000_000).into());
    }
    if scopes.depth() > 0 {
        let names: Vec<serde_json::Value> = scopes.names().map(Into::into).collect();
        context.insert("scopes".into(), names.into());
        context.insert("scope_depth".into(), scopes.depth().into());
    }
    context
}

/// Append `record` as one line, unless the log is full. Never panics.
pub fn append(path: &Path, record: &serde_json::Value) {
    append_opened(&|| open_append(path), record);
}

fn open_append(path: &Path) -> std::io::Result<std::fs::File> {
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // Backtraces and messages may hold paths: owner-only, never through a planted link.
        options.mode(0o600).custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
        options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
    }
    let file = options.open(path)?;
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
        if file.metadata()?.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "panic log is a reparse point",
            ));
        }
    }
    Ok(file)
}

fn append_opened(opener: &impl Fn() -> std::io::Result<std::fs::File>, record: &serde_json::Value) {
    if let Ok(mut file) = opener() {
        if file.metadata().is_ok_and(|meta| meta.len() >= MAX_LOG_BYTES) {
            return;
        }
        // One write per line, so concurrent panics never interleave a line.
        let _ = file.write_all(format!("{record}\n").as_bytes());
    }
}
