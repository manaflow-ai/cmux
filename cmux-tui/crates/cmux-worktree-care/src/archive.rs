//! Acting on a verdict: trimming build output, archiving a worktree's work
//! into git and removing its folder.
//!
//! The archive is taken with a copy of the worktree's index, so its own
//! index, HEAD and files are only read: an index commit (the copy as it
//! was) and a files commit (the copy after `git add -A --sparse` and
//! `git add -f` of the ignored data) whose parents are HEAD and the index
//! commit. `refs/cmux/archive/<id>` keeps both, and a bundle of what the
//! remotes lack copies them out of the repository. The worktree's status
//! and HEAD are read again after the capture and right before the folder
//! goes; any change stops the removal, and the archive stays.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use cmux_git::write_run::{Bound, WriteGit};

use crate::git::{self, HASH, MAX_ARGUMENT_BYTES};
use crate::inventory::{Facts, Repo, Worktree, now_ms};
use crate::policy::Action;
use crate::procs::{self, Open, Uses};
use crate::store::{Manifest, Store, new_id};

/// How long removing a folder (many files) may take before git is waited on
/// anyway: removal is a write and is never killed midway.
const BUNDLE: Duration = Duration::from_secs(600);

/// Removes a kept worktree's build output, each folder only while nothing
/// `uses` lists works in it. Returns the bytes the disk gained.
pub fn trim(worktree: &Worktree, facts: &Facts, uses: &Uses) -> Result<u64, String> {
    let before = available(&worktree.path);
    let processes = uses()?;
    for entry in &facts.build_output {
        let path = worktree.path.join(entry.trim_end_matches('/'));
        if !path.starts_with(&worktree.path) || procs::inside(&processes, &path).is_some() {
            continue;
        }
        let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
        let removed = if meta.is_dir() {
            std::fs::remove_dir_all(&path)
        } else {
            std::fs::remove_file(&path)
        };
        removed.map_err(|e| format!("{}: {e}", path.display()))?;
    }
    Ok(available(&worktree.path).saturating_sub(before))
}

/// Archives (for [`Action::Archive`], or whenever it holds work no remote
/// has) and removes a worktree, writing its manifest first. `facts` must be
/// fresh (`inventory::rescan`). Right before the folder goes, the worktree
/// is read once more: its status, its ignored entries and the tree of its
/// files must be what was archived, and nothing `uses` lists may work in
/// it; else it
/// stays and the archive is dropped. Returns the manifest, with the bytes
/// freed.
#[allow(clippy::too_many_arguments)]
pub fn reclaim(
    repo: &Repo,
    worktree: &Worktree,
    facts: &Facts,
    action: Action,
    reason: &str,
    store: &Store,
    uses: &Uses,
    open: &Open,
) -> Result<Manifest, String> {
    if let Some(why) = &facts.unarchivable {
        return Err(format!("cannot archive: {why}"));
    }
    if worktree.locked || facts.operation.is_some() {
        return Err("it is locked or a git operation is under way".to_string());
    }
    let anchor = repo.main_root.clone().unwrap_or_else(|| repo.common_dir.clone());
    let hooks = empty_hooks(store)?;
    let wt = WriteGit { root: &worktree.path, overrides: &repo.overrides, hooks: &hooks };
    let id = new_id(now_ms(), &worktree.path);
    let fingerprint = fingerprint(repo, worktree)?;
    // The fingerprint starts at HEAD as it is now; the facts are of the
    // HEAD the scan saw. A commit in between is a change.
    let head = git::try_line(
        &worktree.path,
        &repo.overrides,
        &["rev-parse", "--verify", "--quiet", "HEAD"],
    );
    if head != worktree.head {
        return Err("its HEAD moved since the scan; it stays".to_string());
    }
    let mut manifest = Manifest {
        id: id.clone(),
        created_ms: now_ms(),
        path: worktree.path.clone(),
        common_dir: repo.common_dir.clone(),
        main_root: repo.main_root.clone(),
        branch: worktree.branch.clone(),
        head: worktree.head.clone(),
        archive_ref: None,
        archive_commit: None,
        bundle: None,
        sparse: facts.sparse.clone(),
        submodules: facts.submodules.clone(),
        dropped: facts.build_output.clone(),
        reason: reason.to_string(),
        freed: 0,
        restored_ms: None,
    };
    let mut files = None;
    if action == Action::Archive || !facts.is_clean_and_pushed() {
        let (commit, tree) = capture(&wt, worktree, facts, store, &id)?;
        let reference = format!("refs/cmux/archive/{id}");
        // The empty old value: the ref must not exist yet.
        git::write_str(&wt, None, &["update-ref", &reference, &commit, ""], Bound::Unbounded)?;
        manifest.archive_ref = Some(reference.clone());
        manifest.archive_commit = Some(commit);
        if facts.has_remotes {
            let bundle = store.bundle_path(&id);
            let path = bundle.as_os_str();
            let args: [&OsStr; 6] = [
                "bundle".as_ref(),
                "create".as_ref(),
                path,
                reference.as_ref(),
                "--not".as_ref(),
                "--remotes".as_ref(),
            ];
            if let Err(error) = git::write(&wt, None, &args, Bound::Deadline(BUNDLE)) {
                discard(&wt, store, &manifest);
                return Err(error);
            }
            manifest.bundle = Some(bundle);
        }
        files = Some(tree);
    }
    // The manifest is on disk before the folder goes.
    if let Err(error) = store.save(&manifest) {
        discard(&wt, store, &manifest);
        return Err(error);
    }
    if let Err(why) = unchanged(
        repo,
        worktree,
        facts,
        &fingerprint,
        files.as_deref(),
        &wt,
        store,
        &id,
        uses,
        open,
    ) {
        discard(&wt, store, &manifest);
        return Err(format!("{why}; it stays"));
    }
    let before = available(&anchor);
    let main = WriteGit { root: &anchor, overrides: &repo.overrides, hooks: &hooks };
    let path = worktree.path.as_os_str();
    let args: [&OsStr; 4] = ["worktree".as_ref(), "remove".as_ref(), "--force".as_ref(), path];
    git::write(&main, None, &args, Bound::Unbounded)?;
    manifest.freed = available(&anchor).saturating_sub(before);
    store.save(&manifest)?;
    Ok(manifest)
}

