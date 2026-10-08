//! The headless owner loop: it blocks until a termination signal, a daemon
//! shutdown request or the end of the remote runtime wakes it, and records
//! the session shutdown start from the signal thread (`session-shutdown`).

use super::*;

#[cfg(unix)]
mod dev_orphan_exit;

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
    // DEV builds only: stop an orphaned app owner; its terminals keep
    // running (dev_orphan_exit.rs).
    #[cfg(unix)]
    let orphan_exit = dev_orphan_exit::start_for_owner(mux);
    let (lock, wake) = &HEADLESS_WAKE;
    let mut generation = lock.lock().unwrap();
    while !(shutdown_requested() || mux.daemon_shutdown_requested() || remote_runtime_finished()) {
        generation = wake.wait(generation).unwrap();
    }
    drop(generation);
    #[cfg(unix)]
    if let Some(orphan_exit) = orphan_exit {
        orphan_exit.stop();
    }
    Ok(())
}

/// The WebSocket token: `--ws-token`, else `server.ws_token`. A headless
/// daemon with a WebSocket listener needs one (fail closed): it has no TUI
/// to approve a pairing, and only a human surface may approve one (cx-ehrq).
pub(crate) fn ws_token(
    args: &Args,
    ws_addr: &Option<String>,
    configured: &Option<String>,
) -> anyhow::Result<Option<String>> {
    let token = args.ws_token.clone().or_else(|| configured.clone());
    let token = token.filter(|token| !token.trim().is_empty());
    if args.headless && ws_addr.is_some() && token.is_none() {
        anyhow::bail!(
            "--headless --ws needs --ws-token (or server.ws_token): a headless daemon has no TUI to approve a pairing"
        );
    }
    Ok(token)
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

#[cfg(test)]
mod tests {
    fn args(argv: &[&str]) -> crate::Args {
        crate::parse_args(argv.iter().map(|arg| (*arg).to_string()))
    }

    #[test]
    fn a_headless_websocket_listener_needs_a_token() {
        let ws = Some("127.0.0.1:0".to_string());
        let headless = args(&["--headless", "--ws", "127.0.0.1:0"]);
        assert!(super::ws_token(&headless, &ws, &None).is_err());
        assert!(super::ws_token(&headless, &ws, &Some(" ".into())).is_err());
        assert_eq!(super::ws_token(&headless, &ws, &Some("t".into())).unwrap().as_deref(), Some("t"));
        let flagged = args(&["--headless", "--ws", "127.0.0.1:0", "--ws-token", "f"]);
        assert_eq!(super::ws_token(&flagged, &ws, &None).unwrap().as_deref(), Some("f"));
        // The TUI that runs the daemon approves pairings itself.
        let interactive = args(&["--ws", "127.0.0.1:0"]);
        assert_eq!(super::ws_token(&interactive, &ws, &None).unwrap(), None);
        assert_eq!(super::ws_token(&headless, &None, &None).unwrap(), None);
    }
}
