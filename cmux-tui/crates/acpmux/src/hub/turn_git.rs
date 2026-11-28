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
use cmux_json::JsonSet as _;
use serde_json::{Map, Value, json};
use std::time::Duration;

/// The longest a turn's settlement waits on the git read.
const GIT_READ_LIMIT: Duration = Duration::from_secs(2);

/// The `turn_result` fields for the session folder's git state now:
/// `gitBranch` and `gitHead`, each absent when it cannot be read. The linked
/// worktree it is in is kept on the session (`worktree_care/revive.rs`).
pub(super) async fn turn_git(session: &Session) -> Map<String, Value> {
    let (cwd, initial) = session.read_meta(|m| (m.cwd.clone(), m.git_head.clone()));
    // Whether HEAD is on a remote, for the unpushed sidecar rule: read only for a reply that
    // says done, and only for a HEAD this session moved (`sidecars.rs`).
    let check_push = super::sidecars_turn::wants_push_check(session);
    let read = tokio::task::spawn_blocking(move || {
        let git = GitState::read(&cwd);
        let worktree = super::worktree_care::revive::origin_of(&cwd, &git);
        let pushed = match (&git.head, &initial) {
            (Some(head), Some(initial)) if check_push && head != initial => {
                crate::git_state::is_remote_tip(&cwd, head)
            }
            _ => None,
        };
        (git, worktree, pushed)
    });
    let (git, worktree, pushed) = match tokio::time::timeout(GIT_READ_LIMIT, read).await {
        Ok(Ok(read)) => read,
        _ => (GitState::default(), None, None),
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
    if let Some(pushed) = pushed {
        fields.insert("gitHeadPushed".into(), json!(pushed));
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
        if msg.get("cancelForced") == Some(&Value::Bool(true))
            && session
                .cancel_forced_result_turn
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .replace(msg["turnId"].as_str().unwrap_or_default().to_owned())
                .is_some_and(|id| id == msg["turnId"].as_str().unwrap_or_default())
        {
            return;
        }
        if let Some(o) = msg.as_object_mut() {
            o.extend(git);
            super::verify::stamp(&session.id, o);
            super::speculative::stamp(&session.id, o);
            // What this turn's prefetch attached and how much of it was read anyway (`prefetch.rs`).
            if let Some(turn) = o.get("turnId").and_then(Value::as_str).map(str::to_owned) {
                o.extend(self.take_prefetch_counters(session, &turn));
            }
            let trigger = o.get("trigger") == Some(&Value::Bool(true));
            o.insert("unread".into(), Value::Bool(!trigger && !self.attended(session)));
        }
        // The count alone: building the whole row here masked its title and step again on every
        // turn's end (goal sessions-2000-attached).
        msg.set("pendingPermissions", json!(session.pending_permission_count()));
        // Which harness-magic features ran this turn, for the scorecard's like-with-like split.
        super::sidecars::stamp(&session.id, &mut msg);
        super::harness_magic::stamp(&mut msg);
        super::turn_checkpoint::count(&mut msg);
        self.cache_alarm(session, &mut msg);
        self.turn_rules_end(session, &mut msg);
        self.sidecars_end(session, &mut msg);
        super::best_of_n::stamp(&session.id, &mut msg);
        // The turn's edits, tests and PRs as one card (`turn_artifacts.rs`).
        super::turn_artifacts::stamp(&session.id, &mut msg);
        self.record_last_turn(session, &msg);
        // The chat's page after the turn (`turn_shots.rs`), taken once the result is written.
        let turn = msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
        self.append(session, "mux", "turn_result", msg);
        if let Some(turn) = turn {
            super::turn_shots::turn_ended(&self.scope, session, &turn);
            super::turn_frames::turn_ended(session, &turn);
        }
    }
}
