use super::*;

#[test]
fn per_user_and_per_workspace_names() {
    let root = Path::new("/state/tailnet-front");
    let user = StableNodeConfig::per_user(root);
    assert_eq!(user.hostname, "cmux");
    assert_eq!(user.state_dir, root.join("cmux"));
    assert!(!user.node_config().ephemeral);
    let ws = StableNodeConfig::per_workspace(root, "api");
    assert_eq!(ws.hostname, "cmux-api");
    assert_eq!(ws.state_dir, root.join("cmux-api"));
}

#[test]
fn closed_listener_errors_end_the_loop() {
    assert!(ends_listener(&io::Error::from_raw_os_error(libc::EBADF)));
    assert!(ends_listener(&io::Error::from(io::ErrorKind::UnexpectedEof)));
    assert!(!ends_listener(&io::Error::other("one record failed")));
}
