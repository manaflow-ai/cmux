use sha2::{Digest as _, Sha256};

use super::*;

fn sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// A file edited here after the plan read it (between the last check
/// and its move) is never replaced or deleted: the edit stays.
#[test]
fn a_file_edited_after_the_plan_is_never_replaced_or_deleted() {
    let top = tempfile::tempdir().unwrap();
    let (root, staging) = (top.path().join("root"), top.path().join("staging"));
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&staging).unwrap();
    std::fs::write(root.join("a.txt"), "edited\n").unwrap();
    std::fs::write(root.join("b.txt"), "edited\n").unwrap();
    std::fs::write(staging.join("file-1"), "machine\n").unwrap();
    let planned = Expected { sha256: sha256(b"planned\n"), permissions: 0o644 };

    let mut transaction = Transaction::new(&root, &staging).unwrap();
    let error = transaction.write("a.txt", "file-1", Some(&planned)).unwrap_err();
    assert!(error.downcast_ref::<Changed>().is_some(), "{error:#}");
    let error = transaction.delete("b.txt", &planned).unwrap_err();
    assert!(error.downcast_ref::<Changed>().is_some(), "{error:#}");
    // A file made after the plan saw none is not replaced either.
    std::fs::write(root.join("c.txt"), "made here\n").unwrap();
    let error = transaction.write("c.txt", "file-1", None).unwrap_err();
    assert!(error.downcast_ref::<Changed>().is_some(), "{error:#}");
    let _ = transaction.roll_back();

    assert_eq!(std::fs::read_to_string(root.join("a.txt")).unwrap(), "edited\n");
    assert_eq!(std::fs::read_to_string(root.join("b.txt")).unwrap(), "edited\n");
    assert_eq!(std::fs::read_to_string(root.join("c.txt")).unwrap(), "made here\n");
}

/// A symlink made, replaced or removed by a pull is put back exactly by
/// a roll back, and one that changed after the plan stays.
#[test]
fn symlinks_are_placed_and_put_back_and_a_changed_one_stays() {
    let top = tempfile::tempdir().unwrap();
    let (root, staging) = (top.path().join("root"), top.path().join("staging"));
    std::fs::create_dir_all(root.join("src")).unwrap();
    std::fs::create_dir_all(&staging).unwrap();
    std::os::unix::fs::symlink("src", root.join("old")).unwrap();
    std::os::unix::fs::symlink("edited", root.join("mine")).unwrap();

    let mut transaction = Transaction::new(&root, &staging).unwrap();
    transaction.remove_link("old", "src").unwrap();
    transaction.link("old", "src/a").unwrap();
    transaction.link("deep/new", "../src").unwrap();
    assert_eq!(std::fs::read_link(root.join("old")).unwrap(), Path::new("src/a"));
    assert_eq!(std::fs::read_link(root.join("deep/new")).unwrap(), Path::new("../src"));
    let error = transaction.remove_link("mine", "planned").unwrap_err();
    assert!(error.downcast_ref::<Changed>().is_some(), "{error:#}");
    assert_eq!(std::fs::read_link(root.join("mine")).unwrap(), Path::new("edited"));
    transaction.roll_back().unwrap();

    assert_eq!(std::fs::read_link(root.join("old")).unwrap(), Path::new("src"));
    assert!(!root.join("deep").exists());
    assert_eq!(std::fs::read_link(root.join("mine")).unwrap(), Path::new("edited"));
}
