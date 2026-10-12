//! `git.worktree.remove`: a worktree chat's cleanup. The linked worktree's
//! folder goes (`git worktree remove`, run from the main checkout), and so
//! does its branch when `git.worktree.create` made it (`cmux/<name>`, with a
//! recorded base), with the branch's settings.
//!
//! Work that lives only there keeps it: uncommitted changes (tracked or
//! untracked files) and commits that are on no other branch and no remote.
//! `discard` removes it anyway. The main checkout is never touched. The
//! journal keeps the attempt, so a retry after a lost reply finishes what
//! the first run started instead of refusing a half-removed worktree.

use std::path::PathBuf;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::checkpoint::ledger;
use super::journal::Journal;
use super::mutation::{Target, key, output_extra, refused, run_failed};
use super::push::current_branch;
use super::user_run::{UserGit, deadline};
use super::{MAX_SMALL_OUTPUT_BYTES, MAX_STATUS_BYTES, Repository};
use crate::Mux;
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;

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
        let result = remove(&attempt);
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
            value["branch"] = json!(branch);
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
    let branch = current_branch(repository);
    let delete_branch = branch.as_deref().is_some_and(|branch| {
        branch.starts_with(super::worktree::BRANCH_PREFIX) && repository.recorded_base().is_some()
    });
    if !discard {
        let arguments = ["status", "--porcelain", "-z", "--untracked-files=all", "--no-renames"];
        let output = repository
            .run(&arguments, MAX_STATUS_BYTES)
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
        if let Some(branch) = &branch {
            // Commits on no other branch and no remote live only here.
            let exclude = format!("--exclude={branch}");
            let arguments = [
                "rev-list",
                "--count",
                "HEAD",
                "--not",
                exclude.as_str(),
                "--branches",
                "--remotes",
            ];
            let output = repository
                .run(&arguments, MAX_SMALL_OUTPUT_BYTES)
                .map_err(|failure| run_failed(OPERATION, &failure))?;
            let count = String::from_utf8_lossy(&output.stdout).trim().parse::<u64>().unwrap_or(0);
            if count > 0 {
                let message = format!("{branch} has {count} commits on no other branch or remote");
                let extra = json!({"branch": branch, "count": count});
                return Err(refused(OPERATION, "unpushed_commits", message, extra));
            }
        }
    }
    Ok(Attempt { root: repository.root.clone(), main_root, branch, delete_branch, discard })
}

/// Removes the worktree (unless a lost reply's run already did) and then its
/// branch; whether the branch went.
fn remove(attempt: &Attempt) -> Result<bool, ResourceError> {
    let git = UserGit { root: &attempt.main_root, deadline: deadline() };
    let root = attempt.root.to_string_lossy();
    if attempt.root.exists() {
        let mut arguments = vec!["worktree", "remove"];
        if attempt.discard {
            arguments.push("--force");
        }
        arguments.push(root.as_ref());
        let run = git.run(&arguments).map_err(|failure| run_failed(OPERATION, &failure))?;
        if !run.success && attempt.root.exists() {
            let message = "git worktree remove failed";
            return Err(refused(OPERATION, "git_failed", message, output_extra(&run.output())));
        }
    }
    // A folder deleted by hand leaves git's record of it behind.
    let _ = git.run(&["worktree", "prune"]);
    let Some(branch) = attempt.branch.as_deref().filter(|_| attempt.delete_branch) else {
        return Ok(false);
    };
    let reference = format!("refs/heads/{branch}");
    let exists = git
        .run(&["show-ref", "--verify", "--quiet", reference.as_str()])
        .map_err(|failure| run_failed(OPERATION, &failure))?;
    if !exists.success {
        return Ok(true);
    }
    // `branch -D` drops the branch's settings with it, the recorded base too.
    let run =
        git.run(&["branch", "-D", branch]).map_err(|failure| run_failed(OPERATION, &failure))?;
    if !run.success {
        let message = "the worktree was removed, but deleting its branch failed";
        return Err(refused(OPERATION, "git_failed", message, output_extra(&run.output())));
    }
    Ok(true)
}
