//! A reclaimed worktree back where it was, from its manifest: the worktree
//! added again on its branch, its sparse patterns, its files, its index and
//! its submodules. git writes only from the repository's own objects.
//!
//! The archive's objects are made present first (fetched from the bundle
//! beside the manifest when its ref is gone), so a restore that cannot
//! finish never starts; one that fails midway removes the worktree it
//! added, and the manifest stays unrestored for another try.
//!
//! The branch is checked out when its tip is the archived commit, or, with
//! no archived work to lay on top, a commit after it. Otherwise HEAD is
//! detached at the archived commit, with a note: archived files laid over a
//! newer tip would read as reverts of its commits.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Serialize;

use crate::git::{self, user_git};
use crate::inventory::now_ms;
use crate::store::{Manifest, Store};

const LOCAL: Duration = Duration::from_secs(600);
/// How long a restore's submodule update may take by default.
pub const SUBMODULES: Duration = Duration::from_secs(1800);

/// What a restore did.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Restored {
    pub path: PathBuf,
    /// The branch checked out, or `None` when HEAD is detached.
    pub branch: Option<String>,
    pub head: Option<String>,
    /// The archived files and index were put back.
    pub archive: bool,
    /// Things that did not come back as they were, said plainly.
    pub notes: Vec<String>,
}

/// Puts the worktree of `manifest` back at `path` (its old folder when
/// `None`), and marks the manifest restored.
pub fn restore(
    store: &Store,
    manifest: &Manifest,
    path: Option<&Path>,
) -> Result<Restored, String> {
    restore_within(store, manifest, path, SUBMODULES)
}

/// [`restore`], whose submodule update stops after `submodules`.
pub fn restore_within(
    store: &Store,
    manifest: &Manifest,
    path: Option<&Path>,
    submodules: Duration,
) -> Result<Restored, String> {
    let path = path.unwrap_or(&manifest.path).to_path_buf();
    if path.exists() && std::fs::read_dir(&path).map(|mut d| d.next().is_some()).unwrap_or(true) {
        return Err(format!("{} is not empty", path.display()));
    }
    let anchor = manifest.main_root.clone().unwrap_or_else(|| manifest.common_dir.clone());
    if !anchor.exists() {
        return Err(format!("the repository {} is gone", anchor.display()));
    }
    let head = manifest.head.clone().ok_or("the manifest names no commit")?;
    let archive = manifest.archive_commit.as_deref().zip(manifest.archive_ref.as_deref());
    if let Some((commit, reference)) = archive {
        ensure_archive(&anchor, manifest, commit, reference)?;
    } else if git::read(&anchor, &[], &["cat-file", "-e", &format!("{head}^{{commit}}")]).is_err() {
        return Err(format!("the commit {head} is no longer in the repository"));
    }

    let mut notes = Vec::new();
    let checked_out = checked_out_branches(&anchor)?;
    let path_arg = path.to_string_lossy().into_owned();
    let mut args = vec!["worktree".to_string(), "add".into(), "--no-checkout".into()];
    let detached = [String::from("--detach"), path_arg.clone(), head.clone()];
    let mut branch = None;
    match &manifest.branch {
        Some(name) => {
            let reference = format!("refs/heads/{name}");
            let tip =
                git::try_line(&anchor, &[], &["rev-parse", "--verify", "--quiet", &reference]);
            if tip.is_none() {
                args.extend(["-b".into(), name.clone(), path_arg.clone(), head.clone()]);
                branch = Some(name.clone());
            } else if checked_out.contains(name) {
                notes.push(format!("{name} is checked out in another worktree; HEAD is detached"));
                args.extend(detached);
            } else if tip.as_deref() == Some(head.as_str())
                || (archive.is_none() && contains(&anchor, name, &head))
            {
                args.extend([path_arg.clone(), name.clone()]);
                branch = Some(name.clone());
            } else {
                notes.push(format!(
                    "{name} moved since the archive; HEAD is detached at the archived commit {}",
                    &head[..head.len().min(12)]
                ));
                args.extend(detached);
            }
        }
        None => args.extend(detached),
    }
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    user_git(&anchor, &args, LOCAL)?;

    if let Err(error) = fill(manifest, &path, archive.map(|(c, _)| c), submodules, &mut notes) {
        // Only what this restore added goes: a checkout of the repository's
        // own objects. The branch, if it made one, points at `head`.
        let _ = user_git(&anchor, &["worktree", "remove", "--force", &path_arg], LOCAL);
        return Err(error);
    }
    store.save(&Manifest { restored_ms: Some(now_ms()), ..manifest.clone() })?;
    Ok(Restored { path, branch, head: Some(head), archive: archive.is_some(), notes })
}

