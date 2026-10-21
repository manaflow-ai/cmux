//! A session whose worktree was deleted gets it back from its branch before its agent starts
//! (2026-10-20: a reclaim job deleted the worktrees of three lanes whose agents had died, so
//! even a respawn had no folder to start in).
//!
//! Each agent start in an existing folder, and each turn's end (`turn_git.rs`), records the
//! linked worktree the folder is in (`SessionMeta::worktree`: its top folder, the repository's
//! common git directory and the branch checked out). A start whose folder is gone, and that
//! cleanup's archive did not bring back (`worktree_care.rs`), adds the worktree back:
//! `git --git-dir <common> worktree prune`, then `worktree add <root> <branch>`, or, when the
//! local branch is gone too, `worktree add -B <branch> <root> origin/<branch>`. Nothing is
//! forced or overwritten: a branch checked out elsewhere, a folder that exists, a missing
//! repository or branch fail the start, naming the folder and why. Logged as
//! `worktree_recreated` or `worktree_recreate_failed`.
//!
//! A missing folder with no record (not a linked worktree, or never started here) is left as it
//! was: acpmux never makes a folder that git did not.

use crate::git_state::{GitState, WorktreeOrigin, linked_worktree};
use crate::hub::{Hub, Session};
use crate::rpc::RpcError;
use serde_json::json;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Arc;

/// The worktree record for `cwd` on `branch`, read from the folder (blocking).
pub(in crate::hub) fn origin_of(cwd: &Path, branch: Option<&str>) -> Option<WorktreeOrigin> {
    let (root, common_dir) = linked_worktree(cwd)?;
    let branch = branch?.to_owned();
    Some(WorktreeOrigin { cwd: cwd.to_path_buf(), root, common_dir, branch })
}

impl Hub {
    /// Before the agent starts (`ready_to_start`; `one` is the machine's one-restore-at-a-time
    /// lock): an existing folder refreshes the session's record; a missing one with a record
    /// gets its worktree back, or the start fails.
    pub(super) async fn revive_worktree(
        &self,
        session: &Arc<Session>,
        one: &tokio::sync::Mutex<()>,
    ) -> Result<(), RpcError> {
        let meta = session.meta();
        let cwd = meta.cwd.clone();
        if tokio::fs::try_exists(&cwd).await.unwrap_or(true) {
            let read = tokio::task::spawn_blocking(move || {
                origin_of(&cwd, GitState::read(&cwd).branch.as_deref())
            });
            if let Ok(Some(found)) = read.await
                && meta.worktree.as_ref() != Some(&found)
            {
                session.meta.lock().unwrap_or_else(|e| e.into_inner()).worktree = Some(found);
                self.save_meta(session);
            }
            return Ok(());
        }
        let Some(origin) = meta.worktree.filter(|w| w.cwd == cwd) else { return Ok(()) };
        let _one = one.lock().await;
        let job = origin.clone();
        let made = tokio::task::spawn_blocking(move || recreate(&job))
            .await
            .unwrap_or_else(|e| Err(format!("the recreate stopped: {e}")));
        let (branch, root) = (&origin.branch, &origin.root);
        match made {
            Ok(None) => Ok(()),
            Ok(Some(from)) => {
                let msg = json!({"branch": branch, "cwd": cwd, "root": root, "from": from});
                self.append(session, "mux", "worktree_recreated", msg);
                Ok(())
            }
            Err(why) => {
                let msg = json!({"branch": branch, "cwd": cwd, "root": root, "error": why});
                self.append(session, "mux", "worktree_recreate_failed", msg);
                Err(RpcError::new(
                    -32000,
                    format!(
                        "the session's folder {} is gone and acpmux could not add its worktree back from branch {branch}: {why}",
                        cwd.display()
                    ),
                )
                .with_data(json!({"reason": "worktree_missing", "cwd": cwd, "branch": branch})))
            }
        }
    }
}

/// Adds `w`'s worktree back (blocking): `Some` with where its branch came from, `None` when
/// there is nothing to do (the folder or the worktree's top folder exists).
fn recreate(w: &WorktreeOrigin) -> Result<Option<&'static str>, String> {
    if w.cwd.exists() || w.root.exists() {
        return Ok(None);
    }
    if !w.common_dir.is_dir() {
        return Err(format!("its repository {} is gone too", w.common_dir.display()));
    }
    if w.branch.starts_with('-') {
        return Err(format!("{:?} is not a branch acpmux checks out", w.branch));
    }
    let git = |args: &[&str]| git(&w.common_dir, args);
    git(&["worktree", "prune"])?;
    let root = w.root.to_string_lossy();
    let has = |r: &str| git(&["rev-parse", "--verify", "--quiet", r]).is_ok();
    let from = if has(&format!("refs/heads/{}", w.branch)) {
        git(&["worktree", "add", &root, &w.branch])?;
        "branch"
    } else if has(&format!("refs/remotes/origin/{}", w.branch)) {
        git(&["worktree", "add", "-B", &w.branch, &root, &format!("origin/{}", w.branch)])?;
        "origin"
    } else {
        return Err(format!("neither branch {0} nor origin/{0} exists any more", w.branch));
    };
    if !w.cwd.exists() {
        return Err(format!("branch {} has no folder {}", w.branch, w.cwd.display()));
    }
    Ok(Some(from))
}

/// Runs git on the repository at `common` (its common git directory), never asking for input.
fn git(common: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .arg("--git-dir")
        .arg(common)
        .args(args)
        .current_dir(std::env::temp_dir())
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_INDEX_FILE")
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("git did not run: {e}"))?;
    if out.status.success() {
        return Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned());
    }
    let err = String::from_utf8_lossy(&out.stderr);
    Err(format!("git {}: {}", args.join(" "), err.trim()))
}
