//! `git.checkpoint.restore`: writes a checkpoint's covered paths back into
//! the worktree and the index, and removes what is new since, so a chat can
//! be rewound to before a turn. Undo is a restore of the safety checkpoint
//! an apply pins first; there is no second mutation.
//!
//! The change set compares the checkpoint's trees with a capture of the
//! working tree now, taken through the same capture path as create (every
//! eligible untracked file). For each path the checkpoint covers (its
//! worktree, index and untracked trees) the bytes, mode and staged entry it
//! had are written back (`restore`); a path tracked now that it did not
//! have, and a new eligible untracked file that did not exist then, are
//! deleted (`remove`). A path the checkpoint skipped (not selected,
//! excluded, ignored, credential-like, over the limit) existed then and is
//! left alone. Ignored files, nested repositories and submodules are never
//! touched, nothing runs `git clean`, and HEAD never moves: a moved HEAD is
//! `base_changed` unless the caller allows it.
//!
//! An apply, under the store's lock: captures and publishes the safety
//! checkpoint (reason `restore`, pinned `restore:<checkpoint_id>:<key>`),
//! takes the worktree's `index.lock` as git does, checks HEAD and the index
//! are still what the capture saw and every path it will touch still holds
//! what was captured, removes, writes (raw blob bytes, no filters, links as
//! links, never through a linked or non-folder parent), then installs the
//! rebuilt index through the lock and records the reply in the mutation
//! ledger, so a replayed key returns it and never applies again.
//!
//! Not covered yet (the plan's later slices): no preview token (a dry run
//! is advisory, and apply recomputes the change set under the lock), no
//! durable restore journal and so no `recovery_required` state. A failure
//! after the first file write is `restore_incomplete`, naming the safety
//! checkpoint the caller can restore to get back; nothing rolls back on its
//! own. Editors are not stopped by `index.lock`; a write racing the restore
//! between its check and its write is not detected.

mod write;

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::ffi::OsStr;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::capture::{Include, Request};
use super::record::{Limits, Pin, SkipCode, Stored};
use super::scan::{self, Kind, failed, refused};
use super::store::{Store, io_failed};
use super::{CreateArguments, fingerprint, ledger, mutation_key, not_found, refs, writer};
use crate::Mux;
use crate::git_ops::write_run::{Bound, WriteGit};
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;

const OPERATION: &str = "git.checkpoint.restore";
/// Listing a checkpoint's trees writes nothing, so it may stop.
const LIST_DEADLINE: Duration = Duration::from_secs(30);
const MAX_LISTING_BYTES: usize = 64 * 1024 * 1024;
/// Paths listed in a reply; `files_total` counts them all.
const MAX_LISTED: usize = 200;
/// Conflicting paths named in a refusal.
const MAX_CONFLICTS_LISTED: usize = 20;
const GITLINK: &str = "160000";

/// One tree entry: its mode and object.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Entry {
    mode: String,
    oid: String,
}

type Tree = BTreeMap<Vec<u8>, Entry>;

/// A checkpoint's three trees.
struct Trees {
    index: Tree,
    worktree: Tree,
    untracked: Tree,
}

impl Trees {
    fn read(git: &WriteGit<'_>, object: &str) -> Result<Self, ResourceError> {
        Ok(Self {
            index: list(git, &format!("{object}:index"))?,
            worktree: list(git, &format!("{object}:worktree"))?,
            untracked: list(git, &format!("{object}:untracked"))?,
        })
    }

    /// The file or link at `path` (never a gitlink): from the worktree tree,
    /// else the untracked tree.
    fn file(&self, path: &[u8]) -> Option<&Entry> {
        self.worktree
            .get(path)
            .or_else(|| self.untracked.get(path))
            .filter(|entry| entry.mode != GITLINK)
    }
}

/// What a restore does to one path.
#[derive(Debug, Default)]
struct Step {
    /// Write this file or link.
    write: Option<Entry>,
    /// Delete the file or link there.
    remove: bool,
    /// Set (`Some(Some)`) or drop (`Some(None)`) the index entry.
    index: Option<Option<Entry>>,
    /// What the live capture saw there (`None`: absent), checked again
    /// under the lock before a write or a removal.
    expected: Option<Entry>,
    /// The checkpoint has a file here: the path stays.
    kept: bool,
}

impl Step {
    fn changes(&self) -> bool {
        self.write.is_some() || self.remove || self.index.is_some()
    }

