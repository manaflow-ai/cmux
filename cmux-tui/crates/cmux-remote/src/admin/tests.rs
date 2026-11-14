use tempfile::tempdir;
use tokio::io::AsyncWriteExt;
use tokio::net::UnixListener;
use tokio::time::{Duration as TokioDuration, timeout};

use super::*;
use crate::identity::AuthDatabase;
use crate::session::SessionLimits;

#[test]
fn admin_listener_retries_recoverable_accept_errors() {
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "admin::tests::admin_listener_accept_exhaustion_fixture", "--nocapture"])
        .env("CMUX_TEST_ADMIN_ACCEPT_EXHAUSTION", "1")
        .status()
        .unwrap();

    assert!(status.success(), "admin listener stopped after a recoverable accept error");
}

#[tokio::test]
async fn admin_server_shutdown_reports_listener_task_failure() {
    let directory = tempdir().unwrap();
    let auth =
        AuthDatabase::load_or_create(directory.path().join("state"), "failed-admin-task", true)
            .unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let socket = directory.path().join("admin.sock");
    let server = serve_admin(daemon, &socket, Vec::new()).await.unwrap();
    server.task.as_ref().unwrap().abort();

    let error = server.shutdown().await.unwrap_err();

    assert!(error.to_string().contains("admin listener task failed"), "{error}");
}

#[tokio::test]
async fn owner_can_create_invitation_and_read_status() {
    let directory = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(directory.path().join("state"), "test", true).unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let socket = directory.path().join("admin.sock");
    let server =
        serve_admin(daemon, &socket, vec!["ws://127.0.0.1:1/v1/link".into()]).await.unwrap();

    let status = call_admin(&socket, &AdminRequest::Status).await.unwrap();
    assert!(status.ok);
    assert_eq!(status.result.unwrap()["daemon_name"], "test");

    let invitation = call_admin(
        &socket,
        &AdminRequest::CreateInvitation {
            ttl_seconds: 60,
            route_hints: vec![],
            relay_access: vec![],
        },
    )
    .await
    .unwrap();
    assert!(invitation.ok);
    assert!(invitation.result.unwrap()["uri"].as_str().unwrap().starts_with("cmux://enroll/"));
    server.shutdown().await.unwrap();
}

#[tokio::test]
async fn legacy_owner_can_request_runtime_shutdown() {
    let directory = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(directory.path().join("state"), "shutdown-test", true)
        .unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let socket = directory.path().join("admin.sock");
    let (shutdown_tx, mut shutdown_rx) = watch::channel(false);
    let server = serve_admin_with_shutdown(daemon, &socket, Vec::new(), None, Some(shutdown_tx))
        .await
        .unwrap();

    let response = call_admin(&socket, &AdminRequest::Shutdown).await.unwrap();
    assert!(response.ok);
    shutdown_rx.changed().await.unwrap();
    assert!(*shutdown_rx.borrow());
    server.shutdown().await.unwrap();
}

#[tokio::test]
async fn lifecycle_shutdown_requires_the_matching_daemon_instance() {
    let directory = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(directory.path().join("state"), "shutdown-test", true)
        .unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let socket = directory.path().join("admin.sock");
    let (shutdown_tx, mut shutdown_rx) = watch::channel(false);
    let server = serve_admin_with_shutdown(
        daemon,
        &socket,
        Vec::new(),
        Some("current-lifecycle".into()),
        Some(shutdown_tx),
    )
    .await
    .unwrap();

    let mismatch = call_admin(
        &socket,
        &AdminRequest::ShutdownLifecycle { lifecycle_id: "stale-lifecycle".into() },
    )
    .await
    .unwrap();
    assert!(!mismatch.ok);
    assert!(!*shutdown_rx.borrow());
    assert!(!shutdown_rx.has_changed().unwrap());

    let legacy = call_admin(&socket, &AdminRequest::Shutdown).await.unwrap();
    assert!(!legacy.ok);
    assert!(!*shutdown_rx.borrow());
    assert!(!shutdown_rx.has_changed().unwrap());

    let matching = call_admin(
        &socket,
        &AdminRequest::ShutdownLifecycle { lifecycle_id: "current-lifecycle".into() },
    )
    .await
    .unwrap();
    assert!(matching.ok);
    shutdown_rx.changed().await.unwrap();
    assert!(*shutdown_rx.borrow());
    server.shutdown().await.unwrap();
}

#[cfg(unix)]
#[tokio::test]
async fn admin_socket_rejects_an_intermediate_symlink_before_creating_the_parent() {
    use std::os::unix::fs::symlink;

    let directory = tempdir().unwrap();
    let target = directory.path().join("target");
    let alias = directory.path().join("alias");
    std::fs::create_dir(&target).unwrap();
    symlink(&target, &alias).unwrap();

    let result = OwnedUnixListener::bind(alias.join("missing/admin.sock")).await;

    assert!(result.is_err(), "intermediate symlink was accepted");
    assert!(!target.join("missing").exists());
}

