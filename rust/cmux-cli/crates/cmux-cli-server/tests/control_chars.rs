//! Control-character passthrough test.
//!
//! Client sends `sleep 30\n` then Ctrl-C (0x03). If we forward control
//! characters correctly, the shell's foreground process (the `sleep`)
//! receives SIGINT and exits; the next prompt appears and `echo DONE` runs.
//! If we dropped or re-interpreted 0x03, the test would time out.

use std::time::Duration;

use cmux_cli_protocol::{ClientMsg, PROTOCOL_VERSION, ServerMsg, Viewport, read_msg, write_msg};
use cmux_cli_server::{ServerOptions, run};
use tokio::io::{AsyncRead, BufReader};
use tokio::net::UnixStream;
use tokio::time::timeout;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn ctrl_c_interrupts_foreground_process() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: None,
        auth_token: None,
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });

    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while !socket.exists() {
        if tokio::time::Instant::now() > deadline {
            panic!("socket did not appear");
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }

    let stream = UnixStream::connect(&socket).await.unwrap();
    let (read_half, mut w) = stream.into_split();
    let mut r = BufReader::new(read_half);

    write_msg(
        &mut w,
        &ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: None,
        },
    )
    .await
    .unwrap();

    // Welcome + initial workspace/tab announcements — drain.
    let _ = timeout(Duration::from_secs(2), async {
        while let Ok(Ok(Some(msg))) =
            timeout(Duration::from_millis(200), read_msg::<_, ServerMsg>(&mut r)).await
        {
            if matches!(msg, ServerMsg::ActiveTabChanged { .. }) {
                break;
            }
        }
    })
    .await;

    // Kick off a long sleep. Without control-char forwarding this test
    // would block for 30s and time out.
    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"printf CMX_SLEEP_STARTED_51F\\n; sleep 30\n".to_vec(),
        },
    )
    .await
    .unwrap();
    let _ = read_pty_until(&mut r, "CMX_SLEEP_STARTED_51F", Duration::from_secs(5)).await;
    write_msg(&mut w, &ClientMsg::Input { data: vec![0x03] })
        .await
        .unwrap();

    // Prove we're back at a prompt: the echo only runs promptly if Ctrl-C
    // interrupted the foreground sleep.
    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"echo CMX_CTRLC_OK_51F\n".to_vec(),
        },
    )
    .await
    .unwrap();

    let mut buf = String::new();
    let end = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < end && !buf.contains("CMX_CTRLC_OK_51F") {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        if let Ok(Ok(Some(msg))) = timeout(remaining, read_msg::<_, ServerMsg>(&mut r)).await
            && let ServerMsg::PtyBytes { data, .. } = msg
        {
            buf.push_str(&String::from_utf8_lossy(&data));
        }
    }
    assert!(
        buf.contains("CMX_CTRLC_OK_51F"),
        "did not see post-ctrl-c echo within 5s. output:\n{buf}"
    );

    // Clean shutdown.
    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"exit\n".to_vec(),
        },
    )
    .await
    .unwrap();
    let _ = timeout(Duration::from_secs(5), server).await;
}

async fn read_pty_until<R>(r: &mut R, needle: &str, deadline: Duration) -> String
where
    R: AsyncRead + Unpin,
{
    let mut buf = String::new();
    let end = tokio::time::Instant::now() + deadline;
    while tokio::time::Instant::now() < end && !buf.contains(needle) {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        match timeout(remaining, read_msg::<_, ServerMsg>(r)).await {
            Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) => {
                buf.push_str(&String::from_utf8_lossy(&data));
            }
            Ok(Ok(Some(_))) => continue,
            Ok(Ok(None)) => break,
            Ok(Err(error)) => panic!("failed reading PTY bytes: {error}"),
            Err(_) => break,
        }
    }
    assert!(
        buf.contains(needle),
        "did not see {needle:?}. output:\n{buf}"
    );
    buf
}
