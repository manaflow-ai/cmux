//! Verify that while a drag selection is in progress the composed frame
//! emits the selection-color SGR for cells in the selected rect, and
//! DOESN'T repaint the sidebar (selection clips to pane rect).

use std::time::Duration;

use cmux_cli_protocol::{
    ClientMsg, Command, CommandResult, MouseKind, PROTOCOL_VERSION, ServerMsg, Viewport, read_msg,
    write_msg,
};
use cmux_cli_server::{ServerOptions, run};
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::time::timeout;

/// Truecolor SGR for the selection bg — the concrete numbers the server
/// emits. If the server tweaks the selection color this string needs to
/// track it (better: expose a constant, but this keeps the test self-
/// contained and easy to read).
const SEL_BG_SGR: &str = "\x1b[48;2;55;70;95m";

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dragged_selection_paints_pane_cells_blue() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
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

    // Drain handshake-era frames before starting the drag so post-drag
    // assertions cannot be satisfied by stale startup repaints.
    let _welcome = timeout(Duration::from_secs(2), read_msg::<_, ServerMsg>(&mut r))
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    drain_pending(&mut r).await;

    // Drag inside the pane region (sidebar is 16 cols wide).
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 30,
            row: 5,
            event: MouseKind::Down,
        },
    )
    .await
    .unwrap();
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 60,
            row: 9,
            event: MouseKind::Drag,
        },
    )
    .await
    .unwrap();

    // Wait for a frame that contains the selection SGR.
    let mut saw = false;
    let end = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < end && !saw {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        if let Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) =
            timeout(remaining, read_msg::<_, ServerMsg>(&mut r)).await
        {
            let s = String::from_utf8_lossy(&data);
            if s.contains(SEL_BG_SGR) {
                saw = true;
            }
        }
    }
    assert!(
        saw,
        "expected selection bg SGR {SEL_BG_SGR:?} in Drag repaint"
    );

    // Clear any queued drag repaint so the post-MouseUp assertion only accepts
    // a frame emitted after selection has been released.
    drain_pending(&mut r).await;

    // Release → selection clears; a subsequent frame should not contain
    // the selection bg.
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 60,
            row: 9,
            event: MouseKind::Up,
        },
    )
    .await
    .unwrap();
    let mut post_up_clear = false;
    let end = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < end && !post_up_clear {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        if let Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) =
            timeout(remaining, read_msg::<_, ServerMsg>(&mut r)).await
        {
            let s = String::from_utf8_lossy(&data);
            // Skip the OSC 52 frame (narrow, no full compose preamble).
            // A full composed frame starts with cursor-home (CSI H) and
            // doesn't contain the selection bg once it's cleared.
            if s.contains("\x1b[H") && s.contains("\x1b[") && !s.contains(SEL_BG_SGR) {
                post_up_clear = true;
            }
        }
    }
    assert!(post_up_clear, "selection bg still present after MouseUp");

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
async fn dragged_selection_paints_inside_split_pane() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
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
    let _ = timeout(Duration::from_secs(2), read_msg::<_, ServerMsg>(&mut r))
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
    wait_for_command_ok(&mut r, 1).await;
    drain_pending(&mut r).await;

    // The split command focuses the new right-hand pane. A drag inside
    // pane content must start a text selection, not only focus the pane.
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 82,
            row: 6,
            event: MouseKind::Down,
        },
    )
    .await
    .unwrap();
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 104,
            row: 10,
            event: MouseKind::Drag,
        },
    )
    .await
    .unwrap();

    wait_for_ansi(&mut r, |s| s.contains(SEL_BG_SGR)).await;

    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 104,
            row: 10,
            event: MouseKind::Up,
        },
    )
    .await
    .unwrap();
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
async fn primary_screen_mouse_tracking_still_allows_selection() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
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

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"printf '\\033[?1000hMAIN_MOUSE_OK\\n'\n".to_vec(),
        },
    )
    .await
    .unwrap();
    wait_for_ansi(&mut r, |s| s.contains("MAIN_MOUSE_OK")).await;

    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 30,
            row: 5,
            event: MouseKind::Down,
        },
    )
    .await
    .unwrap();
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 60,
            row: 9,
            event: MouseKind::Drag,
        },
    )
    .await
    .unwrap();

    wait_for_ansi(&mut r, |s| s.contains(SEL_BG_SGR)).await;

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"printf '\\033[?1000l'\nexit\n".to_vec(),
        },
    )
    .await
    .unwrap();
    let _ = timeout(Duration::from_secs(5), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn alternate_screen_mouse_tracking_owns_mouse() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
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

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"printf '\\033[?1049h\\033[?1000hALT_MOUSE_OK'\n".to_vec(),
        },
    )
    .await
    .unwrap();
    wait_for_ansi(&mut r, |s| s.contains("ALT_MOUSE_OK")).await;
    drain_pending(&mut r).await;

    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 30,
            row: 5,
            event: MouseKind::Down,
        },
    )
    .await
    .unwrap();
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 60,
            row: 9,
            event: MouseKind::Drag,
        },
    )
    .await
    .unwrap();

    assert_no_selection_frame(&mut r).await;

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"printf '\\033[?1000l\\033[?1049l'\nexit\n".to_vec(),
        },
    )
    .await
    .unwrap();
    let _ = timeout(Duration::from_secs(5), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn selection_is_clipped_to_pane_not_sidebar() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
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
    let _ = timeout(Duration::from_secs(2), read_msg::<_, ServerMsg>(&mut r))
        .await
        .unwrap();

    // Start the drag inside the sidebar (col 2) and extend into the pane.
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 2,
            row: 3,
            event: MouseKind::Down,
        },
    )
    .await
    .unwrap();
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 40,
            row: 8,
            event: MouseKind::Drag,
        },
    )
    .await
    .unwrap();

    // In the repaint, the selection SGR should appear at least once
    // (pane cells) AND the sidebar's own bg (24;26;30) should still be
    // present — meaning sidebar cells weren't repainted as selection.
    let mut ok = false;
    let end = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < end && !ok {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        if let Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) =
            timeout(remaining, read_msg::<_, ServerMsg>(&mut r)).await
        {
            let s = String::from_utf8_lossy(&data);
            if s.contains(SEL_BG_SGR) && s.contains("\x1b[48;2;24;26;30m") {
                ok = true;
            }
        }
    }
    assert!(
        ok,
        "expected both selection SGR and sidebar SGR in same frame after cross-boundary drag"
    );

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
async fn dragging_selection_past_top_and_bottom_autoscrolls() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 10),
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
            viewport: Viewport { cols: 80, rows: 10 },
            token: None,
        },
    )
    .await
    .unwrap();

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"i=1; while [ $i -le 40 ]; do printf 'AUTO_%02d\\n' \"$i\"; i=$((i+1)); done\n"
                .to_vec(),
        },
    )
    .await
    .unwrap();
    wait_for_ansi(&mut r, |s| s.contains("AUTO_40")).await;

    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 20,
            row: 4,
            event: MouseKind::Down,
        },
    )
    .await
    .unwrap();
    // One drag event onto the top border must be enough. Real
    // terminals stop delivering Drag events once the pointer leaves
    // the window, so autoscroll has to continue from held state.
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 20,
            row: 1,
            event: MouseKind::Drag,
        },
    )
    .await
    .unwrap();
    wait_for_ansi(&mut r, |s| s.contains("AUTO_25") && s.contains(SEL_BG_SGR)).await;

    // Same in the other direction: one edge event should keep moving
    // the viewport until the visible selection reaches the bottom.
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 20,
            row: 7,
            event: MouseKind::Drag,
        },
    )
    .await
    .unwrap();
    wait_for_ansi(&mut r, |s| s.contains("AUTO_40") && s.contains(SEL_BG_SGR)).await;

    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 20,
            row: 7,
            event: MouseKind::Up,
        },
    )
    .await
    .unwrap();
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
async fn wheel_scroll_during_selection_keeps_highlight_visible() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 10),
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
            viewport: Viewport { cols: 80, rows: 10 },
            token: None,
        },
    )
    .await
    .unwrap();

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"i=1; while [ $i -le 40 ]; do printf 'WHEEL_%02d\\n' \"$i\"; i=$((i+1)); done\n"
                .to_vec(),
        },
    )
    .await
    .unwrap();
    wait_for_ansi(&mut r, |s| s.contains("WHEEL_40")).await;

    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 20,
            row: 3,
            event: MouseKind::Down,
        },
    )
    .await
    .unwrap();
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 50,
            row: 6,
            event: MouseKind::Drag,
        },
    )
    .await
    .unwrap();
    wait_for_ansi(&mut r, |s| s.contains(SEL_BG_SGR)).await;
    drain_pending(&mut r).await;

    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 50,
            row: 6,
            event: MouseKind::Wheel { lines: -3 },
        },
    )
    .await
    .unwrap();
    let wheel_frame = read_next_ansi(&mut r).await;
    assert!(
        wheel_frame.contains(SEL_BG_SGR),
        "selection highlight disappeared after wheel scroll; frame={wheel_frame:?}",
    );

    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 50,
            row: 6,
            event: MouseKind::Up,
        },
    )
    .await
    .unwrap();
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

