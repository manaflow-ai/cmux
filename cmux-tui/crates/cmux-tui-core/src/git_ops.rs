//! `git.diff`, `git.status` and `git.files.search`: read-only git reads of
//! the repository a path or a terminal's working directory is in. The session host answers them
//! without store state; each request runs git on its own connection thread,
//! bounded by a deadline and output limits. `git.checkpoint.*` captures
//! immutable checkpoints through a separate write runner (`checkpoint`).
//! `git.commit` and `git.push` are the user's own actions and run git in the
//! user's environment (`user_run`), keyed in the mutation ledger
//! (`mutation`).

mod checkpoint;
mod commit;
mod commit_journal;
mod diff;
mod files;
mod mutation;
mod parse;
mod push;
mod run;
mod target;
#[cfg(test)]
mod tests;
mod user_run;
mod write_run;
#[cfg(all(test, unix))]
mod write_tests;

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::{Value, json};

use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::ParsedResourceRequest;
use run::{GitFailure, GitOutput, run_git};

const MAX_SMALL_OUTPUT_BYTES: usize = 64 * 1024;
const MAX_STATUS_BYTES: usize = 256 * 1024;

/// Advertised in identify: the session host owns `git.checkpoint.create`,
/// `get`, `list`, `pin` and `unpin`.
pub(crate) const CHECKPOINTS_CAPABILITY: &str = "git-checkpoints-v1";

/// Advertised in identify: the session host answers `git.files.search`.
pub(crate) const FILES_SEARCH_CAPABILITY: &str = "git-files-search-v1";

/// Advertised in identify: the session host owns `git.commit`.
pub(crate) const COMMIT_CAPABILITY: &str = "git-commit-v1";

/// Advertised in identify: the session host owns `git.push`.
pub(crate) const PUSH_CAPABILITY: &str = "git-push-v1";

pub(crate) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::GitDiff
            | ResourceOperation::GitStatus
            | ResourceOperation::GitFilesSearch
            | ResourceOperation::GitCommit
            | ResourceOperation::GitPush
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
        _ => {}
    }
    let operation = match request.envelope.operation {
        ResourceOperation::GitDiff => "git.diff",
        ResourceOperation::GitStatus => "git.status",
        ResourceOperation::GitFilesSearch => "git.files.search",
        other => unreachable!("git_ops does not handle {other:?}"),
    };
    let directory = target::directory(mux, &request, operation)?;
    let repository = Repository::open(&directory, operation)?;
    match operation {
        "git.diff" => diff::read(&repository, &request.fields),
        "git.files.search" => files::search(&repository, &directory, &request.fields),
        _ => status(&repository),
    }
}

/// A repository's top level, which every run works from, and the config
/// overrides every run carries.
struct Repository {
    root: PathBuf,
    overrides: Vec<String>,
}

impl Repository {
    fn open(directory: &Path, operation: &'static str) -> Result<Self, ResourceError> {
        let arguments = ["rev-parse", "--show-toplevel"];
        let output = match run_git(directory, &[], &arguments, MAX_SMALL_OUTPUT_BYTES) {
            Ok(output) => output,
            Err(GitFailure::Exit(stderr)) if stderr.contains("not a git repository") => {
                return Err(not_a_repository(operation, directory));
            }
            Err(failure) => return Err(git_failed(operation, &failure)),
        };
        let root = String::from_utf8_lossy(&output.stdout).trim_end_matches('\n').to_string();
        if root.is_empty() {
            return Err(not_a_repository(operation, directory));
        }
        let root = PathBuf::from(root);
        let overrides =
            filter_overrides(&root).map_err(|failure| git_failed(operation, &failure))?;
        Ok(Self { root, overrides })
    }

    fn run(&self, arguments: &[&str], max_stdout: usize) -> Result<GitOutput, GitFailure> {
        run_git(&self.root, &self.overrides, arguments, max_stdout)
    }

    /// The commit a revision names, or `None`.
    fn commit(&self, revision: &str) -> Option<String> {
        let revision = format!("{revision}^{{commit}}");
        let arguments = ["rev-parse", "--verify", "--quiet", "--end-of-options", revision.as_str()];
        let output = self.run(&arguments, MAX_SMALL_OUTPUT_BYTES).ok()?;
        let commit = String::from_utf8_lossy(&output.stdout).trim().to_string();
        (!commit.is_empty()).then_some(commit)
    }

    /// The empty tree in this repository's hash, to compare against before
    /// the first commit.
    fn empty_tree(&self) -> Result<String, GitFailure> {
        let output = self.run(&["hash-object", "-t", "tree", "--stdin"], MAX_SMALL_OUTPUT_BYTES)?;
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    }

    /// The branch the branch scope compares with, as (ref, short name):
    /// origin's default branch, else origin/main, origin/master, main or
    /// master.
    fn base_branch(&self) -> Option<(String, String)> {
        let arguments = ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"];
        if let Ok(output) = self.run(&arguments, MAX_SMALL_OUTPUT_BYTES) {
            let reference = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if let Some(short) = reference.strip_prefix("refs/remotes/")
                && self.commit(&reference).is_some()
            {
                return Some((reference.clone(), short.to_string()));
            }
        }
        [
            ("refs/remotes/origin/main", "origin/main"),
            ("refs/remotes/origin/master", "origin/master"),
            ("refs/heads/main", "main"),
            ("refs/heads/master", "master"),
        ]
        .into_iter()
        .find(|(reference, _)| self.commit(reference).is_some())
        .map(|(reference, short)| (reference.to_string(), short.to_string()))
    }
}

/// A filter driver runs a program on file contents (`clean`, `smudge`,
/// `process`), and diffing the working tree would run it. A read never needs
/// one, so every configured driver is blanked: an empty command is no filter,
/// and nothing is required.
fn filter_overrides(root: &Path) -> Result<Vec<String>, GitFailure> {
    let pattern = r"^filter\..*\.(clean|smudge|process|required)$";
    let arguments = ["config", "--null", "--name-only", "--get-regexp", pattern];
    let output = match run_git(root, &[], &arguments, MAX_SMALL_OUTPUT_BYTES) {
        Ok(output) if output.truncated => {
            return Err(GitFailure::Exit("too many filter drivers configured".to_string()));
        }
        Ok(output) => output,
        // `--get-regexp` exits 1 when nothing matches.
        Err(GitFailure::Exit(stderr)) if stderr.is_empty() => return Ok(Vec::new()),
        Err(failure) => return Err(failure),
    };
    let drivers = parse::file_list(&output.stdout)
        .into_iter()
        .filter_map(|key| {
            let (driver, _) = key.strip_prefix("filter.")?.rsplit_once('.')?;
            Some(driver.to_string())
        })
        .collect::<BTreeSet<_>>();
    Ok(drivers
        .into_iter()
        .flat_map(|driver| {
            [
                format!("filter.{driver}.clean="),
                format!("filter.{driver}.smudge="),
                format!("filter.{driver}.process="),
                format!("filter.{driver}.required=false"),
            ]
        })
        .collect())
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
        value["branch"] = json!(branch);
    }
    if let Some(head) = headers.head {
        value["head"] = json!(head);
    }
    if let Some(upstream) = headers.upstream {
        value["upstream"] = json!(upstream);
    }
    if let Some((_, base)) = repository.base_branch() {
        value["base"] = json!(base);
    }
    Ok(value)
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
