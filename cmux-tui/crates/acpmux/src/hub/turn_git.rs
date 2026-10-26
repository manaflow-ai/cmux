//! The branch a turn ended on (hq#1920): each `turn_result` records the git
//! branch and HEAD commit of the session's folder as the turn settles
//! (`gitBranch`, `gitHead`; `git_state.rs`), so the `branches` stats follow
//! an agent that switches branch mid-session. The session's own `gitBranch`
//! stays the one it started on.
//!
//! The read runs off the async runtime and is bounded: a folder whose git
//! state cannot be read in time, or at all, leaves the fields out and never
//! fails or holds up the turn.

use super::{Hub, Session};
use crate::git_state::GitState;
use serde_json::{Map, Value, json};
use std::time::Duration;

/// The longest a turn's settlement waits on the git read.
const GIT_READ_LIMIT: Duration = Duration::from_secs(2);

/// The `turn_result` fields for the session folder's git state now:
/// `gitBranch` and `gitHead`, each absent when it cannot be read. The linked
/// worktree it is in is kept on the session (`worktree_care/revive.rs`).
pub(super) async fn turn_git(session: &Session) -> Map<String, Value> {
    let cwd = session.meta.lock().unwrap_or_else(|e| e.into_inner()).cwd.clone();
    let read = tokio::task::spawn_blocking(move || {
        let git = GitState::read(&cwd);
        let worktree = super::worktree_care::revive::origin_of(&cwd, &git);
        (git, worktree)
    });
    let (git, worktree) = match tokio::time::timeout(GIT_READ_LIMIT, read).await {
        Ok(Ok(read)) => read,
        _ => (GitState::default(), None),
    };
    if let Some(worktree) = worktree {
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).worktree = worktree;
    }
    let mut fields = Map::new();
    if let Some(branch) = git.branch {
        fields.insert("gitBranch".into(), json!(branch));
    }
    if let Some(head) = git.head {
        fields.insert("gitHead".into(), json!(head));
    }
    fields
}

impl Hub {
    /// Writes a settled turn's `turn_result` with the folder's git state at
    /// its end, keeping its outcome as the session's `lastTurn` first.
    pub(super) fn write_turn_result(
        &self,
        session: &Session,
        mut msg: Value,
        git: Map<String, Value>,
    ) {
        if let Some(o) = msg.as_object_mut() {
            o.extend(git);
            o.insert("unread".into(), Value::Bool(!self.shown(session)));
        }
        msg["pendingPermissions"] = self.session_summary(session)["pendingPermissions"].clone();
        self.record_last_turn(session, &msg);
        self.append(session, "mux", "turn_result", msg);
    }
}
