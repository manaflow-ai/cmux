use super::*;

#[test]
fn the_entry_sits_next_to_the_session_socket_and_never_on_it() {
    let session = Path::new("/tmp/cmux-501/main.sock");
    let entry = remote_entry_socket_path(session);
    assert_eq!(entry, Path::new("/tmp/cmux-501/link-entry/main.sock"));
    assert_ne!(entry, session);
}

/// RED (security): no session name can produce the entry path. Session
/// sockets are `<dir>/<name>.sock` and names may contain `.`, so the
/// entry must not be a `.sock` file directly in the session directory.
#[test]
fn no_session_socket_can_be_the_entry_socket() {
    for session in ["/tmp/cmux-501/main.sock", "/tmp/cmux-501/main.link.sock"] {
        let session = Path::new(session);
        let entry = remote_entry_socket_path(session);
        assert_ne!(entry.parent(), session.parent(), "{}", entry.display());
    }
    let directory = format!("/tmp/{}", "d".repeat(60));
    let long = PathBuf::from(format!("{directory}/{}.sock", "s".repeat(30)));
    assert_ne!(remote_entry_socket_path(&long).parent(), long.parent());
}

#[test]
fn a_long_session_path_gets_a_short_hashed_entry_in_the_same_directory() {
    let directory = format!("/tmp/{}", "d".repeat(60));
    let session = PathBuf::from(format!("{directory}/{}.sock", "s".repeat(30)));
    let entry = remote_entry_socket_path(&session);
    assert!(fits(&entry), "{}", entry.display());
    assert_eq!(entry.parent(), Some(session.parent().unwrap().join(ENTRY_DIR).as_path()));
}
