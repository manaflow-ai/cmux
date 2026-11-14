use super::*;

#[test]
fn a_folder_is_made_below_its_base_and_never_through_a_link_on_the_way() {
    let dir = std::env::temp_dir().join(format!("make-below-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let (root, outside) = (dir.join("root"), dir.join("outside"));
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    let root = std::fs::canonicalize(&root).unwrap();
    make_below(&root, Path::new("a/b")).unwrap();
    assert!(root.join("a/b").is_dir());
    // A folder inside the base swapped for a link after the base was checked: the walk
    // from `/` does not follow it, so nothing is made in `outside/b`.
    std::fs::create_dir_all(outside.join("b")).unwrap();
    std::fs::remove_dir_all(root.join("a")).unwrap();
    std::os::unix::fs::symlink(&outside, root.join("a")).unwrap();
    assert!(make_below(&root.join("a/b"), Path::new("child")).is_err());
    assert!(make_below(&root, Path::new("a/b/child")).is_err());
    assert!(!outside.join("b/child").exists());
    let _ = std::fs::remove_dir_all(&dir);
}
