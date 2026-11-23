use super::fresh_private_dir;

#[test]
fn a_snapshot_directory_is_always_a_new_one() {
    let first = fresh_private_dir().unwrap();
    let second = fresh_private_dir().unwrap();
    assert_ne!(first, second);
    assert!(super::create_new_private_dir(&first).is_err(), "an existing path is refused");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&first).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o700);
    }
    std::fs::remove_dir(&first).unwrap();
    std::fs::remove_dir(&second).unwrap();
}
