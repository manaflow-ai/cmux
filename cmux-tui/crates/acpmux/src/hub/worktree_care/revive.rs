//! A session whose folder was deleted does not die with it (2026-10-20: a reclaim job deleted
//! the worktrees of three lanes whose agents had died, and lanes that removed their own worktree
//! after their pull request merged could not start their agent again).
//!
//! Each agent start in an existing folder, and each turn's end (`turn_git.rs`), records the
//! linked worktree the folder is in (`SessionMeta::worktree`: its top folder, the repository's
//! common git directory, the branch checked out and its commit). Before the agent starts, and
//! before each turn, a folder that is gone and that cleanup's archive did not bring back
//! (`worktree_care.rs`) is added back with `git worktree prune`, then `worktree add`: on its
//! branch; else `-b <branch>` at `origin/<branch>`; else, the branch gone, `--detach` at its last
//! recorded commit, or at `origin/HEAD`. Nothing is forced or overwritten (a branch checked out
//! elsewhere, or made meanwhile, fails it). Logged as `worktree_recreated`. Git runs as a
//! sub-session's worktree is made (`subsession_worktree.rs`): the files are written with none
//! of the repository's config, so no filter, hook or helper of the repository's runs in the
//! daemon, and every git call ends within `GIT_BUDGET`.
//!
//! A live agent whose folder went still runs in the deleted one, even once it is back: it
//! starts again, on its conversation, with the turn kept (`ready_folder`).
//!
//! When there is no record (the folder was not a linked worktree) or the worktree cannot be
//! added back (`worktree_recreate_failed`), the session moves to the nearest folder above it
//! that exists (`cwd_fallback`): its agent starts there, a live one restarted. acpmux never
//! makes a folder git did not. A remote chain (`remote_origin`) is left as it was: its sandbox
//! allows writes in its own folder only. Either way the agent's next prompt starts with a line that says
//! what happened (`[acpmux] your cwd ... was missing; ...`). The session never moves to `/`, to
//! `/Volumes` or to a mount's top folder (`bare_root`): the turn fails, saying why, and its queue
//! is held.

use crate::git_state::{GitState, WorktreeOrigin, linked_worktree};
use crate::hub::{Hub, Session, SessionStatus};
use crate::rpc::RpcError;
use crate::subsession_worktree::{add_without_config, git_by};
use serde_json::json;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

/// The longest bringing a worktree back may take, all its git calls together.
const GIT_BUDGET: Duration = Duration::from_secs(60);

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
    ) -> Result<(), RpcError> {
        let meta = session.meta();
        let cwd = meta.cwd.clone();
        // A remote chain's sandbox allows writes in its folder only: it never moves above it,
        // nor runs git on a repository its agent could have written (`remote_sandbox.rs`).
        if meta.remote_origin {
            return Ok(());
        }
        if tokio::fs::try_exists(&cwd).await.unwrap_or(true) {
            if !starting {
                return Ok(());
            }
            let read = tokio::task::spawn_blocking(move || origin_of(&cwd, &GitState::read(&cwd)));
            if let Ok(Some(found)) = read.await
                && meta.worktree.as_ref() != Some(&found)
            {
                session.meta.lock().unwrap_or_else(|e| e.into_inner()).worktree = Some(found);
                self.save_meta(session);
            }
            return Ok(());
        }
        let _one = one.lock().await;
        let origin = meta.worktree.filter(|w| w.cwd == cwd);
        let (job, folder) = (origin.clone(), cwd.clone());
        let revived = tokio::task::spawn_blocking(move || revive(job.as_ref(), &folder))
            .await
            .unwrap_or_else(|e| fallback(&cwd, format!("the recreate stopped: {e}")));
        let shown = cwd.display();
        let notice = match revived {
            Revived::There => return Ok(()),
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
                if bare_root(&to) {
                    let msg = json!({"cwd": cwd, "to": to, "reason": why});
                    self.append(session, "mux", "cwd_fallback_refused", msg);
                    return Err(RpcError::internal(format!(
                        "your cwd {shown} is missing ({why}) and the folder above it is {}: acpmux runs no agent there; recreate the folder or move the chat",
                        to.display()
                    )));
                }
                session.meta.lock().unwrap_or_else(|e| e.into_inner()).cwd = to.clone();
                self.save_meta(session);
                self.append(
                    session,
                    "mux",
                    "cwd_fallback",
                    json!({"from": cwd, "to": to, "reason": why}),
                );
                format!("{why}; running in {} instead", to.display())
            }
        };
        let notice = format!("[acpmux] your cwd {shown} was missing; {notice}.");
        NOTICES.lock().unwrap_or_else(|e| e.into_inner()).insert(session.id.clone(), notice);
        Ok(())
    }

    /// `detach_child` but for the turn: the turn starting stays, so a prompt sent meanwhile
    /// still queues behind it. Idle before the child lock is let go, so the agent's exit reads
    /// as a stop (`permissions.rs`), not a death to resume.
    pub(super) async fn stop_agent_keeping_turn(&self, session: &Arc<Session>) {
        let mut slot = session.child.lock().await;
        let Some(child) = slot.take() else {
            return;
        };
        self.revoke_permission_chat(session);
        self.cancel_pending_permissions(session);
        child.kill().await;
        if session.status() != SessionStatus::Closed {
            self.set_status(session, SessionStatus::Idle);
        }
        drop(slot);
    }
}

