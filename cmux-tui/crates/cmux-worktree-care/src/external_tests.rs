use super::*;

/// A clean Mac has no developer folder: no `xcrun`, so no simulator pass (it would open
/// Apple's developer tools installer). Any one of `xcrun`'s folders is enough.
#[test]
fn simulators_are_pruned_only_with_developer_tools_installed() {
    use std::path::Path;
    let none = |_: &Path| false;
    assert!(!developer_tools_installed(None, &none));
    let only_empty = |p: &Path| p.as_os_str().is_empty();
    assert!(!developer_tools_installed(Some("".into()), &only_empty), "an empty DEVELOPER_DIR");
    for folder in [
        "/var/db/xcode_select_link",
        "/Applications/Xcode.app",
        "/Library/Developer/CommandLineTools",
    ] {
        assert!(
            developer_tools_installed(None, &|p: &Path| p == Path::new(folder)),
            "{folder}"
        );
    }
    let dir = "/opt/Xcode-beta.app/Contents/Developer";
    assert!(developer_tools_installed(Some(dir.into()), &|p: &Path| p == Path::new(dir)));
    assert!(
        !developer_tools_installed(Some(dir.into()), &none),
        "a DEVELOPER_DIR that is gone"
    );
    if !cfg!(target_os = "macos") {
        assert!(!simulators_present());
    }
}

#[test]
fn only_a_daemon_on_a_socket_of_this_users_is_pruned() {
    let mine = crate::store::care_tests::scratch("docker-own");
    let socket = mine.join("docker.sock");
    std::fs::write(&socket, b"").unwrap();
    assert!(daemon_is_mine(&format!("unix://{}", socket.display())).is_ok());
    assert!(daemon_is_mine("tcp://10.0.0.1:2375").is_err());
    assert!(daemon_is_mine("unix:///nonexistent/docker.sock").is_err());
    #[cfg(unix)]
    if unsafe { libc::geteuid() } != 0 {
        // Root's file, as a system daemon's socket is.
        assert!(daemon_is_mine("unix:///etc/passwd").unwrap_err().contains("shared"));
    }
    let _ = std::fs::remove_dir_all(&mine);
}

#[test]
fn docker_sizes_parse() {
    assert_eq!(parse_size("1.5GB (45%)"), Some(1_500_000_000));
    assert_eq!(parse_size("0B"), Some(0));
    assert_eq!(parse_size("12.3MB"), Some(12_300_000));
    assert_eq!(parse_size("n/a"), None);
}