/// Whether the worktree is still what was archived: the same status and
/// HEAD, the same untracked files and ignored entries, the same tree of
/// files (a content change of an already changed or untracked file shows
/// only there), and no process inside.
#[allow(clippy::too_many_arguments)]
fn unchanged(
    repo: &Repo,
    worktree: &Worktree,
    facts: &Facts,
    fingerprint: &[u8],
    files: Option<&str>,
    wt: &WriteGit<'_>,
    store: &Store,
    id: &str,
    uses: &Uses,
    open: &Open,
) -> Result<(), String> {
    if fingerprint != self::fingerprint(repo, worktree)?.as_slice() {
        return Err("its status changed while it was archived".to_string());
    }
    let now = crate::inventory::rescan(repo, &worktree.path)?;
    let now = now.facts.as_ref().map_err(Clone::clone)?;
    if now.untracked != facts.untracked
        || now.ignored_data != facts.ignored_data
        || now.build_output != facts.build_output
        || now.changed != facts.changed
        || now.unarchivable.is_some()
    {
        return Err("its files changed while it was archived".to_string());
    }
    if let Some(files) = files {
        let (_, again) = trees(wt, facts, store, &format!("{id}.check"))?;
        if again != files {
            return Err("its files changed while it was archived".to_string());
        }
    }
    if let Some(process) = procs::inside(&uses()?, &worktree.path) {
        return Err(format!("process {} started working in it", process.pid));
    }
    // Last, right before the folder goes: what no registry records.
    match open(&worktree.path) {
        Ok(None) => Ok(()),
        Ok(Some(pid)) => Err(format!("process {pid} has it open")),
        Err(error) => Err(format!("could not check what has it open ({error})")),
    }
}

/// Drops an archive whose worktree stays: its ref, bundle and manifest.
fn discard(wt: &WriteGit<'_>, store: &Store, manifest: &Manifest) {
    if let (Some(reference), Some(commit)) = (&manifest.archive_ref, &manifest.archive_commit) {
        let deleted =
            git::write_str(wt, None, &["update-ref", "-d", reference, commit], Bound::Unbounded);
        // A ref that stays keeps its manifest, so expiry finds it again.
        if deleted.is_err() && store.manifest_path(&manifest.id).exists() {
            return;
        }
    }
    let _ = std::fs::remove_file(store.bundle_path(&manifest.id));
    let _ = std::fs::remove_file(store.manifest_path(&manifest.id));
}

/// The worktree's HEAD and full status: equal before and after, nothing
/// was written in it meanwhile.
fn fingerprint(repo: &Repo, worktree: &Worktree) -> Result<Vec<u8>, String> {
    let root = &worktree.path;
    let mut bytes = git::read(root, &repo.overrides, &["rev-parse", "--verify", "--quiet", "HEAD"])
        .unwrap_or_default();
    bytes.extend(git::read(
        root,
        &repo.overrides,
        &[
            "status",
            "--porcelain=v2",
            "-z",
            "--branch",
            "--untracked-files=all",
            "--ignored=matching",
        ],
    )?);
    Ok(bytes)
}

/// The archive commit of a worktree's index and files, and its files tree.
fn capture(
    wt: &WriteGit<'_>,
    worktree: &Worktree,
    facts: &Facts,
    store: &Store,
    id: &str,
) -> Result<(String, String), String> {
    let (index_tree, files_tree) = trees(wt, facts, store, id)?;
    let head = worktree.head.as_deref();
    let message = format!("cmux worktree archive {id}\n\npath: {}\n", worktree.path.display());
    let index_commit = commit(wt, &index_tree, head.into_iter().collect(), "index")?;
    let mut parents: Vec<&str> = head.into_iter().collect();
    parents.push(&index_commit);
    let commit = commit(wt, &files_tree, parents, &message)?;
    Ok((commit, files_tree))
}

