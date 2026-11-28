//! The daemon's unix socket admits this user only: bound owner-only, its own directory narrowed
//! to 0700 when it already existed wider, and each peer's uid checked at accept.
//!
//! ```text
//! cargo test -p acpmux --lib socket_access
//! ```
use std::os::unix::fs::{MetadataExt, PermissionsExt};

use super::{bind_daemon_unix, bind_unix, peer_uid_allowed, tighten_socket_dir};

fn mode(path: &std::path::Path) -> u32 {
    std::fs::symlink_metadata(path)
        .unwrap_or_else(|e| panic!("stat {}: {e}", path.display()))
        .mode()
        & 0o777
}

fn set_mode(path: &std::path::Path, m: u32) {
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(m))
        .unwrap_or_else(|e| panic!("chmod {}: {e}", path.display()));
}

#[test]
fn only_this_user_or_root_is_a_peer() {
    assert!(peer_uid_allowed(Some(501), 501));
    assert!(peer_uid_allowed(Some(0), 501), "the provisioner");
    assert!(!peer_uid_allowed(Some(502), 501));
    assert!(!peer_uid_allowed(Some(65534), 501));
    assert!(!peer_uid_allowed(None, 501), "a peer whose uid cannot be read");
}

#[test]
fn acpmuxs_own_directory_is_narrowed_and_a_named_one_is_left() {
    let tmp = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let own = tmp.path().join("acpmux-test");
    let named = tmp.path().join("project");
    for dir in [&own, &named] {
        std::fs::create_dir(dir).unwrap_or_else(|e| panic!("mkdir: {e}"));
        set_mode(dir, 0o775);
    }
    tighten_socket_dir(&own).unwrap_or_else(|e| panic!("tighten: {e}"));
    tighten_socket_dir(&named).unwrap_or_else(|e| panic!("tighten: {e}"));
    assert_eq!(mode(&own), 0o700);
    assert_eq!(mode(&named), 0o775, "a directory the person named is never changed");
    // A symlink named like ours is not followed or changed.
    let link = tmp.path().join("acpmux-link");
    std::os::unix::fs::symlink(&named, &link).unwrap_or_else(|e| panic!("symlink: {e}"));
    tighten_socket_dir(&link).unwrap_or_else(|e| panic!("tighten: {e}"));
    assert_eq!(mode(&named), 0o775);
}

#[tokio::test]
async fn the_socket_is_owner_only_and_its_existing_directory_narrowed() {
    let tmp = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let dir = tmp.path().join("acpmux-sock");
    std::fs::create_dir(&dir).unwrap_or_else(|e| panic!("mkdir: {e}"));
    set_mode(&dir, 0o755);
    let socket = dir.join("a.sock");
    let _listener = bind_unix(&socket).await.unwrap_or_else(|e| panic!("bind: {e:#}"));
    assert_eq!(mode(&socket), 0o600);
    assert_eq!(mode(&dir), 0o700);
    // This user still connects.
    tokio::net::UnixStream::connect(&socket).await.unwrap_or_else(|e| panic!("connect: {e}"));
}

/// The bind never sets the process umask (it is process-wide: a folder another thread made
/// during the bind came out 0600, so binding a socket in it failed "Permission denied"), and the
/// private staging folder it binds in is gone afterwards.
#[tokio::test]
async fn the_bind_leaves_the_umask_and_no_staging_folder() {
    let tmp = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let socket = tmp.path().join("acpmux.sock");
    // SAFETY: umask has no preconditions; read and put back at once.
    let before = unsafe { libc::umask(0o022) };
    unsafe { libc::umask(before) };
    let _listener = bind_unix(&socket).await.unwrap_or_else(|e| panic!("bind: {e:#}"));
    // SAFETY: as above.
    let after = unsafe { libc::umask(before) };
    assert_eq!(after, before, "bind_unix left the umask as it found it");
    assert_eq!(mode(&socket), 0o600);
    let left: Vec<_> = std::fs::read_dir(tmp.path())
        .unwrap_or_else(|e| panic!("read_dir: {e}"))
        .filter_map(|e| e.ok().map(|e| e.file_name()))
        .collect();
    assert_eq!(left, vec![std::ffi::OsString::from("acpmux.sock")], "{left:?}");
    tokio::net::UnixStream::connect(&socket).await.unwrap_or_else(|e| panic!("connect: {e}"));
}

/// A take-over start whose socket answers from a listener this process holds (the copy the old
/// daemon handed it), or from the daemon it took over from, replaces the socket. It used to bail
/// "another acpmux daemon owns" and the daemon died at every update. A listener of any other live
/// process is still refused (`tests/daemon_single_owner.rs`).
#[tokio::test]
async fn the_daemon_replaces_a_socket_that_answers_from_its_own_copy() {
    let tmp = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let socket = tmp.path().join("acpmux.sock");
    let copy = bind_unix(&socket).await.unwrap_or_else(|e| panic!("bind: {e:#}"));
    let refused = bind_unix(&socket).await.err().map(|e| format!("{e:#}")).unwrap_or_default();
    assert!(refused.contains("another acpmux daemon owns"), "{refused}");
    let other = bind_daemon_unix(&socket, |_| false).await.err().map(|e| format!("{e:#}"));
    assert!(other.unwrap_or_default().contains("another acpmux daemon owns"));
    let ours = |pid| pid == std::process::id();
    let listener = bind_daemon_unix(&socket, ours).await.unwrap_or_else(|e| panic!("bind: {e:#}"));
    drop(copy);
    let _client = tokio::net::UnixStream::connect(&socket).await.unwrap_or_else(|e| panic!("{e}"));
    let accepted = tokio::time::timeout(std::time::Duration::from_secs(5), listener.accept()).await;
    assert!(matches!(accepted, Ok(Ok(_))), "the new listener serves the socket");
}
