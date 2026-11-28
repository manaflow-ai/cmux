//! The copy's listing for a two-stage projection. Both passes include explicit
//! directory entries for the root. The first pass only descends into harness folders.

use std::collections::HashSet;
use std::io::{Seek as _, Write as _};
use std::path::Path;

use anyhow::{Context as _, bail};

use super::{
    GitDirs, LocalSet, Rules, Skips, add_git_state, add_worktree, git_command, git_state_path,
    holdable, note_ignored, place, plain_ignores, skips, walk_plain_in,
};

fn harness(path: &str) -> bool {
    matches!(
        path.split('/').next(),
        Some(".claude" | ".codex" | ".cursor" | ".gemini" | ".github" | ".vscode")
    )
}

pub(in super::super) fn listed_projection(
    folder: &Path,
    head_only: bool,
) -> anyhow::Result<(LocalSet, Vec<String>)> {
    let mut set = LocalSet::new(Skips::new(folder));
    let mut dirs = Vec::new();
    if let Some(git) = GitDirs::of(folder)? {
        set.git = true;
        let (paths, root_dirs) = worktree_root(folder)?;
        dirs = root_dirs;
        if head_only {
            // Limit argv size even for a very wide root. An empty pathspec means
            // everything to git, so an empty chunk must never reach add_worktree.
            for paths in paths.chunks(256) {
                let paths: Vec<_> = paths.iter().map(String::as_str).collect();
                add_worktree(&mut set, folder, Rules::Copy, &paths)?;
            }
        } else {
            add_worktree(&mut set, folder, Rules::Copy, &[])?;
            note_ignored(&mut set, folder);
        }
        add_git_state(&mut set, &git, &git_state_path)?;
    } else {
        walk_plain_in(
            &mut set,
            Rules::Copy,
            &mut |path| {
                let in_harness = harness(path);
                if (in_harness || !path.contains('/')) && holdable(path) {
                    dirs.push(path.to_owned());
                }
                !head_only || in_harness
            },
            folder,
            folder,
            &place::Dir::open(folder)?,
            &plain_ignores(folder, folder),
        )?;
    }
    Ok((set, dirs))
}

/// Literal pathspecs for the head's working files and directory names for both passes.
/// Git supplies the tracked/untracked distinction and ignore rules under each harness.
fn worktree_root(folder: &Path) -> anyhow::Result<(Vec<String>, Vec<String>)> {
    let root = place::Dir::open(folder)?;
    let mut paths = Vec::new();
    let mut dirs = Vec::new();
    for name in root.names()? {
        let Some(name) = name.to_str().filter(|name| *name != ".git" && holdable(name)) else {
            continue;
        };
        match root.entry(name)? {
            place::Entry::Dir => {
                if skips::credential(name, true).is_none() && !skips::heavy(folder, name) {
                    dirs.push(name.to_owned());
                }
                if harness(name) {
                    paths.push(name.to_owned());
                }
            }
            place::Entry::File { .. } | place::Entry::Link => paths.push(name.to_owned()),
            _ => {}
        }
    }
    if !dirs.is_empty() {
        // With a NUL-delimited file on stdin neither quoting nor argv limits depend on
        // the names. An ignored directory may still have tracked files: those are listed
        // by git and their parent directories are implicit in the full manifest.
        let mut input = tempfile::tempfile()?;
        for dir in &dirs {
            input.write_all(b"./")?;
            input.write_all(dir.as_bytes())?;
            input.write_all(&[0])?;
        }
        input.rewind()?;
        let output = git_command(folder, &["check-ignore", "--stdin", "-z"])
            .stdin(input)
            .output()
            .context("cannot check ignored root directories")?;
        if !matches!(output.status.code(), Some(0 | 1)) {
            bail!("git check-ignore: {}", String::from_utf8_lossy(&output.stderr).trim());
        }
        let ignored: HashSet<_> = output
            .stdout
            .split(|b| *b == 0)
            .map(|path| path.strip_prefix(b"./").unwrap_or(path))
            .collect();
        dirs.retain(|dir| !ignored.contains(dir.as_bytes()));
    }
    Ok((paths, dirs))
}
