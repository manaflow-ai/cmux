//! Recreate a recorded linked worktree before restarting its session's agent.
//! Failed recovery leaves cwd unchanged; the ordinary folder check keeps the prompt retryable.
use crate::git_state::{GitState, WorktreeOrigin, linked_worktree};
use crate::hub::{Hub, Session};
use crate::subsession_worktree::{add_without_config, git_by};
use serde_json::json;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// None means the read was inconclusive; Some(None) clears a stale record.
pub(in crate::hub) fn origin_of(cwd: &Path, git: &GitState) -> Option<Option<WorktreeOrigin>> {
    if let Some((root, common_dir)) = linked_worktree(cwd) {
        if git.branch.is_none() && git.head.is_none() {
            return None;
        }
        return Some(Some(WorktreeOrigin {
            cwd: cwd.to_path_buf(),
            root,
            common_dir,
            branch: git.branch.clone(),
            head: git.head.clone(),
        }));
    }
    // An unreadable .git file or disappearing folder must retain the previous record.
    let dir = std::fs::canonicalize(cwd).ok()?;
    for dir in dir.ancestors() {
        match std::fs::symlink_metadata(dir.join(".git")) {
            Ok(m) => return m.is_dir().then_some(None),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return None,
        }
    }
    Some(None)
}

impl Hub {
    pub(super) async fn revive_folder(&self, session: &Arc<Session>, one: &tokio::sync::Mutex<()>) {
        let meta = session.meta();
        if meta.remote_origin {
            return;
        }
        let cwd = meta.cwd.clone();
        if tokio::fs::try_exists(&cwd).await.unwrap_or(true) {
            let read = tokio::task::spawn_blocking(move || origin_of(&cwd, &GitState::read(&cwd)));
            if let Ok(Ok(Some(found))) = tokio::time::timeout(Duration::from_secs(2), read).await {
                session.meta.lock().unwrap_or_else(|e| e.into_inner()).worktree = found;
                self.save_meta(session);
            }
            return;
        }
        let Some(origin) = meta.worktree.filter(|w| w.cwd == cwd) else {
            return;
        };
        let _one = one.lock().await;
        if tokio::fs::try_exists(&cwd).await.unwrap_or(true) {
            return;
        }
        let job = origin.clone();
        let result = tokio::task::spawn_blocking(move || recreate(&job)).await;
        match result {
            Ok(Ok((from, at))) => {
                self.append(session, "mux", "worktree_recreated", json!({
                    "cwd": cwd, "root": origin.root, "branch": origin.branch, "from": from, "at": at
                }));
            }
            result => {
                self.append(
                    session,
                    "mux",
                    "worktree_recreate_failed",
                    json!({
                        "cwd": cwd, "error": format!("{result:?}")
                    }),
                );
            }
        }
    }
}

fn recreate(w: &WorktreeOrigin) -> Result<(&'static str, String), String> {
    if w.root.exists() || !w.common_dir.is_dir() {
        return Err("worktree root exists or repository is missing".into());
    }
    if w.branch.as_deref().is_some_and(|b| b.starts_with('-')) {
        return Err("invalid branch".into());
    }
    let by = Instant::now() + Duration::from_secs(60);
    let git = |args: &[&str]| git_by(&w.common_dir, args, by);
    git(&["worktree", "prune"])?;
    let root = w.root.to_string_lossy();
    let commit = |r: &str| git(&["rev-parse", "--verify", "--quiet", &format!("{r}^{{commit}}")]);
    let add = |args: &[&str], at: &str| add_without_config(&w.common_dir, args, &w.root, at, by);
    let (from, at) = if let Some(b) = w.branch.as_deref()
        && let Ok(at) = commit(&format!("refs/heads/{b}"))
    {
        add(&[&root, b], &at)?;
        ("branch", at)
    } else if let Some(b) = w.branch.as_deref()
        && let Ok(at) = commit(&format!("refs/remotes/origin/{b}"))
    {
        // Never reset a branch another session created meanwhile.
        add(&["-b", b, &root, &at], &at)?;
        ("origin", at)
    } else if let Some(at) = w.head.as_deref().and_then(|h| commit(h).ok()) {
        add(&["--detach", &root, &at], &at)?;
        ("last commit", at)
    } else {
        return Err("recorded branch and commit are unavailable".into());
    };
    Ok((from, at))
}
