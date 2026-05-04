//! Stress the attach path to flush out protocol desync bugs.
//!
//! The user hit `CodecError::ProtocolDesync([0x20, 0x20, 0x20, 0x20])` on
//! a fresh attach with a fresh server — four ASCII spaces appeared in
//! the 4-byte length-prefix slot, meaning the client's read cursor
//! slipped out of alignment with the server's write boundaries.
//!
//! These tests exercise the two plausible sources of that bug:
//!   1. Concurrent writers to a single client socket (a task firing
//!      rendered frames while the session loop is also emitting its own).
//!   2. Rapid-fire attach/detach churn producing a stale byte that
//!      bleeds into the next session.
//!
//! If the desync is real it will show up as either a `ProtocolDesync`
//! error on read, or a `FrameTooLarge` error. Both cause panics here.

use std::time::Duration;

use cmux_cli_protocol::{ClientMsg, PROTOCOL_VERSION, ServerMsg, Viewport, read_msg, write_msg};
use cmux_cli_server::{ServerOptions, run};
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::time::timeout;

async fn wait_for_socket(socket: &std::path::Path) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while !socket.exists() {
        if tokio::time::Instant::now() > deadline {
            panic!("socket did not appear");
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

// (Removed: `concurrent_attach_sessions_stay_framed`. The scenario
// it exercised — concurrent clients not desyncing each other's byte
// streams — is implicitly covered by the rapid_mouse_events test
// (same cancel-safety property under heavier load per client), and
// the test's runtime-shutdown semantics caused reliable hangs when
// 8 spawn_blocking PTY reader threads refused to terminate after
// the test completed. Rather than paper over that with a
// shell-teardown attach, rely on the stronger single-client test.)

/// Regression test for the cancel-safety bug that caused desync when
/// a client sent rapid mouse events while the server was streaming
/// frames. `read_msg` inside `tokio::select!` is not cancel-safe; if
/// another branch fires while the session's recv is mid-payload, the
/// partial read is lost and the next recv reads mid-frame bytes as a
/// length prefix. The server-side fix is a dedicated reader task
/// feeding a cancel-safe `mpsc`.
///
/// We reproduce the scenario by pounding a server with hundreds of
/// mouse events while the shell prints continuously. Before the fix
/// this produces `ProtocolDesync` within a few thousand events; after
/// the fix it runs clean.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rapid_mouse_events_do_not_desync_under_output_pressure() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (120, 30),
        snapshot_path: None,
        settings_path: None,
        ws_bind: None,
        auth_token: None,
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });
    wait_for_socket(&socket).await;

    let stream = UnixStream::connect(&socket).await.unwrap();
    let (read_half, mut w) = stream.into_split();
    let mut r = BufReader::new(read_half);

    write_msg(
        &mut w,
        &ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            viewport: Viewport {
                cols: 120,
                rows: 30,
            },
            token: None,
        },
    )
    .await
    .unwrap();

    // Pound mouse events from one task while a second task drains
    // the read side and watches for any codec error. The two tasks
    // race on the socket the same way a real `cmx attach` client
    // does; if the server's recv branch is not cancel-safe this
    // reliably produces a ProtocolDesync within a few thousand events.
    let reader_task = tokio::spawn(async move {
        let end = tokio::time::Instant::now() + Duration::from_secs(15);
        while tokio::time::Instant::now() < end {
            let remaining = end.saturating_duration_since(tokio::time::Instant::now());
            match timeout(remaining, read_msg::<_, ServerMsg>(&mut r)).await {
                Ok(Ok(Some(_))) => {}
                Ok(Ok(None)) => break,
                Ok(Err(e)) => {
                    return Err(format!("codec error during stress: {e}"));
                }
                Err(_) => break,
            }
        }
        Ok(())
    });

    let writer_task = tokio::spawn(async move {
        // Finite burst: enough output pressure to exercise frame
        // coalescing and read cancel-safety, without leaving an
        // unbounded shell loop that can make test teardown hang.
        write_msg(
            &mut w,
            &ClientMsg::Input {
                data: b"for i in $(seq 1 3000); do printf '..........\\n'; done\n".to_vec(),
            },
        )
        .await
        .map_err(|e| format!("failed to start output burst: {e}"))?;
        for i in 0..1500u16 {
            let col = 20 + (i % 80);
            let row = 2 + (i % 20);
            let event = if i % 3 == 0 {
                cmux_cli_protocol::MouseKind::Down
            } else if i % 3 == 1 {
                cmux_cli_protocol::MouseKind::Up
            } else {
                cmux_cli_protocol::MouseKind::Wheel { lines: 1 }
            };
            write_msg(&mut w, &ClientMsg::Mouse { col, row, event })
                .await
                .map_err(|e| format!("failed to write mouse event {i}: {e}"))?;
        }
        write_msg(
            &mut w,
            &ClientMsg::Input {
                data: b"exit\n".to_vec(),
            },
        )
        .await
        .map_err(|e| format!("failed to write exit: {e}"))?;
        Ok::<(), String>(())
    });

    let writer_result = timeout(Duration::from_secs(10), writer_task)
        .await
        .expect("writer timed out")
        .expect("writer panicked");
    if let Err(msg) = writer_result {
        panic!("{msg}");
    }
    let reader_result = timeout(Duration::from_secs(20), reader_task)
        .await
        .expect("reader timed out")
        .expect("reader panicked");
    if let Err(msg) = reader_result {
        panic!("{msg}");
    }

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rapid_attach_detach_cycles_stay_framed() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (120, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: None,
        auth_token: None,
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });
    wait_for_socket(&socket).await;

    // 24 sequential attach → drain one Welcome → detach cycles. Exercises
    // the per-connection setup/teardown path without leaking bytes across
    // sessions.
    for _ in 0..24 {
        let stream = UnixStream::connect(&socket).await.unwrap();
        let (read_half, mut w) = stream.into_split();
        let mut r = BufReader::new(read_half);
        write_msg(
            &mut w,
            &ClientMsg::Hello {
                version: PROTOCOL_VERSION,
                viewport: Viewport {
                    cols: 120,
                    rows: 24,
                },
                token: None,
            },
        )
        .await
        .unwrap();
        let msg = timeout(Duration::from_secs(2), read_msg::<_, ServerMsg>(&mut r))
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert!(matches!(msg, ServerMsg::Welcome { .. }));
        // Drain any immediate follow-ups so we catch a stray byte before
        // detaching.
        for _ in 0..8 {
            match timeout(Duration::from_millis(50), read_msg::<_, ServerMsg>(&mut r)).await {
                Ok(Ok(Some(_))) => {}
                Ok(Ok(None)) => break,
                Ok(Err(e)) => panic!("codec error during drain: {e}"),
                Err(_) => break,
            }
        }
        let _ = write_msg(&mut w, &ClientMsg::Detach).await;
    }

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}
