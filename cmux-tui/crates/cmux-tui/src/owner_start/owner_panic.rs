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

use std::path::PathBuf;

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
    if let Some(path) = log_path(session) {
        let mut fields = cmux_panic_log::Fields::new();
        fields.insert("session".into(), session.into());
        fields.insert("owner_pid".into(), std::process::id().into());
        // The release and build a tester runs, so crash reports group by
        // release and platform (plans/cmux-next/tui-tester-rollout.md).
        fields.insert("version".into(), crate::version_report::DISTRIBUTION_VERSION.into());
        fields.insert("build_identity".into(), build_identity().into());
        fields.insert("os".into(), std::env::consts::OS.into());
        fields.insert("arch".into(), std::env::consts::ARCH.into());
        cmux_panic_log::install(path, fields, is_test_thread);
    }
    #[cfg(debug_assertions)]
    panic_for_test();
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
fn panic_for_test() {
    if std::env::var(TEST_PANIC_ENV).as_deref() != Ok("thread") {
        return;
    }
    let _ = std::thread::Builder::new()
        .name(TEST_PANIC_THREAD.into())
        // crash-allow: debug-only test trigger for the owner panic log
        .spawn(|| panic!("cmux-tui test owner panic"));
}

#[cfg(unix)]
fn build_identity() -> Option<&'static str> {
    Some(cmux_build_identity::BUILD_IDENTITY)
}

#[cfg(not(unix))]
fn build_identity() -> Option<&'static str> {
    None
}
