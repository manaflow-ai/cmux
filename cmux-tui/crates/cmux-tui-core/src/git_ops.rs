//! `git.diff`, `git.status`, `git.branches`, `git.files.search` and `git.files.list`: read-only
//! git reads of the repository a path or a terminal's working directory is in. The session host answers them
//! without store state; each request runs git on its own connection thread,
//! bounded by a deadline and output limits. `git.checkpoint.*` captures
//! immutable checkpoints through a separate write runner (`checkpoint`).
//! `git.commit` and `git.push` are the user's own actions and run git in the
//! user's environment (`user_run`), keyed in the mutation ledger
//! (`mutation`), and so do `git.worktree.create`, a chat's own worktree
//! (`worktree`), and `git.worktree.apply`, which brings its work back to the
//! main checkout (`worktree_apply`), and `git.worktree.remove`, its cleanup
//! (`worktree_remove`). The pure git pieces (bounded runs, the repository
//! handle, parsers, diff scopes and branch refs) live in the `cmux-git`
//! crate, which the diff sidecar links too.

use cmux_json::JsonSet as _;

mod checkpoint;
mod commit;
mod commit_args;
mod diff;
mod diff_pages;
mod files;
mod journal;
mod list;
mod mutation;
mod push;
mod target;
mod user_run;
mod worktree;
mod worktree_apply;
mod worktree_remove;

use std::path::Path;
use std::sync::Arc;

use cmux_git::run::GitFailure;
use cmux_git::{OpenError, Repository, parse, refs, run, write_run};
use serde_json::{Value, json};

use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::ParsedResourceRequest;

const MAX_SMALL_OUTPUT_BYTES: usize = cmux_git::MAX_SMALL_OUTPUT_BYTES;
const MAX_STATUS_BYTES: usize = 256 * 1024;
/// Branches `git.branches` returns without a `limit`.
const DEFAULT_BRANCH_LIMIT: u64 = 200;

/// Advertised in identify: the session host owns `git.checkpoint.create`,
/// `get`, `list`, `pin` and `unpin`.
pub(crate) const CHECKPOINTS_CAPABILITY: &str = "git-checkpoints-v1";

/// Advertised in identify: the session host answers `git.files.search`.
pub(crate) const FILES_SEARCH_CAPABILITY: &str = "git-files-search-v1";

/// Advertised in identify: the session host answers `git.files.list`.
pub(crate) const FILES_LIST_CAPABILITY: &str = "git-files-list-v1";

/// Advertised in identify: the session host answers `git.branches`.
pub(crate) const BRANCHES_CAPABILITY: &str = "git-branches-v1";

/// Advertised in identify: the session host owns `git.commit`.
pub(crate) const COMMIT_CAPABILITY: &str = "git-commit-v1";

/// Advertised in identify: the session host owns `git.push`.
pub(crate) const PUSH_CAPABILITY: &str = "git-push-v1";

/// Advertised in identify: the session host owns `git.worktree.create`.
pub(crate) const WORKTREE_CAPABILITY: &str = "git-worktree-v1";

/// Advertised in identify: the session host owns `git.worktree.apply`.
pub(crate) const WORKTREE_APPLY_CAPABILITY: &str = "git-worktree-apply-v1";

/// Advertised in identify: the session host owns `git.worktree.remove`.
pub(crate) const WORKTREE_REMOVE_CAPABILITY: &str = "git-worktree-remove-v1";

pub(crate) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::GitDiff
            | ResourceOperation::GitStatus
            | ResourceOperation::GitBranches
            | ResourceOperation::GitFilesSearch
            | ResourceOperation::GitFilesList
            | ResourceOperation::GitCommit
            | ResourceOperation::GitPush
            | ResourceOperation::GitWorktreeCreate
            | ResourceOperation::GitWorktreeApply
            | ResourceOperation::GitWorktreeRemove
    ) || checkpoint::handles(operation)
}

pub(crate) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    debug_assert!(handles(request.envelope.operation));
    if checkpoint::handles(request.envelope.operation) {
        return checkpoint::dispatch(mux, request);
    }
    match request.envelope.operation {
        ResourceOperation::GitCommit => return commit::dispatch(mux, &request),
        ResourceOperation::GitPush => return push::dispatch(mux, &request),
        ResourceOperation::GitWorktreeCreate => return worktree::dispatch(mux, &request),
        ResourceOperation::GitWorktreeApply => return worktree_apply::dispatch(mux, &request),
        ResourceOperation::GitWorktreeRemove => return worktree_remove::dispatch(mux, &request),
        _ => {}
    }
    let operation = match request.envelope.operation {
        ResourceOperation::GitDiff => "git.diff",
        ResourceOperation::GitStatus => "git.status",
        ResourceOperation::GitBranches => "git.branches",
        ResourceOperation::GitFilesSearch => "git.files.search",
        ResourceOperation::GitFilesList => "git.files.list",
        other => unreachable!("git_ops does not handle {other:?}"),
    };
    let directory = target::directory(mux, &request, operation)?;
    let repository = open_repository(&directory, operation)?;
    match operation {
        "git.diff" => diff::read(&repository, &request.fields),
        "git.branches" => branches(&repository, &request.fields),
        "git.files.search" => files::search(&repository, &directory, &request.fields),
        "git.files.list" => list::list(&repository, &directory, &request.fields),
        _ => status(&repository),
    }
}