async fn wait_for_ansi(
    r: &mut (impl tokio::io::AsyncRead + Unpin),
    predicate: impl Fn(&str) -> bool,
) {
    let end = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut last_frame = String::new();
    while tokio::time::Instant::now() < end {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        if let Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) =
            timeout(remaining, read_msg::<_, ServerMsg>(r)).await
        {
            let s = String::from_utf8_lossy(&data);
            if predicate(&s) {
                return;
            }
            last_frame = s.into_owned();
        }
    }
    panic!("timed out waiting for matching rendered frame; last frame:\n{last_frame}");
}

async fn read_next_ansi(r: &mut (impl tokio::io::AsyncRead + Unpin)) -> String {
    let end = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        match timeout(remaining, read_msg::<_, ServerMsg>(r)).await {
            Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) => {
                return String::from_utf8_lossy(&data).into_owned();
            }
            Ok(Ok(Some(_))) => {}
            Ok(Ok(None)) => panic!("server closed before rendered frame"),
            Ok(Err(e)) => panic!("read failed before rendered frame: {e}"),
            Err(_) => panic!("timed out waiting for rendered frame"),
        }
    }
}

async fn drain_pending(r: &mut (impl tokio::io::AsyncRead + Unpin)) {
    while let Ok(Ok(Some(_))) =
        timeout(Duration::from_millis(50), read_msg::<_, ServerMsg>(r)).await
    {}
}

