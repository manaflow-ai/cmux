//! A session whose folder was deleted does not die with it (2026-10-20: a reclaim job deleted
//! the worktrees of three lanes whose agents had died, and lanes that removed their own worktree
//! after their pull request merged could not start their agent again).
//!
//! Each agent start in an existing folder, and each turn's end (`turn_git.rs`), records the
//! linked worktree the folder is in (`SessionMeta::worktree`: its top folder, the repository's
//! common git directory, the branch checked out and its commit). Before the agent starts, and
//! before each turn, a folder that is gone and that cleanup's archive did not bring back
//! (`worktree_care.rs`) is added back with `git --git-dir <common> worktree prune`, then
//! `worktree add`: on its branch; else `-B <branch>` from `origin/<branch>`; else, the branch
//! gone, `--detach` at its last recorded commit, or at `origin/HEAD`. Nothing is forced or
//! overwritten (a branch checked out elsewhere fails it). Logged as `worktree_recreated`.
//!
//! When there is no record (the folder was not a linked worktree) or the worktree cannot be
//! added back (`worktree_recreate_failed`), the session moves to the nearest folder above it
//! that exists (`cwd_fallback`): its agent starts there, a live one restarted. acpmux never
//! makes a folder git did not. A remote chain (`remote_origin`) is left as it was: its sandbox
//! allows writes in its own folder only. Either way the agent's next prompt starts with a line that says
//! what happened (`[acpmux] your cwd ... was missing; ...`).

use crate::git_state::{GitState, WorktreeOrigin, linked_worktree};
use crate::hub::{Hub, Session};
use serde_json::json;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, LazyLock, Mutex};

/// What acpmux did about a missing folder, for each session's next prompt. Per process: a
/// daemon restart forgets it.
static NOTICES: LazyLock<Mutex<HashMap<String, String>>> = LazyLock::new(Default::default);

/// The worktree record for `cwd` in the state `git` read there (blocking).
pub(in crate::hub) fn origin_of(cwd: &Path, git: &GitState) -> Option<WorktreeOrigin> {
    let (root, common_dir) = linked_worktree(cwd)?;
    let branch = git.branch.clone()?;
    let head = git.head.clone();
    Some(WorktreeOrigin { cwd: cwd.to_path_buf(), root, common_dir, branch, head })
}

/// The line the session's next prompt starts with, once (`run_prompt`).
pub(in crate::hub) fn take_notice(session_id: &str) -> Option<String> {
    NOTICES.lock().unwrap_or_else(|e| e.into_inner()).remove(session_id)
}

