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

/// Debug builds only: panic a worker thread when the test asks for it, or
/// end the owner by a fatal path that no panic hook sees (`abort`,
/// `stack_overflow`, `oom`) once the test opens the FIFO named by
/// `CMUX_TUI_TEST_OWNER_FATAL_TRIGGER` for writing
/// (tests/terminal_host_recovery/owner_fatal.rs).
#[cfg(debug_assertions)]
fn panic_for_test() {
    let Ok(kind) = std::env::var(TEST_PANIC_ENV) else { return };
    if kind == "thread" {
        let _ = std::thread::Builder::new()
            .name(TEST_PANIC_THREAD.into())
            // crash-allow: debug-only test trigger for the owner panic log
            .spawn(|| panic!("cmux-tui test owner panic"));
        return;
    }
    let Some(trigger) = std::env::var_os("CMUX_TUI_TEST_OWNER_FATAL_TRIGGER") else { return };
    let _ = std::thread::Builder::new().name("owner-fatal-test".into()).spawn(move || {
        // Opening a FIFO for reading blocks until the test opens it for
        // writing: the test decides the moment (after its terminals run).
        let _ = std::fs::File::open(&trigger);
        fatal_for_test(&kind);
    });
}

/// The fatal paths a release owner can still take: each ends the process at
/// once with SIGABRT, and no hook, destructor or supervisor runs.
#[cfg(debug_assertions)]
fn fatal_for_test(kind: &str) {
    #[cfg(unix)]
    // SAFETY: setrlimit with a valid rlimit that outlives the call; no core
    // file, so the abort ends the owner at once on a loaded build host.
    unsafe {
        let limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
        libc::setrlimit(libc::RLIMIT_CORE, &limit);
    }
    match kind {
        // crash-allow: debug-only test trigger for the owner's fatal paths
        "abort" => std::process::abort(),
        "stack_overflow" => {
            // Rust's guard page handler prints "has overflowed its stack" and aborts.
            #[allow(unconditional_recursion, reason = "the test overflows the stack on purpose")]
            fn recurse(depth: u64) -> u64 {
                let frame = std::hint::black_box([depth; 64]);
                recurse(depth + 1).wrapping_add(frame[0])
            }
            std::hint::black_box(recurse(0));
        }
        "oom" => {
            // An allocation no allocator can give (and no overcommit lends):
            // `handle_alloc_error` aborts ("memory allocation of N bytes
            // failed"), as a real OOM does.
            let bytes = std::hint::black_box(isize::MAX as usize);
            let buffer = Vec::<u8>::with_capacity(bytes);
            std::hint::black_box(buffer);
        }
        _ => {}
    }
}

#[cfg(unix)]
fn build_identity() -> Option<&'static str> {
    Some(cmux_build_identity::BUILD_IDENTITY)
}

#[cfg(not(unix))]
fn build_identity() -> Option<&'static str> {
    None
}
