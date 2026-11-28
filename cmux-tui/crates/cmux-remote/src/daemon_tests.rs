use tempfile::tempdir;
#[cfg(unix)]
use tokio::net::UnixListener;

use super::*;

#[test]
fn trusted_carrier_scope_admits_only_loopback_and_private_peers() {
    for inside in [
        "127.0.0.1",
        "10.4.0.7",
        "172.16.0.1",
        "192.168.1.2",
        "100.64.0.1",
        "100.127.255.254",
        "::1",
        "fd00:4::7",
        "fd7a:115c:a1e0::a",
        "fc00::1",
        "::ffff:10.0.0.5",
    ] {
        assert!(trusted_carrier_peer_in_scope(inside.parse().unwrap()), "{inside}");
    }
    for outside in [
        "8.8.8.8",
        "100.128.0.1",
        "100.63.255.255",
        "169.254.169.254",
        "172.32.0.1",
        "2602:f75c:0:1::2a",
        "fe80::1",
        "::ffff:8.8.8.8",
        "0.0.0.0",
        "::",
    ] {
        assert!(!trusted_carrier_peer_in_scope(outside.parse().unwrap()), "{outside}");
    }
}

#[tokio::test]
async fn trusted_carrier_off_loopback_needs_the_explicit_opt_in() {
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "trusted-scope", false).unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let refused = serve_direct_websocket_with_options(
        daemon.clone(),
        "0.0.0.0:0".parse().unwrap(),
        65_535,
        DirectWebSocketOptions {
            allow_insecure_non_loopback: true,
            trusted_carrier: true,
            ..Default::default()
        },
    )
    .await;
    let Err(DaemonError::Protocol(message)) = refused else {
        panic!("trusted carrier bound off loopback without the opt-in");
    };
    assert!(message.contains("requires a client grant"), "{message}");
    // Loopback stays a valid trusted listener with no opt-in.
    serve_direct_websocket_with_options(
        daemon.clone(),
        "127.0.0.1:0".parse().unwrap(),
        65_535,
        DirectWebSocketOptions { trusted_carrier: true, ..Default::default() },
    )
    .await
    .unwrap()
    .shutdown()
    .await
    .unwrap();
    serve_direct_websocket_with_options(
        daemon,
        "0.0.0.0:0".parse().unwrap(),
        65_535,
        DirectWebSocketOptions {
            allow_insecure_non_loopback: true,
            trusted_carrier: true,
            allow_trusted_carrier_non_loopback: true,
            ..Default::default()
        },
    )
    .await
    .unwrap()
    .shutdown()
    .await
    .unwrap();
}

#[cfg(unix)]
#[test]
fn unix_listener_retries_recoverable_accept_errors() {
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "daemon::tests::unix_listener_accept_exhaustion_fixture", "--nocapture"])
        .env("CMUX_TEST_UNIX_ACCEPT_EXHAUSTION", "1")
        .status()
        .unwrap();

    assert!(status.success(), "Unix listener stopped after a recoverable accept error");
}

#[cfg(unix)]
#[tokio::test]
async fn unix_server_shutdown_reports_listener_task_failure() {
    let directory = tempdir().unwrap();
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "failed-unix-task", false).unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let socket = directory.path().join("link.sock");
    let server = serve_unix(daemon, &socket, 65_535).await.unwrap();
    server.task.as_ref().unwrap().abort();

    let error = server.shutdown().await.unwrap_err();

    assert!(error.to_string().contains("Unix listener task failed"), "{error}");
}

#[cfg(unix)]
#[tokio::test]
async fn unix_server_shutdown_aborts_active_handlers() {
    let directory = tempdir().unwrap();
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "active-unix-shutdown", false).unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let socket = directory.path().join("link.sock");
    let server = serve_unix(daemon, &socket, 65_535).await.unwrap();

    // A connected peer with no protocol prelude keeps daemon.accept in its
    // handshake read. JoinSet::shutdown must abort that handler.
    let _peer = tokio::net::UnixStream::connect(&socket).await.unwrap();
    tokio::task::yield_now().await;
    tokio::time::timeout(Duration::from_secs(1), server.shutdown())
        .await
        .expect("Unix shutdown hung with an active handler")
        .unwrap();
}

#[cfg(unix)]
#[tokio::test]
async fn unix_server_connection_admission_recovers_after_handlers_finish() {
    let directory = tempdir().unwrap();
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "admission-unix", false).unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let socket = directory.path().join("link.sock");
    let server = serve_unix(daemon, &socket, 65_535).await.unwrap();

    // Fill the bounded handler set, then close every peer. A later peer
    // must still be admitted after the finished handlers release permits.
    let mut peers = Vec::with_capacity(MAX_UNIX_CONNECTIONS);
    for _ in 0..MAX_UNIX_CONNECTIONS {
        peers.push(tokio::net::UnixStream::connect(&socket).await.unwrap());
    }
    drop(peers);
    tokio::time::sleep(Duration::from_millis(25)).await;
    let recovered = tokio::net::UnixStream::connect(&socket).await;
    assert!(recovered.is_ok(), "Unix admission did not recover: {recovered:?}");
    server.shutdown().await.unwrap();
}

#[cfg(unix)]
#[tokio::test]
async fn unix_server_drop_removes_socket_path() {
    let directory = tempdir().unwrap();
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "drop-unix", false).unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let socket = directory.path().join("link.sock");
    let server = serve_unix(daemon, &socket, 65_535).await.unwrap();
    assert!(socket.exists());
    drop(server);
    assert!(!socket.exists(), "dropping UnixServer left its socket path behind");
}

