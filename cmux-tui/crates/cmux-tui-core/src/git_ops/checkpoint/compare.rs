//! `git.checkpoint.diff`: what changed between a checkpoint and a later one,
//! or between a checkpoint and the working tree now. The agent pane's "Last
//! turn" is the checkpoint acpmux takes before a prompt against the one it
//! takes when the turn ends (or the working tree while the turn runs).
//!
//! A checkpoint's files are its worktree tree with its untracked tree laid
//! over it; that tree is built in a temporary index. The working tree side
//! reads a private copy of the repository's index with every untracked,
//! nonignored file added as intent-to-add, so new files diff like tracked
//! ones and files untracked at both ends compare by content. Neither the
//! user's index, HEAD nor the worktree changes; only tree objects are
//! written.

use std::ffi::OsStr;
use std::sync::Arc;

use serde_json::{Value, json};

use super::scan::{self, failed};
use super::store::{Scratch, Store, io_failed};
use super::{not_found, target, writer};
use crate::Mux;
use crate::git_ops::write_run::{Bound, WriteGit};
use crate::git_ops::{MAX_SMALL_OUTPUT_BYTES, Repository, diff, parse};
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;

const OPERATION: &str = "git.checkpoint.diff";
/// Untracked files added to the private index; the rest are counted in
/// `untracked_skipped`.
const MAX_UNTRACKED_FILES: usize = 2000;
/// Paths per `add -N` run, well inside argument limits.
const ADD_BATCH: usize = 256;

pub(super) fn diff(
    mux: &Arc<Mux>,
    store: &Store,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let from_id = request.fields.get("from").and_then(Value::as_str).unwrap_or_default();
    let to_id = request.fields.get("to").and_then(Value::as_str);
    let Some(target) = target(mux, store, request, OPERATION, false)? else {
        return Err(not_found(from_id));
    };
    let load = |id: &str| {
        let stored = store
            .load(&target.repository_id, id)
            .map_err(|error| io_failed(OPERATION, &error))?
            .filter(|stored| stored.record.worktree_id == target.worktree_id)
            .ok_or_else(|| not_found(id))?;
        Ok::<_, ResourceError>(stored.record.object_id)
    };
    let from_object = load(from_id)?;
    let to_object = to_id.map(load).transpose()?;
    let hooks = store.hooks();
    let git = writer(&target, &hooks);
    let scratch = store.scratch().map_err(|error| io_failed(OPERATION, &error))?;
    let from_tree = files_tree(&git, &scratch, "from", &from_object)?;
    let repository = &target.repository;
    let mut value = match &to_object {
        Some(to_object) => {
            let to_tree = files_tree(&git, &scratch, "to", to_object)?;
            diff::between(repository, from_tree, to_tree, &request.fields, OPERATION)?
        }
        None => {
            let (live, skipped) = live_index(&git, repository, &scratch)?;
            let mut value = diff::against_worktree(&live, from_tree, &request.fields, OPERATION)?;
            if skipped > 0 {
                value["untracked_skipped"] = json!(u32::try_from(skipped).unwrap_or(u32::MAX));
            }
            value
        }
    };
    drop(scratch);
    value["from"] = json!(from_id);
    if let Some(to_id) = to_id {
        value["to"] = json!(to_id);
    }
    Ok(value)
}

/// The tree of a checkpoint's files: its worktree tree with its untracked
/// tree laid over it.
fn files_tree(
    git: &WriteGit<'_>,
    scratch: &Scratch,
    name: &str,
    object: &str,
) -> Result<String, ResourceError> {
    let index = scratch.path.join(format!("{name}.index"));
    let worktree = format!("{object}:worktree");
    let untracked = format!("{object}:untracked");
    let run = |index: Option<&std::path::Path>, arguments: &[&str], stdin: &[u8]| {
        let arguments = arguments.iter().map(OsStr::new).collect::<Vec<_>>();
        git.run(index, &arguments, stdin, Bound::Unbounded, 64 * 1024 * 1024)
            .map_err(|failure| scan::git(OPERATION, &failure))
    };
    run(Some(&index), &["read-tree", worktree.as_str()], &[])?;
    let listed = run(None, &["ls-tree", "-r", "-z", "--full-tree", untracked.as_str()], &[])?;
    if listed.truncated {
        return Err(failed(OPERATION, "budget_exceeded", "the checkpoint lists too many files"));
    }
    if !listed.stdout.is_empty() {
        run(Some(&index), &["update-index", "-z", "--index-info"], &listed.stdout)?;
    }
    let tree = run(Some(&index), &["write-tree"], &[])?;
    let tree = String::from_utf8_lossy(&tree.stdout).trim().to_string();
    if tree.is_empty() {
        return Err(failed(OPERATION, "git_failed", "git printed no tree"));
    }
    Ok(tree)
}

/// A private copy of the repository's index with the untracked, nonignored
/// files added as intent-to-add, and how many were left out past
/// [`MAX_UNTRACKED_FILES`].
fn live_index(
    git: &WriteGit<'_>,
    repository: &Repository,
    scratch: &Scratch,
) -> Result<(Repository, usize), ResourceError> {
    let read = |arguments: &[&str], limit| {
        repository.run(arguments, limit).map_err(|failure| scan::git(OPERATION, &failure))
    };
    let index = scratch.path.join("live.index");
    let own = read(&["rev-parse", "--path-format=absolute", "--git-path", "index"], 64 * 1024)?;
    let own = String::from_utf8_lossy(&own.stdout).trim().to_string();
    match std::fs::copy(&own, &index) {
        Ok(_) => {}
        // Before the first `git add` there is no index: start empty.
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(io_failed(OPERATION, &error)),
    }
    let listed = read(&["ls-files", "--others", "--exclude-standard", "-z"], 8 * 1024 * 1024)?;
    let mut untracked = parse::file_list(&listed.stdout);
    if listed.truncated {
        untracked.pop();
    }
    let skipped = untracked.len().saturating_sub(MAX_UNTRACKED_FILES);
    untracked.truncate(MAX_UNTRACKED_FILES);
    for batch in untracked.chunks(ADD_BATCH) {
        let mut arguments = vec![OsStr::new("add"), OsStr::new("-N"), OsStr::new("--")];
        arguments.extend(batch.iter().map(OsStr::new));
        git.run(Some(&index), &arguments, &[], Bound::Unbounded, MAX_SMALL_OUTPUT_BYTES)
            .map_err(|failure| scan::git(OPERATION, &failure))?;
    }
    Ok((repository.with_index(index), skipped))
}
