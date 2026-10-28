//! A terminal host's crash sidecar (cx-0tgl LA).
//!
//! A host panic is a bug. The panic hook writes `<terminal-id>.crash` next
//! to the host's discovery record (message, location, thread, backtrace,
//! incarnation) before the default hook runs. A panic does not always end
//! the host (a caught parser panic publishes a normal exit; another thread's
//! panic ends only that thread), so the owner reports it as context: "the
//! host had panicked" next to the signals, in `terminal-losses.jsonl`, and
//! as a flag in the tab's end. The owner removes the sidecar on every end of
//! the host's incarnation.
//!
//! Before it removes the sidecar, the owner appends it to its own panic log
//! as one `cmux-panic-log` line with `"source": "cmux-tui-host"`
//! ([`append_to_panic_log`]), so a host panic reaches Sentry the way the
//! owner's do (the app's `OwnerPanicForwarder`, or `crash_forward` for a
//! standalone cmux-tui), labeled as the host's. This is Chrome's split: a
//! child process records its crash and the browser process uploads it
//! (components/crash/core/app/crashpad.cc).

#[cfg(debug_assertions)]
use crate::supervised::{self, Fatal, ShutdownBehavior};
use cmux_threads::checked::fs as files;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use super::super::sys::{self, PrivateOpen};

/// Largest backtrace kept in the sidecar.
const MAX_BACKTRACE_BYTES: usize = 64 * 1024;

/// Debug builds only: the path of a marker file. The first host that creates
/// it panics and aborts once it published its record and the test opens the
/// FIFO `<marker>.trigger` for writing (crash tests decide the moment, for
/// example after the owner holds the PTY custody); hosts that find the
/// marker already present run normally, so a replacement host lives.
#[cfg(debug_assertions)]
const ABORT_ONCE_TEST_ENV: &str = "CMUX_TUI_TEST_HOST_ABORT_ONCE";
/// Debug builds only: the thread of that injected crash. Its sidecar says
/// `"test": true`, so its panic-log line is one the app never sends.
#[cfg(debug_assertions)]
const TEST_CRASH_THREAD: &str = "terminal-host-test-crash";

/// The `source` of a host panic's line in the owner's panic log; the app
/// labels such a line as the terminal host's, not the owner's.
pub const PANIC_LOG_SOURCE: &str = "cmux-tui-host";

/// Where the owner appends its hosts' panics: its own panic log, with the
/// fields every line of that log carries (session, version, build).
#[derive(Debug, Clone, PartialEq)]
pub struct HostPanicLog {
    pub path: PathBuf,
    pub fields: cmux_panic_log::Fields,
}

/// The panic-log line for one sidecar's text: `fields`, the sidecar's
/// terminal, incarnation and host pid, and its panic (message, location,
/// thread, backtrace, the time it happened, and whether a debug test
/// injected it). `None` for text that is not a crash record.
pub(crate) fn panic_log_line(
    sidecar: &str,
    fields: &cmux_panic_log::Fields,
) -> Option<serde_json::Value> {
    let crash = serde_json::from_str::<serde_json::Value>(sidecar).ok()?;
    let text = |key: &str| crash.get(key).and_then(serde_json::Value::as_str);
    let message = text("message")?;
    let mut fields = fields.clone();
    fields.insert("source".into(), PANIC_LOG_SOURCE.into());
    for key in ["terminal_id", "incarnation", "host_pid"] {
        if let Some(value) = crash.get(key).filter(|value| !value.is_null()) {
            fields.insert(key.into(), value.clone());
        }
    }
    let mut line = cmux_panic_log::record(
        &fields,
        message,
        text("location").unwrap_or_default(),
        text("thread").unwrap_or("unnamed"),
        crash.get("test").and_then(serde_json::Value::as_bool).unwrap_or(false),
        text("backtrace").unwrap_or_default().to_string(),
    );
    // The time of the panic, not of the owner's read.
    if let (Some(at_ms), serde_json::Value::Object(object)) = (crash.get("at_ms"), &mut line)
        && at_ms.is_u64()
    {
        object.insert("at_ms".into(), at_ms.clone());
    }
    Some(line)
}

