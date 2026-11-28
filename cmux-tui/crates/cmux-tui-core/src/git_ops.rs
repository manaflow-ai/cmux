//! `git.diff`, `git.fingerprint`, `git.status`, `git.branches`, `git.files.search` and `git.files.list`: read-only
//! git reads of the repository a path or a terminal's working directory is in. The session host answers them
//! without store state; a connection's request runs git on the daemon's git lane
//! (`server/git_lane.rs`), never on the connection's reader thread,
//! bounded by a deadline and output limits. `git.status` reads the refs only
//! (`cmux_git::head`), not the work tree. `git.fingerprint` says if a diff is
//! still current without making it (`fingerprint`). `git.checkpoint.*` captures
//! immutable checkpoints through a separate write runner (`checkpoint`).
//! `git.commit` and `git.push` are the user's own actions and run git in the
//! user's environment (`user_run`), keyed in the mutation ledger
//! (`mutation`), and so do `git.worktree.create`, a chat's own worktree
//! (`worktree`), and `git.worktree.apply`, which brings its work back to the
//! main checkout (`worktree_apply`), and `git.worktree.remove`, its cleanup
//! (`worktree_remove`). `git.worktree.setup` reads a repository's worktree
//! recipe and a worktree's setup run (`worktree_setup`). `project.actions.list`
//! reads a project's `.cmux/actions.json` with the global actions (`project_actions`). `diff.comments.*`
//! keeps the diff page's review comments per worktree root until they are
//! sent (`diff_comments`). `git.review.*` reviews a GitHub pull request
//! from its link in a worktree of its own, with those comments as its
//! drafts (`pr_review`). The pure git pieces (bounded runs, the repository
//! handle, parsers, diff scopes and branch refs) live in the `cmux-git`
//! crate, which the diff sidecar links too.

use cmux_json::JsonSet as _;

mod checkpoint;
mod commit;
mod commit_args;
mod diff;
mod diff_comments;
mod diff_pages;
mod files;
#[cfg(all(test, unix))]
mod files_stress_tests;
mod fingerprint;
mod journal;
mod list;
mod mutation;
mod pr_review;
mod project_actions;
mod push;
mod read_cache;
#[cfg(all(test, unix))]
mod read_cache_tests;
#[cfg(test)]
mod read_probe;
mod target;
mod user_run;
mod work_tree_entry;
mod worktree;
mod worktree_apply;
mod worktree_include;
mod worktree_recipe;
mod worktree_remove;
mod worktree_setup;

pub(crate) use pr_review::POST as REVIEW_POST_OPERATION;

use std::path::Path;
use std::sync::Arc;

use cmux_git::head::Checkout;
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

/// Advertised in identify: the session host answers `git.fingerprint`.
pub(crate) const FINGERPRINT_CAPABILITY: &str = "git-fingerprint-v1";

/// Advertised in identify: the session host owns `diff.comments.list`,
/// `save` and `delete`.
pub(crate) const DIFF_COMMENTS_CAPABILITY: &str = diff_comments::CAPABILITY;

/// Advertised in identify: the session host owns `git.review.start`,
/// `comment` and `post`.
pub(crate) const REVIEW_CAPABILITY: &str = pr_review::CAPABILITY;

/// Advertised in identify: the session host answers `diff.comments.send`.
pub(crate) const DIFF_COMMENTS_SEND_CAPABILITY: &str = diff_comments::SEND_CAPABILITY;

/// Advertised in identify: the session host keeps review threads.
pub(crate) const DIFF_COMMENTS_THREADS_CAPABILITY: &str = diff_comments::THREADS_CAPABILITY;

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

/// Advertised in identify: a new worktree is set up from the project's
/// recipe, and the session host answers `git.worktree.setup`.
pub(crate) const WORKTREE_SETUP_CAPABILITY: &str = "git-worktree-setup-v1";

/// Advertised in identify: a repository recipe's setup waits for the
/// person's approval, and the session host answers `git.worktree.setup.run`.
pub(crate) const WORKTREE_SETUP_RUN_CAPABILITY: &str = "git-worktree-setup-run-v1";

