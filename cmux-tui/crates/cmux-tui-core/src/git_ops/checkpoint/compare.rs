//! `git.checkpoint.diff`: what changed between a checkpoint and a later one,
//! or between a checkpoint and the working tree now. The agent pane's "Last
//! turn" is the checkpoint acpmux takes before a prompt against the one it
//! takes when the turn ends (or the working tree while the turn runs).
//!
//! A checkpoint's files are its worktree tree with its untracked tree laid
//! over it; that tree is built in a temporary index. The working tree side is
//! captured the way a checkpoint is (raw bytes, the same eligibility rules:
//! no ignored, credential-like or oversized untracked files), but never
//! published, so both sides compare like with like. Neither the user's
//! index, HEAD, refs nor the worktree changes; only unreferenced objects are
//! written.

use std::ffi::OsStr;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};

use super::capture::{self, Include, Request, Stamp};
use super::record::{Limits, now_ms, rfc3339};
use super::scan::{self, failed};
use super::store::{Scratch, Store, io_failed, mint};
use super::{Target, not_found, target, writer};
use crate::Mux;
use crate::git_ops::diff;
use crate::git_ops::write_run::{Bound, WriteGit};
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;

const OPERATION: &str = "git.checkpoint.diff";
/// Building a files tree writes nothing a reader depends on, so it may stop.
const TREE_DEADLINE: Duration = Duration::from_secs(30);

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
        Ok::<_, ResourceError>((stored.record.object_id, stored.record.complete))
    };
    let (from_object, from_complete) = load(from_id)?;
    let to_object = to_id.map(load).transpose()?;
    let hooks = store.hooks();
    let git = writer(&target, &hooks);
    let scratch = store.scratch().map_err(|error| io_failed(OPERATION, &error))?;
    let from_tree = files_tree(&git, &scratch, "from", &from_object)?;
    let repository = &target.repository;
    let (mut value, to_complete) = match &to_object {
        Some((to_object, to_complete)) => {
            let to_tree = files_tree(&git, &scratch, "to", to_object)?;
            let value = diff::between(repository, from_tree, to_tree, &request.fields, OPERATION)?;
            (value, *to_complete)
        }
        None => {
            let (live, live_complete) = live_files(&git, &target, &scratch)?;
            let to_tree = files_tree(&git, &scratch, "live", &live)?;
            let value = diff::between(repository, from_tree, to_tree, &request.fields, OPERATION)?;
            (value, live_complete)
        }
    };
    drop(scratch);
    value["from"] = json!(from_id);
    // A side that left eligible files out (too large, over the file limit)
    // cannot show their changes, so the comparison is incomplete.
    value["complete"] = json!(from_complete && to_complete);
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
        git.run(index, &arguments, stdin, Bound::Deadline(TREE_DEADLINE), 64 * 1024 * 1024)
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

/// The working tree now, captured as a checkpoint would be (every eligible
/// untracked file, default limits) but never published: its object id.
fn live_files(
    git: &WriteGit<'_>,
    target: &Target,
    scratch: &Scratch,
) -> Result<(String, bool), ResourceError> {
    let checkpoint_id = mint("live");
    let created_at = rfc3339(now_ms());
    let stamp = Stamp {
        checkpoint_id: &checkpoint_id,
        repository_id: &target.repository_id,
        worktree_id: &target.worktree_id,
        created_at: &created_at,
        reason: "live",
    };
    let request =
        Request { include: Include::Eligible, exclude: Vec::new(), limits: Limits::default() };
    let captured = capture::capture(
        git,
        &target.repository,
        &target.layout,
        scratch,
        &request,
        &stamp,
        OPERATION,
    )?;
    Ok((captured.object_id, captured.complete))
}
