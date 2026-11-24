use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};

use super::{answering, candidates};

#[test]
fn candidates_are_the_nightly_paths_new_then_old() {
    let paths = candidates(Path::new("/Users/a"));
    assert_eq!(
        paths,
        vec![
            PathBuf::from("/Users/a/.local/state/cmux/cmux-nightly.sock"),
            PathBuf::from("/tmp/cmux-nightly.sock"),
        ]
    );
}

#[test]
fn the_one_socket_that_answers_is_picked() {
    let dir = tempfile::tempdir().unwrap();
    let live = dir.path().join("live.sock");
    let stale = dir.path().join("stale.sock");
    let _listener = UnixListener::bind(&live).unwrap();
    // A socket file nothing listens on any more (an app that quit).
    drop(UnixListener::bind(&stale).unwrap());
    let missing = dir.path().join("missing.sock");
    let answers = |path: &Path| std::os::unix::net::UnixStream::connect(path).is_ok();
    assert_eq!(answering(&[stale.clone(), missing.clone(), live.clone()], answers), Some(live));
    assert_eq!(answering(&[stale, missing], answers), None);
}

#[test]
fn two_answering_sockets_pick_none() {
    let dir = tempfile::tempdir().unwrap();
    let a = dir.path().join("a.sock");
    let b = dir.path().join("b.sock");
    let _a = UnixListener::bind(&a).unwrap();
    let _b = UnixListener::bind(&b).unwrap();
    let answers = |path: &Path| std::os::unix::net::UnixStream::connect(path).is_ok();
    assert_eq!(answering(&[a, b], answers), None);
}

#[test]
fn a_symlink_to_the_answering_socket_is_the_same_socket() {
    let dir = tempfile::tempdir().unwrap();
    let real = dir.path().join("real.sock");
    let link = dir.path().join("link.sock");
    let _listener = UnixListener::bind(&real).unwrap();
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let answers = |path: &Path| std::os::unix::net::UnixStream::connect(path).is_ok();
    assert_eq!(answering(&[real.clone(), link], answers), Some(real));
}