pub(crate) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::GitDiff
            | ResourceOperation::GitStatus
            | ResourceOperation::GitBranches
            | ResourceOperation::GitFilesSearch
            | ResourceOperation::GitFilesList
            | ResourceOperation::GitFingerprint
            | ResourceOperation::GitCommit
            | ResourceOperation::GitPush
            | ResourceOperation::GitWorktreeCreate
            | ResourceOperation::GitWorktreeApply
            | ResourceOperation::GitWorktreeRemove
            | ResourceOperation::GitWorktreeSetup
            | ResourceOperation::GitWorktreeSetupRun
            | ResourceOperation::ProjectActionsList
    ) || checkpoint::handles(operation)
        || diff_comments::handles(operation)
        || pr_review::handles(operation)
}

pub(crate) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    debug_assert!(handles(request.envelope.operation));
    if checkpoint::handles(request.envelope.operation) {
        return checkpoint::dispatch(mux, request);
    }
    if diff_comments::handles(request.envelope.operation) {
        return diff_comments::dispatch(mux, &request);
    }
    let changed = match request.envelope.operation {
        // A review's start fetches and makes a worktree: it moves refs too.
        operation if pr_review::handles(operation) => Some(pr_review::dispatch(mux, &request)),
        ResourceOperation::GitCommit => Some(commit::dispatch(mux, &request)),
        ResourceOperation::GitPush => Some(push::dispatch(mux, &request)),
        ResourceOperation::GitWorktreeCreate => Some(worktree::dispatch(mux, &request)),
        ResourceOperation::GitWorktreeApply => Some(worktree_apply::dispatch(mux, &request)),
        ResourceOperation::GitWorktreeRemove => Some(worktree_remove::dispatch(mux, &request)),
        ResourceOperation::GitWorktreeSetup => return worktree_setup::dispatch(mux, &request),
        ResourceOperation::GitWorktreeSetupRun => {
            return worktree_setup::dispatch_run(mux, &request);
        }
        ResourceOperation::ProjectActionsList => return project_actions::dispatch(mux, &request),
        _ => None,
    };
    if let Some(result) = changed {
        // The daemon moved a repository itself (also when the run failed
        // part way): every cached read is read again before its next answer.
        read_cache::invalidate_all();
        return result;
    }
    let operation = match request.envelope.operation {
        ResourceOperation::GitDiff => "git.diff",
        ResourceOperation::GitStatus => "git.status",
        ResourceOperation::GitBranches => "git.branches",
        ResourceOperation::GitFilesSearch => "git.files.search",
        ResourceOperation::GitFilesList => "git.files.list",
        ResourceOperation::GitFingerprint => "git.fingerprint",
        other => unreachable!("git_ops does not handle {other:?}"),
    };
    let directory = target::directory(mux, &request, operation)?;
    if operation == "git.status" {
        let github = request.fields.get("github").and_then(Value::as_bool).unwrap_or(false);
        return status_reply(&directory, github);
    }
    if operation == "git.fingerprint" {
        return fingerprint::read(&directory, &request.fields);
    }
    if operation == "git.branches" {
        return branches_reply(&directory, &request.fields);
    }
    if operation == "git.files.list" {
        // A folder in no repository still lists, from the disk: git only adds to a file tree.
        return match Repository::open(&directory) {
            // The home folder's repository holds every folder of the home
            // folder: its listing would walk all of them (`cmux_git::home`).
            Ok(repository) if !repository.lists_untracked() => {
                list::list_folder(&directory, &request.fields)
            }
            Ok(repository) => list::list(&repository, &directory, &request.fields),
            Err(OpenError::NotARepository) => list::list_folder(&directory, &request.fields),
            Err(error) => Err(open_failed(operation, &directory, error)),
        };
    }
    let repository = open_repository(&directory, operation)?;
    match operation {
        "git.diff" => diff::read(&repository, &request.fields),
        _ => files::search(&repository, &directory, &request.fields),
    }
}

