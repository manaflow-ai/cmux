//! The holder's panic log (p10-stability-150). A holder panic can end every
//! terminal it keeps, and the release profile unwinds, so no system crash
//! report has it. [`install_from_env`] adds a panic hook that appends one
//! JSON line per panic to the file the daemon names ([`PANIC_LOG_ENV`]),
//! then runs the previous hook. The line has the cmux-panic-log format
//! (`message`, `location`, `thread`, `at_ms`, `test`, `backtrace` and the
//! process fields `process`, `pid`, `version`, `os`, `arch`), written with std
//! only: the holder links std and libc (tests/host_spans.rs). The cmux-next
//! app sends new lines to Sentry (`RustPanicSource.holder`).

use std::fmt::Write as _;
use std::io::Write as _;
use std::path::{Path, PathBuf};

/// The file the holder appends its panics to; the daemon sets it
/// (cmux-tui-core `diagnostics::holder_panic_log_path`). An environment
/// variable, not an argument, so an older holder that does not know it still
/// starts. Unset: no hook.
pub const PANIC_LOG_ENV: &str = "CMUX_HOLDER_PANIC_LOG";
/// The release of the daemon that started the holder from its own bundle,
/// the `version` field of each line.
pub const PANIC_LOG_VERSION_ENV: &str = "CMUX_HOLDER_PANIC_LOG_VERSION";
/// Debug builds only: `thread` makes a worker thread panic once the hook is
/// installed (tests/panic_log.rs). Its line carries `"test": true`.
#[cfg(debug_assertions)]
pub const TEST_PANIC_ENV: &str = "CMUX_HOLDER_TEST_PANIC";
#[cfg(debug_assertions)]
const TEST_PANIC_THREAD: &str = "holder-panic-test";

/// Largest backtrace kept per line (cmux-panic-log `MAX_BACKTRACE_BYTES`).
const MAX_BACKTRACE_BYTES: usize = 16 * 1024;
/// The log stops growing at this size (cmux-panic-log `MAX_LOG_BYTES`).
const MAX_LOG_BYTES: u64 = 1024 * 1024;

/// Install the panic hook when the daemon named a log. Call once, from the
/// holder process's entry point, before it serves.
pub fn install_from_env() {
    let Some(path) = std::env::var_os(PANIC_LOG_ENV).filter(|path| !path.is_empty()) else {
        return;
    };
    let path = PathBuf::from(path);
    let fields = fields(std::env::var(PANIC_LOG_VERSION_ENV).ok().as_deref());
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let thread = std::thread::current().name().unwrap_or("unnamed").to_string();
        let message = info
            .payload()
            .downcast_ref::<&str>()
            .map(|text| (*text).to_string())
            .or_else(|| info.payload().downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "non-text panic payload".to_string());
        let location = info.location().map(ToString::to_string).unwrap_or_default();
        let backtrace = std::backtrace::Backtrace::force_capture().to_string();
        let test = is_test_thread(&thread);
        append(&path, &line(&fields, &message, &location, &thread, test, backtrace));
        previous(info);
    }));
    #[cfg(debug_assertions)]
    panic_for_test();
}

/// The process fields of every line, as JSON members with a trailing comma.
fn fields(version: Option<&str>) -> String {
    let mut fields = String::new();
    member(&mut fields, "process", "cmux-holder");
    let _ = write!(fields, "\"pid\":{},", std::process::id());
    if let Some(version) = version.filter(|version| !version.is_empty()) {
        member(&mut fields, "version", version);
    }
    member(&mut fields, "os", std::env::consts::OS);
    member(&mut fields, "arch", std::env::consts::ARCH);
    fields
}

/// One log line: `fields`, then the panic's own keys.
fn line(
    fields: &str,
    message: &str,
    location: &str,
    thread: &str,
    test: bool,
    mut backtrace: String,
) -> String {
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
    let mut line = String::from("{");
    line.push_str(fields);
    member(&mut line, "message", message);
    member(&mut line, "location", location);
    member(&mut line, "thread", thread);
    let _ = write!(line, "\"at_ms\":{at_ms},\"test\":{test},");
    line.push_str("\"backtrace\":");
    quote(&mut line, &backtrace);
    line.push_str("}\n");
    line
}

/// `"key":"value",` with `value` escaped.
fn member(out: &mut String, key: &str, value: &str) {
    quote(out, key);
    out.push(':');
    quote(out, value);
    out.push(',');
}

/// `text` as a JSON string (RFC 8259 section 7).
fn quote(out: &mut String, text: &str) {
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            control if u32::from(control) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", u32::from(control));
            }
            other => out.push(other),
        }
    }
    out.push('"');
}

/// Append `line` with one write, unless the log is full. Never panics.
fn append(path: &Path, line: &str) {
    use std::os::unix::fs::OpenOptionsExt;
    // Backtraces and messages may hold paths: owner-only, never through a planted link.
    let opened = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path);
    let Ok(mut file) = opened else { return };
    if file.metadata().is_ok_and(|meta| meta.len() >= MAX_LOG_BYTES) {
        return;
    }
    let _ = file.write_all(line.as_bytes());
}

/// The debug test trigger's thread; its line carries `"test": true`.
fn is_test_thread(thread: &str) -> bool {
    #[cfg(debug_assertions)]
    {
        thread == TEST_PANIC_THREAD
    }
    #[cfg(not(debug_assertions))]
    {
        let _ = thread;
        false
    }
}

/// Debug builds only: panic a worker thread when the test asks for it.
#[cfg(debug_assertions)]
#[allow(
    clippy::panic,
    reason = "debug-build test trigger for the holder panic log; release builds have no seam"
)]
fn panic_for_test() {
    if std::env::var(TEST_PANIC_ENV).as_deref() != Ok("thread") {
        return;
    }
    let _ = std::thread::Builder::new()
        .name(TEST_PANIC_THREAD.into())
        // crash-allow: debug-only test trigger for the holder panic log
        .spawn(|| panic!("cmux-holder test panic"));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_line_is_one_json_object_with_its_text_escaped() {
        let fields = fields(Some("1.2.3"));
        let line =
            line(&fields, "bad \"x\"\n\u{1}", "src/lib.rs:3:4", "main", false, "0: f".into());
        assert!(line.ends_with("}\n"), "{line}");
        assert_eq!(line.matches('\n').count(), 1, "one line: {line}");
        assert!(line.contains(r#""message":"bad \"x\"\n\u0001""#), "{line}");
        assert!(line.contains(r#""process":"cmux-holder","#), "{line}");
        assert!(line.contains(r#""version":"1.2.3","#), "{line}");
        assert!(line.contains(r#""test":false,"backtrace":"0: f"}"#), "{line}");
    }
}
