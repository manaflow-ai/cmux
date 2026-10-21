//! A reclaimed worktree back where it was, from its manifest: the worktree
//! added again on its branch (or detached at its commit when the branch
//! moved away or is checked out elsewhere), its sparse patterns, its files,
//! its index and its submodules. git writes only from the repository's own
//! objects; a missing archive commit is fetched from the bundle beside the
//! manifest.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Serialize;

use crate::git::{self, user_git};
use crate::inventory::now_ms;
use crate::store::{Manifest, Store};

const LOCAL: Duration = Duration::from_secs(600);
const SUBMODULES: Duration = Duration::from_secs(1800);

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
    /// Things that did not come back, said plainly.
    pub notes: Vec<String>,
}

/// Puts the worktree of `manifest` back at `path` (its old folder when
/// `None`), and marks the manifest restored.
pub fn restore(
    store: &Store,
    manifest: &Manifest,
    path: Option<&Path>,
) -> Result<Restored, String> {
    let path = path.unwrap_or(&manifest.path).to_path_buf();
    if path.exists() && std::fs::read_dir(&path).map(|mut d| d.next().is_some()).unwrap_or(true) {
        return Err(format!("{} is not empty", path.display()));
    }
    let anchor = manifest.main_root.clone().unwrap_or_else(|| manifest.common_dir.clone());
    if !anchor.exists() {
        return Err(format!("the repository {} is gone", anchor.display()));
    }
    let mut notes = Vec::new();
    let checked_out = checked_out_branches(&anchor)?;
    let head = manifest.head.clone();
    let path_arg = path.to_string_lossy().into_owned();
    let mut args = vec!["worktree".to_string(), "add".into(), "--no-checkout".into()];
    let mut branch = None;
    match (&manifest.branch, &head) {
        (Some(name), Some(head)) => {
            let reference = format!("refs/heads/{name}");
            let tip =
                git::try_line(&anchor, &[], &["rev-parse", "--verify", "--quiet", &reference]);
            if tip.is_none() {
                args.extend(["-b".into(), name.clone(), path_arg, head.clone()]);
                branch = Some(name.clone());
            } else if checked_out.contains(name) {
                notes.push(format!("{name} is checked out in another worktree; HEAD is detached"));
                args.extend(["--detach".into(), path_arg, head.clone()]);
            } else if tip.as_deref() == Some(head.as_str()) || contains(&anchor, name, head) {
                args.extend([path_arg, name.clone()]);
                branch = Some(name.clone());
            } else {
                notes.push(format!("{name} moved to a commit without {head}; HEAD is detached"));
                args.extend(["--detach".into(), path_arg, head.clone()]);
            }
        }
        (_, Some(head)) => args.extend(["--detach".into(), path_arg, head.clone()]),
        (_, None) => return Err("the manifest names no commit".to_string()),
    }
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    user_git(&anchor, &args, LOCAL)?;

    let wt = |args: &[&str]| user_git(&path, args, LOCAL);
    if let Some(sparse) = &manifest.sparse {
        wt(&["sparse-checkout", "init", if sparse.cone { "--cone" } else { "--no-cone" }])?;
        let git_dir = git::line(&path, &[], &["rev-parse", "--absolute-git-dir"])?;
        let file = Path::new(&git_dir).join("info/sparse-checkout");
        let mut text = sparse.patterns.join("\n");
        text.push('\n');
        std::fs::write(&file, text).map_err(|e| format!("{}: {e}", file.display()))?;
    }
    wt(&["reset", "--hard", "--quiet", "HEAD"])?;

    let mut archive = false;
    if let (Some(commit), Some(reference)) = (&manifest.archive_commit, &manifest.archive_ref) {
        let have =
            git::read(&anchor, &[], &["cat-file", "-e", &format!("{commit}^{{commit}}")]).is_ok();
        if !have {
            let bundle = manifest
                .bundle
                .as_ref()
                .ok_or("the archive commit is gone and no bundle has it")?;
            let bundle = bundle.to_string_lossy();
            user_git(
                &anchor,
                &["fetch", "--quiet", &bundle, &format!("{reference}:{reference}")],
                LOCAL,
            )?;
        }
        wt(&["restore", "--source", commit, "--worktree", "--", ":/"])?;
        let index_tree = format!("{commit}^2^{{tree}}");
        let head_tree = git::try_line(&path, &[], &["rev-parse", "HEAD^{tree}"]);
        if git::try_line(&path, &[], &["rev-parse", &index_tree]) != head_tree {
            wt(&["read-tree", &index_tree])?;
            if manifest.sparse.is_some() {
                wt(&["sparse-checkout", "reapply"])?;
            }
            let _ = wt(&["update-index", "-q", "--refresh"]);
        }
        archive = true;
    }

    if !manifest.submodules.is_empty() {
        let mut args = vec!["submodule", "update", "--init", "--"];
        args.extend(manifest.submodules.iter().map(String::as_str));
        if let Err(error) = user_git(&path, &args, SUBMODULES) {
            notes.push(format!("submodules did not come back: {error}"));
        }
    }

    store.save(&Manifest { restored_ms: Some(now_ms()), ..manifest.clone() })?;
    Ok(Restored { path, branch, head, archive, notes })
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
