//! The daemon socket is never reachable with a mode wider than 0600, also
//! between its bind and its chmod: a watcher that reads the path's mode while
//! the daemon binds it, under the widest umask, never sees group or other
//! bits. (Its own test binary: the umask is per process.)
#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_daemon_socket_is_never_wider_than_owner_only() {
    // SAFETY: umask has no preconditions; this test binary runs this test only.
    unsafe { libc::umask(0) };
    let dir = cmux_unix_socket::short_test_dir("acpbind");
    // The socket's directory is private, as the daemon's always is (umask 0 made it 0777).
    std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    let path = dir.path().join("a.sock");
    let stop = Arc::new(AtomicBool::new(false));
    let wide = Arc::new(AtomicU32::new(0));
    let watcher = {
        let (path, stop, wide) = (path.clone(), stop.clone(), wide.clone());
        std::thread::spawn(move || {
            while !stop.load(Ordering::Relaxed) {
                if let Ok(meta) = std::fs::symlink_metadata(&path) {
                    let mode = meta.permissions().mode() & 0o777;
                    if mode & 0o077 != 0 {
                        wide.store(mode, Ordering::Relaxed);
                    }
                }
            }
        })
    };
    for _ in 0..300 {
        let listener = acpmux::server::bind_unix(&path).await.unwrap();
        drop(listener);
        let _ = std::fs::remove_file(&path);
    }
    stop.store(true, Ordering::Relaxed);
    watcher.join().unwrap();
    let mode = wide.load(Ordering::Relaxed);
    assert_eq!(mode, 0, "the socket was reachable with mode {mode:o}");
}
