//! The last way `cmux` finds its app: the one cmux NIGHTLY that answers.
//!
//! A `cmux` outside every app bundle (a copy or a symlink on `PATH`), run
//! outside the app's terminals (an ssh shell), has no app around it and none
//! named in its environment, so it said "no cmux app found" while NIGHTLY ran
//! on that Mac. Then the NIGHTLY control socket that answers is the app: its
//! own path (`~/.local/state/cmux/cmux-nightly.sock`) or the old `/tmp` one,
//! only when exactly one of them answers, and the CLI says so once on stderr.
//! A named route (`--app-socket`, `--socket`, `--session`, the app terminal's
//! environment) never comes here.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use crate::app_identity::AppIdentity;

const NIGHTLY_BUNDLE_ID: &str = "com.cmuxterm.app.nightly";

/// The NIGHTLY socket this process falls back to, probed once per process;
/// the first time it is found, a note on stderr names it.
pub(super) fn nightly(home: &Path) -> Option<PathBuf> {
    static FOUND: OnceLock<Option<PathBuf>> = OnceLock::new();
    FOUND
        .get_or_init(|| {
            let uid = cmux_tui_core::platform::effective_uid();
            let found =
                answering(&candidates(home), |path| super::connect_for_uid(path, uid).is_ok());
            if let Some(path) = &found {
                let messages = &crate::localization::catalog().app_control;
                eprintln!(
                    "{}",
                    messages.nightly_fallback.replace("{path}", &path.display().to_string())
                );
            }
            found
        })
        .clone()
}

/// Where an untagged cmux NIGHTLY listens: the path it uses now, then the
/// `/tmp` path an app from before the move uses.
pub(super) fn candidates(home: &Path) -> Vec<PathBuf> {
    let nightly = AppIdentity {
        bundle_id: Some(NIGHTLY_BUNDLE_ID.to_owned()),
        tag: None,
        socket_override: None,
        shipped_tag: None,
    };
    // `AppIdentity::control_socket` picks one of the two by which exists; both are tried here.
    let Some(old) = nightly.build().control_socket(home) else { return Vec::new() };
    let mut paths = Vec::new();
    if let Ok(name) = old.strip_prefix("/tmp") {
        paths.push(home.join(".local/state/cmux").join(name));
    }
    paths.push(old);
    paths
}

/// The one candidate that `answers`; `None` when none or more than one does
/// (two apps: which one is meant is not known, so none is picked). Two
/// spellings of one socket (a symlink) are one.
pub(super) fn answering(
    candidates: &[PathBuf],
    answers: impl Fn(&Path) -> bool,
) -> Option<PathBuf> {
    let canonical = |path: &Path| std::fs::canonicalize(path).unwrap_or_else(|_| path.to_owned());
    let mut found = candidates.iter().filter(|path| answers(path));
    let first = found.next()?;
    let first_canonical = canonical(first);
    found.all(|other| canonical(other) == first_canonical).then(|| first.clone())
}

#[cfg(test)]
#[path = "fallback_socket_tests.rs"]
mod tests;
