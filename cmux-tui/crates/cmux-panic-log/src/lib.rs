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
//! process's [`crash_keys`] at the panic) when any key is set.
//!
//! The hang log beside it ([`hang`]) gets one JSON line per watched scope
//! that runs past its hang deadline, with the hung thread's stack.
//!
//! Features: `json` (default) is the serde_json writer above and the hang
//! log. `minimal` writes the same line with std alone ([`minimal`]), for
//! the holder, which links std and libc only.

pub mod crash_keys;
#[cfg(feature = "json")]
pub mod hang;
#[cfg(feature = "minimal")]
pub mod minimal;

#[cfg(any(feature = "json", feature = "minimal"))]
use std::io::Write;
#[cfg(any(feature = "json", feature = "minimal"))]
use std::path::Path;
#[cfg(feature = "json")]
use std::path::PathBuf;

/// Largest backtrace kept per line.
pub const MAX_BACKTRACE_BYTES: usize = 16 * 1024;
/// The log stops growing at this size; the app reads it from its own offset.
pub const MAX_LOG_BYTES: u64 = 1024 * 1024;

/// Fields every line carries besides the panic itself (process, pid, version).
#[cfg(feature = "json")]
pub type Fields = serde_json::Map<String, serde_json::Value>;

/// Install a hook that appends each panic to `path`, then runs the previous
/// hook. `is_test_thread` marks lines from a debug test trigger (`"test": true`).
#[cfg(feature = "json")]
pub fn install(path: PathBuf, fields: Fields, is_test_thread: fn(&str) -> bool) {
    install_with_opener(move || open_append(&path), fields, is_test_thread);
}

/// Install the hook with a caller-owned secure opener. A daemon whose state
/// has an ownership/DACL policy can enforce it on the exact handle written by
/// the panic hook instead of validating a pathname separately.
#[cfg(feature = "json")]
pub fn install_with_opener(
    opener: impl Fn() -> std::io::Result<std::fs::File> + Send + Sync + 'static,
    fields: Fields,
    is_test_thread: fn(&str) -> bool,
) {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let panic = Panic::capture(info);
        let test = is_test_thread(&panic.thread);
        let mut line =
            record(&fields, &panic.message, &panic.location, &panic.thread, test, panic.backtrace);
        let keys = crash_keys::snapshot();
        if let (false, serde_json::Value::Object(object)) = (keys.is_empty(), &mut line) {
            object.insert("crash_keys".into(), keys.to_json());
        }
        append_line(&opener, format!("{line}\n").as_bytes());
        previous(info);
    }));
}

/// One log line's JSON: `fields` plus the panic's own keys (which win).
#[cfg(feature = "json")]
pub fn record(
    fields: &Fields,
    message: &str,
    location: &str,
    thread: &str,
    test: bool,
    mut backtrace: String,
) -> serde_json::Value {
    truncate_backtrace(&mut backtrace);
    let mut line = fields.clone();
    line.insert("message".into(), message.into());
    line.insert("location".into(), location.into());
    line.insert("thread".into(), thread.into());
    line.insert("at_ms".into(), serde_json::json!(now_ms()));
    line.insert("test".into(), test.into());
    line.insert("backtrace".into(), backtrace.into());
    serde_json::Value::Object(line)
}

/// Append `record` as one line, unless the log is full. Never panics.
#[cfg(feature = "json")]
pub fn append(path: &Path, record: &serde_json::Value) {
    append_line(&|| open_append(path), format!("{record}\n").as_bytes());
}

/// What a panic hook reads from the panic, the same for both writers.
#[cfg(any(feature = "json", feature = "minimal"))]
struct Panic {
    message: String,
    location: String,
    thread: String,
    backtrace: String,
}

#[cfg(any(feature = "json", feature = "minimal"))]
impl Panic {
    fn capture(info: &std::panic::PanicHookInfo<'_>) -> Self {
        let message = info
            .payload()
            .downcast_ref::<&str>()
            .map(|text| (*text).to_string())
            .or_else(|| info.payload().downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "non-text panic payload".to_string());
        Self {
            message,
            location: info.location().map(ToString::to_string).unwrap_or_default(),
            thread: std::thread::current().name().unwrap_or("unnamed").to_string(),
            backtrace: std::backtrace::Backtrace::force_capture().to_string(),
        }
    }
}

/// Cut `backtrace` to at most [`MAX_BACKTRACE_BYTES`], on a char boundary.
#[cfg(any(feature = "json", feature = "minimal"))]
fn truncate_backtrace(backtrace: &mut String) {
    if backtrace.len() > MAX_BACKTRACE_BYTES {
        let mut end = MAX_BACKTRACE_BYTES;
        while !backtrace.is_char_boundary(end) {
            end -= 1;
        }
        backtrace.truncate(end);
    }
}

/// Milliseconds since the Unix epoch, 0 before it.
#[cfg(any(feature = "json", feature = "minimal"))]
fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis())
        .unwrap_or_default()
}

#[cfg(any(feature = "json", feature = "minimal"))]
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

/// Append one whole `line` (its newline included), unless the log is full.
#[cfg(any(feature = "json", feature = "minimal"))]
fn append_line(opener: &impl Fn() -> std::io::Result<std::fs::File>, line: &[u8]) {
    if let Ok(mut file) = opener() {
        if file.metadata().is_ok_and(|meta| meta.len() >= MAX_LOG_BYTES) {
            return;
        }
        // One write per line, so concurrent panics never interleave a line.
        let _ = file.write_all(line);
    }
}
