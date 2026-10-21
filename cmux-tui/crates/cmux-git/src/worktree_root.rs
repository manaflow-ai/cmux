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

/// `home/.cmux/worktrees`, after making it the link to
/// `home/.cmux/worktrees.noindex` on macOS. Elsewhere it only returns the path.
pub fn worktree_root(home: &Path) -> io::Result<PathBuf> {
    let root = home.join(".cmux").join("worktrees");
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
            std::fs::rename(root, &real)?;
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
mod tests {
    use super::*;

    /// A scratch folder removed when dropped (this crate has no tempfile dependency).
    struct Scratch(PathBuf);

    impl Scratch {
        fn new() -> Self {
            use std::sync::atomic::{AtomicUsize, Ordering};
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let n = NEXT.fetch_add(1, Ordering::Relaxed);
            let dir = std::env::temp_dir()
                .join(format!("cmux-git-worktree-root-{}-{n}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            Scratch(dir)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn root_in(dir: &Path) -> PathBuf {
        let root = dir.join(".cmux").join("worktrees");
        std::fs::create_dir_all(root.parent().unwrap()).unwrap();
        root
    }

    #[test]
    fn a_first_use_makes_the_noindex_folder_and_the_link() {
        let dir = Scratch::new();
        let root = root_in(dir.path());
        link_noindex(&root).unwrap();
        assert_eq!(std::fs::read_link(&root).unwrap(), Path::new(NOINDEX_NAME));
        assert!(dir.path().join(".cmux").join(NOINDEX_NAME).is_dir());
        link_noindex(&root).unwrap(); // idempotent
        assert_eq!(std::fs::read_link(&root).unwrap(), Path::new(NOINDEX_NAME));
    }

    #[test]
    fn an_existing_folder_moves_whole_and_its_paths_still_work() {
        let dir = Scratch::new();
        let root = root_in(dir.path());
        std::fs::create_dir_all(root.join("app").join("fix-retry")).unwrap();
        std::fs::write(root.join("app").join("fix-retry").join(".git"), "gitdir: x\n").unwrap();
        link_noindex(&root).unwrap();
        let real = dir.path().join(".cmux").join(NOINDEX_NAME);
        assert!(real.join("app/fix-retry/.git").is_file());
        assert_eq!(
            std::fs::read_to_string(root.join("app/fix-retry/.git")).unwrap(),
            "gitdir: x\n"
        );
    }

    #[test]
    fn someone_elses_layout_is_left_alone() {
        let dir = Scratch::new();
        let root = root_in(dir.path());
        let real = dir.path().join(".cmux").join(NOINDEX_NAME);
        std::fs::create_dir_all(root.join("a")).unwrap();
        std::fs::create_dir_all(real.join("b")).unwrap();
        link_noindex(&root).unwrap();
        assert!(
            root.join("a").is_dir()
                && !std::fs::symlink_metadata(&root).unwrap().file_type().is_symlink()
        );
        assert!(real.join("b").is_dir());

        let other = Scratch::new();
        let root = root_in(other.path());
        std::os::unix::fs::symlink(other.path(), &root).unwrap();
        link_noindex(&root).unwrap();
        assert_eq!(std::fs::read_link(&root).unwrap(), other.path());
    }
}
