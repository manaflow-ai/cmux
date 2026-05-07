//! Verify the composited frame emitted to a Grid client contains the
//! vertical workspace sidebar, the status bar, and the active pane's shell
//! output — all addressed with cursor positioning so pasting the bytes into
//! any VT-capable host reproduces cmx's chrome.

use std::time::Duration;

use cmux_cli_protocol::{
    ClientMsg, Command, PROTOCOL_VERSION, ServerMsg, Viewport, read_msg, write_msg,
};
use cmux_cli_server::{ServerOptions, run};
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::time::timeout;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn composed_frame_shows_sidebar_and_status() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (100, 24),
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
            viewport: Viewport {
                cols: 100,
                rows: 24,
            },
            token: None,
        },
    )
    .await
    .unwrap();
    write_msg(&mut w, &ClientMsg::ClientLatency { latency_ms: 42 })
        .await
        .unwrap();

    // Drive the shell to echo a sentinel.
    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"echo CMX_CHROME_OK_22A\n".to_vec(),
        },
    )
    .await
    .unwrap();

    // Collect rendered Grid frames; each one is a full-screen composite. Look
    // for:
    //  - "[main"       — status bar (workspace title + active space)
    //  - "CMX_CHROME_OK_22A" — echo output inside the pane
    let mut frames_buf = String::new();
    let end = tokio::time::Instant::now() + Duration::from_secs(10);
    while tokio::time::Instant::now() < end {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        match timeout(remaining, read_msg::<_, ServerMsg>(&mut r)).await {
            Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) => {
                frames_buf.push_str(&String::from_utf8_lossy(&data));
                if frames_buf.contains("CMX_CHROME_OK_22A")
                    && frames_buf.contains("[main")
                    && frames_buf.contains("42ms")
                {
                    break;
                }
            }
            Ok(Ok(Some(_))) => continue,
            _ => break,
        }
    }

    assert!(
        frames_buf.contains("[main"),
        "status bar missing workspace title. snippet: {}",
        &frames_buf[..frames_buf.len().min(800)]
    );
    assert!(
        frames_buf.contains("42ms"),
        "status bar missing client latency. snippet: {}",
        &frames_buf[..frames_buf.len().min(800)]
    );
    assert!(
        frames_buf.contains("CMX_CHROME_OK_22A"),
        "pane content missing from composite. snippet: {}",
        &frames_buf[..frames_buf.len().min(800)]
    );
    // Every composed frame starts with cursor-home (CSI H) so the
    // client's terminal is repositioned before painting cells. The old
    // CSI H CSI 2J preamble was removed to eliminate flicker on bursty
    // TUI startup — alt-screen already gives us a blank buffer.
    assert!(
        frames_buf.contains("\x1b[H"),
        "no cursor-home preamble detected in any composed frame"
    );
    // Workspace and space hints must be discoverable in the status bar.
    assert!(
        frames_buf.contains("ws-nav"),
        "workspace hint missing from status bar; snippet: {}",
        &frames_buf[..frames_buf.len().min(800)]
    );
    assert!(
        frames_buf.contains("new-space"),
        "space hint missing from status bar; snippet: {}",
        &frames_buf[..frames_buf.len().min(800)]
    );
    assert!(
        frames_buf.contains("[new]"),
        "sidebar new-workspace button missing from composed frame; snippet: {}",
        &frames_buf[..frames_buf.len().min(800)]
    );
    // Zellij-style rounded-corner border around the pane area. The
    // top-left `╭` and bottom-right `╯` glyphs prove both corners
    // got drawn; horizontal / vertical runs must also be present.
    for glyph in ["╭", "╮", "╰", "╯", "─", "│"] {
        assert!(
            frames_buf.contains(glyph),
            "pane border glyph {glyph:?} missing from composed frame",
        );
    }

    // Clean up.
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn overflowing_tab_bar_keeps_active_tab_visible() {
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
    wait_for_socket(&socket).await;

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

    for id in 1..=10 {
        write_msg(
            &mut w,
            &ClientMsg::Command {
                id,
                command: Command::NewTab,
            },
        )
        .await
        .unwrap();
        wait_for_reply(&mut r, id).await;
    }

    let mut frames = String::new();
    let end = tokio::time::Instant::now() + Duration::from_secs(3);
    while tokio::time::Instant::now() < end {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        match timeout(remaining, read_msg::<_, ServerMsg>(&mut r)).await {
            Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) => {
                frames.push_str(&String::from_utf8_lossy(&data));
                if frames.contains("10:term-10") && frames.contains('…') {
                    break;
                }
            }
            Ok(Ok(Some(_))) => {}
            _ => break,
        }
    }

    assert!(
        frames.contains("10:term-10"),
        "active overflowed tab was not kept visible. snippet: {}",
        &frames[..frames.len().min(800)]
    );
    assert!(
        frames.contains('…'),
        "overflow marker missing from crowded tab bar. snippet: {}",
        &frames[..frames.len().min(800)]
    );

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn focused_split_pane_has_obvious_ring() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (100, 24),
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
                rows: 24,
            },
            token: None,
        },
    )
    .await
    .unwrap();

    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 1,
            command: Command::SplitHorizontal,
        },
    )
    .await
    .unwrap();

    let focus_ring_sgr = "\x1b[38;2;120;210;255m";
    let muted_border_sgr = "\x1b[38;2;90;100;120m";
    let mut saw_reply = false;
    let mut saw_focus_ring = false;
    let mut saw_muted_border = false;
    let mut frames = String::new();
    let end = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < end {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        match timeout(remaining, read_msg::<_, ServerMsg>(&mut r)).await {
            Ok(Ok(Some(ServerMsg::CommandReply { id: 1, result }))) => {
                assert!(
                    matches!(result, cmux_cli_protocol::CommandResult::Ok { .. }),
                    "split failed: {result:?}"
                );
                saw_reply = true;
            }
            Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) => {
                let frame = String::from_utf8_lossy(&data);
                saw_focus_ring |= frame.contains(focus_ring_sgr) && frame.contains("\x1b[1m");
                saw_muted_border |= frame.contains(muted_border_sgr);
                frames.push_str(&frame);
            }
            Ok(Ok(Some(_))) => {}
            _ => break,
        }
        if saw_reply && saw_focus_ring && saw_muted_border {
            break;
        }
    }

    assert!(saw_reply, "split command did not reply");
    assert!(
        saw_focus_ring,
        "focused pane ring colour missing. snippet: {}",
        &frames[..frames.len().min(800)]
    );
    assert!(
        saw_muted_border,
        "inactive pane muted border missing. snippet: {}",
        &frames[..frames.len().min(800)]
    );

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

async fn wait_for_reply(r: &mut (impl tokio::io::AsyncRead + Unpin), want_id: u32) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, read_msg::<_, ServerMsg>(r))
            .await
            .expect("reply timeout")
            .unwrap()
            .unwrap();
        if let ServerMsg::CommandReply { id, result } = msg
            && id == want_id
        {
            assert!(
                matches!(result, cmux_cli_protocol::CommandResult::Ok { .. }),
                "command {want_id} failed: {result:?}"
            );
            return;
        }
    }
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
