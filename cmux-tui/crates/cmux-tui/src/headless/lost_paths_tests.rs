use super::Reachable;
use std::path::Path;

fn read(socket: &Path, state: Option<&Path>) -> Option<Reachable> {
    let folder = socket.parent().map(Path::to_path_buf);
    let required = std::iter::once(socket.to_path_buf()).chain(folder.clone());
    Reachable::read(folder, state.map(Path::to_path_buf), required)
}

#[test]
fn a_removed_or_replaced_path_is_lost_and_an_unchanged_one_is_not() {
    let root = tempfile::tempdir().unwrap();
    let state = root.path().join("state");
    std::fs::create_dir(&state).unwrap();
    let socket = root.path().join("run").join("owner.sock");
    std::fs::create_dir(socket.parent().unwrap()).unwrap();
    std::fs::write(&socket, "").unwrap();
    let reachable = read(&socket, Some(&state)).unwrap();
    assert_eq!(reachable.lost(), None);
    // Replaced: another file renamed over it (made while the first one
    // exists, so it cannot reuse the first one's inode).
    std::fs::write(root.path().join("other"), "").unwrap();
    std::fs::rename(root.path().join("other"), &socket).unwrap();
    assert!(reachable.lost().unwrap().ends_with("was replaced"), "{:?}", reachable.lost());
    let reachable = read(&socket, Some(&state)).unwrap();
    std::fs::remove_dir_all(&state).unwrap();
    assert!(reachable.lost().unwrap().ends_with("was removed"), "{:?}", reachable.lost());
}

/// The process that started the owner may remove its root the moment it
/// reads the readiness byte; a socket already gone then is a loss.
#[test]
fn a_socket_gone_before_the_owner_was_ready_is_lost() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("owner.sock");
    let reachable = read(&socket, None).expect("the folder is watched");
    assert!(reachable.lost().unwrap().ends_with("before the owner was ready"));
}

/// An in-memory session has no state directory: that is no loss.
#[test]
fn a_missing_state_directory_is_optional() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("owner.sock");
    std::fs::write(&socket, "").unwrap();
    let reachable = read(&socket, Some(&root.path().join("no-state"))).unwrap();
    assert_eq!(reachable.lost(), None);
}

/// A symlinked state directory is the directory it names: removing the
/// target is a loss.
#[test]
fn a_symlinked_state_directory_follows_its_target() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("owner.sock");
    std::fs::write(&socket, "").unwrap();
    let target = root.path().join("target");
    std::fs::create_dir(&target).unwrap();
    let link = root.path().join("state");
    std::os::unix::fs::symlink(&target, &link).unwrap();
    let reachable = read(&socket, Some(&link)).unwrap();
    assert_eq!(reachable.lost(), None);
    std::fs::remove_dir(&target).unwrap();
    assert!(reachable.lost().unwrap().ends_with("was removed"), "{:?}", reachable.lost());
}
