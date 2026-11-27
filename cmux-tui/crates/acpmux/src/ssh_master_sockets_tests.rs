#![cfg(unix)]

use super::*;
use std::os::unix::net::UnixListener;

fn sockets(dir: &Path) -> usize {
    use std::os::unix::fs::FileTypeExt;
    std::fs::read_dir(dir)
        .unwrap()
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|k| k.is_socket()))
        .count()
}

/// Counted before and after: N masters per host leave their sockets when they die, and one more
/// is still live. Before the sweep every socket is in the directory. After it, only the live
/// master's socket and the lock files remain.
#[test]
fn dead_masters_sockets_go_and_a_live_ones_stays() {
    let dir = tempfile::tempdir().unwrap();
    let dead = 6;
    for i in 0..dead {
        // A master that ended without unlinking: bound, then dropped (closed), file left.
        let path = dir.path().join(format!("dead{i:02}"));
        drop(UnixListener::bind(&path).unwrap());
        std::fs::write(path.with_extension("lock"), b"").unwrap();
    }
    let live_path = dir.path().join("live");
    let _live = UnixListener::bind(&live_path).unwrap();
    std::fs::write(dir.path().join("notes"), b"not a socket").unwrap();

    assert_eq!(sockets(dir.path()), dead + 1, "before: every master's socket is left");
    let swept = sweep(dir.path());
    assert_eq!(swept, Swept { removed: dead, live: 1 });
    assert_eq!(sockets(dir.path()), 1, "after: only the live master's socket");
    assert!(live_path.exists());
    assert!(dir.path().join("notes").exists());
    assert!(dir.path().join("dead00.lock").exists(), "locks are kept");
    eprintln!("sockets: before {} (1 live), after {}", dead + 1, sockets(dir.path()));

    // A second sweep finds nothing to do.
    assert_eq!(sweep(dir.path()), Swept { removed: 0, live: 1 });
}

#[test]
fn a_missing_dir_is_nothing() {
    assert_eq!(sweep(Path::new("/nonexistent/acpmux/run/ssh")), Swept::default());
}
