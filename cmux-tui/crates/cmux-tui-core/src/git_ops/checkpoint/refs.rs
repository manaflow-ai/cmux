//! The owner's refs, `refs/cmux/checkpoints/<worktree_id>/<checkpoint_id>`:
//! publishing one, checking a journaled one, retention pruning and sweeping
//! orphans. Nothing here touches a ref outside that namespace.

use std::collections::HashSet;
use std::ffi::OsStr;
use std::time::Duration;

use super::record::{self, Stored, now_ms};
use super::scan;
use super::store::Store;
use crate::git_ops::write_run::{Bound, WriteGit};
use crate::resource::ResourceError;

const NAMESPACE: &str = "refs/cmux/checkpoints/";
const LOOKUP_DEADLINE: Duration = Duration::from_secs(20);
const MAX_REF_LISTING_BYTES: usize = 4 * 1024 * 1024;

fn run(git: &WriteGit<'_>, arguments: &[&str], bound: Bound, max: usize) -> Option<Vec<u8>> {
    let arguments = arguments.iter().map(OsStr::new).collect::<Vec<_>>();
    git.run(None, &arguments, &[], bound, max).ok().map(|output| output.stdout)
}

/// Publishes a checkpoint's ref, which must not exist yet.
pub(super) fn publish(
    git: &WriteGit<'_>,
    stored: &Stored,
    operation: &'static str,
) -> Result<(), ResourceError> {
    let zero = "0".repeat(stored.record.object_id.len());
    let reference = stored.record.reference.as_str();
    let object = stored.record.object_id.as_str();
    let arguments = ["update-ref", "-m", "cmux checkpoint", reference, object, zero.as_str()];
    let arguments = arguments.iter().map(OsStr::new).collect::<Vec<_>>();
    git.run(None, &arguments, &[], Bound::Unbounded, 4096)
        .map(|_| ())
        .map_err(|failure| scan::git(operation, &failure))
}

/// Whether a journaled draft's ref was published and points at its commit.
pub(super) fn published(git: &WriteGit<'_>, draft: &Stored) -> bool {
    let reference = draft.record.reference.as_str();
    let arguments = ["rev-parse", "--verify", "--quiet", reference];
    run(git, &arguments, Bound::Deadline(LOOKUP_DEADLINE), 4096)
        .is_some_and(|stdout| String::from_utf8_lossy(&stdout).trim() == draft.record.object_id)
}

/// Deletes `reference` only while it still points at `object`.
fn delete(git: &WriteGit<'_>, reference: &str, object: &str) -> bool {
    if !reference.starts_with(NAMESPACE) {
        return false;
    }
    run(git, &["update-ref", "-d", reference, object], Bound::Unbounded, 4096).is_some()
}

/// Removes the repository's expired and excess unpinned checkpoints: their
/// refs and records. Best effort; git objects stay until the repository's
/// own maintenance collects them.
pub(super) fn prune(store: &Store, git: &WriteGit<'_>, repository_id: &str) {
    let Ok(records) = store.all(repository_id) else { return };
    for checkpoint_id in record::prunable(&records, now_ms()) {
        let found = records.iter().find(|stored| stored.record.checkpoint_id == checkpoint_id);
        if let Some(stored) = found
            && delete(git, &stored.record.reference, &stored.record.object_id)
        {
            let _ = store.remove(repository_id, &checkpoint_id);
        }
    }
}

/// Deletes the refs under this worktree's namespace that have neither a
/// record nor an unfinished journaled create: what a crash between
/// publishing and recording left behind. Best effort.
pub(super) fn sweep(store: &Store, git: &WriteGit<'_>, repository_id: &str, worktree_id: &str) {
    let prefix = format!("{NAMESPACE}{worktree_id}/");
    let Ok(pending) = store.all_pending() else { return };
    let pending =
        pending.iter().map(|entry| entry.draft.record.reference.as_str()).collect::<HashSet<_>>();
    let pattern = format!("{NAMESPACE}{worktree_id}");
    let arguments = ["for-each-ref", "--format=%(refname) %(objectname)", pattern.as_str()];
    let bound = Bound::Deadline(LOOKUP_DEADLINE);
    let Some(listing) = run(git, &arguments, bound, MAX_REF_LISTING_BYTES) else { return };
    for line in String::from_utf8_lossy(&listing).lines() {
        let Some((reference, object)) = line.split_once(' ') else { continue };
        let Some(checkpoint_id) = reference.strip_prefix(&prefix) else { continue };
        if checkpoint_id.contains('/') || pending.contains(reference) {
            continue;
        }
        if matches!(store.load(repository_id, checkpoint_id), Ok(None)) {
            delete(git, reference, object);
        }
    }
}
