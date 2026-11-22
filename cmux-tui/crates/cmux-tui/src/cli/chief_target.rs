//! Where a Chief's `cmux` call goes: one rule with the brain host's turn
//! env (schemas/chief-cmux-target/vectors.json, optchat-chief cmux_env.rs).
//!
//! The brain host names the app's control socket (`CMUX_SOCKET_PATH`), the
//! app's daemon (`CMUX_APP_DAEMON_SOCKET`, both links that the app makes in
//! the Chief home) and the Chief's own owner daemon
//! (`CMUX_CHIEF_OWNER_SOCKET`). While the app's control socket and daemon
//! exist, daemon commands go to the app's daemon, where the user sees them.
//! Else (`cmux chief` without the app, or the app quit) they go to the owner
//! daemon. App commands go to the app's control socket and say that they
//! need the app when it does not exist (app.rs `connect`). E17.

use std::path::{Path, PathBuf};

pub(super) const APP_CONTROL_KEY: &str = "CMUX_SOCKET_PATH";
pub(super) const APP_DAEMON_KEY: &str = "CMUX_APP_DAEMON_SOCKET";
pub(super) const OWNER_KEY: &str = "CMUX_CHIEF_OWNER_SOCKET";

/// The daemon of a Chief's `cmux` call; `None` outside a Chief's env (no
/// owner daemon named), where the usual resolution applies.
pub(super) fn daemon_socket(
    env: impl Fn(&str) -> Option<String>,
    is_socket: impl Fn(&Path) -> bool,
) -> Option<PathBuf> {
    let named = |key: &str| env(key).filter(|v| !v.trim().is_empty()).map(PathBuf::from);
    let owner = named(OWNER_KEY)?;
    if let (Some(control), Some(daemon)) = (named(APP_CONTROL_KEY), named(APP_DAEMON_KEY))
        && is_socket(&control)
        && is_socket(&daemon)
    {
        return Some(daemon);
    }
    Some(owner)
}

/// Whether `path` (a link is followed) is a socket now.
pub(super) fn is_socket(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::FileTypeExt;
        std::fs::metadata(path).is_ok_and(|m| m.file_type().is_socket())
    }
    #[cfg(not(unix))]
    {
        path.exists()
    }
}

#[cfg(test)]
#[path = "chief_target_tests.rs"]
mod tests;
