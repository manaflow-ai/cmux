//! A launch's own state root (`CMUX_NEXT_STATE_ROOT`): every per-user thing the launch keeps goes
//! under one folder the launcher picks, and every Keychain service it signs in with carries that
//! folder's run segment, so a fresh folder is a fresh person (Chromium's `--user-data-dir`). A
//! fresh-home probe sets it to a new temporary folder per run instead of wiping the account.
//!
//! The folder stands for the home: the selection state and its client-config cache are in
//! `<root>/Library/Application Support/cmux-next/<bundle id>` ([`crate::bundle_folder`] of the
//! root), as the app's own folders are (CmuxNext `NextSupport.stateRoot`). The selection's sign-in
//! namespace ends in [`run_segment`], so the Stack token Keychain service, its file fallback, the
//! `cmux.auth.*` defaults keys and every store the app namespaces by the selection (install key,
//! device hub, mobile host, Cloud paths) are the run's own. Unset or blank: nothing changes.

use std::path::{Path, PathBuf};

/// The launch variable naming the state root (an absolute path).
pub const STATE_ROOT_ENV: &str = "CMUX_NEXT_STATE_ROOT";

/// The state root `value` names: an absolute path, trailing slashes dropped; None for an unset,
/// blank or relative value (a relative root would move with the working folder).
pub fn state_root(value: Option<&str>) -> Option<PathBuf> {
    let trimmed = value?.trim();
    if !trimmed.starts_with('/') {
        return None;
    }
    let path = trimmed.trim_end_matches('/');
    Some(PathBuf::from(if path.is_empty() { "/" } else { path }))
}

/// This process's state root ([`STATE_ROOT_ENV`]).
pub fn state_root_from_env() -> Option<PathBuf> {
    state_root(std::env::var(STATE_ROOT_ENV).ok().as_deref())
}

/// The run segment of `root`: `run-` and the FNV-1a 64 hash of its path's bytes as 16 lowercase
/// hex digits (CmuxNext `NextSupport.runSegment(stateRoot:)` makes the same). Path- and
/// Keychain-safe; one root always gives one segment, so a relaunch on the same root restores
/// the run's sign-in.
pub fn run_segment(root: &Path) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in root.as_os_str().as_encoded_bytes() {
        hash = (hash ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("run-{hash:016x}")
}

/// The sign-in namespace `namespace` becomes under a state root whose segment is `run`.
pub(crate) fn scoped_namespace(namespace: &str, run: &str) -> String {
    format!("{namespace}-{run}")
}

#[cfg(test)]
#[path = "state_root_tests.rs"]
mod tests;