/// The repository `directory` is in, as `operation`'s errors.
fn open_repository(directory: &Path, operation: &'static str) -> Result<Repository, ResourceError> {
    Repository::open(directory).map_err(|error| match error {
        OpenError::NotARepository => not_a_repository(operation, directory),
        OpenError::Git(failure) => git_failed(operation, &failure),
    })
}

fn status(repository: &Repository) -> Result<Value, ResourceError> {
    let arguments = [
        "status",
        "--porcelain=v2",
        "--branch",
        "-z",
        "--untracked-files=no",
        "--ignore-submodules=all",
    ];
    let output = repository
        .run(&arguments, MAX_STATUS_BYTES)
        .map_err(|failure| git_failed("git.status", &failure))?;
    // The branch headers come first, so a cut listing still has them.
    let headers = parse::branch_headers(&output.stdout);
    let mut value = json!({
        "root":repository.root.to_string_lossy(),
        "detached":headers.branch.is_none(),
        "ahead":clamp(headers.ahead),
        "behind":clamp(headers.behind),
    });
    if let Some(branch) = headers.branch {
        value.set("branch", json!(branch));
    }
    if let Some(head) = headers.head {
        value.set("head", json!(head));
    }
    if let Some(upstream) = headers.upstream {
        value.set("upstream", json!(upstream));
    }
    if let Some((_, base)) = repository.base_branch() {
        value.set("base", json!(base));
    }
    if let Some(main) = repository.main_checkout() {
        value.set("worktree", json!({"main_root": main.to_string_lossy()}));
    }
    Ok(value)
}

/// Local, then remote branches, with HEAD's branch and the bases a branch
/// diff may compare with (`cmux_git::refs`).
fn branches(
    repository: &Repository,
    fields: &serde_json::Map<String, Value>,
) -> Result<Value, ResourceError> {
    let limit = fields.get("limit").and_then(Value::as_u64).unwrap_or(DEFAULT_BRANCH_LIMIT);
    let limit = usize::try_from(limit).unwrap_or(usize::MAX);
    let listing = refs::branches(repository, limit)
        .map_err(|failure| git_failed("git.branches", &failure))?;
    let branches = listing.branches.iter().map(branch_json).collect::<Vec<_>>();
    let suggested = refs::suggested_base(repository)
        .into_iter()
        .map(|base| json!({"name":base.name,"ref":base.reference,"reason":base.reason.as_str()}))
        .collect::<Vec<_>>();
    let mut value = json!({
        "root":repository.root.to_string_lossy(),
        "detached":listing.current.is_none(),
        "branches":branches,
        "truncated":listing.truncated,
        "suggested_bases":suggested,
    });
    if let Some(current) = listing.current {
        value.set("current", json!(current));
    }
    Ok(value)
}

fn branch_json(branch: &refs::BranchRef) -> Value {
    let mut value = json!({
        "name":branch.name,
        "ref":branch.reference,
        "kind":branch.kind.as_str(),
        "commit":branch.commit,
        "current":branch.current,
    });
    if let Some(upstream) = &branch.upstream {
        value.set("upstream", json!(upstream));
    }
    if branch.upstream_gone {
        value.set("upstream_gone", json!(true));
    }
    if let Some(ahead) = branch.ahead {
        value.set("ahead", json!(ahead));
    }
    if let Some(behind) = branch.behind {
        value.set("behind", json!(behind));
    }
    if let Some(committed_at) = branch.committed_at.and_then(|seconds| u32::try_from(seconds).ok())
    {
        value.set("committed_at", json!(committed_at));
    }
    value
}

fn clamp(count: u64) -> u32 {
    u32::try_from(count).unwrap_or(u32::MAX)
}

fn not_a_repository(operation: &'static str, directory: &Path) -> ResourceError {
    ResourceError::operation_failed(
        operation,
        format!("{} is not in a git repository", directory.display()),
        json!({"code":"not_a_repository","path":directory.to_string_lossy()}),
    )
}

fn git_failed(operation: &'static str, failure: &GitFailure) -> ResourceError {
    ResourceError::operation_failed(operation, failure.reason(), json!({"code":"git_failed"}))
}
