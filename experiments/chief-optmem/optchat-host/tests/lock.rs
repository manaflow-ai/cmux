//! One writer per chat (section 2).

mod common;

use std::os::unix::net::UnixListener;

use common::*;
use optchat_host::*;

#[test]
fn a_second_open_is_refused_while_the_first_lives() {
    let dir = tempfile::tempdir().unwrap();
    let first = open(dir.path(), 128_000, instant(200));
    // Many probes: unaccepted connections would fill the backlog and make the
    // live lock look stale.
    for _ in 0..300 {
        let second = OptChat::open_with(
            dir.path(),
            config(128_000).0,
            instant(200),
            std::sync::Arc::new(SystemClock),
        );
        assert!(matches!(second, Err(Error::Locked)));
    }
    first.append(Kind::User, "still mine").unwrap();
    first.shutdown();
    assert!(matches!(
        first.append(Kind::User, "late"),
        Err(Error::Closed)
    ));
    // After shutdown the socket file remains but refuses: taken over.
    assert!(dir.path().join("lock").exists());
    let second = open(dir.path(), 128_000, instant(200));
    assert_eq!(second.append(Kind::User, "now yours").unwrap(), 1);
}

#[test]
fn a_stale_socket_is_taken_over() {
    let dir = tempfile::tempdir().unwrap();
    // A dead owner leaves its socket file behind; the OS closed the socket.
    drop(UnixListener::bind(dir.path().join("lock")).unwrap());
    assert!(dir.path().join("lock").exists());
    let chat = open(dir.path(), 128_000, instant(200));
    assert!(matches!(
        OptChat::open_with(
            dir.path(),
            config(128_000).0,
            instant(200),
            std::sync::Arc::new(SystemClock)
        ),
        Err(Error::Locked)
    ));
    drop(chat);
    // No leftovers from the takeover besides the lock itself.
    let names: Vec<String> = std::fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter(|n| n.starts_with("lock"))
        .collect();
    assert_eq!(names, vec!["lock".to_string()]);
}

#[test]
fn a_child_process_is_refused_too() {
    // Run this test binary as the second process: it tries to open the chat.
    if let Ok(dir) = std::env::var("OPTCHAT_LOCK_CHILD_DIR") {
        let r = OptChat::open_with(
            &dir,
            config(128_000).0,
            instant(200),
            std::sync::Arc::new(SystemClock),
        );
        std::process::exit(if matches!(r, Err(Error::Locked)) {
            3
        } else {
            4
        });
    }
    let dir = tempfile::tempdir().unwrap();
    let chat = open(dir.path(), 128_000, instant(200));
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["a_child_process_is_refused_too", "--exact", "--nocapture"])
        .env("OPTCHAT_LOCK_CHILD_DIR", dir.path())
        .status()
        .unwrap();
    assert_eq!(status.code(), Some(3));
    drop(chat);
}
