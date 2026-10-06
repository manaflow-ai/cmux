//! The headless owner loop: it blocks until a termination signal, a daemon
//! shutdown request or the end of the remote runtime wakes it, and records
//! the session shutdown start from the signal thread (`session-shutdown`).

use super::*;

pub(crate) fn run_headless<F>(
    mux: &Arc<Mux>,
    socket_path: &Path,
    remote_runtime_finished: F,
) -> anyhow::Result<()>
where
    F: Fn() -> bool,
{
    crate::client_log::stderr_log!(
        "startup",
        "{BIN}: headless, control socket at {}",
        socket_path.display()
    );
    // The daemon is ready: apps with an `always` server start off this path.
    #[cfg(unix)]
    cmux_tui_core::server::start_apps_when_ready(mux);
    // Keep the process alive; the control socket drives everything and
    // the mux reaps exited surfaces itself. The loop blocks until a signal,
    // a daemon shutdown request or the end of the remote runtime wakes it;
    // it used to wake every 250 ms (and on every terminal output event) to
    // re-check these flags.
    mux.set_daemon_shutdown_waker(wake_headless);
    #[cfg(unix)]
    {
        // Peek, not read: other shutdown waiters (remote runtime, browser
        // proxy) consume the same wake byte. Record the session shutdown
        // start here, before the loop wakes and teardown begins, so a
        // shell that dies of the same logout signal is a host loss
        // (`session-shutdown`).
        let signalled = Arc::downgrade(mux);
        let _ = std::thread::Builder::new().name("headless-signal-wait".into()).spawn(move || {
            wait_for_shutdown_signal_peek();
            if shutdown_requested()
                && let Some(mux) = signalled.upgrade()
            {
                mux.begin_session_shutdown();
            }
            wake_headless();
        });
    }
    let (lock, wake) = &HEADLESS_WAKE;
    let mut generation = lock.lock().unwrap();
    while !(shutdown_requested() || mux.daemon_shutdown_requested() || remote_runtime_finished()) {
        generation = wake.wait(generation).unwrap();
    }
    Ok(())
}

/// Wakes `run_headless`. Callers set their flag first; the wait re-checks
/// every flag under this lock, so no wake is lost.
static HEADLESS_WAKE: (std::sync::Mutex<u64>, std::sync::Condvar) =
    (std::sync::Mutex::new(0), std::sync::Condvar::new());

pub(crate) fn wake_headless() {
    let (lock, wake) = &HEADLESS_WAKE;
    let mut generation = lock.lock().unwrap();
    *generation = generation.wrapping_add(1);
    wake.notify_all();
}
