//! RED (decision D4): only a Linux host with a root-owned Cloud image stamp
//! and the Cloud identity serves file ops. The stamp checks run against a
//! temporary tree whose owner stands in for root.

use std::fs;
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _, symlink};
use std::path::PathBuf;

use super::*;

/// `<tmp>/etc/cmux/image-stamp`, removed on drop.
struct Tree {
    base: PathBuf,
}

impl Tree {
    fn new(label: &str) -> Self {
        let base = std::env::temp_dir().join(format!("cmux-stamp-{label}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(base.join("etc/cmux")).unwrap();
        let base = fs::canonicalize(base).unwrap();
        for dir in [base.clone(), base.join("etc"), base.join("etc/cmux")] {
            fs::set_permissions(dir, fs::Permissions::from_mode(0o755)).unwrap();
        }
        Self { base }
    }

    fn stamp(&self) -> PathBuf {
        self.base.join("etc/cmux/image-stamp")
    }

    fn write_stamp(&self, text: &str, mode: u32) {
        fs::write(self.stamp(), text).unwrap();
        fs::set_permissions(self.stamp(), fs::Permissions::from_mode(mode)).unwrap();
    }

    /// The uid that owns the tree (root's stand-in).
    fn owner(&self) -> u32 {
        fs::metadata(&self.base).unwrap().uid()
    }
}

impl Drop for Tree {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.base);
    }
}

#[test]
fn only_a_linux_host_with_a_trusted_stamp_and_the_cloud_identity_serves_fs() {
    assert!(is_cloud_host(true, true, true));
    assert!(!is_cloud_host(false, true, true), "a Mac is never a Cloud host");
    assert!(!is_cloud_host(true, false, true), "no trusted stamp");
    assert!(!is_cloud_host(true, true, false), "no Cloud identity");
}

#[test]
fn a_correct_stamp_tree_is_trusted() {
    let tree = Tree::new("ok");
    tree.write_stamp("cmux-devbox 7 desktop\n", 0o644);
    assert!(trusted_stamp(&tree.stamp(), &tree.base, tree.owner()));
}

#[test]
fn a_stamp_owned_by_a_normal_user_is_refused() {
    let tree = Tree::new("user");
    tree.write_stamp("cmux-devbox 7 desktop\n", 0o644);
    if tree.owner() != 0 {
        assert!(!trusted_stamp(&tree.stamp(), &tree.base, 0), "a user-owned stamp is not root's");
    }
    assert!(!trusted_stamp(&tree.stamp(), &tree.base, tree.owner().wrapping_add(1)));
}

#[test]
fn a_writable_stamp_or_folder_is_refused() {
    let tree = Tree::new("writable");
    tree.write_stamp("cmux-vm inputs=abc md 2026\n", 0o666);
    assert!(!trusted_stamp(&tree.stamp(), &tree.base, tree.owner()), "group/world-writable stamp");
    tree.write_stamp("cmux-vm inputs=abc md 2026\n", 0o644);
    fs::set_permissions(tree.base.join("etc/cmux"), fs::Permissions::from_mode(0o777)).unwrap();
    assert!(!trusted_stamp(&tree.stamp(), &tree.base, tree.owner()), "a writable folder lets anyone swap it");
}

#[test]
fn a_symlinked_stamp_is_refused() {
    let tree = Tree::new("symlink");
    let real = tree.base.join("etc/cmux/real-stamp");
    fs::write(&real, "cmux-devbox 7\n").unwrap();
    fs::set_permissions(&real, fs::Permissions::from_mode(0o644)).unwrap();
    symlink(&real, tree.stamp()).unwrap();
    assert!(!trusted_stamp(&tree.stamp(), &tree.base, tree.owner()));
}

#[test]
fn a_stamp_that_is_not_a_cloud_image_stamp_is_refused() {
    let tree = Tree::new("text");
    tree.write_stamp("something else\n", 0o644);
    assert!(!trusted_stamp(&tree.stamp(), &tree.base, tree.owner()));
    assert!(!trusted_stamp(&tree.base.join("etc/cmux/missing"), &tree.base, tree.owner()));
}
