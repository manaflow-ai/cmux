//! Spend and agent working time per git branch (hq#1920): the join from a
//! session to the pull request it produced, so cost and agent-hours can be
//! read per merged PR.
//!
//! A session belongs to the branch its `cwd` had checked out when it started
//! (`SessionMeta::git_branch`, `git_state.rs`), for all its turns: a session
//! that switches branch later (an agent's own `git checkout -b`) stays on the
//! one it started on. The cwd is taken as given, so a session in a subfolder
//! of the same checkout is another row. A row is keyed by that branch
//! and the session's `cwd`, not by repository: a repository's identity
//! (`hub/adoption.rs` `repo_identity`) asks git about a folder that is often
//! gone by the time its PR merges, so the cwd keeps one branch name in two
//! checkouts apart instead. Sessions with no branch (a detached HEAD, no
//! repository, or a session older than the field) are left out; the summary's
//! totals still count them.
//!
//! Only turns in the range count, with the spend each `turn_result` recorded,
//! never `SessionMeta::totals`, which spans the session's whole life. A
//! fork's log starts with copies of its parent's turns: those count only in
//! the parent's log (not at all once that log is deleted or unreadable).

use crate::store::{SessionMeta, TurnUsage};
use serde::Serialize;
use serde_json::Value;
use std::collections::BTreeMap;

/// The most rows an answer carries: the branches with the most working time.
pub const MAX_BRANCHES: usize = 50;

#[derive(Debug, Clone, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BranchStats {
    /// The sessions' folder when they started.
    pub cwd: String,
    pub branch: String,
    /// Sessions with a turn, or working time, in the range.
    pub sessions: u64,
    pub turns: u64,
    pub working_ms: u64,
    /// The spend of the turns counted: `TurnUsage` fields, each absent when
    /// no turn reported it.
    #[serde(flatten)]
    pub usage: TurnUsage,
}

/// One session's turns in the range, without its fork copies.
#[derive(Default)]
pub(super) struct BranchShare {
    pub turns: u64,
    pub working_ms: u64,
    pub usage: TurnUsage,
}

#[derive(Default)]
pub(super) struct Branches(BTreeMap<(String, String), BranchStats>);

impl Branches {
    pub(super) fn add(&mut self, meta: &SessionMeta, share: BranchShare) {
        let Some(branch) = meta.git_branch.as_deref() else { return };
        if share.turns == 0 && share.working_ms == 0 {
            return;
        }
        let cwd = meta.cwd.to_string_lossy().into_owned();
        let row = self.0.entry((cwd.clone(), branch.to_owned())).or_insert_with(|| BranchStats {
            cwd,
            branch: branch.to_owned(),
            ..BranchStats::default()
        });
        row.sessions += 1;
        row.turns += share.turns;
        row.working_ms += share.working_ms;
        row.usage.add(&share.usage);
    }

    /// Most working time first, at most `MAX_BRANCHES`.
    pub(super) fn finish(self) -> Vec<BranchStats> {
        let mut rows: Vec<BranchStats> = self.0.into_values().collect();
        rows.sort_by(|a, b| b.working_ms.cmp(&a.working_ms).then(b.turns.cmp(&a.turns)));
        rows.truncate(MAX_BRANCHES);
        rows
    }
}

/// The spend a `turn_result` recorded (`hub/turn_usage.rs`).
pub(super) fn turn_usage(msg: &Value) -> TurnUsage {
    let count = |key: &str| msg.get(key).and_then(Value::as_u64);
    TurnUsage {
        cost_usd: msg
            .get("costUsd")
            .and_then(Value::as_f64)
            .filter(|cost| cost.is_finite() && *cost >= 0.0),
        input_tokens: count("inputTokens"),
        output_tokens: count("outputTokens"),
        cache_read_tokens: count("cacheReadTokens"),
        cache_write_tokens: count("cacheWriteTokens"),
    }
}
