//! Regression tests for the render-flicker fix.
//!
//! Problem before this fix: every chunk of PTY output produced a
//! full-frame `PtyBytes` repaint, and every frame carried a
//! `CSI H CSI 2J` preamble. TUI startup (btop, vim, htop) emits many
//! small chunks, so the client saw dozens of "home + clear screen"
//! sequences in rapid succession — visibly flickered the whole screen
//! before the program settled.
//!
//! Two asserts here. First: when the shell emits a burst of output,
//! the server coalesces into ≤ a small constant of `PtyBytes` frames
//! instead of one per chunk. Second: no composed frame contains the
//! `CSI H CSI 2J` preamble.

use std::time::Duration;

use cmux_cli_protocol::{ClientMsg, PROTOCOL_VERSION, ServerMsg, Viewport, read_msg, write_msg};
use cmux_cli_server::{ServerOptions, run};
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::time::timeout;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn bursty_pty_output_coalesces_into_few_frames() {
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
    // Drain the handshake-era messages (Welcome, ActiveWorkspaceChanged,
    // ActiveTabChanged, and initial frames) before counting the burst.
    let end = tokio::time::Instant::now() + Duration::from_millis(600);
    while tokio::time::Instant::now() < end {
        match timeout(Duration::from_millis(150), read_msg::<_, ServerMsg>(&mut r)).await {
            Ok(Ok(Some(_))) => {}
            _ => break,
        }
    }

    // Trigger a bursty run with independent protocol writes. This keeps the
    // test focused on server-side render coalescing instead of relying on the
    // shell to split one loop command into many PTY chunks.
    const NUM_WRITES: usize = 64;
    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"cat\n".to_vec(),
        },
    )
    .await
    .unwrap();
    for i in 1..=NUM_WRITES {
        write_msg(
            &mut w,
            &ClientMsg::Input {
                data: format!("LINE_{i:03}_XYZ\n").into_bytes(),
            },
        )
        .await
        .unwrap();
    }
    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"\x04".to_vec(),
        },
    )
    .await
    .unwrap();

    // Count rendered Grid frames and scan for any 2J preamble. Stop once the
    // last line's text has shown up — by then the burst is done.
    let mut frames = 0usize;
    let mut saw_2j = false;
    let mut saw_last_line = false;
    let mut last_frame = String::new();
    let end = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < end && !saw_last_line {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        match timeout(remaining, read_msg::<_, ServerMsg>(&mut r)).await {
            Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) => {
                frames += 1;
                let s = String::from_utf8_lossy(&data);
                if s.contains("\x1b[H\x1b[2J") {
                    saw_2j = true;
                }
                if s.contains(&format!("LINE_{NUM_WRITES:03}_XYZ")) {
                    saw_last_line = true;
                }
                last_frame = s.into_owned();
            }
            Ok(Ok(Some(_))) => {}
            _ => break,
        }
    }
    assert!(
        saw_last_line,
        "burst never finished rendering; frames={frames}; last frame:\n{last_frame}"
    );
    assert!(
        !saw_2j,
        "a composed frame still contained CSI H CSI 2J — flicker fix regressed",
    );
    // Without coalescing, this tends toward one repaint per independent
    // ClientMsg. The broker should collapse the burst by a large margin.
    assert!(
        frames <= NUM_WRITES / 2,
        "coalescer didn't sufficiently reduce frame count: got {frames} frames for {NUM_WRITES} independent writes"
    );

    // Clean up.
    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"exit\n".to_vec(),
        },
    )
    .await
    .unwrap();
    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

async fn wait_for_socket(socket: &std::path::Path) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while !socket.exists() {
        if tokio::time::Instant::now() > deadline {
            panic!("socket did not appear");
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

/// Every composed frame must hide the cursor before painting cells
/// (`CSI ?25 l`) and then decide its final visibility + position at
/// the tail. Without the hide-at-start the host terminal renders
/// intermediate flushes of cell writes and the user sees the cursor
/// streaking across the bottom of the frame.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn composed_frames_hide_cursor_before_painting_cells() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (100, 20),
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
                cols: 100,
                rows: 20,
            },
            token: None,
        },
    )
    .await
    .unwrap();

    // Drive a bit of shell output so there are multiple repaints to
    // inspect, not just the welcome frame.
    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"echo CURSOR_HIDE_CHECK_4C; printf 'x\\n'\n".to_vec(),
        },
    )
    .await
    .unwrap();

    let end = tokio::time::Instant::now() + Duration::from_secs(3);
    let mut full_frames_seen = 0usize;
    while tokio::time::Instant::now() < end && full_frames_seen < 3 {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        match timeout(remaining, read_msg::<_, ServerMsg>(&mut r)).await {
            Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) => {
                // A full composed frame always contains the per-row CUP
                // sequence `\x1b[1;1H` emitted by `emit_ansi` for row
                // 0. Narrow OSC-52 frames don't, so we skip those.
                let cup = b"\x1b[1;1H";
                let has_row_cup = data.windows(cup.len()).any(|w| w == cup);
                if !has_row_cup {
                    continue;
                }
                full_frames_seen += 1;
                let hide_at_start = data.starts_with(b"\x1b[?25l\x1b[H");
                assert!(
                    hide_at_start,
                    "composed frame did not start with cursor-hide + home — cursor will streak",
                );
                // Tail must explicitly set cursor visibility: either
                // show (`?25h`) or keep hidden (`?25l`).
                assert!(
                    data.windows(6).any(|w| w == b"\x1b[?25h") || data.ends_with(b"\x1b[?25l"),
                    "composed frame did not finalise cursor visibility at the tail",
                );
            }
            Ok(Ok(Some(_))) => {}
            _ => break,
        }
    }
    assert!(full_frames_seen > 0, "no full composed frames observed");

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"exit\n".to_vec(),
        },
    )
    .await
    .unwrap();
    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}
