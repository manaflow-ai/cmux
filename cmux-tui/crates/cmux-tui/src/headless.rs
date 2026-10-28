//! The headless owner loop: it blocks until a termination signal, a daemon
//! shutdown request or the end of the remote runtime wakes it, and records
//! the session shutdown start from the signal thread (`session-shutdown`).

use super::*;

#[cfg(unix)]
mod chief_owner_exit;
#[cfg(unix)]
mod dev_orphan_exit;
#[cfg(unix)]
#[path = "server_lifecycle.rs"]
mod server_lifecycle;

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
    // The brains of the Chiefs that are not the default, when the app asked
    // for them (CMUX_TUI_CHIEF_BRAINS); they end with this owner.
    let chief_brains = cmux_tui_core::chief_brains::start(mux, socket_path);
    // Keep the process alive; the control socket drives everything and
    // the mux reaps exited surfaces itself. The loop blocks until a signal,
    // a daemon shutdown request or the end of the remote runtime wakes it;
    // it used to wake every 250 ms (and on every terminal output event) to
    // re-check these flags.
    mux.set_daemon_shutdown_waker(wake_headless);
    #[cfg(unix)]
    let signal_wait = {
        // Peek, not read: other shutdown waiters (remote runtime, browser
        // proxy) consume the same wake byte. Record the session shutdown
        // start here, before the loop wakes and teardown begins, so a
        // shell that dies of the same logout signal is a host loss
        // (`session-shutdown`).
        let signalled = Arc::downgrade(mux);
        std::thread::Builder::new()
            .name("headless-signal-wait".into())
            .spawn(move || {
                wait_for_shutdown_signal_peek();
                if shutdown_requested()
                    && let Some(mux) = signalled.upgrade()
                {
                    mux.begin_session_shutdown();
                    // Name who stopped this owner (cx-0tgl LA).
                    if let Some((signal, sender, uid)) = signal_sender::shutdown_signal() {
                        mux.record_daemon_signal(signal, sender, uid);
                    }
                }
                wake_headless();
            })
            .ok()
    };
    #[cfg(not(unix))]
    let signal_wait: Option<std::thread::JoinHandle<()>> = None;
    // DEV builds only: stop an orphaned app owner; its terminals keep
    // running (dev_orphan_exit.rs).
    #[cfg(unix)]
    let orphan_exit = dev_orphan_exit::start_for_owner(mux);
    // Any owner, with leftoverDaemonIdleExit on (server_lifecycle.rs).
    #[cfg(unix)]
    let idle_exit = server_lifecycle::start_for_owner(mux, chief_brains.is_some());
    // A Chief owner an app started stops soon after that app exits, when
    // nothing needs it (chief_owner_exit.rs).
    #[cfg(unix)]
    let chief_owner_exit = chief_owner_exit::start_for_owner(
        mux,
        chief_brains.as_ref().map_or_else(Arc::default, |brains| brains.live()),
    );
    wait_for_stop(|| {
        shutdown_requested() || mux.daemon_shutdown_requested() || remote_runtime_finished()
    });
    // Another waiter (the remote runtime) can wake the loop on the same
    // signal before the signal thread has recorded the shutdown start and
    // the sender; teardown and exit then raced that record and left a cut
    // `daemon_signal` line. A signal stop waits for the record (the thread
    // returns once the signal is seen); any other stop leaves the thread
    // parked on the wake descriptor.
    if shutdown_requested()
        && let Some(signal_wait) = signal_wait
    {
        let _ = blocking::thread::join(signal_wait);
    }
    if let Some(chief_brains) = chief_brains {
        chief_brains.stop();
    }
    #[cfg(unix)]
    if let Some(orphan_exit) = orphan_exit {
        orphan_exit.stop();
    }
    #[cfg(unix)]
    if let Some(idle_exit) = idle_exit {
        idle_exit.stop();
    }
    #[cfg(unix)]
    if let Some(chief_owner_exit) = chief_owner_exit {
        chief_owner_exit.stop();
    }
    Ok(())
}

/// The WebSocket token: `--ws-token`, else `server.ws_token`. A headless
/// daemon with a WebSocket listener needs one (fail closed): it has no TUI
/// to approve a pairing on its own (cx-ehrq). On a loopback listener with no
/// configured token it mints one (`minted` true) that the caller writes to
/// the 0600 credential file next to the socket (`websocket_credential`),
/// so a same-user host (the app) reads it and nothing puts it on argv
/// (cx-hnmbt.2). A wider bind still needs a configured token.
pub(crate) fn ws_token(
    args: &Args,
    ws_addr: &Option<String>,
    configured: &Option<String>,
) -> anyhow::Result<WsToken> {
    let token = args.ws_token.clone().or_else(|| configured.clone());
    let token = token.filter(|token| !token.trim().is_empty());
    if !args.headless || token.is_some() {
        return Ok(WsToken { token, minted: false });
    }
    let Some(addr) = ws_addr else { return Ok(WsToken { token: None, minted: false }) };
    let loopback =
        addr.parse::<std::net::SocketAddr>().is_ok_and(|address| address.ip().is_loopback());
    if !loopback {
        anyhow::bail!(
            "--headless --ws on a non-loopback address needs --ws-token (or server.ws_token): a headless daemon has no TUI to approve a pairing"
        );
    }
    Ok(WsToken { token: Some(websocket_credential::mint_token()?), minted: true })
}