    fn label(&self) -> &'static str {
        if !self.kept && (self.remove || matches!(self.index, Some(None))) {
            "remove"
        } else {
            "restore"
        }
    }
}

/// The change set.
#[derive(Default)]
struct Plan {
    steps: BTreeMap<Vec<u8>, Step>,
    conflicts: Vec<(Vec<u8>, &'static str)>,
    /// Some live path could not be decided (the checkpoint's skip list was
    /// cut short), so it was left as it is.
    undecided: bool,
}

pub(super) fn restore(
    mux: &Arc<Mux>,
    store: &Store,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let key = mutation_key(request);
    let flag = |name: &str| request.fields.get(name).and_then(Value::as_bool) == Some(true);
    let (dry_run, allow_base_change) = (flag("dry_run"), flag("allow_base_change"));
    let checkpoint_id =
        request.fields.get("checkpoint_id").and_then(Value::as_str).unwrap_or_default().to_string();
    store.exclusive(|| {
        let target = super::resolved(mux, store, request, OPERATION)?;
        let fingerprint = fingerprint(request, &target);
        if let Some(replayed) = ledger::prior(mux, &key, OPERATION, &fingerprint)? {
            return Ok(replayed);
        }
        let stored = store
            .load(&target.repository_id, &checkpoint_id)
            .map_err(|error| io_failed(OPERATION, &error))?
            .ok_or_else(|| not_found(&checkpoint_id))?;
        if stored.record.worktree_id != target.worktree_id {
            let message = format!(
                "{checkpoint_id} belongs to worktree {}, not this one ({})",
                stored.record.worktree_id, target.worktree_id
            );
            let extra = json!({"worktree_id":stored.record.worktree_id});
            return Err(refused(OPERATION, "worktree_mismatch", message, extra));
        }
        let hooks = store.hooks();
        let git = writer(&target, &hooks);
        let arguments = CreateArguments {
            request: Request {
                include: Include::Eligible,
                exclude: Vec::new(),
                limits: Limits::default(),
            },
            reason: "restore".to_string(),
        };
        let (mut live, observed) = super::capture(store, &git, &target, &arguments, OPERATION)?;
        // A checkout of another branch at the same commit moved the base too.
        let (now, then) = (&live.record.base, &stored.record.base);
        let base_changed =
            now.head != then.head || now.branch != then.branch || now.detached != then.detached;
        if base_changed && !allow_base_change && !dry_run {
            let at = |base: &super::record::Base| {
                let head = base.head.as_deref().unwrap_or("unborn");
                match (&base.branch, base.detached) {
                    (Some(branch), false) => format!("{head} on {branch}"),
                    _ => format!("{head} (detached)"),
                }
            };
            let message = format!(
                "HEAD is {} but the checkpoint was taken at {}; restore with allow_base_change to keep HEAD and restore only the files",
                at(now),
                at(then),
            );
            let extra = json!({
                "head": now.head,
                "checkpoint_head": then.head,
                "branch": now.branch,
                "checkpoint_branch": then.branch,
            });
            return Err(refused(OPERATION, "base_changed", message, extra));
        }
        let wanted = Trees::read(&git, &stored.record.object_id)?;
        let now = Trees::read(&git, &live.record.object_id)?;
        let plan = plan(&target.repository.root, &stored, &wanted, &live, &now);
        if !plan.conflicts.is_empty() {
            return Err(conflict(&plan.conflicts));
        }
        let complete = stored.record.complete && live.record.complete && !plan.undecided;
        let mut object = Map::new();
        object.insert("checkpoint_id".into(), Value::String(checkpoint_id.clone()));
        object.insert("base_changed".into(), Value::Bool(base_changed));
        object.insert("complete".into(), Value::Bool(complete));
        object.insert("files_total".into(), json!(plan.steps.len()));
        object.insert("files".into(), listed(&plan));
        if dry_run {
            object.insert("dry_run".into(), Value::Bool(true));
        } else {
            // The safety checkpoint is published and pinned before the
            // first write, so Undo exists even when the restore fails.
            live.record.pins.push(Pin {
                pin_id: format!("restore:{checkpoint_id}:{key}"),
                reason: format!("Undo of the restore of {checkpoint_id}"),
            });
            live.settle();
            refs::publish(&git, &live, OPERATION)?;
            store.save(&live).map_err(|error| io_failed(OPERATION, &error))?;
            let safety = live.record.checkpoint_id.clone();
            object.insert("safety_checkpoint_id".into(), Value::String(safety.clone()));
            let zero = "0".repeat(stored.record.object_id.len());
            let apply = write::Apply {
                git: &git,
                root: &target.repository.root,
                git_dir: &target.layout.git_dir,
                repository: &target.repository,
                observed: &observed,
                zero: &zero,
                safety: &safety,
                operation: OPERATION,
            };
            write::apply(&apply, store, &plan)?;
        }
        refs::prune(store, &git, &target.repository_id);
        let value = Value::Object(object);
        ledger::commit(mux, &key, OPERATION, &fingerprint, &value, false, &request.actor)
    })
}

/// The first [`MAX_LISTED`] changed paths, in path order.
fn listed(plan: &Plan) -> Value {
    let files = plan
        .steps
        .iter()
        .take(MAX_LISTED)
        .map(|(path, step)| json!({"path":String::from_utf8_lossy(path),"change":step.label()}))
        .collect();
    Value::Array(files)
}

fn conflict(conflicts: &[(Vec<u8>, &'static str)]) -> ResourceError {
    let message = match conflicts.first() {
        Some((path, why)) => format!(
            "{} path(s) cannot be restored safely; the first, {}, is {}",
            conflicts.len(),
            String::from_utf8_lossy(path),
            why.replace('_', " ")
        ),
        None => "a path cannot be restored safely".to_owned(),
    };
    let paths = conflicts
        .iter()
        .take(MAX_CONFLICTS_LISTED)
        .map(|(path, why)| json!({"path":String::from_utf8_lossy(path),"conflict":why}))
        .collect::<Vec<_>>();
    let extra = json!({"conflicts":paths,"conflicts_total":conflicts.len()});
    refused(OPERATION, "conflict", message, extra)
}

/// The skip a record lists for `path`, or for a folder (`dir/`) holding it.
fn skipped(record: &Stored, path: &[u8]) -> Option<SkipCode> {
    let path = String::from_utf8_lossy(path);
    record
        .record
        .skipped
        .iter()
        .find(|skip| {
            skip.path == path || (skip.path.ends_with('/') && path.starts_with(skip.path.as_str()))
        })
        .map(|skip| skip.code)
}

fn cut_short(record: &Stored) -> bool {
    record.record.skipped_total as usize > record.record.skipped.len()
}

/// The change set from the live capture `live` (trees `now`) back to the
/// checkpoint `stored` (trees `wanted`), with the paths it cannot change
/// safely.
fn plan(
    root: &std::path::Path,
    stored: &Stored,
    wanted: &Trees,
    live: &Stored,
    now: &Trees,
) -> Plan {
    let mut plan = Plan::default();
    let mut paths = BTreeSet::new();
    for tree in [&wanted.index, &wanted.worktree, &wanted.untracked] {
        paths.extend(tree.keys().cloned());
    }
    for tree in [&now.index, &now.worktree, &now.untracked] {
        paths.extend(tree.keys().cloned());
    }
    let gitlinks = wanted
        .index
        .iter()
        .chain(now.index.iter())
        .filter(|(_, entry)| entry.mode == GITLINK)
        .map(|(path, _)| path.clone())
        .collect::<HashSet<_>>();
    for path in paths {
        let (was_staged, is_staged) = (wanted.index.get(&path), now.index.get(&path));
        if was_staged.is_some_and(|entry| entry.mode == GITLINK)
            || is_staged.is_some_and(|entry| entry.mode == GITLINK)
        {
            if was_staged != is_staged {
                plan.conflicts.push((path, "submodule"));
            }
            continue;
        }
        let mut step = Step {
            expected: now.file(&path).cloned(),
            kept: wanted.file(&path).is_some(),
            ..Step::default()
        };
        let covered = wanted.file(&path).is_some() || was_staged.is_some();
        if covered {
            match wanted.file(&path) {
                Some(entry) if step.expected.as_ref() != Some(entry) => {
                    step.write = Some(entry.clone());
                }
                Some(_) => {}
                // Tracked then but its file could not be stored: left alone.
                None if skipped(stored, &path).is_some_and(SkipCode::unavailable) => {}
                // Its skip entry may be past the stored list's cut: never removed on a guess.
                None if skipped(stored, &path).is_none() && cut_short(stored) => {
                    plan.undecided = true;
                    continue;
                }
                // Deleted in the worktree then.
                None => step.remove = step.expected.is_some(),
            }
            if was_staged != is_staged {
                step.index = Some(was_staged.cloned());
            }
        } else if skipped(stored, &path).is_some() {
            // It existed then, or was excluded: not the checkpoint's to change.
            continue;
        } else if cut_short(stored) {
            plan.undecided = true;
            continue;
        } else {
            // New since: tracked now, or a new eligible untracked file.
            step.remove = step.expected.is_some();
            if is_staged.is_some() {
                step.index = Some(None);
            }
        }
        if !step.changes() {
            continue;
        }
        if let Some(why) = blocked(root, &path, &step, live, &gitlinks) {
            plan.conflicts.push((path, why));
            continue;
        }
        plan.steps.insert(path, step);
    }
    // A write under a path that becomes a folder needs that path removed.
    let removed = plan
        .steps
        .iter()
        .filter(|(_, step)| step.remove)
        .map(|(path, _)| path.clone())
        .collect::<HashSet<_>>();
    let mut parents = Vec::new();
    for (path, step) in &plan.steps {
        if step.write.is_some()
            && let Some(why) = parent_blocked(root, path, &removed)
        {
            parents.push((path.clone(), why));
        }
    }
    plan.conflicts.extend(parents);
    plan
}

/// Why `step` cannot touch `path`, if it cannot.
fn blocked(
    root: &std::path::Path,
    path: &[u8],
    step: &Step,
    live: &Stored,
    gitlinks: &HashSet<Vec<u8>>,
) -> Option<&'static str> {
    if scan::parents(path).any(|prefix| gitlinks.contains(prefix)) {
        return Some("submodule");
    }
    if !(step.write.is_some() || step.remove) {
        return None;
    }
    if skipped(live, path).is_some_and(SkipCode::unavailable) {
        return Some("unavailable");
    }
    match scan::inspect(root, path) {
        Err(_) => Some("unavailable"),
        Ok(Some(Kind::Folder)) => Some("folder"),
        Ok(Some(Kind::Other)) => Some("unavailable"),
        // Something the capture did not take (ignored, credential-like,
        // over the limit) is there: never overwritten or deleted.
        Ok(Some(_)) if step.expected.is_none() => Some("occupied"),
        _ => None,
    }
}

/// Why a write to `path` cannot reach it: a leading part that is not a real
/// folder (and is not removed first), or a nested repository.
fn parent_blocked(
    root: &std::path::Path,
    path: &[u8],
    removed: &HashSet<Vec<u8>>,
) -> Option<&'static str> {
    for prefix in scan::parents(path) {
        match std::fs::symlink_metadata(scan::join(root, prefix)) {
            Ok(metadata) if metadata.is_dir() => {
                if std::fs::symlink_metadata(scan::join(root, prefix).join(".git")).is_ok() {
                    return Some("nested_repository");
                }
            }
            Ok(_) if removed.contains(prefix) => return None,
            Ok(_) => return Some("parent_not_folder"),
            Err(_) => return None,
        }
    }
    None
}

/// Every entry of a tree, recursively (a gitlink is one entry).
fn list(git: &WriteGit<'_>, tree: &str) -> Result<Tree, ResourceError> {
    let arguments = ["ls-tree", "-r", "-z", "--full-tree", tree];
    let arguments = arguments.iter().map(OsStr::new).collect::<Vec<_>>();
    let output = git
        .run(None, &arguments, &[], Bound::Deadline(LIST_DEADLINE), MAX_LISTING_BYTES)
        .map_err(|failure| scan::git(OPERATION, &failure))?;
    if output.truncated {
        return Err(failed(OPERATION, "budget_exceeded", "the checkpoint lists too many files"));
    }
    let mut entries = Tree::new();
    for record in scan::records(&output.stdout) {
        // `<mode> <type> <oid>\t<path>`
        let mut parts = record.splitn(2, |byte| *byte == b'\t');
        let (Some(header), Some(path)) = (parts.next(), parts.next()) else { continue };
        let header = String::from_utf8_lossy(header);
        let mut fields = header.split(' ');
        let (Some(mode), Some(_), Some(oid)) = (fields.next(), fields.next(), fields.next()) else {
            return Err(failed(OPERATION, "git_failed", "unexpected ls-tree output"));
        };
        let entry = Entry { mode: mode.to_string(), oid: oid.to_string() };
        entries.insert(path.to_vec(), entry);
    }
    Ok(entries)
}