/// The repository `directory` is in, as `operation`'s errors.
fn open_repository(directory: &Path, operation: &'static str) -> Result<Repository, ResourceError> {
    Repository::open(directory).map_err(|error| open_failed(operation, directory, error))
}

fn open_failed(operation: &'static str, directory: &Path, error: OpenError) -> ResourceError {
    match error {
        OpenError::NotARepository => not_a_repository(operation, directory),
        OpenError::Git(failure) => git_failed(operation, &failure),
    }
}

/// `git.status` of `directory`, from the cache while HEAD, the refs and the
/// config are as they were (`read_cache`).
fn status_reply(directory: &Path, github: bool) -> Result<Value, ResourceError> {
    let at = directory.to_path_buf();
    read_cache::status(directory, github, move || status(&at, github))
}

/// `git.branches` of the repository `directory` is in.
fn branches_reply(
    directory: &Path,
    fields: &serde_json::Map<String, Value>,
) -> Result<Value, ResourceError> {
    let limit = fields.get("limit").and_then(Value::as_u64);
    let (at, fields) = (directory.to_path_buf(), fields.clone());
    read_cache::branches(directory, limit, move || {
        let repository = open_repository(&at, "git.branches")?;
        let root = repository.root.clone();
        let git_dir = repository.git_dir().to_path_buf();
        // Taken before the reads, so a ref that moves during them leaves the
        // answer stale.
        let stamp = read_cache::refs_stamp(&root, &git_dir);
        let value = branches(&at, &repository, &fields)?;
        Ok(read_cache::RefsRead { value, root, git_dir, stamp })
    })
}

/// What HEAD of the checkout `directory` is in is on. A view that shows a
/// branch asks this often and a person waits for it, so it comes from the
/// refs (`cmux_git::head`): no run looks at the work tree's files, whose
/// count would set the cost. `github` adds `github_repo`, the `owner/name`
/// of the upstream's remote (else `origin`) on github.com: one more git run,
/// so only a caller that asks pays it.
fn status(directory: &Path, github: bool) -> Result<read_cache::RefsRead, ResourceError> {
    const OPERATION: &str = "git.status";
    #[cfg(test)]
    read_probe::ran(read_probe::Read::Status, directory);
    let repository =
        Checkout::open(directory).map_err(|error| open_failed(OPERATION, directory, error))?;
    let root = repository.root().to_path_buf();
    let git_dir = repository.git_dir().to_path_buf();
    // Taken before the reads, so a ref that moves during them leaves the
    // answer stale.
    let stamp = read_cache::refs_stamp(&root, &git_dir);
    let headers = repository.head().map_err(|failure| git_failed(OPERATION, &failure))?;
    let mut value = json!({
        "root":repository.root().to_string_lossy(),
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
    if github {
        let remote = headers
            .upstream
            .as_deref()
            .and_then(|upstream| upstream.split_once('/'))
            .map_or("origin", |(remote, _)| remote);
        if let Some(repo) = repository.github_repo(remote) {
            value.set("github_repo", json!(repo));
        }
    }
    if let Some(upstream) = headers.upstream {
        value.set("upstream", json!(upstream));
    }
    if let Some((_, base)) = repository.base_branch() {
        value.set("base", json!(base));
    }
    let layout = repository.layout();
    if let Some(main) = layout.main_checkout {
        value.set("worktree", json!({"main_root": main.to_string_lossy()}));
    }
    // A view offers no Commit (git.commit refuses merge_in_progress) and no
    // Apply (git.worktree.apply refuses unmerged) while this is set.
    if let Some(state) = layout.in_progress {
        value.set("in_progress", json!(state));
    }
    Ok(read_cache::RefsRead { value, root, git_dir, stamp })
}

/// Local, then remote branches, with HEAD's branch and the bases a branch
/// diff may compare with (`cmux_git::refs`).
fn branches(
    directory: &Path,
    repository: &Repository,
    fields: &serde_json::Map<String, Value>,
) -> Result<Value, ResourceError> {
    #[cfg(test)]
    read_probe::ran(read_probe::Read::Branches, directory);
    #[cfg(not(test))]
    let _ = directory;
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