/// The WebSocket token a daemon starts with, and whether it minted it.
pub(crate) struct WsToken {
    pub token: Option<String>,
    pub minted: bool,
}

/// Stops the listeners and the mux of a served session, then releases the
/// socket.
#[cfg(unix)]
pub(crate) fn finish_server_shutdown<W, R>(
    websocket_server: Option<W>,
    mux: &Arc<Mux>,
    socket_path: &Path,
    remote_shutdown: anyhow::Result<Option<R>>,
    result: anyhow::Result<()>,
) -> anyhow::Result<()> {
    drop(websocket_server);
    mux.shutdown();
    mux.release_ownership(socket_path);
    remote_shutdown.map(|_| ())?;
    result
}

/// Blocks the owner's main thread until `stopped`, re-checked on every
/// [`wake_headless`]. The thread waits as the `main` registry row at
/// UserInitiated (`owner_start::register_main_thread`): every worker it
/// starts runs by now, so none inherits that class.
fn wait_for_stop(stopped: impl Fn() -> bool) {
    owner_start::register_main_thread();
    let (lock, wake) = &HEADLESS_WAKE;
    let mut generation = lock.lock().unwrap();
    while !stopped() {
        generation = wake.wait(generation).unwrap();
    }
}

/// Wakes `run_headless`. Callers set their flag first; the wait re-checks
/// every flag under this lock, so no wake is lost.
static HEADLESS_WAKE: (std::sync::Mutex<u64>, cmux_threads::sync::Condvar) =
    (std::sync::Mutex::new(0), cmux_threads::sync::Condvar::new());

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

    /// p02-threads-207: the headless owner's main thread waits as the
    /// `main` row at UserInitiated, and a thread it starts during setup
    /// (`owner_start::prepare`, then the mux workers) does not run at that
    /// class. On Linux the class is nice 0, which a thread started at a
    /// higher nice value (a `nice cargo test`) may not take back.
    #[test]
    fn the_owner_main_thread_waits_at_user_initiated_and_its_workers_do_not() {
        use cmux_threads::{LiveQos, ThreadQos};
        std::thread::spawn(|| {
            let before = cmux_threads::current();
            super::super::owner_start::prepare(&args(&[])).unwrap();
            let worker = std::thread::spawn(cmux_threads::current).join().unwrap();
            assert_ne!(worker, LiveQos::Class(ThreadQos::UserInitiated), "setup worker");
            assert!(cmux_threads::snapshot().iter().all(|row| row.name != "main"));
            let seen = std::cell::RefCell::new(None);
            super::wait_for_stop(|| {
                *seen.borrow_mut() =
                    cmux_threads::snapshot().into_iter().find(|row| row.name == "main");
                true
            });
            let row = seen.into_inner().expect("a main row while the owner waits");
            assert_eq!(row.declared, ThreadQos::UserInitiated);
            if cfg!(target_vendor = "apple") || before == LiveQos::Nice(0) {
                assert_eq!(row.effective, Some(ThreadQos::UserInitiated));
            }
            #[cfg(target_vendor = "apple")]
            assert_eq!(row.live, LiveQos::Class(ThreadQos::UserInitiated));
            let slot = cmux_threads::current_slot().expect("the waiting thread is the row");
            assert_eq!(slot.name(), "main");
        })
        .join()
        .unwrap();
        assert!(
            cmux_threads::snapshot().iter().all(|row| row.name != "main"),
            "the row leaves with its thread"
        );
    }

    #[test]
    fn a_headless_websocket_listener_needs_a_token() {
        let token = |args: &crate::Args, ws: &Option<String>, configured: &Option<String>| {
            super::ws_token(args, ws, configured).map(|value| value.token)
        };
        let ws = Some("127.0.0.1:0".to_string());
        let wide = Some("0.0.0.0:0".to_string());
        let headless = args(&["--headless", "--ws", "127.0.0.1:0"]);
        assert!(token(&headless, &wide, &None).is_err());
        assert!(token(&headless, &wide, &Some(" ".into())).is_err());
        // A loopback listener mints its own credential (cx-hnmbt.2).
        let minted = super::ws_token(&headless, &ws, &None).unwrap();
        assert!(minted.minted && minted.token.is_some_and(|value| value.len() == 64));
        assert_eq!(token(&headless, &ws, &Some("t".into())).unwrap().as_deref(), Some("t"));
        let flagged = args(&["--headless", "--ws", "127.0.0.1:0", "--ws-token", "f"]);
        assert_eq!(token(&flagged, &ws, &None).unwrap().as_deref(), Some("f"));
        // The TUI that runs the daemon approves pairings itself.
        let interactive = args(&["--ws", "127.0.0.1:0"]);
        assert_eq!(token(&interactive, &ws, &None).unwrap(), None);
        assert_eq!(token(&headless, &None, &None).unwrap(), None);
    }
}
