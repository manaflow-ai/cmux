//! The daemon's unix socket admits this user only: bound owner-only, its own directory narrowed
//! to 0700 when it already existed wider, and each peer's uid checked at accept.
//!
//! ```text
//! cargo test -p acpmux --lib socket_access
//! ```
use std::os::unix::fs::{MetadataExt, PermissionsExt};

use super::{bind_unix, peer_uid_allowed, tighten_socket_dir};

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
