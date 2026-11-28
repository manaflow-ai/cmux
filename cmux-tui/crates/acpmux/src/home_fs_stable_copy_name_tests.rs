/// Every write of one file by one process goes through the same copy name, and none is left:
/// fseventsd keeps every path it is told of until it restarts, so a random name per write
/// (`tempfile::NamedTempFile`) grows it by one path per write (RFD 0180).
#[test]
fn durable_writes_reuse_one_copy_name_and_leave_none() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("state.json");
    let copy = super::aside(&path).expect("copy name");
    assert_eq!(copy, super::aside(&path).expect("copy name"), "the copy name is stable");
    for i in 0..50 {
        super::write_durable(&path, format!("{{\"n\":{i}}}")).expect("write");
    }
    assert_eq!(std::fs::read_to_string(&path).expect("read"), "{\"n\":49}");
    let names: Vec<_> = std::fs::read_dir(dir.path())
        .expect("list")
        .map(|e| e.expect("entry").file_name())
        .collect();
    assert_eq!(names, vec![std::ffi::OsString::from("state.json")], "no copy left beside it");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let mode = std::fs::metadata(&path).expect("meta").permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }
}
