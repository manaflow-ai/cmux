use super::*;

/// A scratch folder removed when dropped (this crate has no tempfile dependency).
struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Self {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let dir =
            std::env::temp_dir().join(format!("cmux-git-worktree-root-{}-{n}", std::process::id()));
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
    assert_eq!(std::fs::read_to_string(root.join("app/fix-retry/.git")).unwrap(), "gitdir: x\n");
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
