use std::os::unix::fs::PermissionsExt;

#[test]
fn a_test_directory_is_owner_only() {
    let directory = super::short_test_dir("private-");
    let mode = std::fs::metadata(directory.path()).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o700, "mode {mode:o}");
}

/// A caller's umask of 002 (a lane VM's default) made every test directory group-writable,
/// and the stores and daemons that refuse such a folder failed their tests for that alone.
#[test]
fn a_callers_group_writable_umask_does_not_reach_a_test_directory() {
    let exe = std::env::current_exe().unwrap();
    let status = std::process::Command::new("/bin/sh")
        .args(["-c", r#"umask 002; exec "$0" "$@""#])
        .arg(&exe)
        .args(["--exact", "tests::a_test_directory_is_owner_only"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(status.success(), "the directory was not owner-only under umask 002: {status}");
}
