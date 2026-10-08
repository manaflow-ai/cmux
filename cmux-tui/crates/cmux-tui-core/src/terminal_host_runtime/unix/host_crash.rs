//! A terminal host's crash sidecar (cx-0tgl LA).
//!
//! A host panic is a bug. The panic hook writes `<terminal-id>.crash` next
//! to the host's discovery record (message, location, thread, backtrace,
//! incarnation) before the default hook runs, so the owner names the crash
//! in `terminal-losses.jsonl` and the tab's end instead of an anonymous
//! "uncatchable end". The owner removes the sidecar with the breadcrumbs.

use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;

/// Largest backtrace kept in the sidecar.
const MAX_BACKTRACE_BYTES: usize = 64 * 1024;

/// Debug builds only: the path of a marker file. The first host that creates
/// it panics and aborts once it published its record (crash tests); hosts
/// that find it already present run normally, so a replacement host lives.
#[cfg(debug_assertions)]
const ABORT_ONCE_TEST_ENV: &str = "CMUX_TUI_TEST_HOST_ABORT_ONCE";

/// Install the crash hook for this host process (once its terminal is known).
pub(super) fn install(path: PathBuf, terminal_id: &str, incarnation: &str) {
    let terminal_id = terminal_id.to_string();
    let incarnation = incarnation.to_string();
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
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
        let at_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_millis())
            .unwrap_or_default();
        let record = serde_json::json!({
            "terminal_id": terminal_id,
            "incarnation": incarnation,
            "message": message,
            "location": location,
            "thread": std::thread::current().name().unwrap_or("unnamed"),
            "host_pid": std::process::id(),
            "at_ms": at_ms,
            "backtrace": backtrace,
        });
        if let Ok(mut file) = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&path)
        {
            let _ = file.write_all(record.to_string().as_bytes());
        }
        previous(info);
    }));
    #[cfg(debug_assertions)]
    abort_once_for_test();
}

#[cfg(debug_assertions)]
fn abort_once_for_test() {
    let Some(marker) = std::env::var_os(ABORT_ONCE_TEST_ENV) else { return };
    if OpenOptions::new().write(true).create_new(true).open(&marker).is_err() {
        return;
    }
    let _ = std::thread::Builder::new().name("terminal-host-test-crash".into()).spawn(|| {
        std::thread::sleep(std::time::Duration::from_millis(300));
        // crash-allow: a test-only injected crash (debug builds, explicit env).
        let _ = std::panic::catch_unwind(|| panic!("test-injected host crash"));
        // crash-allow: a test-only injected crash (debug builds, explicit env).
        std::process::abort();
    });
}