/// Append the sidecar at `sidecar` to `log` as one panic-log line. The owner
/// calls it right before it removes the sidecar. Best effort: a missing or
/// unreadable sidecar appends nothing.
pub(crate) fn append_to_panic_log(sidecar: &Path, log: &HostPanicLog) {
    let Ok(text) = files::read_to_string(sidecar) else { return };
    if let Some(line) = panic_log_line(&text, &log.fields) {
        cmux_panic_log::append(&log.path, &line);
    }
}

/// Install the crash hook for this host process (once its terminal is known).
pub(crate) fn install(path: PathBuf, terminal_id: &str, incarnation: &str) {
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
        let thread = std::thread::current().name().unwrap_or("unnamed").to_string();
        let record = serde_json::json!({
            "terminal_id": terminal_id,
            "incarnation": incarnation,
            "message": message,
            "location": location,
            "test": is_test_thread(&thread),
            "thread": thread,
            "host_pid": std::process::id(),
            "at_ms": at_ms,
            "backtrace": backtrace,
        });
        // Concurrent panics each write their own file and rename it over the
        // sidecar, so the sidecar is always one whole record.
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let temporary = path.with_extension(format!(
            "crash.tmp-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        if let Ok(mut file) = sys::open_private(&temporary, PrivateOpen::CreateNewNoFollow) {
            if file.write_all(record.to_string().as_bytes()).is_ok() {
                let _ = files::rename(&temporary, &path);
            } else {
                let _ = files::remove_file(&temporary);
            }
        }
        previous(info);
    }));
    #[cfg(debug_assertions)]
    abort_once_for_test();
}

/// The debug test crash's thread; its sidecar carries `"test": true`.
fn is_test_thread(thread: &str) -> bool {
    #[cfg(debug_assertions)]
    {
        thread == TEST_CRASH_THREAD
    }
    #[cfg(not(debug_assertions))]
    {
        let _ = thread;
        false
    }
}

