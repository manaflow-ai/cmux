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
mod tests {
    use super::*;

    #[test]
    fn start_settings_in_the_root_or_a_subpath_folder_keep_the_head_unmarked() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::create_dir_all(root.join("app/web")).unwrap();
        let folders = [Path::new("app"), Path::new("app/web")];
        assert!(head_allowed(root, &folders));
        std::fs::write(root.join("app/web/.mcp.json"), "{}").unwrap();
        assert!(!head_allowed(root, &folders), "a subpath folder's MCP servers");
        assert!(head_allowed(root, &[]), "the root alone has none");
        std::fs::write(root.join(".mcp.json"), "{}").unwrap();
        assert!(!head_allowed(root, &[]), "the root's MCP servers");
    }

    #[test]
    fn a_subpath_folder_link_out_of_the_head_keeps_it_unmarked() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::create_dir_all(root.join("app/.claude")).unwrap();
        std::os::unix::fs::symlink("../../docs/a.md", root.join("app/.claude/a.md")).unwrap();
        assert!(head_allowed(root, &[]), "a folder off the head is not read");
        assert!(!head_allowed(root, &[Path::new("app")]));
    }

    /// Review F1 (cmux#39018): a harness folder linked to a folder resolves, but the head
    /// holds only that folder's own files, not the skills below it.
    #[test]
    fn a_harness_folder_linked_to_a_folder_keeps_the_head_unmarked() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::create_dir_all(root.join("skills/review")).unwrap();
        std::fs::write(root.join("skills/review/SKILL.md"), "x").unwrap();
        assert!(head_allowed(root, &[]));
        std::os::unix::fs::symlink(".", root.join(".claude")).unwrap();
        assert!(!head_allowed(root, &[]), "a root harness folder");
        std::fs::remove_file(root.join(".claude")).unwrap();
        std::fs::create_dir_all(root.join(".codex")).unwrap();
        std::os::unix::fs::symlink("../skills", root.join(".codex/skills")).unwrap();
        assert!(!head_allowed(root, &[]), "a folder link inside a harness folder");
        std::fs::remove_file(root.join(".codex/skills")).unwrap();
        std::fs::create_dir_all(root.join("app")).unwrap();
        std::os::unix::fs::symlink("..", root.join("app/.claude")).unwrap();
        assert!(head_allowed(root, &[]), "a folder off the head is not read");
        assert!(!head_allowed(root, &[Path::new("app")]), "a subpath folder's harness folder");
    }
}
