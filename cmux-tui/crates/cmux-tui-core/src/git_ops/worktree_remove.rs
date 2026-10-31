//! `git.worktree.remove`: a worktree chat's cleanup. The linked worktree's
//! folder goes (`git worktree remove`, run from the main checkout), with its
//! ignored files, and so does its branch when `git.worktree.create` made it
//! (`cmux/<name>` with a recorded base), with the branch's settings.
//!
//! Work that lives only there keeps it: uncommitted changes (tracked or
//! untracked files) and commits on no other branch and no remote, on a
//! detached HEAD or on the branch that goes. `discard` removes it anyway. It
//! is checked again right before the folder and before the branch go, so a
//! commit made meanwhile is never lost without `discard`: a branch with new
//! commits stays. The main checkout and other worktrees are never touched.
//! The journal keeps the attempt, so a retry after a timeout finishes what
//! the first run started.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::checkpoint::ledger;
use super::journal::Journal;
use super::mutation::{Target, key, output_extra, refused, run_failed};
use super::user_run::{UserGit, deadline};
use super::worktree::BRANCH_PREFIX;
use super::{MAX_SMALL_OUTPUT_BYTES, MAX_STATUS_BYTES, Repository};
use crate::Mux;
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;
use cmux_json::JsonSet as _;

const OPERATION: &str = "git.worktree.remove";
/// The uncommitted paths a refusal lists.
const MAX_LISTED_FILES: usize = 20;

/// A started removal, as the journal keeps it.
#[derive(Debug, Serialize, Deserialize)]
struct Attempt {
    root: PathBuf,
    main_root: PathBuf,
    branch: Option<String>,
    /// The branch goes too: `git.worktree.create` made it.
    delete_branch: bool,
    discard: bool,
}

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let key = key(request);
    let target = Target::resolve(mux, request, OPERATION)?;
    let fingerprint = target.fingerprint(request);
    target.exclusive(OPERATION, || {
        if let Some(replayed) = ledger::prior(mux, &key, OPERATION, &fingerprint)? {
            return Ok(replayed);
        }
        let journal = Journal::open(mux, &target.identity(), &key, OPERATION)?;
        let attempt = match journal.attempt::<Attempt>(&fingerprint) {
            Some(attempt) => attempt,
            None => {
                let discard = request.fields.get("discard").and_then(Value::as_bool) == Some(true);
                let attempt = plan(&target.repository, discard)?;
                journal.start(&fingerprint, &attempt)?;
                attempt
            }
        };
        let result = remove(&target.repository, &attempt);
        if !result.as_ref().is_err_and(|error| error.details["reason"] == "timed_out") {
            journal.finish();
        }
        let branch_deleted = result?;
        let mut value = json!({
            "root": attempt.root.to_string_lossy(),
            "main_root": attempt.main_root.to_string_lossy(),
            "branch_deleted": branch_deleted,
        });
        if let Some(branch) = &attempt.branch {
            value.set("branch", json!(branch));
        }
        ledger::commit(mux, &key, OPERATION, &fingerprint, &value, false, &request.actor)
    })
}

/// The worktree to remove, refused while it holds work found nowhere else
/// (unless `discard`).
fn plan(repository: &Repository, discard: bool) -> Result<Attempt, ResourceError> {
    let Some(main_root) = repository.main_checkout() else {
        let message = "this is no linked worktree: the main checkout is never removed";
        return Err(refused(OPERATION, "not_a_worktree", message, Value::Null));
    };
    // The full ref: `--short` names `heads/<b>` when a tag shares the name.
    let branch = repository
        .run(&["symbolic-ref", "--quiet", "HEAD"], MAX_SMALL_OUTPUT_BYTES)
        .ok()
        .and_then(|output| {
            let head = String::from_utf8_lossy(&output.stdout).trim().to_string();
            head.strip_prefix("refs/heads/").map(str::to_string)
        });
    let delete_branch = branch.as_deref().is_some_and(|branch| {
        let setting = format!("branch.{branch}.cmuxBase");
        branch.starts_with(BRANCH_PREFIX)
            && repository
                .run(&["config", "--get", setting.as_str()], MAX_SMALL_OUTPUT_BYTES)
                .is_ok()
    });
    let attempt =
        Attempt { root: repository.root.clone(), main_root, branch, delete_branch, discard };
    if !discard {
        guard(repository, &attempt)?;
    }
    Ok(attempt)
}

