//! A plan build's record, kept on the plan's chat (`SessionMeta::plan_builds`): the builds
//! themselves start and compare in `hub/plan_build.rs`.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Arc;

/// One plan build, kept on the plan's chat (`SessionMeta::plan_builds`) by acpmux alone: which
/// chats are its builds, and each one's worktree root and base as its start made them. Tags would
/// not do: a build's agent can set its own chat's tags (`_acpmux/tag`), and compare runs git in
/// the root it names.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanBuildRecord {
    pub build_id: String,
    pub builds: Vec<PlanBuildEntry>,
    /// The build kept (`_acpmux/plan/keep`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kept: Option<String>,
}

/// Whether a chat has no plan builds (`SessionMeta::plan_builds` is then left out).
pub(crate) fn no_records(records: &Arc<Vec<PlanBuildRecord>>) -> bool {
    records.is_empty()
}

/// One build of a [`PlanBuildRecord`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanBuildEntry {
    pub session_id: String,
    /// Its worktree's root, from the start (the chat's folder is the started-from folder's place
    /// in the worktree).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root: Option<PathBuf>,
    /// The branch its worktree was made from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
}
