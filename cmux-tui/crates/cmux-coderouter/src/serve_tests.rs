use super::*;
use std::os::unix::fs::PermissionsExt;
use std::time::{Duration, Instant};

async fn wait_for(path: &Path) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !path.exists() {
        assert!(Instant::now() < deadline, "{} never appeared", path.display());
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// The router's start with no blocking std file call on a worker: the
/// admin socket is still private, and router.lock (opened by tokio, then
/// locked on its own thread) still keeps a second router out until the
/// first one ends.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_admin_socket_is_private_and_router_lock_admits_one_router() {
    let home = tempfile::tempdir().unwrap();
    let socket = admin_socket_path(home.path());
    let first_home = home.path().to_owned();
    let first = tokio::spawn(async move { serve_owned(&first_home, bind_unix_admin).await });
    wait_for(&socket).await;
    let mode = std::fs::metadata(&socket).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600, "admin socket mode {mode:o}");
    assert!(home.path().join("router").join("router.lock").is_file());

    std::fs::remove_file(&socket).unwrap();
    let second_home = home.path().to_owned();
    let second = tokio::spawn(async move { serve_owned(&second_home, bind_unix_admin).await });
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!socket.exists(), "a second router bound its socket while the first held the lock");
    assert!(!second.is_finished());

    first.abort();
    assert!(first.await.unwrap_err().is_cancelled());
    wait_for(&socket).await;
    second.abort();
    let _ = second.await;
}
