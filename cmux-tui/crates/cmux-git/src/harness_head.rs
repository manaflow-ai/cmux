//! What a harness reads as it starts in a checkout that fills head first: the root's own
//! files, the harness folders ([`HEAD_DIRS`]) and, for a chat opened below the root, each
//! folder on its path with its own files. Shared by the repo pick's `cmux repo hold`
//! (cmux-tui) and the Mac folder seed (cmux-tui-core `git_seed`), the two producers that
//! mark [`crate::sync_barrier::Sync::head_ready`] (cmuxterm-hq goals/cloud-no-network-wait.md).

use std::path::Path;

/// The folders a harness reads at start, beside a folder's own files (the repo pick's
/// `head_dirs` in cmux-cloud-start-core `machine_repo/step.sh`).
pub const HEAD_DIRS: &[&str] =
    &[".claude", ".codex", ".cursor", ".gemini", ".github", ".vscode", ".devcontainer"];

/// The head's harness settings that run a command when the harness starts (hooks, and the
/// project's MCP servers, which start outside the tool gate): a start at the head would run
/// them on a partial checkout, so such a head is never marked.
pub const START_SETTINGS: &[&str] =
    &[".claude/settings.json", ".claude/settings.local.json", ".mcp.json"];

/// Whether the head of `root` may be marked ready. `folders`: the folders below `root`,
/// relative, whose own files and harness folders the head holds too (a chat's subpath and
/// its parents). In none of them is one of [`START_SETTINGS`], and no symlink there or in
/// their [`HEAD_DIRS`] points at what the head left out (a `CLAUDE.md` linked into
/// `docs/`): a start would read no instructions where the whole checkout has them. Nor
/// does any of them link to a folder: a `.claude -> .` resolves, but the head holds only
/// its target's own files, not the `skills/` below it a start would read.
pub fn head_allowed(root: &Path, folders: &[&Path]) -> bool {
    std::iter::once(root.to_path_buf()).chain(folders.iter().map(|folder| root.join(folder))).all(
        |dir| {
            START_SETTINGS
                .iter()
                .all(|settings| std::fs::symlink_metadata(dir.join(settings)).is_err())
                && !links_out_of_the_head(&dir, 0)
        },
    )
}

/// Whether the file at `relative` (to the root, `/`-separated) is in the head of a chat opened
/// at `subpath` (`a/b`, empty for the root): a file of the root or of a folder on the subpath,
/// or one anywhere in their [`HEAD_DIRS`]. The Mac's held copy (cmux-tui `link::seed_cli`)
/// sends these first, for the machine to mark with [`head_allowed`].
pub fn in_head(relative: &str, subpath: &str) -> bool {
    let subpath = subpath.trim_matches('/');
    let mut folders = vec![""];
    if !subpath.is_empty() {
        folders.extend(subpath.match_indices('/').filter_map(|(at, _)| subpath.get(..at)));
        folders.push(subpath);
    }
    folders.iter().any(|folder| {
        let rest = if folder.is_empty() {
            Some(relative)
        } else {
            relative.strip_prefix(*folder).and_then(|rest| rest.strip_prefix('/'))
        };
        rest.is_some_and(|rest| match rest.split_once('/') {
            None => true,
            Some((first, _)) => HEAD_DIRS.contains(&first),
        })
    })
}

/// A symlink in `dir` (and, from a head folder, in [`HEAD_DIRS`]) whose target is not there
/// or is a folder.
fn links_out_of_the_head(dir: &Path, depth: usize) -> bool {
    let Ok(entries) = std::fs::read_dir(dir) else { return false };
    entries.flatten().any(|entry| {
        let path = entry.path();
        let Ok(kind) = entry.file_type() else { return true };
        if kind.is_symlink() {
            return std::fs::metadata(&path).ok().is_none_or(|target| target.is_dir());
        }
        let harness = depth == 0 && HEAD_DIRS.iter().any(|d| entry.file_name() == *d);
        kind.is_dir()
            && (harness || depth > 0)
            && depth < 8
            && links_out_of_the_head(&path, depth + 1)
    })
}

#[cfg(test)]
mod tests;
