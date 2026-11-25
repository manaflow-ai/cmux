//! The git reads: bounded and confined by `cmux-git` (no hook, filter,
//! fsmonitor or transport from the repository runs). Nothing is written.

use std::path::{Path, PathBuf};
use std::time::Duration;

use cmux_git::run::run_git_within;

const READ: Duration = Duration::from_secs(20);
const MAX_OUTPUT: usize = 8 << 20;

/// One entry of `git worktree list --porcelain -z`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct ListEntry {
    pub path: PathBuf,
    pub branch: Option<String>,
    pub prunable: bool,
}

fn read(dir: &Path, args: &[&str]) -> Result<Vec<u8>, String> {
    let overrides = cmux_git::filter_overrides(dir).map_err(|f| f.reason())?;
    let output = run_git_within(dir, &overrides, args, MAX_OUTPUT, READ).map_err(|f| f.reason())?;
    if output.truncated {
        return Err(format!("git {} printed more than {MAX_OUTPUT} bytes", args.join(" ")));
    }
    Ok(output.stdout)
}

/// The repository's worktrees, the main one first.
pub(crate) fn worktrees(root: &Path) -> Result<Vec<ListEntry>, String> {
    Ok(parse_worktree_list(&read(root, &["worktree", "list", "--porcelain", "-z"])?))
}

/// Whether `commit` names a commit in the repository at `root`.
pub(crate) fn has_commit(root: &Path, commit: &str) -> bool {
    if commit.is_empty() || !commit.bytes().all(|b| b.is_ascii_hexdigit()) {
        return false;
    }
    let spec = format!("{commit}^{{commit}}");
    read(root, &["cat-file", "-e", &spec]).is_ok()
}

/// Whether `branch` is a local branch of the repository at `root`.
pub(crate) fn has_branch(root: &Path, branch: &str) -> bool {
    let reference = format!("refs/heads/{branch}");
    read(root, &["show-ref", "--verify", "--quiet", &reference]).is_ok()
}

pub(crate) fn parse_worktree_list(bytes: &[u8]) -> Vec<ListEntry> {
    let mut entries = Vec::new();
    let mut current: Option<ListEntry> = None;
    for record in bytes.split(|b| *b == 0) {
        let text = String::from_utf8_lossy(record);
        if text.is_empty() {
            entries.extend(current.take());
            continue;
        }
        let (key, value) = text.split_once(' ').unwrap_or((&text, ""));
        if key == "worktree" {
            entries.extend(current.take());
            current = Some(ListEntry { path: PathBuf::from(value), ..ListEntry::default() });
            continue;
        }
        let Some(entry) = current.as_mut() else { continue };
        match key {
            "branch" => entry.branch = value.strip_prefix("refs/heads/").map(str::to_string),
            "prunable" => entry.prunable = true,
            _ => {}
        }
    }
    entries.extend(current);
    entries
}

pub(crate) fn same_path(a: &Path, b: &Path) -> bool {
    a == b
        || match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
            (Ok(a), Ok(b)) => a == b,
            _ => false,
        }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn porcelain_entries() {
        let listing = b"worktree /r\0HEAD 0123\0branch refs/heads/main\0\0worktree /w/a\0HEAD 4567\0branch refs/heads/feat\0\0worktree /w/gone\0HEAD 89ab\0detached\0prunable gitdir file points to non-existent location\0\0";
        let entries = parse_worktree_list(listing);
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[1].branch.as_deref(), Some("feat"));
        assert!(entries[2].prunable && entries[2].branch.is_none());
    }
}
