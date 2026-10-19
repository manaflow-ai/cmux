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

use std::io::Write;
use std::path::PathBuf;
use std::sync::Arc;
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

/// Where one terminal's crash sidecar goes.
pub(crate) struct CrashTarget {
    path: PathBuf,
    terminal_id: String,
    incarnation: String,
}

thread_local! {
    /// The terminal this thread works for, in a shared host
    /// (`unix/shared_host.rs`), whose panic hook writes only that
    /// terminal's sidecar.
    static THREAD_TERMINAL: std::cell::RefCell<Option<Arc<CrashTarget>>> =
        const { std::cell::RefCell::new(None) };
}

/// Install the crash hook for this host process (once its terminal is known).
pub(crate) fn install(path: PathBuf, terminal_id: &str, incarnation: &str) {
    let target = Arc::new(CrashTarget {
        path,
        terminal_id: terminal_id.to_string(),
        incarnation: incarnation.to_string(),
    });
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        write_sidecar(&target, info);
        previous(info);
    }));
    #[cfg(debug_assertions)]
    abort_once_for_test();
}

/// Install the shared host's crash hook (once): a panic writes the sidecar
/// of the terminal its thread works for ([`enter_terminal`]); a panic on a
/// thread that serves no terminal writes none.
pub(crate) fn install_shared() {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        if let Some(target) = THREAD_TERMINAL.with(|current| current.borrow().clone()) {
            write_sidecar(&target, info);
        }
        previous(info);
    }));
}

/// Name the terminal the calling thread (and every host thread it starts
/// through [`spawn`]) works for, in a shared host.
pub(crate) fn enter_terminal(path: PathBuf, terminal_id: &str, incarnation: &str) {
    let target = Arc::new(CrashTarget {
        path,
        terminal_id: terminal_id.to_string(),
        incarnation: incarnation.to_string(),
    });
    THREAD_TERMINAL.with(|current| *current.borrow_mut() = Some(target));
    #[cfg(debug_assertions)]
    abort_once_for_test();
}

/// Start a named host thread that works for the same terminal as the
/// calling thread, so a shared host attributes its panic.
pub(crate) fn spawn<T: Send + 'static>(
    name: &str,
    body: impl FnOnce() -> T + Send + 'static,
) -> std::io::Result<std::thread::JoinHandle<T>> {
    let target = THREAD_TERMINAL.with(|current| current.borrow().clone());
    std::thread::Builder::new().name(name.into()).spawn(move || {
        if target.is_some() {
            THREAD_TERMINAL.with(|current| *current.borrow_mut() = target);
        }
        body()
    })
}

/// `body` running with the calling thread's terminal attribution, on
/// whichever thread runs it (a shared host's pool worker).
pub(crate) fn attribute<R>(
    mut body: impl FnMut() -> R + Send + 'static,
) -> impl FnMut() -> R + Send + 'static {
    let target = THREAD_TERMINAL.with(|current| current.borrow().clone());
    move || {
        // Restored also when `body` panics (a pool worker runs other
        // terminals' jobs next).
        struct Restore(Option<Arc<CrashTarget>>);
        impl Drop for Restore {
            fn drop(&mut self) {
                let previous = self.0.take();
                THREAD_TERMINAL.with(|current| *current.borrow_mut() = previous);
            }
        }
        let _restore = Restore(THREAD_TERMINAL.with(|current| current.replace(target.clone())));
        body()
    }
}

/// Forget the calling thread's terminal (a pool worker between jobs).
pub(crate) fn clear_thread_terminal() {
    THREAD_TERMINAL.with(|current| current.borrow_mut().take());
}

/// Run `body` once, off the calling thread: a job of a shared host's pool,
/// else a named thread of its own.
pub(crate) fn run_task(name: &str, body: impl FnOnce() + Send + 'static) -> std::io::Result<()> {
    #[cfg(unix)]
    if let Some(executor) = super::super::unix::shared_exec::executor() {
        let mut body = Some(body);
        let task = attribute(move || {
            if let Some(body) = body.take() {
                body();
            }
        });
        executor.submit(task);
        return Ok(());
    }
    spawn(name, body).map(drop)
}

fn write_sidecar(target: &CrashTarget, info: &std::panic::PanicHookInfo<'_>) {
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
        "terminal_id": target.terminal_id,
        "incarnation": target.incarnation,
        "message": message,
        "location": location,
        "thread": std::thread::current().name().unwrap_or("unnamed"),
        "host_pid": std::process::id(),
        "at_ms": at_ms,
        "backtrace": backtrace,
    });
    // Concurrent panics each write their own file and rename it over the
    // sidecar, so the sidecar is always one whole record.
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let temporary = target.path.with_extension(format!(
        "crash.tmp-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    if let Ok(mut file) = sys::open_private(&temporary, PrivateOpen::CreateNewNoFollow) {
        if file.write_all(record.to_string().as_bytes()).is_ok() {
            let _ = std::fs::rename(&temporary, &target.path);
        } else {
            let _ = std::fs::remove_file(&temporary);
        }
    }
}

#[cfg(debug_assertions)]
fn abort_once_for_test() {
    use std::fs::OpenOptions;

    let Some(marker) = std::env::var_os(ABORT_ONCE_TEST_ENV) else { return };
    if OpenOptions::new().write(true).create_new(true).open(&marker).is_err() {
        return;
    }
    let mut trigger = marker;
    trigger.push(".trigger");
    let _ = spawn("terminal-host-test-crash", move || {
        // Opening a FIFO for reading blocks until the test opens it for
        // writing: the crash happens at the moment the test chose.
        let _ = std::fs::File::open(&trigger);
        // crash-allow: a test-only injected crash (debug builds, explicit env).
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
    });
}