#[cfg(unix)]
#[tokio::test]
async fn admin_server_respects_the_socket_path_lock() {
    use std::fs::OpenOptions;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;

    let directory = tempdir().unwrap();
    let socket = directory.path().join("admin.sock");
    let stale = UnixListener::bind(&socket).unwrap();
    drop(stale);
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(directory.path().join("admin.sock.lock"))
        .unwrap();
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);
    let auth =
        AuthDatabase::load_or_create(directory.path().join("state"), "locked-admin", true).unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());

    let result = serve_admin(daemon, &socket, Vec::new()).await;
    let ignored_lock = result.is_ok();
    if let Ok(server) = result {
        server.shutdown().await.unwrap();
    }
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);

    assert!(!ignored_lock, "admin socket ignored its ownership lock");
}

#[cfg(unix)]
#[tokio::test]
async fn admin_server_shutdown_never_unlinks_a_bound_successor() {
    let directory = tempdir().unwrap();
    let socket = directory.path().join("admin.sock");
    let auth =
        AuthDatabase::load_or_create(directory.path().join("state"), "admin-successor", true)
            .unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let server = serve_admin(daemon, &socket, Vec::new()).await.unwrap();

    std::fs::remove_file(&socket).unwrap();
    let successor = UnixListener::bind(&socket).unwrap();
    server.shutdown().await.unwrap();
    let successor_preserved = socket.exists();
    let reachable = timeout(TokioDuration::from_secs(1), UnixStream::connect(&socket))
        .await
        .is_ok_and(|result| result.is_ok());
    drop(successor);
    let _ = std::fs::remove_file(&socket);

    assert!(successor_preserved, "old admin server unlinked its successor socket");
    assert!(reachable, "successor admin socket was unreachable after old-server shutdown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn repeated_admin_requests_do_not_fail_spuriously() {
    let directory = tempdir().unwrap();
    let auth =
        AuthDatabase::load_or_create(directory.path().join("state"), "stress-test", true).unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let socket = directory.path().join("admin.sock");
    let server = serve_admin(daemon, &socket, Vec::new()).await.unwrap();

    for iteration in 0..1_000 {
        let response = call_admin(&socket, &AdminRequest::Connections)
            .await
            .unwrap_or_else(|error| panic!("admin request {iteration} failed spuriously: {error}"));
        assert!(response.ok);
    }

    server.shutdown().await.unwrap();
}

#[tokio::test]
async fn oversized_unterminated_request_is_rejected_without_waiting_for_eof() {
    let directory = tempdir().unwrap();
    let auth =
        AuthDatabase::load_or_create(directory.path().join("state"), "bounded-test", true).unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let socket = directory.path().join("admin.sock");
    let server = serve_admin(daemon, &socket, Vec::new()).await.unwrap();
    let mut stream = UnixStream::connect(&socket).await.unwrap();
    verify_unix_peer_owner(&stream).unwrap();
    stream.write_all(&vec![b'x'; MAX_ADMIN_MESSAGE_BYTES + 1]).await.unwrap();

    let mut reader = BufReader::new(stream);
    let mut encoded = Vec::new();
    timeout(TokioDuration::from_secs(1), reader.read_until(b'\n', &mut encoded))
        .await
        .expect("oversized request remained buffered until EOF")
        .unwrap();
    let response: AdminResponse = serde_json::from_slice(&encoded).unwrap();
    assert!(!response.ok);
    assert_eq!(response.error.as_deref(), Some("admin request is too large"));

    server.shutdown().await.unwrap();
}

#[tokio::test]
async fn exact_maximum_request_payload_is_accepted_before_dispatch() {
    let directory = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(directory.path().join("state"), "boundary-test", true)
        .unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let socket = directory.path().join("admin.sock");
    let server = serve_admin(daemon, &socket, Vec::new()).await.unwrap();
    let empty = AdminRequest::Deny { invitation_id: String::new() };
    let fixed_bytes = serde_json::to_vec(&empty).unwrap().len();
    let request =
        AdminRequest::Deny { invitation_id: "x".repeat(MAX_ADMIN_MESSAGE_BYTES - fixed_bytes - 1) };
    assert_eq!(serde_json::to_vec(&request).unwrap().len() + 1, MAX_ADMIN_MESSAGE_BYTES);

    let response = call_admin(&socket, &request).await.unwrap();

    assert_eq!(response.error.as_deref(), Some("admin response is too large"));
    server.shutdown().await.unwrap();
}