/// How a missing folder came back.
enum Revived {
    /// It is there (another start brought it back).
    There,
    /// Its worktree was added back: its record, from where, and the commit it is on.
    Made(WorktreeOrigin, &'static str, String),
    /// The session moves to this folder above it, for this reason.
    Moved(PathBuf, String),
}

impl Hub {
    /// The session's folder before its agent starts (`starting`, from the cold start) or a
    /// turn starts (`one` is the machine's one-restore-at-a-time lock): there, a start refreshes
    /// the record; gone, it comes back or the session moves (module doc).
    pub(super) async fn revive_folder(
        &self,
        session: &Arc<Session>,
        one: &tokio::sync::Mutex<()>,
        starting: bool,
    ) {
        let meta = session.meta();
        let cwd = meta.cwd.clone();
        // A remote chain's sandbox allows writes in its folder only: it never moves above it,
        // nor runs git on a repository its agent could have written (`remote_sandbox.rs`).
        if meta.remote_origin {
            return;
        }
        if tokio::fs::try_exists(&cwd).await.unwrap_or(true) {
            if !starting {
                return;
            }
            let read = tokio::task::spawn_blocking(move || origin_of(&cwd, &GitState::read(&cwd)));
            if let Ok(Some(found)) = read.await
                && meta.worktree.as_ref() != Some(&found)
            {
                session.meta.lock().unwrap_or_else(|e| e.into_inner()).worktree = Some(found);
                self.save_meta(session);
            }
            return;
        }
        let _one = one.lock().await;
        let origin = meta.worktree.filter(|w| w.cwd == cwd);
        let (job, folder) = (origin.clone(), cwd.clone());
        let revived = tokio::task::spawn_blocking(move || revive(job.as_ref(), &folder))
            .await
            .unwrap_or_else(|e| fallback(&cwd, format!("the recreate stopped: {e}")));
        let shown = cwd.display();
        let notice = match revived {
            Revived::There => return,
            Revived::Made(w, from, at) => {
                let b = &w.branch;
                let msg = json!({"branch": b, "cwd": cwd, "root": w.root, "from": from, "at": at});
                self.append(session, "mux", "worktree_recreated", msg);
                match from {
                    "branch" => format!("recreated it from branch {b}"),
                    "origin" => format!("recreated it from origin/{b} as branch {b}"),
                    _ => format!(
                        "branch {b} is gone, so recreated it at {from} {at} (detached HEAD)"
                    ),
                }
            }
            Revived::Moved(to, why) => {
                if let Some(w) = &origin {
                    let msg = json!({"branch": w.branch, "cwd": cwd, "root": w.root, "error": why});
                    self.append(session, "mux", "worktree_recreate_failed", msg);
                }
                session.meta.lock().unwrap_or_else(|e| e.into_inner()).cwd = to.clone();
                self.save_meta(session);
                self.append(
                    session,
                    "mux",
                    "cwd_fallback",
                    json!({"from": cwd, "to": to, "reason": why}),
                );
                // At a turn's start, a live agent still runs in the folder that is gone: it
                // starts again here. A cold start replaces the agent anyway.
                if !starting && session.child.lock().await.is_some() {
                    self.detach_child(session).await;
                }
                format!("{why}; running in {} instead", to.display())
            }
        };
        let notice = format!("[acpmux] your cwd {shown} was missing; {notice}.");
        NOTICES.lock().unwrap_or_else(|e| e.into_inner()).insert(session.id.clone(), notice);
    }
}

/// Brings `cwd` back from its worktree record, else names the folder above it (blocking).
fn revive(origin: Option<&WorktreeOrigin>, cwd: &Path) -> Revived {
    if cwd.exists() {
        return Revived::There;
    }
    let Some(w) = origin else {
        return fallback(cwd, "it was not a git worktree acpmux knew".to_owned());
    };
    let why = match recreate(w) {
        Ok((from, at)) if cwd.exists() => return Revived::Made(w.clone(), from, at),
        Ok((_, at)) => format!("its worktree came back at {at} without this folder"),
        Err(why) => format!("its worktree could not be added back ({why})"),
    };
    fallback(cwd, why)
}

/// The nearest folder above `cwd` that exists (the root at worst).
fn fallback(cwd: &Path, why: String) -> Revived {
    let to = cwd.ancestors().skip(1).find(|p| p.is_dir()).unwrap_or(Path::new("/"));
    Revived::Moved(to.to_path_buf(), why)
}

/// Adds `w`'s worktree back (blocking): where it came from and the commit it is on.
fn recreate(w: &WorktreeOrigin) -> Result<(&'static str, String), String> {
    if w.root.exists() {
        return Err(format!("its top folder {} is there", w.root.display()));
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
    let commit = |r: &str| git(&["rev-parse", "--verify", "--quiet", &format!("{r}^{{commit}}")]);
    let (local, remote) = (format!("refs/heads/{}", w.branch), format!("origin/{}", w.branch));
    let (from, at) = if let Ok(at) = commit(&local) {
        git(&["worktree", "add", &root, &w.branch])?;
        ("branch", at)
    } else if let Ok(at) = commit(&format!("refs/remotes/{remote}")) {
        git(&["worktree", "add", "-B", &w.branch, &root, &remote])?;
        ("origin", at)
    } else if let Some((head, at)) =
        w.head.as_deref().and_then(|h| commit(h).ok().map(|at| (h, at)))
    {
        git(&["worktree", "add", "--detach", &root, head])?;
        ("its last commit", at)
    } else if let Ok(at) = commit("refs/remotes/origin/HEAD") {
        git(&["worktree", "add", "--detach", &root, "origin/HEAD"])?;
        ("origin/HEAD", at)
    } else {
        return Err(format!("neither branch {0} nor origin/{0} nor origin/HEAD exists", w.branch));
    };
    Ok((from, at.chars().take(12).collect()))
}

/// Runs git on the repository at `common` (its common git directory), never asking for input
/// and running none of the repository's hooks.
fn git(common: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .arg("--git-dir")
        .arg(common)
        .args(["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"])
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
