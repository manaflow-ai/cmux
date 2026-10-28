//! Process setup that only the terminal owner (the mux server) needs.

mod background_checks;
mod crash_forward;
mod memory_guard;
mod owner_panic;
pub(crate) mod poll_watch_lab;

/// Debug builds only: the owner's hang log test trigger, once its mux
/// exists (tests/owner_panic.rs).
#[cfg(debug_assertions)]
pub(crate) fn hang_for_test(headless: bool) {
    if headless {
        owner_panic::hang_for_test();
    }
}

/// The QoS of the owner's main thread: it serves requests a person waits
/// on, so UserInitiated (Chromium's kDefault in the `cmux_threads::qos`
/// table), below the UserInteractive echo threads.
const MAIN_THREAD_QOS: cmux_threads::ThreadQos = cmux_threads::ThreadQos::UserInitiated;

/// Lists the calling thread as `main` in the thread registry at
/// [`MAIN_THREAD_QOS`] and sets its QoS, so `cmux_threads::snapshot` (and
/// `server.threads` on it, p02-threads task 203) shows it.
/// Returns false, and changes nothing, when the thread is listed already.
///
/// Call it once the main thread starts no more threads: a macOS thread
/// starts at its creator's class, and the owner's workers (journal
/// maintenance, history search, the panic and memory watchers) run at
/// their own lower classes, not at the main thread's.
pub(crate) fn register_main_thread() -> bool {
    cmux_threads::register_current("main", MAIN_THREAD_QOS)
}

/// The daemon's black box, first: its heap ring takes records at once and
/// a one-shot thread maps its file in the app's trace folder ([`cmux_trace::process_dir`]), which
/// the daemon's hosts share. Then, once per start and never on a timer, a background thread
/// deletes the rings of processes that ended long ago ([`cmux_trace::cleanup`]).
#[cfg(unix)]
fn start_blackbox() {
    let dir = cmux_trace::process_dir();
    drop(cmux_trace::init_blackbox(&dir, cmux_trace::Role::Daemon));
    let cleanup =
        cmux_threads::spawn("trace-cleanup", cmux_threads::ThreadQos::Background, move || {
            cmux_trace::cleanup::run(&dir);
        });
    if let Err(error) = cleanup {
        crate::client_log::stderr_log!(
            "startup",
            "{}: no trace ring cleanup: {error}",
            crate::cli::BIN
        );
    }
}

/// The headless owner's panic log for its terminal hosts' crash sidecars
/// (`SurfaceOptions::host_panic_log`); `None` for any other process.
pub(crate) fn host_panic_log(
    headless: bool,
    session: &str,
) -> Option<cmux_tui_core::terminal_host_runtime::HostPanicLog> {
    headless.then(|| owner_panic::host_panic_log(session)).flatten()
}

/// Starts the server process's release hang watch (cmux-hang-watch,
/// Chrome's `base::HangWatcher`): `hangs-<pid>.jsonl` at the state root,
/// beside the owner's panic and hang logs. Call it before the mux exists
/// and before any listener starts: a daemon thread (mux-conn, the journal
/// writer, terminal work) that registers before it is never watched.
fn start_hang_watch() {
    let Some(dir) = cmux_tui_core::diagnostics::owner_log_dir() else { return };
    if let Err(error) = cmux_hang_watch::init(&dir) {
        crate::client_log::stderr_log!("startup", "{}: {error}", crate::cli::BIN);
    }
}

/// The server process's setup before its mux: the hang watch first, then
/// [`prepare`], whose supervisor it returns.
pub(crate) fn start_server_process(
    args: &crate::Args,
) -> anyhow::Result<cmux_panic_log::Supervisor> {
    start_hang_watch();
    prepare(args)
}

/// Validate the owner's storage flags and raise its open-file soft limit.
///
/// The owner holds descriptors for every terminal, and the default soft
/// limit (256 on macOS) stopped it at about 60 terminals. Terminal hosts and
/// the programs in terminals get the original limit back at spawn.
///
/// The headless owner also records every panic (`owner_panic`, cx-urd.59)
/// and sends the ones not sent yet to Sentry (`crash_forward`), and watches
/// its own memory (`memory_guard`), and fetches the signed invite-wave flags
/// and the daily update answer (`background_checks`).
///
/// Returns the process's [`cmux_panic_log::Supervisor`]: a fatal worker
/// failure records a `supervised_exit` line in the owner's panic log and
/// exits, so whoever started the owner starts it again.
pub(crate) fn prepare(args: &crate::Args) -> anyhow::Result<cmux_panic_log::Supervisor> {
    let supervisor = owner_panic::supervisor(args.headless.then_some(args.session.as_str()));
    if args.headless {
        #[cfg(unix)]
        start_blackbox();
        owner_panic::install(&args.session);
        #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
        poll_watch_lab::install(&args.session);
        // Earlier panics and memory alerts not sent yet (tester rollout #7),
        // then the memory guard (#9), which sends its alerts as they happen.
        let panic_log = owner_panic::log_path(&args.session);
        let logs = panic_log
            .iter()
            .flat_map(|log| [log.clone(), memory_guard::memory_log_path(log)])
            .collect();
        let forwarder = crash_forward::start(logs);
        memory_guard::spawn(&supervisor, panic_log, forwarder);
        background_checks::spawn();
    }
    if args.ephemeral && args.state.is_some() {
        anyhow::bail!("--ephemeral and --state are mutually exclusive");
    }
    #[cfg(unix)]
    if let Err(error) = cmux_tui_core::raise_open_file_limit(cmux_tui_core::OPEN_FILE_LIMIT_CEILING)
    {
        crate::client_log::stderr_log!(
            "startup",
            "{}: cannot raise the open-file limit: {error}",
            crate::cli::BIN
        );
    }
    Ok(supervisor)
}

/// The owner's loop ended with `result`: stop its supervised workers before
/// the mux they serve goes away (none restarts, Skip workers are asked to
/// stop, Block workers are waited for). When the signal thread failed, the
/// supervisor's fatal sink is ending the process: wait for that exit instead
/// of racing it with teardown and a second exit.
pub(crate) fn stop_supervised(
    supervisor: &cmux_panic_log::Supervisor,
    result: &anyhow::Result<()>,
) {
    if let Err(error) = result
        && error.downcast_ref::<crate::headless::SignalRecordFailed>().is_some()
    {
        await_supervised_exit();
    }
    let report = supervisor.shutdown();
    if !report.late.is_empty() {
        crate::client_log::stderr_log!(
            "shutdown",
            "{}: supervised workers still running at their deadline: {}",
            crate::cli::BIN,
            report.late.join(", ")
        );
    }
}

/// The owner's [`owner_panic::supervisor`] sink (`ExitProcess`) never
/// returns: it records the failure and exits. The caller parks until then.
fn await_supervised_exit() -> ! {
    loop {
        std::thread::park();
    }
}
