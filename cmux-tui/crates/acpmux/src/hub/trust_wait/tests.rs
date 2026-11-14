use super::only_root_links;
use std::path::Path;

#[test]
fn a_link_the_person_owns_can_be_pointed_elsewhere() {
    let root = std::env::temp_dir().join(format!("acpmux-root-links-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(root.join("target")).unwrap();
    let root = std::fs::canonicalize(&root).unwrap();
    std::os::unix::fs::symlink(root.join("target"), root.join("link")).unwrap();
    assert!(!only_root_links(&root.join("link"), 0));
    assert!(!only_root_links(&root.join("link/sub"), 0));
    assert!(only_root_links(&root.join("target"), 0));
    assert!(!only_root_links(Path::new("relative"), 0));
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_system_link_only_root_can_change_is_taken() {
    // macOS's /tmp -> private/tmp; on a system without it there is nothing to check.
    let tmp = Path::new("/tmp");
    if std::fs::symlink_metadata(tmp).is_ok_and(|m| m.file_type().is_symlink()) {
        assert!(only_root_links(tmp, 0));
    }
}
