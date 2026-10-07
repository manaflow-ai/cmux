use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::UnixListener;

use super::*;

/// RED: the file is 0600 and replaced by a rename (a new inode each time),
/// never truncated in place, and no temp file stays behind.
#[test]
fn the_registration_is_written_atomically_with_mode_0600() {
    let directory = cmux_unix_socket::short_test_dir("linkreg");
    let state = directory.path();
    write(state, &Registration::new("/tmp/a.sock".into(), 11)).unwrap();
    let first = std::fs::metadata(path(state)).unwrap();
    assert_eq!(first.permissions().mode() & 0o777, 0o600);
    write(state, &Registration::new("/tmp/b.sock".into(), 12)).unwrap();
    let second = std::fs::metadata(path(state)).unwrap();
    assert_eq!(second.permissions().mode() & 0o777, 0o600);
    assert_ne!(first.ino(), second.ino(), "the file was rewritten in place, not renamed");
    let names: Vec<_> = std::fs::read_dir(state)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    assert_eq!(names, vec![FILE_NAME.to_string()]);
    assert_eq!(read(state), Some(Registration::new("/tmp/b.sock".into(), 12)));
    assert_eq!(
        std::fs::read_to_string(path(state)).unwrap(),
        r#"{"version":1,"socket":"/tmp/b.sock","pid":12}"#
    );
}

/// RED: after a link crash the file stays; readers get `None`, never a dead
/// socket: a gone pid, or a live pid whose socket does not accept.
#[test]
fn a_registration_left_by_a_crashed_link_reads_as_none() {
    let directory = cmux_unix_socket::short_test_dir("linkreg");
    let state = directory.path();
    let socket = state.join("l.sock");
    let mut child = std::process::Command::new("true").spawn().unwrap();
    let dead_pid = child.id();
    child.wait().unwrap();
    write(state, &Registration::new(socket.clone(), dead_pid)).unwrap();
    assert_eq!(read_live(state), None, "a dead pid");
    write(state, &Registration::new(socket.clone(), std::process::id())).unwrap();
    assert_eq!(read_live(state), None, "a live pid but no socket");
    let _listener = UnixListener::bind(&socket).unwrap();
    assert_eq!(read_live(state), Some(Registration::new(socket, std::process::id())));
}

#[test]
fn only_the_owning_link_removes_its_registration() {
    let directory = cmux_unix_socket::short_test_dir("linkreg");
    let state = directory.path();
    write(state, &Registration::new("/tmp/a.sock".into(), 77)).unwrap();
    remove_if_owned(state, 78);
    assert!(read(state).is_some());
    remove_if_owned(state, 77);
    assert!(read(state).is_none());
}
