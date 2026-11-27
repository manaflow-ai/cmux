//! Part of `Hub`; see `hub/mod.rs`. Nothing lives only on the VM (RFD 0063, item 1): at each
//! turn end and before each pause, the work in the session's folder, committed or not, is
//! written as a commit under `refs/cmux-wip/<session id>` and pushed to `origin` there, outside
//! `refs/heads`, so a VM that is lost takes no work with it. The folder's own branch, index and
//! working tree are not touched: the commit is built in a scratch index, from everything git does
//! not ignore, on top of HEAD.
//!
//! Off unless `ACPMUX_WIP_REF=1` (an agent VM's daemon sets it): a person's own machine does not
//! push their folder anywhere on its own. A folder with no git repository, one with no `origin`
//! and no commit yet (a plain folder, nothing is written), one with no `origin`, an
//! unreachable remote and a push that is refused are logged and never fail or hold up a turn or
//! a pause. It runs the same for every harness: it reads the folder, not the agent.

use super::Session;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

/// The longest a turn end's or a pause's save runs before it is left behind.
const LIMIT: Duration = Duration::from_secs(45);

/// Whether this daemon saves work in progress (see the module docs).
pub(super) fn enabled() -> bool {
    std::env::var("ACPMUX_WIP_REF").is_ok_and(|v| v == "1")
}

/// The ref a session's work is kept under, None for an id that is no plain ref component.
fn ref_name(session_id: &str) -> Option<String> {
    let plain = !session_id.is_empty()
        && session_id.len() <= 80
        && session_id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    plain.then(|| format!("refs/cmux-wip/{session_id}"))
}

/// Runs git in `dir`; its trimmed stdout when it succeeds.
fn git(dir: &Path, index: Option<&Path>, args: &[&str]) -> Option<String> {
    let mut command = Command::new("git");
    command
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=acpmux", "-c", "user.email=acpmux@example.com"])
        .args(["-c", "commit.gpgsign=false"])
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .stdin(Stdio::null())
        .stderr(Stdio::null());
    if let Some(index) = index {
        command.env("GIT_INDEX_FILE", index);
    }
    let out = command.output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

/// What a save did, for the log and the tests.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Saved {
    /// Not a git folder, or no ref name for the session.
    Skipped,
    /// The ref already holds this tree; nothing was written or pushed.
    Unchanged,
    /// The commit is in the folder's repository; `pushed` says whether `origin` has it.
    Written { commit: String, pushed: bool },
}

/// Writes the folder's work as the session's wip commit and pushes it (blocking).
pub(super) fn save_blocking(cwd: &Path, session_id: &str) -> Saved {
    let Some(name) = ref_name(session_id) else { return Saved::Skipped };
    let Some(top) = git(cwd, None, &["rev-parse", "--show-toplevel"]) else {
        return Saved::Skipped;
    };
    let top = PathBuf::from(top);
    if is_unborn_without_origin(&top) {
        return Saved::Skipped;
    }
    let Some(gitdir) = git(&top, None, &["rev-parse", "--absolute-git-dir"]) else {
        return Saved::Skipped;
    };
    let index = Path::new(&gitdir).join(format!("cmux-wip-{session_id}.index"));
    let _ = crate::home_fs::remove_file(&index);
    let tree = git(&top, Some(&index), &["add", "-A", "--", "."])
        .and_then(|_| git(&top, Some(&index), &["write-tree"]));
    let _ = crate::home_fs::remove_file(&index);
    let Some(tree) = tree else { return Saved::Skipped };
    let kept = git(&top, None, &["rev-parse", "--verify", "-q", &format!("{name}^{{tree}}")]);
    if kept.as_deref() == Some(tree.as_str()) {
        return Saved::Unchanged;
    }
    let head = git(&top, None, &["rev-parse", "--verify", "-q", "HEAD"]);
    let mut args = vec!["commit-tree", tree.as_str(), "-m", "cmux wip"];
    if let Some(head) = head.as_deref() {
        args.extend(["-p", head]);
    }
    let Some(commit) = git(&top, None, &args) else { return Saved::Skipped };
    if git(&top, None, &["update-ref", &name, &commit]).is_none() {
        return Saved::Skipped;
    }
    let refspec = format!("{commit}:{name}");
    let pushed =
        git(&top, None, &["push", "--no-verify", "--force", "-q", "origin", &refspec]).is_some();
    Saved::Written { commit, pushed }
}

/// A repository with no `origin` and no commit on HEAD (a lane VM's `/home/cmux` is `git init`
/// and nothing more) holds no work a save could keep: no push can succeed, and `add -A` would
/// hash every file under it, the whole home folder, at each turn end. It is a plain folder, as a
/// move reads it (`cli/run/session_move.rs` `checkout_of`).
fn is_unborn_without_origin(top: &Path) -> bool {
    git(top, None, &["remote", "get-url", "origin"]).is_none()
        && git(top, None, &["rev-parse", "--verify", "-q", "HEAD^{commit}"]).is_none()
}

/// [`save_blocking`] off the runtime, bounded; logs what it could not do.
pub(super) async fn save(cwd: PathBuf, session_id: String) {
    let id = session_id.clone();
    let run = tokio::task::spawn_blocking(move || save_blocking(&cwd, &session_id));
    match tokio::time::timeout(LIMIT, run).await {
        Ok(Ok(Saved::Written { pushed: false, .. })) => {
            tracing::warn!(session = %id, "work in progress is saved here but origin did not take it");
        }
        Ok(Ok(_)) => {}
        _ => tracing::warn!(session = %id, "saving work in progress did not finish"),
    }
}

impl super::Hub {
    /// Saves the folder's work in the background when this daemon does (turn end).
    pub(super) fn save_wip_in_background(&self, session: &Session) {
        if !enabled() {
            return;
        }
        let cwd = session.meta.lock().unwrap_or_else(|e| e.into_inner()).cwd.clone();
        let id = session.id.clone();
        self.scope.spawn_until_cancelled("wip-ref", save(cwd, id));
    }
}

impl Session {
    /// Saves the folder's work and waits for it, before a pause.
    pub(super) async fn save_wip(&self) {
        if enabled() {
            let cwd = self.meta.lock().unwrap_or_else(|e| e.into_inner()).cwd.clone();
            save(cwd, self.id.clone()).await;
        }
    }
}

#[cfg(test)]
#[path = "wip_ref_tests.rs"]
mod tests;