async fn assert_no_selection_frame(r: &mut (impl tokio::io::AsyncRead + Unpin)) {
    let end = tokio::time::Instant::now() + Duration::from_millis(500);
    while tokio::time::Instant::now() < end {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        match timeout(remaining, read_msg::<_, ServerMsg>(r)).await {
            Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) => {
                let frame = String::from_utf8_lossy(&data);
                assert!(
                    !frame.contains(SEL_BG_SGR),
                    "alternate-screen mouse tracking should not paint host selection; frame={frame:?}"
                );
            }
            Ok(Ok(Some(_))) => {}
            Ok(Ok(None)) => return,
            Ok(Err(e)) => panic!("read failed while checking for no selection: {e}"),
            Err(_) => return,
        }
    }
}

async fn wait_for_command_ok(r: &mut (impl tokio::io::AsyncRead + Unpin), want_id: u32) {
    let end = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < end {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        match timeout(remaining, read_msg::<_, ServerMsg>(r)).await {
            Ok(Ok(Some(ServerMsg::CommandReply { id, result }))) if id == want_id => match result {
                CommandResult::Ok { .. } => return,
                CommandResult::Err { message } => panic!("command failed: {message}"),
            },
            Ok(Ok(Some(_))) => {}
            Ok(Ok(None)) => panic!("server closed before command reply"),
            Ok(Err(e)) => panic!("read failed before command reply: {e}"),
            Err(_) => break,
        }
    }
    panic!("timed out waiting for command reply {want_id}");
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
