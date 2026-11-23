use super::*;

#[test]
fn carrier_names_are_twelve_lowercase_hex() {
    assert!(is_carrier_name("cmux-link-0123456789ab.sock"));
    assert!(!is_carrier_name("cmux-link-0123456789AB.sock"));
    assert!(!is_carrier_name("cmux-link-0123456789a.sock"));
    assert!(!is_carrier_name("cmux.sock"));
}

#[test]
fn a_path_that_is_not_a_carrier_socket_is_refused() {
    for (path, why) in [
        ("relative/cmux-link-0123456789ab.sock", "not an absolute path"),
        ("/tmp/../cmux-link-0123456789ab.sock", "not a carrier socket path"),
        ("/tmp/daemon.sock", "not a carrier socket path"),
    ] {
        assert_eq!(check_as(path, 501), Err(unsafe_socket(why)), "{path}");
    }
}

#[test]
fn an_open_directory_names_the_chmod_target() {
    let base = std::env::temp_dir().join(format!("serve-policy-{}", std::process::id()));
    std::fs::create_dir_all(&base).expect("temp dir");
    std::fs::set_permissions(&base, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    let path = base.join("cmux-link-0123456789ab.sock");
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    let result = check_as(&path.to_string_lossy(), uid);
    std::fs::remove_dir_all(&base).expect("cleanup");
    // An ancestor of the temp dir may already fail first on some hosts;
    // when the ancestors pass, the directory's own mode is what fails.
    if let Err(LinkError::OpenDirectory { path: open, parent: false }) = &result {
        assert_eq!(Path::new(open), base);
    } else {
        assert!(result.is_err(), "{result:?}");
    }
}