/// The archive commit, its files tree and its index tree present in the
/// repository, fetched from the bundle when the ref was lost.
fn ensure_archive(
    anchor: &Path,
    manifest: &Manifest,
    commit: &str,
    reference: &str,
) -> Result<(), String> {
    let present = || {
        ["^{commit}", "^{tree}", "^1^{commit}", "^2^{tree}"].iter().all(|suffix| {
            let object = format!("{commit}{suffix}");
            git::read(anchor, &[], &["cat-file", "-e", &object]).is_ok()
        })
    };
    if present() {
        return Ok(());
    }
    let bundle =
        manifest.bundle.as_ref().ok_or("the archive commit is gone and no bundle has it")?;
    let bundle = bundle.to_string_lossy();
    user_git(anchor, &["fetch", "--quiet", &bundle, &format!("+{reference}:{reference}")], LOCAL)?;
    if present() { Ok(()) } else { Err("the bundle did not bring the archive back".to_string()) }
}

/// The new worktree's sparse patterns, files, index and submodules.
fn fill(
    manifest: &Manifest,
    path: &Path,
    archive: Option<&str>,
    submodules: Duration,
    notes: &mut Vec<String>,
) -> Result<(), String> {
    let wt = |args: &[&str]| user_git(path, args, LOCAL);
    if let Some(sparse) = &manifest.sparse {
        wt(&["sparse-checkout", "init", if sparse.cone { "--cone" } else { "--no-cone" }])?;
        let git_dir = git::line(path, &[], &["rev-parse", "--absolute-git-dir"])?;
        let file = Path::new(&git_dir).join("info/sparse-checkout");
        let mut text = sparse.patterns.join("\n");
        text.push('\n');
        std::fs::write(&file, text).map_err(|e| format!("{}: {e}", file.display()))?;
    }
    wt(&["reset", "--hard", "--quiet", "HEAD"])?;
    if let Some(commit) = archive {
        wt(&["restore", "--source", commit, "--worktree", "--", ":/"])?;
        let index_tree = format!("{commit}^2^{{tree}}");
        let head_tree = git::try_line(path, &[], &["rev-parse", "HEAD^{tree}"]);
        if git::try_line(path, &[], &["rev-parse", &index_tree]) != head_tree {
            wt(&["read-tree", &index_tree])?;
            if manifest.sparse.is_some() {
                wt(&["sparse-checkout", "reapply"])?;
            }
            let _ = wt(&["update-index", "-q", "--refresh"]);
        }
    }
    if !manifest.submodules.is_empty() {
        let mut args = vec!["submodule", "update", "--init", "--"];
        args.extend(manifest.submodules.iter().map(String::as_str));
        if let Err(error) = user_git(path, &args, submodules) {
            notes.push(format!("submodules did not come back: {error}"));
        }
    }
    Ok(())
}

fn contains(anchor: &Path, branch: &str, commit: &str) -> bool {
    let reference = format!("refs/heads/{branch}");
    git::read(anchor, &[], &["merge-base", "--is-ancestor", commit, &reference]).is_ok()
}

fn checked_out_branches(anchor: &Path) -> Result<Vec<String>, String> {
    let listing = git::read(anchor, &[], &["worktree", "list", "--porcelain", "-z"])?;
    Ok(crate::inventory::parse_worktree_list(&listing)
        .into_iter()
        .filter_map(|e| e.branch)
        .collect())
}
