//! The session owner's panic log (cx-urd.59).
//!
//! The detached owner runs with no stdio, so the default panic message goes
//! nowhere: a main-thread panic exited with status 101 and a worker-thread
//! panic ended only that thread, both without a trace. The owner's panic
//! hook appends one JSON line per panic to `owner-panics-<session>.jsonl` at
//! the state root (beside `client.log`): message, location, thread,
//! backtrace. It records caught panics too (the kitty PNG decoder, hook
//! delivery and journal retention catch theirs and recover; a caught panic
//! is still a bug). It never aborts, so those recoveries keep working. The
//! cmux-next app reads new lines and sends them to Sentry under the user's
//! telemetry choice.

use std::io::Write;
use std::path::PathBuf;

/// Largest backtrace kept per line.
const MAX_BACKTRACE_BYTES: usize = 16 * 1024;
/// The log stops growing at this size; the app reads it from its own offset.
const MAX_LOG_BYTES: u64 = 1024 * 1024;

/// Debug builds only: `thread` makes a worker thread panic once the hook is
/// installed (tests/owner_panic.rs). Its line carries `"test": true`.
#[cfg(debug_assertions)]
const TEST_PANIC_ENV: &str = "CMUX_TUI_TEST_OWNER_PANIC";
#[cfg(debug_assertions)]
const TEST_PANIC_THREAD: &str = "owner-panic-test";

/// The log for `session`: the state root (the parent of the sessions
/// directory). A session name that needs escaping gets a hash suffix, so two
/// names never share a log.
pub(super) fn log_path(session: &str) -> Option<PathBuf> {
    let sessions = cmux_tui_core::platform::workspace_state_dir()?;
    let root = sessions.parent().map(PathBuf::from).unwrap_or(sessions);
    let safe: String = session
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') { c } else { '-' })
        .collect();
    let name = if safe == session {
        safe
    } else {
        // FNV-1a: stable across builds, no dependency.
        let hash = session.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
            (hash ^ u64::from(byte)).wrapping_mul(0x100_0000_01b3)
        });
        format!("{safe}-{:08x}", hash as u32)
    };
    Some(root.join(format!("owner-panics-{name}.jsonl")))
}

/// Install the owner's panic hook. Call once, in the headless owner only.
pub(super) fn install(session: &str) {
    let session = session.to_string();
    let path = log_path(&session);
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        if let Some(path) = &path {
            append(path, &session, info);
        }
        previous(info);
    }));
    #[cfg(debug_assertions)]
    panic_for_test();
}

fn append(path: &std::path::Path, session: &str, info: &std::panic::PanicHookInfo<'_>) {
    let message = info
        .payload()
        .downcast_ref::<&str>()
        .map(|text| (*text).to_string())
        .or_else(|| info.payload().downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "non-text panic payload".to_string());
    let location = info.location().map(ToString::to_string).unwrap_or_default();
    let mut backtrace = std::backtrace::Backtrace::force_capture().to_string();
    if backtrace.len() > MAX_BACKTRACE_BYTES {
        let mut end = MAX_BACKTRACE_BYTES;
        while !backtrace.is_char_boundary(end) {
            end -= 1;
        }
        backtrace.truncate(end);
    }
    let thread = std::thread::current().name().unwrap_or("unnamed").to_string();
    let at_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis())
        .unwrap_or_default();
    #[cfg(debug_assertions)]
    let test = thread == TEST_PANIC_THREAD;
    #[cfg(not(debug_assertions))]
    let test = false;
    let record = serde_json::json!({
        "session": session,
        "message": message,
        "location": location,
        "thread": thread,
        "owner_pid": std::process::id(),
        "version": env!("CARGO_PKG_VERSION"),
        "at_ms": at_ms,
        "test": test,
        "backtrace": backtrace,
    });
    if std::fs::metadata(path).is_ok_and(|meta| meta.len() >= MAX_LOG_BYTES) {
        return;
    }
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // Backtraces and messages may hold paths: owner-only, never through a planted link.
        options.mode(0o600).custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW);
    }
    if let Ok(mut file) = options.open(path) {
        // One write per line, so concurrent panics never interleave a line.
        let _ = file.write_all(format!("{record}\n").as_bytes());
    }
}

/// Debug builds only: panic a worker thread when the test asks for it.
#[cfg(debug_assertions)]
fn panic_for_test() {
    if std::env::var(TEST_PANIC_ENV).as_deref() != Ok("thread") {
        return;
    }
    let _ = std::thread::Builder::new()
        .name(TEST_PANIC_THREAD.into())
        // crash-allow: debug-only test trigger for the owner panic log
        .spawn(|| panic!("cmux-tui test owner panic"));
}
