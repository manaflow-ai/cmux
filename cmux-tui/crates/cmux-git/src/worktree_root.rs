//! Where cmux puts the worktrees it makes: `~/.cmux/worktrees`, which on
//! macOS is a link to `~/.cmux/worktrees.noindex`. Spotlight skips a folder
//! whose name ends in `.noindex`, so it no longer indexes every checkout an
//! agent makes (one Mac had over a hundred of them, each a full source tree
//! with its build output). Every path cmux records or prints stays
//! `~/.cmux/worktrees/...`, and the link keeps those working.
//!
//! [`worktree_root`] makes that layout on first use and migrates an existing
//! `~/.cmux/worktrees` folder: one rename on the same volume, so a worktree
//! is never half moved, then the link at the old path. A process working in
//! a worktree keeps its working directory, and git finds every registered
//! worktree through the link. Anything other than a plain folder or an
//! absent path (a link someone made, a file) is left as it is.

use std::io;
use std::path::{Path, PathBuf};

/// The real folder's name, beside the `worktrees` link.
pub const NOINDEX_NAME: &str = "worktrees.noindex";

/// `home/.cmux/worktrees`, without touching it: where [`worktree_root`] makes its worktrees.
pub fn worktree_root_path(home: &Path) -> PathBuf {
    home.join(".cmux").join("worktrees")
}

/// `home/.cmux/worktrees`, after making it the link to
/// `home/.cmux/worktrees.noindex` on macOS. Elsewhere it only returns the path.
pub fn worktree_root(home: &Path) -> io::Result<PathBuf> {
    let root = worktree_root_path(home);
    if cfg!(target_os = "macos") {
        link_noindex(&root)?;
    }
    Ok(root)
}

/// Makes `root` a relative link to its `.noindex` sibling, moving a plain
/// folder there first. Leaves `root` alone when it is already a link or the
/// sibling exists beside a real folder (someone else's layout, not ours to merge).
pub fn link_noindex(root: &Path) -> io::Result<()> {
    let parent = root.parent().ok_or_else(|| io::Error::other("worktree root has no parent"))?;
    let real = parent.join(NOINDEX_NAME);
    match std::fs::symlink_metadata(root) {
        Ok(meta) if meta.file_type().is_symlink() => return Ok(()),
        Ok(meta) if meta.is_dir() => {
            if std::fs::symlink_metadata(&real).is_ok() {
                return Ok(());
            }
            if let Err(error) = std::fs::rename(root, &real) {
                // Another process migrated it between our check and the rename.
                let linked =
                    std::fs::symlink_metadata(root).is_ok_and(|m| m.file_type().is_symlink());
                return if linked { Ok(()) } else { Err(error) };
            }
        }
        Ok(_) => return Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            std::fs::create_dir_all(&real)?;
        }
        Err(error) => return Err(error),
    }
    match symlink(Path::new(NOINDEX_NAME), root) {
        // Another process made the link between our check and now.
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists && root.is_dir() => Ok(()),
        other => other,
    }
}

#[cfg(unix)]
fn symlink(target: &Path, link: &Path) -> io::Result<()> {
    std::os::unix::fs::symlink(target, link)
}

#[cfg(not(unix))]
fn symlink(_target: &Path, _link: &Path) -> io::Result<()> {
    Err(io::Error::other("worktree root links need a unix host"))
}

#[cfg(all(test, unix))]
#[path = "worktree_root_tests.rs"]
mod tests;
