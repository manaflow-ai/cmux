use std::path::Path;

/// The limit is the portable 103 bytes every host binds; it was 100, so a
/// 101 to 103-byte path moved to the temporary directory for no reason.
#[test]
fn a_socket_path_up_to_the_portable_limit_stays_in_its_directory() {
    let name = "1.sock";
    let fit =
        "/".to_owned() + &"d".repeat(cmux_unix_socket::PORTABLE_MAX_PATH_BYTES - 2 - name.len());
    let path = super::socket_path(Path::new(&fit), "link-1");
    assert_eq!(path.as_os_str().len(), cmux_unix_socket::PORTABLE_MAX_PATH_BYTES);
    assert_eq!(path.parent(), Some(Path::new(&fit)));
    let over = fit + "d";
    let path = super::socket_path(Path::new(&over), "link-1");
    assert_ne!(path.parent(), Some(Path::new(&over)));
    assert!(path.ends_with(name), "{}", path.display());
}