#[cfg(debug_assertions)]
fn abort_once_for_test() {
    let Some(marker) = std::env::var_os(ABORT_ONCE_TEST_ENV) else { return };
    if files::open_with(files::File::options().write(true).create_new(true), &marker).is_err() {
        return;
    }
    let mut trigger = marker;
    trigger.push(".trigger");
    let _ = supervised::spawn_at(
        TEST_CRASH_THREAD,
        cmux_threads::ThreadQos::Utility,
        Fatal,
        ShutdownBehavior::Continue,
        move || {
            // Opening a FIFO for reading blocks until the test opens it for
            // writing: the crash happens at the moment the test chose.
            let _ = files::open(&trigger);
            // crash-allow: a test-only injected crash (debug builds, explicit env).
            #[allow(
                clippy::panic,
                reason = "a test-only injected crash (debug builds, explicit env)"
            )]
            let _ = std::panic::catch_unwind(|| panic!("test-injected host crash"));
            // No core dump: a dump of this process (systemd-coredump compresses
            // it) keeps the host alive for seconds under load, which delays the
            // owner's replacement the test waits for.
            #[cfg(target_os = "linux")]
            // SAFETY: prctl(PR_SET_DUMPABLE) takes integer arguments only.
            unsafe {
                libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0);
            }
            #[cfg(unix)]
            // SAFETY: `limit` is a valid rlimit that outlives the call.
            unsafe {
                let limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
                libc::setrlimit(libc::RLIMIT_CORE, &limit);
            }
            // crash-allow: a test-only injected crash (debug builds, explicit env).
            std::process::abort();
        },
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch() -> PathBuf {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "cmux-host-crash-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn owner_log(dir: &Path) -> HostPanicLog {
        let mut fields = cmux_panic_log::Fields::new();
        fields.insert("session".into(), "main".into());
        fields.insert("version".into(), "0.1.0".into());
        HostPanicLog { path: dir.join("owner-panics-main.jsonl"), fields }
    }

    fn sidecar() -> serde_json::Value {
        serde_json::json!({
            "terminal_id": "t1",
            "incarnation": "inc-1",
            "message": "index out of bounds",
            "location": "crates/vt/src/parser.rs:12:5",
            "thread": "terminal-host-parser",
            "test": false,
            "host_pid": 4242,
            "at_ms": 1_700_000_000_000_u64,
            "backtrace": "0: vt::parser::advance\n1: main",
        })
    }

    fn lines(log: &Path) -> Vec<serde_json::Value> {
        std::fs::read_to_string(log)
            .unwrap_or_default()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }

    #[test]
    fn a_sidecar_becomes_one_panic_log_line_with_location_and_backtrace() {
        let dir = scratch();
        let log = owner_log(&dir);
        let crash = dir.join("t1.crash");
        std::fs::write(&crash, sidecar().to_string()).unwrap();

        append_to_panic_log(&crash, &log);

        let lines = lines(&log.path);
        assert_eq!(lines.len(), 1);
        let line = &lines[0];
        assert_eq!(line["source"], PANIC_LOG_SOURCE);
        assert_eq!(line["message"], "index out of bounds");
        assert_eq!(line["location"], "crates/vt/src/parser.rs:12:5");
        assert_eq!(line["backtrace"], "0: vt::parser::advance\n1: main");
        assert_eq!(line["thread"], "terminal-host-parser");
        assert_eq!(line["terminal_id"], "t1");
        assert_eq!(line["incarnation"], "inc-1");
        assert_eq!(line["host_pid"], 4242);
        assert_eq!(line["at_ms"], 1_700_000_000_000_u64);
        assert_eq!(line["test"], false);
        // The owner's own fields, so the app tags the release and session.
        assert_eq!(line["session"], "main");
        assert_eq!(line["version"], "0.1.0");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn host_crash_is_logged_before_the_owner_removes_the_sidecar() {
        let dir = scratch();
        let log = owner_log(&dir);
        let record = dir.join("t1.json");
        let crash = crate::terminal_loss_cause::crash_path(&record);
        std::fs::write(&crash, sidecar().to_string()).unwrap();

        crate::terminal_loss_log::remove_signals(&record, Some(&log));

        assert!(!crash.exists());
        assert_eq!(lines(&log.path).len(), 1);
        // The sidecar is gone, so nothing is appended twice.
        crate::terminal_loss_log::remove_signals(&record, Some(&log));
        assert_eq!(lines(&log.path).len(), 1);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[cfg(debug_assertions)]
    #[test]
    fn a_test_injected_host_crash_gives_a_test_line() {
        // The host's hook marks the debug test crash's thread.
        assert!(is_test_thread(TEST_CRASH_THREAD));
        assert!(!is_test_thread("terminal-host-parser"));
        let mut crash = sidecar();
        crash["thread"] = TEST_CRASH_THREAD.into();
        crash["test"] = is_test_thread(TEST_CRASH_THREAD).into();
        let line = panic_log_line(&crash.to_string(), &cmux_panic_log::Fields::new()).unwrap();
        assert_eq!(line["test"], true);
        assert_eq!(line["thread"], TEST_CRASH_THREAD);
    }

    #[test]
    fn host_crash_text_that_is_not_a_record_appends_nothing() {
        let fields = cmux_panic_log::Fields::new();
        assert_eq!(panic_log_line("not json", &fields), None);
        assert_eq!(panic_log_line(r#"{"terminal_id":"t1"}"#, &fields), None);
        let dir = scratch();
        let log = owner_log(&dir);
        append_to_panic_log(&dir.join("missing.crash"), &log);
        assert!(!log.path.exists());
        let _ = std::fs::remove_dir_all(dir);
    }
}