/// The tree of the worktree's index, and of its files: a copy of its index
/// with every change, untracked file and ignored data added (an
/// assume-unchanged or skip-worktree entry made unarchivable before this).
fn trees(
    wt: &WriteGit<'_>,
    facts: &Facts,
    store: &Store,
    name: &str,
) -> Result<(String, String), String> {
    let index = store.dir.join(format!(".{name}.index"));
    let _cleanup = Remove(index.clone());
    let source = facts.git_dir.join("index");
    if source.exists() {
        std::fs::copy(&source, &index).map_err(|e| format!("{}: {e}", source.display()))?;
    }
    let index_tree = git::write_str(wt, Some(&index), &["write-tree"], Bound::Unbounded)?;
    git::write_str(wt, Some(&index), &["add", "-A", "--sparse"], Bound::Deadline(HASH))?;
    for chunk in chunks(&facts.ignored_data) {
        let mut args: Vec<&OsStr> =
            vec!["add".as_ref(), "-f".as_ref(), "--sparse".as_ref(), "--".as_ref()];
        args.extend(chunk.iter().map(|path| OsStr::new(path.trim_end_matches('/'))));
        git::write(wt, Some(&index), &args, Bound::Deadline(HASH))?;
    }
    let files_tree = git::write_str(wt, Some(&index), &["write-tree"], Bound::Unbounded)?;
    Ok((index_tree, files_tree))
}

fn commit(
    wt: &WriteGit<'_>,
    tree: &str,
    parents: Vec<&str>,
    message: &str,
) -> Result<String, String> {
    let mut args = vec!["commit-tree", tree, "-m", message];
    for parent in parents {
        args.extend(["-p", parent]);
    }
    let commit = git::write_str(wt, None, &args, Bound::Unbounded)?;
    if !git::is_object_id(&commit) {
        return Err(format!("git commit-tree printed {commit:?}"));
    }
    Ok(commit)
}

/// Paths in groups whose bytes stay inside one command line.
fn chunks(paths: &[String]) -> Vec<&[String]> {
    let mut groups = Vec::new();
    let (mut start, mut bytes) = (0, 0);
    for (index, path) in paths.iter().enumerate() {
        if bytes + path.len() + 1 > MAX_ARGUMENT_BYTES && index > start {
            groups.push(&paths[start..index]);
            (start, bytes) = (index, 0);
        }
        bytes += path.len() + 1;
    }
    if start < paths.len() {
        groups.push(&paths[start..]);
    }
    groups
}

/// An empty hooks folder the store owns: git runs no hook from it.
/// Drops the archives older than `keep_ms`: their refs, bundles and
/// manifests. Returns the ids dropped.
pub fn expire(store: &Store, now: u64, keep_ms: u64) -> Result<Vec<String>, String> {
    let hooks = empty_hooks(store)?;
    let mut dropped = Vec::new();
    for manifest in store.list() {
        if now.saturating_sub(manifest.created_ms) < keep_ms {
            continue;
        }
        let anchor = manifest.main_root.clone().unwrap_or_else(|| manifest.common_dir.clone());
        if anchor.exists() {
            let wt = WriteGit { root: &anchor, overrides: &[], hooks: &hooks };
            discard(&wt, store, &manifest);
        } else {
            let _ = std::fs::remove_file(store.bundle_path(&manifest.id));
            let _ = std::fs::remove_file(store.manifest_path(&manifest.id));
        }
        dropped.push(manifest.id);
    }
    Ok(dropped)
}

pub(crate) fn empty_hooks(store: &Store) -> Result<PathBuf, String> {
    let hooks = store.dir.join(".empty-hooks");
    std::fs::create_dir_all(&hooks).map_err(|e| format!("{}: {e}", hooks.display()))?;
    if std::fs::read_dir(&hooks).map_err(|e| e.to_string())?.next().is_some() {
        return Err(format!("{} is not empty", hooks.display()));
    }
    Ok(hooks)
}

fn available(path: &Path) -> u64 {
    crate::disk::usage(path).map_or(0, |usage| usage.available)
}

/// Removes a temporary file when dropped.
struct Remove(PathBuf);

impl Drop for Remove {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

#[cfg(test)]
mod care_tests {
    use super::*;

    #[test]
    fn long_path_lists_split_inside_the_argument_limit() {
        let paths: Vec<String> = (0..10_000).map(|i| format!("some/longer/path/{i:05}")).collect();
        let groups = chunks(&paths);
        assert!(groups.len() > 1);
        assert_eq!(groups.iter().map(|g| g.len()).sum::<usize>(), paths.len());
        assert!(
            groups
                .iter()
                .all(|g| g.iter().map(|p| p.len() + 1).sum::<usize>() <= MAX_ARGUMENT_BYTES)
        );
        assert!(chunks(&[]).is_empty());
    }
}
