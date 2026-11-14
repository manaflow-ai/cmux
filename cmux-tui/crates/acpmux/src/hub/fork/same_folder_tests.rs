use super::same_folder;

#[test]
fn the_same_folder_spelled_another_way_is_not_a_move() {
    let dir = tempfile::tempdir().unwrap();
    let other = tempfile::tempdir().unwrap();
    assert!(same_folder(dir.path(), &dir.path().join(".")));
    assert!(!same_folder(dir.path(), other.path()));
}
