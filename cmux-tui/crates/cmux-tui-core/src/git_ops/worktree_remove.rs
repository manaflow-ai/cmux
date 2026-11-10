//! `git.worktree.remove`: a worktree chat's cleanup. The linked worktree's
//! folder goes (`git worktree remove`, run from the main checkout), with its
//! ignored files, and so does its branch when `git.worktree.create` made it
//! (`cmux_git::worktree::branch_goes_with_worktree`: a branch it made, named
//! or `cmux/<name>`), with the branch's settings; a branch that was there
//! before stays.
//!
//! Work that lives only there keeps it (`cmux_git::worktree::work_kept`, the
//! same check `acpmux worktree remove` makes): uncommitted changes (tracked or
//! untracked files) and commits on no other branch and no remote, on a
//! detached HEAD or on the branch that goes; the refusal names `--discard`.
//! `discard` removes it anyway. It
//! is checked again right before the folder and before the branch go, so a
//! commit made meanwhile is never lost without `discard`: a branch with new
//! commits stays. The main checkout and other worktrees are never touched.
//! The journal keeps the attempt, so a retry after a timeout finishes what
//! the first run started.
//!
//! Before the folder goes, a setup still running there is stopped and the
//! project's teardown runs in it (`worktree_setup`), once; its exit and
//! output are in the reply, and a failed teardown does not keep the
//! worktree. The worktree was clean when the removal began, so what the
//! teardown leaves there goes with it; commits found nowhere else still
//! keep it. Its ports go back once it is gone.
//!
//! The reply names the worktree as `git.worktree.create` printed it, under
//! the `~/.cmux/worktrees` link rather than its `.noindex` folder, and the
//! project folder in the worktree root goes with its last worktree.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::checkpoint::ledger;
use super::journal::Journal;
use super::mutation::{Target, key, output_extra, refused, run_failed};
use super::user_run::{UserGit, deadline};
use super::{MAX_SMALL_OUTPUT_BYTES, Repository, worktree_recipe, worktree_setup};
use crate::Mux;
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;
use cmux_git::worktree::{self as shared, KeptWork};
use cmux_json::JsonSet as _;

const OPERATION: &str = "git.worktree.remove";

/// A started removal, as the journal keeps it.
#[derive(Debug, Serialize, Deserialize)]
struct Attempt {
    root: PathBuf,
    main_root: PathBuf,
    branch: Option<String>,
    /// The branch goes too: `git.worktree.create` made it.
    delete_branch: bool,
    discard: bool,
    /// A teardown runs before the removal: the worktree was clean when the
    /// removal was planned, so what the teardown leaves in it goes too.
    #[serde(default)]
    teardown: bool,
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
        let mut teardown = None;
        let attempt = match journal.attempt::<Attempt>(&fingerprint) {
            Some(attempt) => attempt,
            None => {
                let discard = request.fields.get("discard").and_then(Value::as_bool) == Some(true);
                let mut attempt = plan(&target.repository, discard)?;
                let script =
                    worktree_recipe::resolve(mux, Some(&attempt.main_root), &attempt.main_root)
                        .recipe
                        .teardown;
                attempt.teardown = script.is_some();
                journal.start(&fingerprint, &attempt)?;
                teardown = run_teardown(&attempt, target.git_dir(), script.as_deref());
                attempt
            }
        };
        // Resolved while the folder is still there: the ports are kept by it.
        let resolved_root = worktree_setup::resolved(&attempt.root);
        let home = crate::platform::home_dir();
        let printed_root = match &home {
            Some(home) => shared::shown(home, &attempt.root),
            None => attempt.root.clone(),
        };
        let result = remove(&target.repository, &attempt);
        if result.is_ok() {
            worktree_setup::removed(target.git_dir(), &resolved_root);
            if let Some(home) = &home {
                shared::remove_empty_project_folder(home, &attempt.root);
            }
        }
        if !result.as_ref().is_err_and(|error| error.details["reason"] == "timed_out") {
            journal.finish();
        }
        let branch_deleted = result?;
        let mut value = json!({
            "root": printed_root.to_string_lossy(),
            "main_root": attempt.main_root.to_string_lossy(),
            "branch_deleted": branch_deleted,
        });
        if let Some(branch) = &attempt.branch {
            value.set("branch", json!(branch));
        }
        if let Some(teardown) = teardown {
            value.set("teardown", teardown);
        }
        ledger::commit(mux, &key, OPERATION, &fingerprint, &value, false, &request.actor)
    })
}

