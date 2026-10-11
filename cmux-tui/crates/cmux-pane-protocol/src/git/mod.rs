//! `cmux.git.status` and `cmux.git.diff`: declarations, types, and the
//! provider-side implementation.
//!
//! The implementation sits behind [`GitBackend`] so the daemon can plug in
//! its own git layer later. [`CommandGit`] is the built-in backend: a small
//! bounded git runner with the same hardening as cmux-tui-core's git reads
//! (no `GIT_*` environment, no fsmonitor, no external diff or textconv, a
//! deadline). cmux-tui-core's `git_ops` are crate-private and that crate
//! links the terminal core, so this crate does not depend on it.

mod command;

use std::future::Future;
use std::sync::Arc;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

pub use command::CommandGit;

use crate::error::ErrorBody;
use crate::provider::Provider;

pub const NOT_A_REPO: &str = "cmux.git.not_a_repo";
pub const BAD_REF: &str = "cmux.git.bad_ref";

/// Params of `cmux.git.status`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GitStatusParams {
    /// Absolute path inside the working tree.
    pub cwd: String,
}

/// One changed path. `index` and `worktree` are git's porcelain v1 status
/// letters for the staged and unstaged side: ` ` unmodified, `M`, `A`,
/// `D`, `R`, `C`, `U`, and `?` for untracked.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GitFileStatus {
    pub path: String,
    pub index: String,
    pub worktree: String,
}

/// Working tree status.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
#[schemars(transform = crate::ir::require_all)]
pub struct GitStatus {
    /// The checked-out branch; null when HEAD is detached.
    #[serde(deserialize_with = "crate::ir::nullable")]
    pub branch: Option<String>,
    pub files: Vec<GitFileStatus>,
}

/// Params of `cmux.git.diff`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GitDiffParams {
    /// Absolute path inside the working tree.
    pub cwd: String,
    /// Compare the working tree with this commit; null or absent means HEAD
    /// (the empty tree before the first commit). Untracked files are not
    /// part of the diff.
    #[serde(default)]
    pub base: Option<String>,
    /// Include each file's unified patch.
    #[serde(default)]
    pub include_patch: bool,
}

/// One changed file. A binary file has 0 additions and 0 deletions.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GitDiffFile {
    pub path: String,
    pub additions: u64,
    pub deletions: u64,
    /// The unified patch, when requested and within the size limit.
    #[serde(default)]
    pub patch: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GitDiff {
    pub files: Vec<GitDiffFile>,
}

crate::pane_op! {
    /// Working tree status of the repository containing `cwd`.
    pub GitStatusOp {
        name: "cmux.git.status", kind: Read, scope: "git:read",
        params: GitStatusParams, result: GitStatus,
        errors: ["cmux.git.not_a_repo"],
        paths: ["cwd"],
        mcp: Default in "git",
        cli: "git status",
    }
}

crate::pane_op! {
    /// Per-file line counts (and optionally patches) of the working tree
    /// against `base`.
    pub GitDiffOp {
        name: "cmux.git.diff", kind: Read, scope: "git:read",
        params: GitDiffParams, result: GitDiff,
        errors: ["cmux.git.not_a_repo", "cmux.git.bad_ref"],
        paths: ["cwd"],
        mcp: Default in "git",
        cli: "git diff" positional ["base"],
    }
}

crate::pane_event! {
    /// The status of a watched working tree changed.
    pub GitStatusChanged { name: "cmux.git.status.changed", scope: "git:read", data: GitStatus }
}

/// The git layer a provider serves `cmux.git.*` from.
pub trait GitBackend: Send + Sync + 'static {
    fn status(
        &self,
        params: GitStatusParams,
    ) -> impl Future<Output = Result<GitStatus, ErrorBody>> + Send;
    fn diff(
        &self,
        params: GitDiffParams,
    ) -> impl Future<Output = Result<GitDiff, ErrorBody>> + Send;
}

/// Register `cmux.git.status` and `cmux.git.diff` on `provider`.
pub fn register<B: GitBackend>(provider: &mut Provider, backend: Arc<B>) {
    let status_backend = backend.clone();
    provider.handle::<GitStatusOp, _, _>(move |_claims, params| {
        let backend = status_backend.clone();
        async move { backend.status(params).await }
    });
    provider.handle::<GitDiffOp, _, _>(move |_claims, params| {
        let backend = backend.clone();
        async move { backend.diff(params).await }
    });
}
