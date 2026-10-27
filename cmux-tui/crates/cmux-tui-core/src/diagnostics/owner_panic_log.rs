//! Where the session owner's panic log lives (cx-urd.59). The owner's panic
//! hook appends to it (cmux-tui `owner_start/owner_panic.rs`) and
//! `oracle-state` reports it, so both read the one path rule here. The
//! owner's hang log lives beside it; the request watchdog writes it
//! (server/request_watchdog.rs).

use std::path::{Path, PathBuf};

/// The log for `session`: `owner-panics-<session>.jsonl` at the state root
/// (the parent of the sessions directory). A session name that needs
/// escaping gets a hash suffix, so two names never share a log.
pub fn owner_panic_log_path(session: &str) -> Option<PathBuf> {
    owner_log_path("owner-panics", session)
}

/// The hang log for `session`: `owner-hangs-<session>.jsonl` beside the
/// panic log. The owner's hang watcher (cmux-panic-log `hang`) appends one
/// line per scope busy past its hang tier.
pub fn owner_hang_log_path(session: &str) -> Option<PathBuf> {
    owner_log_path("owner-hangs", session)
}

/// The panic log of the terminal holder of `host_root`, a session's
/// `terminal_host_root`: `holder-panics.jsonl` in it. The daemon names it in
/// the holder's environment (`cmux_holder::panic_log::PANIC_LOG_ENV`); the
/// cmux-next app reads it (`RustPanicSource.holderLog`).
pub fn holder_panic_log_path(host_root: &Path) -> PathBuf {
    host_root.join("holder-panics.jsonl")
}

fn owner_log_path(prefix: &str, session: &str) -> Option<PathBuf> {
    let sessions = crate::platform::workspace_state_dir()?;
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
    Some(root.join(format!("{prefix}-{name}.jsonl")))
}

/// Debug builds only: block a thread in a scope of the process's request
/// watchdog past its 500 ms hang tier, so its hang is written to the hang
/// log (cmux-tui tests/owner_panic.rs).
#[cfg(debug_assertions)]
pub fn spawn_owner_hang_test() {
    crate::server::spawn_owner_hang_test();
}

#[cfg(all(test, unix))]
mod tests {
    /// The app computes the same path (RustLogForwardTests
    /// `theHolderLogIsInTheSessionsTerminalHostRoot`).
    #[test]
    fn the_holder_panic_log_of_session_main_is_where_the_app_reads_it() {
        let root = crate::terminal_host_runtime::terminal_host_root(
            std::path::Path::new("/state/sessions"),
            "main",
        );
        assert_eq!(
            super::holder_panic_log_path(&root),
            std::path::Path::new(
                "/state/sessions/terminal-hosts-1f5962a2ce9803c8/holder-panics.jsonl"
            )
        );
    }
}