#[cfg(unix)]
#[tokio::test]
async fn serve_unix_accepts_private_owner_directory() {
    use std::os::unix::fs::PermissionsExt;

    let directory = tempdir().unwrap();
    let parent = directory.path().join("private");
    std::fs::create_dir(&parent).unwrap();
    std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o700)).unwrap();
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "safe-unix-parent", false).unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());

    let server = serve_unix(daemon, parent.join("link.sock"), 65_535).await.unwrap();
    server.shutdown().await.unwrap();
}

#[cfg(unix)]
#[tokio::test]
async fn unix_server_shutdown_never_unlinks_a_bound_successor() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("link.sock");
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "socket-successor", false).unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let server = serve_unix(daemon, &path, 65_535).await.unwrap();

    std::fs::remove_file(&path).unwrap();
    let successor = UnixListener::bind(&path).unwrap();
    server.shutdown().await.unwrap();
    let successor_preserved = path.exists();
    let reachable =
        tokio::time::timeout(Duration::from_secs(1), tokio::net::UnixStream::connect(&path))
            .await
            .is_ok_and(|result| result.is_ok());
    drop(successor);
    let _ = std::fs::remove_file(&path);

    assert!(successor_preserved, "old Unix server unlinked its successor socket");
    assert!(reachable, "successor Unix socket was unreachable after old-server shutdown");
}

#[cfg(unix)]
#[tokio::test]
async fn serve_unix_rejects_sticky_world_writable_parent() {
    use std::os::unix::fs::PermissionsExt;

    let directory = tempdir().unwrap();
    let parent = directory.path().join("shared");
    std::fs::create_dir(&parent).unwrap();
    std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o1777)).unwrap();
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "unsafe-unix-parent", false).unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());

    match serve_unix(daemon, parent.join("link.sock"), 65_535).await {
        Err(DaemonError::Protocol(message)) => {
            assert!(message.contains("socket directory"), "{message}");
        }
        Err(error) => panic!("unexpected error: {error}"),
        Ok(server) => {
            server.shutdown().await.unwrap();
            panic!("sticky world-writable socket parent was accepted");
        }
    }
}

#[cfg(unix)]
#[tokio::test]
async fn serve_unix_rejects_symlink_parent() {
    use std::os::unix::fs::symlink;

    let directory = tempdir().unwrap();
    let real_parent = directory.path().join("real-parent");
    let linked_parent = directory.path().join("linked-parent");
    std::fs::create_dir(&real_parent).unwrap();
    symlink(&real_parent, &linked_parent).unwrap();
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "symlink-unix-parent", false).unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());

    match serve_unix(daemon, linked_parent.join("link.sock"), 65_535).await {
        Err(DaemonError::Protocol(message)) => {
            assert!(message.contains("socket directory"), "{message}");
        }
        Err(error) => panic!("unexpected error: {error}"),
        Ok(server) => {
            server.shutdown().await.unwrap();
            panic!("symlink socket parent was accepted");
        }
    }
    assert!(!real_parent.join("link.sock").exists());
}

#[cfg(unix)]
#[tokio::test]
async fn serve_unix_rejects_an_intermediate_symlink_before_creating_the_parent() {
    use std::os::unix::fs::symlink;

    let directory = tempdir().unwrap();
    let target = directory.path().join("target");
    let alias = directory.path().join("alias");
    std::fs::create_dir(&target).unwrap();
    symlink(&target, &alias).unwrap();
    let state = tempdir().unwrap();
    let auth =
        AuthDatabase::load_or_create(state.path(), "intermediate-symlink-parent", false).unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());

    match serve_unix(daemon, alias.join("missing/link.sock"), 65_535).await {
        Err(DaemonError::Protocol(_)) => {}
        Err(error) => panic!("unexpected error: {error}"),
        Ok(server) => {
            server.shutdown().await.unwrap();
            panic!("intermediate symlink was accepted");
        }
    }
    assert!(!target.join("missing").exists());
}

#[test]
fn client_limit_scales_with_the_soft_open_file_limit() {
    // No limit to read, or a small one: today's floor.
    assert_eq!(client_limit_for_open_files(None), MIN_CLIENT_CONNECTIONS);
    assert_eq!(client_limit_for_open_files(Some(256)), MIN_CLIENT_CONNECTIONS);
    assert_eq!(client_limit_for_open_files(Some(1_024)), MIN_CLIENT_CONNECTIONS);
    // Half the descriptors at 16 per client.
    assert_eq!(client_limit_for_open_files(Some(10_240)), 320);
    assert_eq!(client_limit_for_open_files(Some(65_536)), 2_048);
    // An unlimited hard limit still bounds per-client state.
    assert_eq!(client_limit_for_open_files(Some(u64::MAX)), MAX_CLIENT_CONNECTIONS);
}

#[test]
fn a_daemon_refuses_a_zero_client_limit() {
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "zero-client-limit", false).unwrap();
    let result = RemoteDaemon::with_client_limit(
        auth,
        SessionLimits::default(),
        DaemonSessionPolicy::default(),
        0,
    );
    assert!(matches!(result, Err(DaemonError::Protocol(_))));
}

#[test]
fn too_many_clients_names_the_limit() {
    assert_eq!(
        DaemonError::TooManyClients { limit: 64 }.to_string(),
        "too many connected clients (the limit is 64)"
    );
}
