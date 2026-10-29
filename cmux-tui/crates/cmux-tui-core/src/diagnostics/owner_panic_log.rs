//! Where the session owner's panic log lives (cx-urd.59). The owner's panic
//! hook appends to it (cmux-tui `owner_start/owner_panic.rs`), which reads
//! the one path rule here. The
//! owner's hang log lives beside it; the request watchdog writes it
//! (server/request_watchdog.rs).

use std::path::PathBuf;

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

/// The panic logs of the processes the owner's machine runs besides the
/// owner, one per process kind at the state root beside the owner's log.
/// Each line carries its writer's `pid`. The cmux-next app reads each one
/// (`RustDiagnosticsLog.all`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HelperPanicLog {
    /// `cmux-app-host`; the supervisor passes the path (`--panic-log`),
    /// since the host starts with an empty environment and opens it
    /// before its sandbox holds.
    AppHost,
    /// `cmux-browser-host serve`, started by the daemon (`--panic-log`).
    BrowserHost,
    /// `cmux mcp serve`, started by an MCP client.
    McpServe,
}

impl HelperPanicLog {
    /// The log's file name at the state root.
    pub const fn file_name(self) -> &'static str {
        match self {
            Self::AppHost => "app-host-panics.jsonl",
            Self::BrowserHost => "browser-host-panics.jsonl",
            Self::McpServe => "mcp-panics.jsonl",
        }
    }

    /// The log's path, or `None` with no state directory.
    pub fn path(self) -> Option<PathBuf> {
        Some(owner_log_dir()?.join(self.file_name()))
    }
}

/// The directory of the owner's logs: the state root (the parent of the
/// sessions directory). The owner's release hang watch writes its
/// `hangs-<pid>.jsonl` here too (cmux-hang-watch `init`).
pub fn owner_log_dir() -> Option<PathBuf> {
    let sessions = crate::platform::workspace_state_dir()?;
    Some(sessions.parent().map(PathBuf::from).unwrap_or(sessions))
}

fn owner_log_path(prefix: &str, session: &str) -> Option<PathBuf> {
    let root = owner_log_dir()?;
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

#[cfg(test)]
mod tests {
    /// The hang watch's `hangs-<pid>.jsonl` goes beside the panic and hang
    /// logs: one directory holds every owner log.
    #[test]
    fn owner_logs_share_the_owner_log_dir() {
        let Some(dir) = super::owner_log_dir() else { return };
        for log in [super::owner_panic_log_path("main"), super::owner_hang_log_path("main")] {
            assert_eq!(log.as_deref().and_then(std::path::Path::parent), Some(dir.as_path()));
        }
    }
}