/// Refused while the worktree has uncommitted changes, or commits that only
/// its HEAD reaches: on a detached HEAD, or on the branch that goes with it.
fn guard(repository: &Repository, attempt: &Attempt) -> Result<(), ResourceError> {
    // One deadline for every run here, the submodule search included.
    let repository = &repository.within(deadline());
    let arguments = [
        "status",
        "--porcelain",
        "-z",
        "--untracked-files=all",
        "--no-renames",
        "--ignore-submodules=none",
    ];
    // Submodules stay in the status (a changed one is work to keep, even one
    // `submodule.<name>.ignore` hides), so their own filter drivers are
    // blanked too.
    let output = repository
        .with_submodule_filters()
        .and_then(|repository| repository.run(&arguments, MAX_STATUS_BYTES))
        .map_err(|failure| run_failed(OPERATION, &failure))?;
    let files: Vec<String> = output
        .stdout
        .split(|byte| *byte == 0)
        .filter_map(|entry| entry.get(3..))
        .filter(|path| !path.is_empty())
        .map(|path| String::from_utf8_lossy(path).into_owned())
        .collect();
    if !files.is_empty() || output.truncated {
        let message = "the worktree has uncommitted changes";
        let listed: Vec<&String> = files.iter().take(MAX_LISTED_FILES).collect();
        let extra = json!({"files": listed, "count": files.len()});
        return Err(refused(OPERATION, "uncommitted_changes", message, extra));
    }
    if attempt.branch.is_some() && !attempt.delete_branch {
        return Ok(());
    }
    let count = only_here(repository, "HEAD", attempt.branch.as_deref())?;
    if count > 0 {
        let at = attempt.branch.as_deref().unwrap_or("the detached HEAD");
        let message = format!("{at} has {count} commits on no other branch or remote");
        let extra = json!({"branch": attempt.branch, "count": count});
        return Err(refused(OPERATION, "unpushed_commits", message, extra));
    }
    Ok(())
}

/// How many of `revision`'s commits are on no branch but `branch` and on no
/// remote.
fn only_here(
    repository: &Repository,
    revision: &str,
    branch: Option<&str>,
) -> Result<u64, ResourceError> {
    let exclude = branch.map(|branch| format!("--exclude={branch}"));
    let mut arguments = vec!["rev-list", "--count", revision, "--not"];
    arguments.extend(exclude.as_deref());
    arguments.extend(["--branches", "--remotes"]);
    let output = repository
        .run(&arguments, MAX_SMALL_OUTPUT_BYTES)
        .map_err(|failure| run_failed(OPERATION, &failure))?;
    String::from_utf8_lossy(&output.stdout).trim().parse::<u64>().map_err(|_| {
        let message = "git rev-list --count answered no count";
        refused(OPERATION, "git_failed", message, Value::Null)
    })
}

/// Removes the worktree (unless a timed-out run already did) and then its
/// branch; whether the branch went.
fn remove(repository: &Repository, attempt: &Attempt) -> Result<bool, ResourceError> {
    let git = UserGit { root: &attempt.main_root, deadline: deadline() };
    if attempt.root.exists() && !attempt.discard {
        guard(repository, attempt)?;
    }
    if let Some(listed) = registered(&git, &attempt.root)? {
        let mut arguments = vec!["worktree", "remove"];
        if attempt.discard {
            arguments.push("--force");
        }
        arguments.push(listed.as_str());
        let run = git.run(&arguments).map_err(|failure| run_failed(OPERATION, &failure))?;
        if !run.success && registered(&git, &attempt.root)?.is_some() {
            let message = "git worktree remove failed";
            return Err(refused(OPERATION, "git_failed", message, output_extra(&run.output())));
        }
    }
    let Some(branch) = attempt.branch.as_deref().filter(|_| attempt.delete_branch) else {
        return Ok(false);
    };
    let main = super::open_repository(&attempt.main_root, OPERATION)?;
    let reference = format!("refs/heads/{branch}");
    if main.commit(&reference).is_none() {
        return Ok(true);
    }
    // A commit made since the check keeps the branch, the worktree gone.
    if !attempt.discard && only_here(&main, &reference, Some(branch))? > 0 {
        return Ok(false);
    }
    // `branch -D` drops the branch's settings with it, the recorded base
    // too. A branch git keeps (checked out elsewhere) stays: the worktree
    // is gone either way.
    let run =
        git.run(&["branch", "-D", branch]).map_err(|failure| run_failed(OPERATION, &failure))?;
    Ok(run.success)
}

/// The path git lists for the worktree at `root`, while git still has it.
fn registered(git: &UserGit<'_>, root: &Path) -> Result<Option<String>, ResourceError> {
    let run = git
        .run(&["worktree", "list", "--porcelain"])
        .map_err(|failure| run_failed(OPERATION, &failure))?;
    if !run.success {
        let message = "git worktree list failed";
        return Err(refused(OPERATION, "git_failed", message, output_extra(&run.output())));
    }
    let wanted = resolved(root);
    Ok(run
        .stdout
        .split(|byte| *byte == b'\n')
        .filter_map(|line| line.strip_prefix(b"worktree "))
        .map(|path| String::from_utf8_lossy(path).into_owned())
        .find(|path| resolved(Path::new(path)) == wanted))
}

/// `path` with symlinks resolved, through its parent once it is gone.
fn resolved(path: &Path) -> PathBuf {
    if let Ok(path) = std::fs::canonicalize(path) {
        return path;
    }
    match (path.parent().and_then(|parent| std::fs::canonicalize(parent).ok()), path.file_name()) {
        (Some(parent), Some(name)) => parent.join(name),
        _ => path.to_path_buf(),
    }
}
