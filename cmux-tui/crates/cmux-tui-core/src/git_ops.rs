//! `git.diff`, `git.status` and `git.files.search`: read-only git reads of
//! the repository a path or a terminal's working directory is in. The session host answers them
//! without store state; each request runs git on its own connection thread,
//! bounded by a deadline and output limits. `git.checkpoint.*` captures
//! immutable checkpoints through a separate write runner (`checkpoint`).

mod checkpoint;
mod diff;
mod files;
mod target;
#[cfg(test)]
mod tests;

use std::path::Path;
use std::sync::Arc;

use cmux_git::run::GitFailure;
use cmux_git::{OpenError, Repository, parse, run, write_run};
use serde_json::{Value, json};

use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::ParsedResourceRequest;

const MAX_SMALL_OUTPUT_BYTES: usize = cmux_git::MAX_SMALL_OUTPUT_BYTES;
const MAX_STATUS_BYTES: usize = 256 * 1024;

/// Advertised in identify: the session host owns `git.checkpoint.create`,
/// `get`, `list`, `pin` and `unpin`.
pub(crate) const CHECKPOINTS_CAPABILITY: &str = "git-checkpoints-v1";

/// Advertised in identify: the session host answers `git.files.search`.
pub(crate) const FILES_SEARCH_CAPABILITY: &str = "git-files-search-v1";

pub(crate) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::GitDiff
            | ResourceOperation::GitStatus
            | ResourceOperation::GitFilesSearch
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
    let operation = match request.envelope.operation {
        ResourceOperation::GitDiff => "git.diff",
        ResourceOperation::GitStatus => "git.status",
        ResourceOperation::GitFilesSearch => "git.files.search",
        other => unreachable!("git_ops does not handle {other:?}"),
    };
    let directory = target::directory(mux, &request, operation)?;
    let repository = open_repository(&directory, operation)?;
    match operation {
        "git.diff" => diff::read(&repository, &request.fields),
        "git.files.search" => files::search(&repository, &directory, &request.fields),
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
