//! The exact commands a version-skew error names instead of "update the
//! app" (plans/cmux-next/version-skew.md step 4; the lint is
//! scripts/cmux-next/check-capability-text.py).

use std::path::{Path, PathBuf};

/// This CLI's own binary, by absolute path when it can be resolved: the
/// command must run this build, not whichever `cmux` PATH finds first.
pub(super) fn this_cli() -> PathBuf {
    std::env::current_exe()
        .and_then(std::fs::canonicalize)
        .unwrap_or_else(|_| PathBuf::from("cmux"))
}

/// Stops the daemon at `socket` (its terminals survive the handoff).
pub(super) fn stop_daemon(cli: &Path, socket: &Path) -> String {
    format!("{} daemon stop --socket {}", quote(cli), quote(socket))
}

/// Stops the daemon at `socket` and starts it again with `cli`'s build.
pub(super) fn restart_daemon(cli: &Path, socket: &Path) -> String {
    format!(
        "{} && {} daemon ensure --socket {}",
        stop_daemon(cli, socket),
        quote(cli),
        quote(socket)
    )
}

/// [`restart_daemon`] for the daemon this CLI's environment routes to,
/// where the caller does not know the socket.
pub(super) fn restart_routed_daemon(cli: &Path) -> String {
    format!("{} daemon stop && {} daemon ensure", quote(cli), quote(cli))
}

fn quote(path: &Path) -> String {
    format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
}
