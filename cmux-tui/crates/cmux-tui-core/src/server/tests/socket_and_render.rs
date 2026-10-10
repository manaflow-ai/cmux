//! Socket paths, the start lock, JSON line limits, and render attach messages, deltas and the shared graphics cache.

use super::*;

#[cfg(unix)]
#[test]
fn serve_paused_preserves_explicit_socket_parent_permissions() {
    use std::os::unix::fs::PermissionsExt;

    let root = TestSocketDir::create("explicit-runtime-directory");
    let directory = root.path().join("socket-parent");
    std::fs::create_dir(&directory).unwrap();
    std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o755)).unwrap();
    let pending = serve_paused(test_mux(), Some(directory.join("mux.sock"))).unwrap();
    drop(pending);
    assert_eq!(std::fs::metadata(&directory).unwrap().permissions().mode() & 0o777, 0o755);
}

/// A configured socket path longer than sun_path is refused with the
/// path and the limit, never a bare bind error.
#[cfg(unix)]
#[test]
fn serve_paused_names_a_socket_path_longer_than_sun_path() {
    let root = TestSocketDir::create("long");
    let directory = root.path().join("d".repeat(cmux_unix_socket::MAX_PATH_BYTES));
    let socket = directory.join("mux.sock");
    let Err(error) = serve_paused(test_mux(), Some(socket.clone())) else {
        panic!("a socket path longer than sun_path must be refused");
    };
    let message = format!("{error:#}");
    assert!(message.contains(&socket.display().to_string()), "{message}");
    assert!(message.contains("Unix socket limit"), "{message}");
    assert!(!directory.exists(), "nothing is created for a refused path");
}

#[test]
fn serve_paused_creates_missing_explicit_socket_parent() {
    let root = TestSocketDir::create("explicit-runtime-directory-missing");
    let directory = root.path().join("missing").join("nested");
    let socket = directory.join("mux.sock");
    let pending = serve_paused(test_mux(), Some(socket.clone())).unwrap();
    drop(pending);
    assert!(directory.is_dir());
    assert!(!socket.exists());
}

/// Stale-socket recovery (probe, unlink, bind) is not atomic, so
/// unserialized concurrent starts could both classify the socket as
/// stale and the second unlink would strand the first starter on an
/// unreachable socket. The start lock makes exactly one starter win
/// while the winner stays reachable.
#[test]
fn serve_paused_serializes_concurrent_starts_over_a_stale_socket() {
    // Short names keep the socket under the unix path-length cap even in
    // deep macOS temp directories, unlike this module's sibling tests.
    let root = TestSocketDir::create("race");
    let socket = root.path().join("m.sock");
    std::fs::write(&socket, b"stale").unwrap();
    let results: Vec<_> = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..2)
            .map(|_| {
                let socket = socket.clone();
                scope.spawn(move || serve_paused(test_mux(), Some(socket)))
            })
            .collect();
        handles.into_iter().map(|handle| handle.join().unwrap()).collect()
    });
    let winners = results.iter().filter(|result| result.is_ok()).count();
    assert_eq!(winners, 1, "exactly one concurrent starter may bind a stale socket");
    assert!(transport::connect(&socket).is_ok(), "the winner must stay reachable");
    drop(results);
}
