//! Tests of the Windows seams (`seams.rs`).

use super::*;

/// A fresh owner-only directory under the temp folder.
fn private_dir(tag: &str) -> PathBuf {
    let nanos =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().subsec_nanos();
    let dir = std::env::temp_dir().join(format!("cth-seam-{tag}-{}-{nanos}", std::process::id()));
    prepare_private_dir(&dir).unwrap();
    dir
}

#[test]
fn a_private_directory_proves_ownership_and_a_shared_one_does_not() {
    let dir = private_dir("owner");
    file_owner(&dir).expect("our owner-only directory");
    let shared = std::env::temp_dir().join(format!("cth-seam-wide-{}", std::process::id()));
    std::fs::create_dir_all(&shared).unwrap();
    let refused = file_owner(&shared).unwrap_err();
    assert_eq!(refused.kind(), io::ErrorKind::PermissionDenied, "{refused}");
    let _ = std::fs::remove_dir_all(&shared);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn record_files_open_by_kind_and_are_private_in_a_private_directory() {
    let dir = private_dir("open");
    let owner = file_owner(&dir).unwrap();
    let path = dir.join("a.json");
    drop(open_private(&path, PrivateOpen::CreateNewNoFollow).unwrap());
    assert_eq!(
        open_private(&path, PrivateOpen::CreateNew).unwrap_err().kind(),
        io::ErrorKind::AlreadyExists
    );
    drop(open_private(&path, PrivateOpen::TruncateNoFollow).unwrap());
    drop(open_private(&path, PrivateOpen::ExistingNoFollow).unwrap());
    let metadata = std::fs::symlink_metadata(&path).unwrap();
    assert!(is_private_file(&metadata, owner));
    assert!(has_single_link(&metadata));
    assert!(!is_endpoint_file(&metadata));
    assert!(!is_private_file(&std::fs::symlink_metadata(&dir).unwrap(), owner));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_rename_never_replaces_an_existing_record() {
    let dir = private_dir("rename");
    let (from, to) = (dir.join("from"), dir.join("to"));
    std::fs::write(&from, b"new").unwrap();
    std::fs::write(&to, b"old").unwrap();
    assert_eq!(rename_no_replace(&from, &to).unwrap_err().kind(), io::ErrorKind::AlreadyExists);
    assert_eq!(std::fs::read(&to).unwrap(), b"old");
    std::fs::remove_file(&to).unwrap();
    rename_no_replace(&from, &to).unwrap();
    assert_eq!(std::fs::read(&to).unwrap(), b"new");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_liveness_lease_reads_held_while_it_lives_and_free_after() {
    let dir = private_dir("live");
    let path = dir.join("t.live");
    let lease = HostLivenessLease::acquire(path.clone()).unwrap();
    assert!(HostLivenessLease::acquire(path.clone()).is_err(), "one lease per file");
    let probe = open_private(&path, PrivateOpen::ExistingNoFollow).unwrap();
    assert_eq!(probe_lease(&probe), LeaseProbe::Held);
    assert!(!lease_was_free(&probe));
    drop(lease);
    assert_eq!(probe_lease(&probe), LeaseProbe::Free);
    wait_lease_exclusive(&probe).unwrap();
    let other = open_private(&path, PrivateOpen::ExistingNoFollow).unwrap();
    assert_eq!(probe_lease(&other), LeaseProbe::Held, "the waited lease holds");
    drop((probe, other));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_process_is_gone_only_after_it_ended() {
    assert!(!process_definitely_gone(std::process::id()));
    let mut child =
        std::process::Command::new("cmd.exe").args(["/c", "exit", "0"]).spawn().unwrap();
    let pid = child.id();
    child.wait().unwrap();
    // The Child still holds a handle: the pid names an exited process.
    assert!(process_definitely_gone(pid));
    drop(child);
}

#[test]
fn the_accept_waker_wakes_and_drains() {
    let waker = AcceptWaker::new().unwrap();
    assert!(!waker.wait_readable(Duration::from_millis(1)).unwrap());
    waker.wake();
    assert!(waker.wait_readable(Duration::from_millis(1)).unwrap());
    waker.drain();
    assert!(!waker.wait_readable(Duration::from_millis(1)).unwrap());
}

#[test]
fn the_canonical_endpoint_is_in_this_users_endpoint_directory() {
    let dir = private_dir("endpoint");
    let owner = file_owner(&dir).unwrap();
    let id = "0123456789abcdef0123456789abcdef";
    assert_eq!(canonical_endpoint(owner, id), endpoint::endpoint_dir().join(format!("{id}.sock")));
    let _ = std::fs::remove_dir_all(&dir);
}
