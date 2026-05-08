//! Server-boundary test: drive `cmux_cli_server::run` directly over a Unix
//! socket, no client binary or PTY-in-PTY. Validates that a correct
//! protocol handshake wraps a process end-to-end: Hello → Welcome → Input
//! "SENTINEL\n" → PtyBytes… → Bye.
//!
//! The test sidesteps crossterm entirely so it's deterministic in CI.

use std::time::Duration;

use cmux_cli_protocol::{ClientMsg, PROTOCOL_VERSION, ServerMsg, Viewport, read_msg, write_msg};
use cmux_cli_server::{ServerOptions, run};
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::time::timeout;

const SENTINEL: &str = "CMX_PROTO_OK_D4E1";

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn shell_output_streams_over_socket() {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("server.sock");

    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
        shell: "/bin/cat".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: None,
        auth_token: None,
    };

    // Server runs until the shell exits (alive_rx flips to false).
    let server_handle = tokio::spawn(async move { run(opts).await });

    // Wait for the socket to appear.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while !socket.exists() {
        if tokio::time::Instant::now() > deadline {
            panic!("socket did not appear");
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }

    // Connect.
    let stream = UnixStream::connect(&socket).await.expect("connect");
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);

    write_msg(
        &mut write_half,
        &ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: None,
        },
    )
    .await
    .expect("send Hello");

    let welcome = timeout(
        Duration::from_secs(5),
        read_msg::<_, ServerMsg>(&mut reader),
    )
    .await
    .expect("welcome timeout")
    .expect("welcome io")
    .expect("welcome eof");
    matches!(welcome, ServerMsg::Welcome { .. })
        .then_some(())
        .expect("expected Welcome");

    let mut collected = Vec::<u8>::new();
    let mut saw_bye = false;

    // Drive the process through the protocol input path.
    let cmd = format!("{SENTINEL}\n");
    write_msg(
        &mut write_half,
        &ClientMsg::Input {
            data: cmd.into_bytes(),
        },
    )
    .await
    .expect("send Input");

    // Collect rendered Grid bytes until the sentinel appears or timeout.
    let read_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    let mut saw_sentinel = false;
    while tokio::time::Instant::now() < read_deadline {
        let remaining = read_deadline.saturating_duration_since(tokio::time::Instant::now());
        match timeout(remaining, read_msg::<_, ServerMsg>(&mut reader)).await {
            Err(_) => break, // deadline expired
            Ok(Ok(None)) => break,
            Ok(Err(e)) => panic!("protocol error: {e:?}"),
            Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) => {
                collected.extend_from_slice(&data);
                if String::from_utf8_lossy(&collected).contains(SENTINEL) {
                    saw_sentinel = true;
                    break;
                }
            }
            Ok(Ok(Some(ServerMsg::Bye))) => {
                saw_bye = true;
                break;
            }
            Ok(Ok(Some(ServerMsg::Error { message }))) => {
                panic!("server Error: {message}");
            }
            Ok(Ok(Some(_))) => {}
        }
    }

    let joined = String::from_utf8_lossy(&collected).into_owned();
    assert!(
        saw_sentinel,
        "expected sentinel {SENTINEL} in stream; got:\n{joined}"
    );

    write_msg(&mut write_half, &ClientMsg::Input { data: vec![0x04] })
        .await
        .expect("send eof");

    let bye_deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < bye_deadline && !saw_bye {
        let remaining = bye_deadline.saturating_duration_since(tokio::time::Instant::now());
        match timeout(remaining, read_msg::<_, ServerMsg>(&mut reader)).await {
            Err(_) => break,
            Ok(Ok(None)) => break,
            Ok(Err(e)) => panic!("protocol error after eof: {e:?}"),
            Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) => collected.extend_from_slice(&data),
            Ok(Ok(Some(ServerMsg::Bye))) => {
                saw_bye = true;
                break;
            }
            Ok(Ok(Some(ServerMsg::Error { message }))) => {
                panic!("server Error after eof: {message}");
            }
            Ok(Ok(Some(_))) => {}
        }
    }
    let joined = String::from_utf8_lossy(&collected).into_owned();
    assert!(saw_bye, "expected Bye after shell exit, got:\n{joined}");

    // Server task should wind down shortly after alive=false.
    timeout(Duration::from_secs(5), server_handle)
        .await
        .expect("server shutdown timeout")
        .expect("server task panicked")
        .expect("server returned error");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn shell_output_streams_over_grid_socket() {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("server.sock");

    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
        shell: "/bin/cat".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: None,
        auth_token: None,
    };

    let server_handle = tokio::spawn(async move { run(opts).await });

    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while !socket.exists() {
        if tokio::time::Instant::now() > deadline {
            panic!("socket did not appear");
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }

    let stream = UnixStream::connect(&socket).await.expect("connect");
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);

    write_msg(
        &mut write_half,
        &ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: None,
        },
    )
    .await
    .expect("send Hello");

    let welcome = timeout(
        Duration::from_secs(5),
        read_msg::<_, ServerMsg>(&mut reader),
    )
    .await
    .expect("welcome timeout")
    .expect("welcome io")
    .expect("welcome eof");
    matches!(welcome, ServerMsg::Welcome { .. })
        .then_some(())
        .expect("expected Welcome");

    let cmd = format!("{SENTINEL}\n");
    write_msg(
        &mut write_half,
        &ClientMsg::Input {
            data: cmd.into_bytes(),
        },
    )
    .await
    .expect("send Input");

    let read_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    let mut collected = Vec::<u8>::new();
    let mut saw_sentinel = false;
    while tokio::time::Instant::now() < read_deadline {
        let remaining = read_deadline.saturating_duration_since(tokio::time::Instant::now());
        match timeout(remaining, read_msg::<_, ServerMsg>(&mut reader)).await {
            Err(_) => break,
            Ok(Ok(None)) => break,
            Ok(Err(e)) => panic!("protocol error: {e:?}"),
            Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) => {
                collected.extend_from_slice(&data);
                if String::from_utf8_lossy(&collected).contains(SENTINEL) {
                    saw_sentinel = true;
                    break;
                }
            }
            Ok(Ok(Some(ServerMsg::Error { message }))) => {
                panic!("server Error: {message}");
            }
            Ok(Ok(Some(_))) => {}
        }
    }

    let joined = String::from_utf8_lossy(&collected).into_owned();
    assert!(
        saw_sentinel,
        "expected sentinel {SENTINEL} in grid stream; got:\n{joined}"
    );

    write_msg(&mut write_half, &ClientMsg::Input { data: vec![0x04] })
        .await
        .expect("send eof");
    timeout(Duration::from_secs(5), server_handle)
        .await
        .expect("server shutdown timeout")
        .expect("server task panicked")
        .expect("server returned error");
}