/// Stops the worktree's setup and runs the project's teardown in it; what
/// the reply says of the teardown. It runs once, before the first try.
fn run_teardown(attempt: &Attempt, git_dir: &Path, script: Option<&str>) -> Option<Value> {
    let place = worktree_setup::Place {
        root: worktree_setup::resolved(&attempt.root),
        main_root: Some(attempt.main_root.clone()),
        git_dir: git_dir.to_path_buf(),
    };
    worktree_setup::teardown(&place, script)
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
    let delete_branch = branch
        .as_deref()
        .is_some_and(|branch| shared::branch_goes_with_worktree(repository, branch));
    let attempt = Attempt {
        root: repository.root.clone(),
        main_root,
        branch,
        delete_branch,
        discard,
        teardown: false,
    };
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
    let kept = shared::work_kept(repository, attempt.branch.as_deref(), attempt.delete_branch)
        .map_err(|failure| run_failed(OPERATION, &failure))?;
    kept.map_or(Ok(()), |kept| Err(kept_refusal(&kept)))
}

/// Refused while the worktree has commits that only its HEAD reaches.
fn unpushed(repository: &Repository, attempt: &Attempt) -> Result<(), ResourceError> {
    let kept = shared::unpushed(repository, attempt.branch.as_deref(), attempt.delete_branch)
        .map_err(|failure| run_failed(OPERATION, &failure))?;
    kept.map_or(Ok(()), |kept| Err(kept_refusal(&kept)))
}

/// The refusal for work the removal keeps; its message names `--discard`.
fn kept_refusal(kept: &KeptWork) -> ResourceError {
    let extra = match kept {
        KeptWork::Uncommitted { files, count, .. } => json!({"files": files, "count": count}),
        KeptWork::Unpushed { branch, count } => json!({"branch": branch, "count": count}),
    };
    refused(OPERATION, kept.reason(), kept.message(), extra)
}

/// How many of `revision`'s commits are on no branch but `branch` and on no
/// remote.
fn only_here(
    repository: &Repository,
    revision: &str,
    branch: Option<&str>,
) -> Result<u64, ResourceError> {
    shared::commits_only_on(repository, revision, branch)
        .map_err(|failure| run_failed(OPERATION, &failure))
}

/// Removes the worktree (unless a timed-out run already did) and then its
/// branch; whether the branch went.
fn remove(repository: &Repository, attempt: &Attempt) -> Result<bool, ResourceError> {
    let git = UserGit { root: &attempt.main_root, deadline: deadline() };
    if attempt.root.exists() && !attempt.discard {
        // After a teardown only commits are kept: its own files go.
        if attempt.teardown {
            unpushed(&repository.within(deadline()), attempt)?;
        } else {
            guard(repository, attempt)?;
        }
    }
    if let Some(listed) = registered(&git, &attempt.root)? {
        let mut arguments = vec!["worktree", "remove"];
        if attempt.discard || attempt.teardown {
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
    let wanted = shared::resolved(root);
    Ok(run
        .stdout
        .split(|byte| *byte == b'\n')
        .filter_map(|line| line.strip_prefix(b"worktree "))
        .map(|path| String::from_utf8_lossy(path).into_owned())
        .find(|path| shared::resolved(Path::new(path)) == wanted))
}
