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
//! telemetry choice. The line format and hook live in `cmux-panic-log`,
//! which the acpmux daemon uses too.
//!
//! A terminal host's panic goes to the same log: the host writes a `.crash`
//! sidecar, and the owner appends it as one line with `"source":
//! "cmux-tui-host"` before it removes the sidecar ([`host_panic_log`],
//! cmux-tui-core `host_crash.rs`).
//!
//! The owner's hang log (cmux-panic-log `hang`) is beside it,
//! `owner-hangs-<session>.jsonl` with the same fields: the request watchdog
//! writes one line per watched scope (a request, a journal commit, a
//! holder-link frame) busy past its hang tier, with the method and the
//! hung thread's stack.

/// Debug builds only: `thread` makes a worker thread panic once the hook is
/// installed (tests/owner_panic.rs). Its line carries `"test": true`.
#[cfg(debug_assertions)]
const TEST_PANIC_ENV: &str = "CMUX_TUI_TEST_OWNER_PANIC";
#[cfg(debug_assertions)]
const TEST_PANIC_THREAD: &str = "owner-panic-test";

/// The log for `session` (the rule lives in core, so `oracle-state` reports
/// the same path).
pub(super) use cmux_tui_core::diagnostics::owner_panic_log_path as log_path;

/// Install the owner's panic hook and hang log. Call once, in the headless
/// owner only, before its mux is built (the mux watches holder links only
/// in a process with a hang log).
pub(super) fn install(session: &str) {
    if let Some(path) = log_path(session) {
        cmux_panic_log::install(path, fields(session), is_test_thread);
    }
    install_hang_log(session);
    #[cfg(debug_assertions)]
    panic_for_test();
}

/// The owner's supervisor. A headless owner (`session`) records a fatal
/// worker failure in its panic log; either kind then exits through
/// `client_log::exit`, which drains the client log first.
pub(super) fn supervisor(session: Option<&str>) -> cmux_panic_log::Supervisor {
    let (log, fields) = match session {
        Some(session) => (log_path(session), fields(session)),
        None => (None, cmux_panic_log::Fields::new()),
    };
    let sink = cmux_panic_log::ExitProcess::new(log, fields, exit_supervised);
    cmux_panic_log::Supervisor::new(std::sync::Arc::new(sink))
}

fn exit_supervised(code: i32) {
    crate::client_log::exit(code)
}

/// Where the owner of `session` appends its terminal hosts' panics: its own
/// panic log, with the owner's fields (the host runs the same build).
pub(super) fn host_panic_log(
    session: &str,
) -> Option<cmux_tui_core::terminal_host_runtime::HostPanicLog> {
    Some(cmux_tui_core::terminal_host_runtime::HostPanicLog {
        path: log_path(session)?,
        fields: fields(session),
    })
}

/// Every line's fields: the session and the build that wrote it.
fn fields(session: &str) -> cmux_panic_log::Fields {
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("session".into(), session.into());
    fields.insert("owner_pid".into(), std::process::id().into());
    // The release and build a tester runs, so crash reports group by
    // release and platform (plans/cmux-next/tui-tester-rollout.md).
    fields.insert("version".into(), crate::version_report::DISTRIBUTION_VERSION.into());
    fields.insert("build_identity".into(), build_identity().into());
    fields.insert("os".into(), std::env::consts::OS.into());
    fields.insert("arch".into(), std::env::consts::ARCH.into());
    fields
}

/// Make the owner's hang log the process's: the request watchdog writes
/// each hung scope there.
fn install_hang_log(session: &str) {
    use cmux_panic_log::hang;
    let Some(path) = cmux_tui_core::diagnostics::owner_hang_log_path(session) else { return };
    // A second install keeps the first log (one per process).
    let _ = hang::install(hang::file_sink(path, fields(session)));
}

/// Debug builds only: with `CMUX_TUI_TEST_OWNER_PANIC=hang`, block a thread
/// in a watched scope once the owner's mux exists, so one line reaches the
/// hang log (tests/owner_panic.rs).
#[cfg(debug_assertions)]
pub(super) fn hang_for_test() {
    if std::env::var(TEST_PANIC_ENV).as_deref() == Ok("hang") {
        cmux_tui_core::diagnostics::spawn_owner_hang_test();
    }
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
    reason = "debug builds only: the owner panic-log test asks for this panic through its environment variable"
)]
fn panic_for_test() {
    if std::env::var(TEST_PANIC_ENV).as_deref() != Ok("thread") {
        return;
    }
    // supervise-allow: debug-only test trigger; the test asks for exactly this thread's panic line.
    let _ = cmux_threads::spawn(TEST_PANIC_THREAD, cmux_threads::ThreadQos::Utility, || {
        panic!("cmux-tui test owner panic")
    });
}

#[cfg(unix)]
fn build_identity() -> Option<&'static str> {
    Some(cmux_build_identity::BUILD_IDENTITY)
}

#[cfg(not(unix))]
fn build_identity() -> Option<&'static str> {
    None
}
