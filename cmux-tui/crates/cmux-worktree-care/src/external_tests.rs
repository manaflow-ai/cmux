use super::*;

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
