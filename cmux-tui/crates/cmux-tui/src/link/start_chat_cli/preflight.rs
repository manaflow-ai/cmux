//! `cmux link start-chat preflight --local FOLDER`: whether a Cloud chat may start from `FOLDER`
//! at all, asked before any machine or lease is made for it (the App's `CloudStartChat`). A folder
//! in git goes on (a seed clones it; the copy it may fall back to is counted then). A plain folder
//! is counted as its copy would be ([`size_cap::check_plain`]), stopping at the first limit; one
//! past a limit is refused with [`size_cap::CODE`], the folder as the person reads it, and the git
//! working copies right inside it (`repos`), so the card offers each as the chat's folder instead.
//!
//! Leo, 2026-11-10, on a Cloud start from `~/Projects` (a parent of many repositories, 20 GB) that
//! made a machine, then failed its copy with a Retry that could only fail again: "then there's
//! this limit" and "did you guys not test these".

use std::path::Path;

use serde_json::{Value, json};

use super::super::sync_cli::{self, size_cap};
use size_cap::{MAX_REPOS, child_repos};

/// The answer for `local`: `{"ok":true}`, or the refusal with the repositories inside it.
pub(super) fn run(local: &str) -> Value {
    let folder = Path::new(local);
    if !folder.is_absolute() {
        return super::refused("usage.invalid", "--local must be an absolute folder");
    }
    match check(folder) {
        Ok(()) => json!({"ok": true}),
        Err(refusal) => refusal,
    }
}

/// [`run`]'s check: Err is the refusal's JSON.
pub(super) fn check(folder: &Path) -> Result<(), Value> {
    // A folder that is gone or unreadable is the pane's and the copy's to report.
    let Ok(folder) = std::fs::canonicalize(folder) else { return Ok(()) };
    if sync_cli::in_git(&folder) {
        return Ok(());
    }
    let Err(large) = size_cap::check_plain(&folder) else { return Ok(()) };
    let (repos, more) = child_repos(&folder, MAX_REPOS);
    let listed: Vec<Value> = repos
        .iter()
        .map(|repo| json!({"name": repo.name, "path": repo.path.to_string_lossy()}))
        .collect();
    Err(json!({
        "ok": false,
        "error": format!("{large}{}", size_cap::repos_hint(&folder)),
        "error_code": size_cap::CODE,
        "folder": size_cap::shown(&folder),
        "bytes": large.bytes,
        "files": large.files,
        "repos": listed,
        "repos_more": more,
    }))
}

#[cfg(test)]
#[path = "preflight_tests.rs"]
mod tests;