/// A folder no session moves to: the root, `/Volumes`, a volume's top folder there, or any
/// mount's top folder (another device than the folder above it: `/mnt/data`).
fn bare_root(dir: &Path) -> bool {
    #[cfg(unix)]
    let device = |p: &Path| std::os::unix::fs::MetadataExt::dev(&std::fs::metadata(p).ok()?).into();
    #[cfg(not(unix))]
    let device = |_: &Path| None;
    bare_root_by(dir, device)
}

/// [`bare_root`], `device` naming a folder's device.
fn bare_root_by(dir: &Path, device: impl Fn(&Path) -> Option<u64>) -> bool {
    let volumes = Path::new("/Volumes");
    let Some(parent) = dir.parent() else {
        return true;
    };
    if dir == volumes || parent == volumes {
        return true;
    }
    matches!((device(dir), device(parent)), (Some(a), Some(b)) if a != b)
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
    let by = Instant::now() + GIT_BUDGET;
    let git = |args: &[&str]| git_by(&w.common_dir, args, by);
    git(&["worktree", "prune"])?;
    let root = w.root.to_string_lossy();
    let commit = |r: &str| git(&["rev-parse", "--verify", "--quiet", &format!("{r}^{{commit}}")]);
    let add = |args: &[&str], at: &str| add_without_config(&w.common_dir, args, &w.root, at, by);
    let (local, remote) = (format!("refs/heads/{}", w.branch), format!("origin/{}", w.branch));
    let (from, at) = if let Ok(at) = commit(&local) {
        add(&[&root, &w.branch], &at)?;
        ("branch", at)
    } else if let Ok(at) = commit(&format!("refs/remotes/{remote}")) {
        // `-b`, never `-B`: a branch of that name made meanwhile is not reset; git refuses.
        add(&["-b", &w.branch, &root, &at], &at)?;
        let _ = git(&["branch", &format!("--set-upstream-to={remote}"), &w.branch]);
        ("origin", at)
    } else if let Some(at) = w.head.as_deref().and_then(|h| commit(h).ok()) {
        add(&["--detach", &root, &at], &at)?;
        ("its last commit", at)
    } else if let Ok(at) = commit("refs/remotes/origin/HEAD") {
        add(&["--detach", &root, &at], &at)?;
        ("origin/HEAD", at)
    } else {
        return Err(format!("neither branch {0} nor origin/{0} nor origin/HEAD exists", w.branch));
    };
    Ok((from, at.chars().take(12).collect()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_mount_top_is_a_bare_root_by_its_device() {
        let device = |p: &Path| Some(if p.starts_with("/mnt/data") { 2 } else { 1 });
        assert!(bare_root_by(Path::new("/mnt/data"), device));
        assert!(!bare_root_by(Path::new("/mnt/data/project"), device));
        assert!(!bare_root_by(Path::new("/mnt"), device));
        assert!(!bare_root_by(Path::new("/mnt/data"), |_: &Path| None));
    }

    #[test]
    fn a_session_never_moves_to_the_root_or_a_volume_top() {
        let one_device = |_: &Path| Some(1);
        for dir in ["/", "/Volumes", "/Volumes/Work"] {
            assert!(bare_root_by(Path::new(dir), one_device), "{dir}");
        }
        for dir in ["/Users", "/tmp/x", "/Volumes/Work/repo", "/home/me"] {
            assert!(!bare_root_by(Path::new(dir), one_device), "{dir}");
        }
        let Revived::Moved(to, _) = fallback(Path::new("/acpmux-never-made/deeper"), "x".into())
        else {
            panic!("a missing folder moves");
        };
        assert!(bare_root(&to));
    }
}
