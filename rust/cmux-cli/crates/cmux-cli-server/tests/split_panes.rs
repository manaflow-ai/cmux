//! Split panes: `Command::SplitHorizontal` / `Command::SplitVertical`
//! split the focused panel and render every panel leaf with its own tab
//! stack and border.

use std::time::Duration;

use cmux_cli_protocol::{
    ClientMsg, Command, PROTOCOL_VERSION, ServerMsg, Viewport, read_msg, write_msg,
};
use cmux_cli_server::{ServerOptions, run};
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::time::timeout;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn split_horizontal_adds_a_second_leaf_pane() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (140, 30),
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
                cols: 140,
                rows: 30,
            },
            token: None,
        },
    )
    .await
    .unwrap();

    // Count `╭` corners in an unsplit frame (expect 1).
    let before_corners =
        wait_for_corner_count(&mut r, Duration::from_secs(3), |count| count == 1).await;
    assert_eq!(
        before_corners, 1,
        "unsplit frame should have exactly 1 top-left corner, got {before_corners}"
    );

    // Split the focused panel; this auto-spawns a tab in the new panel.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 1,
            command: Command::SplitHorizontal,
        },
    )
    .await
    .unwrap();

    let split_corners =
        wait_for_corner_count(&mut r, Duration::from_secs(3), |count| count >= 2).await;
    assert!(
        split_corners >= 2,
        "split frame should have at least 2 top-left corners (one per leaf), got {split_corners}"
    );

    // ListTabs is panel-local. After a split, the newly focused right
    // panel has its own one-tab stack rather than sharing the left panel's
    // tabs.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 2,
            command: Command::ListTabs,
        },
    )
    .await
    .unwrap();
    let tabs_len = loop {
        let m = timeout(Duration::from_secs(2), read_msg::<_, ServerMsg>(&mut r))
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        if let ServerMsg::CommandReply {
            id: 2,
            result:
                cmux_cli_protocol::CommandResult::Ok {
                    data: Some(cmux_cli_protocol::CommandData::TabList { tabs, .. }),
                },
        } = m
        {
            break tabs.len();
        }
    };
    assert_eq!(tabs_len, 1);

    // Unsplit and confirm corners drop back to 1.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 3,
            command: Command::Unsplit,
        },
    )
    .await
    .unwrap();
    let after_corners =
        wait_for_corner_count(&mut r, Duration::from_secs(3), |count| count == 1).await;
    assert_eq!(
        after_corners, 1,
        "unsplit again → 1 corner, got {after_corners}"
    );

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

/// Clicking inside a background split leaf's pane area must focus
/// that leaf (`ActiveTabChanged`). This is separate from the tab-pill
/// click: a user pointing at the TERMINAL area of the non-focused
/// pane expects focus to follow.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn clicking_inside_leaf_pane_focuses_it() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (140, 30),
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
                cols: 140,
                rows: 30,
            },
            token: None,
        },
    )
    .await
    .unwrap();

    // Enter horizontal split (spawns a 2nd tab).
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 1,
            command: Command::SplitHorizontal,
        },
    )
    .await
    .unwrap();
    // After SplitHorizontal the active tab is index 0 inside the new
    // right-hand panel's own tab stack.
    let right_tab_id = read_until_active(&mut r, 0).await;

    // Click INSIDE the left leaf's terminal area. Sidebar = 16 wide,
    // horizontal split halves the ~124 pane-area cols → left leaf
    // roughly cols 17..77. Pick col 30 (inside left) and row 10 (in
    // pane body, below top border).
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 30,
            row: 10,
            event: cmux_cli_protocol::MouseKind::Down,
        },
    )
    .await
    .unwrap();

    // Expect ActiveTabChanged { index: 0 } with a different tab id:
    // click focused the left leaf's own one-tab stack.
    let left_tab_id = read_until_active(&mut r, 0).await;
    assert_ne!(left_tab_id, right_tab_id);

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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn panels_have_independent_tab_stacks() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (140, 30),
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
                cols: 140,
                rows: 30,
            },
            token: None,
        },
    )
    .await
    .unwrap();

    send_command(&mut w, 1, Command::SplitHorizontal).await;
    expect_ok(&mut r, 1).await;
    assert_eq!(list_tabs_len(&mut w, &mut r, 2).await, 1);

    send_command(&mut w, 3, Command::NewTab).await;
    expect_ok(&mut r, 3).await;
    assert_eq!(list_tabs_len(&mut w, &mut r, 4).await, 2);

    send_command(&mut w, 5, Command::FocusLeft).await;
    expect_ok(&mut r, 5).await;
    assert_eq!(list_tabs_len(&mut w, &mut r, 6).await, 1);

    send_command(&mut w, 7, Command::FocusRight).await;
    expect_ok(&mut r, 7).await;
    assert_eq!(list_tabs_len(&mut w, &mut r, 8).await, 2);

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nested_splits_render_more_than_two_panels() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (160, 36),
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
                cols: 160,
                rows: 36,
            },
            token: None,
        },
    )
    .await
    .unwrap();

    send_command(&mut w, 1, Command::SplitHorizontal).await;
    expect_ok(&mut r, 1).await;
    send_command(&mut w, 2, Command::SplitVertical).await;
    expect_ok(&mut r, 2).await;

    let corners = wait_for_corner_count(&mut r, Duration::from_secs(3), |count| count >= 3).await;
    assert!(
        corners >= 3,
        "nested split frame should render at least 3 panels, got {corners}"
    );

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn focus_left_is_noop_when_only_diagonal_panes_exist() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (160, 36),
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
                cols: 160,
                rows: 36,
            },
            token: None,
        },
    )
    .await
    .unwrap();
    let _initial_tab_id = read_until_active(&mut r, 0).await;

    // Bottom pane gets focus and keeps a distinct two-tab stack.
    send_command(&mut w, 1, Command::SplitVertical).await;
    let _bottom_tab_id = read_until_active(&mut r, 0).await;
    send_command(&mut w, 2, Command::NewTab).await;
    let _bottom_second_tab_id = read_until_active(&mut r, 1).await;
    assert_eq!(list_tabs_len(&mut w, &mut r, 3).await, 2);

    // Split the top pane into top-left / top-right, then return focus to
    // the bottom pane. From the bottom pane there is no vertically
    // overlapping pane to the left, only diagonal panes above.
    send_command(&mut w, 4, Command::FocusUp).await;
    let _top_tab_id = read_until_active(&mut r, 0).await;
    send_command(&mut w, 5, Command::SplitHorizontal).await;
    let _top_right_tab_id = read_until_active(&mut r, 0).await;
    send_command(&mut w, 6, Command::FocusDown).await;
    let _focused_bottom_again = read_until_active(&mut r, 1).await;
    assert_eq!(list_tabs_len(&mut w, &mut r, 7).await, 2);

    send_command(&mut w, 8, Command::FocusLeft).await;
    expect_ok(&mut r, 8).await;
    assert_eq!(
        list_tabs_len(&mut w, &mut r, 9).await,
        2,
        "FocusLeft should stay on the bottom pane when only diagonal panes exist to the left"
    );

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn focus_down_from_wide_top_returns_to_the_same_bottom_side() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (160, 36),
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
                cols: 160,
                rows: 36,
            },
            token: None,
        },
    )
    .await
    .unwrap();
    let _top_tab_id = read_until_active(&mut r, 0).await;

    // Build the exact layout from the screenshot:
    //   - top pane spans the full width
    //   - bottom row is split into left / right
    send_command(&mut w, 1, Command::SplitVertical).await;
    let bottom_tab_id = read_until_active(&mut r, 0).await;

    send_command(&mut w, 2, Command::NewTab).await;
    let bottom_left_second_tab_id = read_until_active(&mut r, 1).await;
    assert_ne!(bottom_left_second_tab_id, bottom_tab_id);

    send_command(&mut w, 3, Command::SplitHorizontal).await;
    let bottom_right_tab_id = read_until_active(&mut r, 0).await;
    assert_ne!(bottom_right_tab_id, bottom_left_second_tab_id);

    // Bottom-right -> top -> down should return to bottom-right, not to
    // bottom-left just because the top pane is wide and centered.
    send_command(&mut w, 4, Command::FocusUp).await;
    let focused_top_again = read_until_active(&mut r, 0).await;
    assert_eq!(focused_top_again, _top_tab_id);

    send_command(&mut w, 5, Command::FocusDown).await;
    let focused_bottom_again = read_until_active(&mut r, 0).await;
    assert_eq!(
        focused_bottom_again, bottom_right_tab_id,
        "FocusDown from the wide top pane should return to the bottom-right pane after entering from the right"
    );

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn closing_active_tab_keeps_focus_in_same_split_panel_when_tabs_remain() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (140, 30),
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
                cols: 140,
                rows: 30,
            },
            token: None,
        },
    )
    .await
    .unwrap();
    let _initial_tab_id = read_until_active(&mut r, 0).await;

    send_command(&mut w, 1, Command::SplitHorizontal).await;
    let right_tab_id = read_until_active(&mut r, 0).await;

    send_command(&mut w, 2, Command::NewTab).await;
    let newer_right_tab_id = read_until_active(&mut r, 1).await;
    assert_ne!(newer_right_tab_id, right_tab_id);

    send_command(&mut w, 3, Command::CloseTab).await;
    let focused_after_close = read_until_active(&mut r, 0).await;
    assert_eq!(
        focused_after_close, right_tab_id,
        "closing the active tab should stay in the same split panel when a sibling tab remains"
    );

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn closing_nested_pane_focuses_the_sibling_that_absorbed_it() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (160, 36),
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
                cols: 160,
                rows: 36,
            },
            token: None,
        },
    )
    .await
    .unwrap();
    let _initial_tab_id = read_until_active(&mut r, 0).await;

    send_command(&mut w, 1, Command::SplitHorizontal).await;
    let top_right_tab_id = read_until_active(&mut r, 0).await;

    send_command(&mut w, 2, Command::SplitVertical).await;
    let bottom_right_tab_id = read_until_active(&mut r, 0).await;
    assert_ne!(bottom_right_tab_id, top_right_tab_id);

    send_command(&mut w, 3, Command::CloseTab).await;
    let focused_after_close = read_until_active(&mut r, 0).await;
    assert_eq!(
        focused_after_close, top_right_tab_id,
        "closing a nested pane should focus the sibling pane that absorbed its space"
    );

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

async fn read_until_active(r: &mut (impl tokio::io::AsyncRead + Unpin), want: usize) -> u64 {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, read_msg::<_, ServerMsg>(r))
            .await
            .expect("read timeout")
            .unwrap()
            .unwrap();
        if let ServerMsg::ActiveTabChanged { index, tab_id } = msg
            && index == want
        {
            return tab_id;
        }
    }
}

async fn send_command<W: tokio::io::AsyncWrite + Unpin>(w: &mut W, id: u32, command: Command) {
    write_msg(w, &ClientMsg::Command { id, command })
        .await
        .unwrap();
}

async fn expect_ok(r: &mut (impl tokio::io::AsyncRead + Unpin), want_id: u32) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, read_msg::<_, ServerMsg>(r))
            .await
            .expect("expect_ok timeout")
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

async fn list_tabs_len<W: tokio::io::AsyncWrite + Unpin, R: tokio::io::AsyncRead + Unpin>(
    w: &mut W,
    r: &mut R,
    id: u32,
) -> usize {
    send_command(w, id, Command::ListTabs).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, read_msg::<_, ServerMsg>(r))
            .await
            .expect("list tabs timeout")
            .unwrap()
            .unwrap();
        if let ServerMsg::CommandReply {
            id: got,
            result:
                cmux_cli_protocol::CommandResult::Ok {
                    data: Some(cmux_cli_protocol::CommandData::TabList { tabs, .. }),
                },
        } = msg
            && got == id
        {
            return tabs.len();
        }
    }
}

/// Resizing a horizontal split changes the relative sizes
/// the compositor uses. We can't easily inspect the inner layout
/// from outside, but we CAN observe that `ResizePane { delta }`
/// clamps to [100, 900] permille and that consecutive calls
/// accumulate — the test below walks past the clamp at both ends
/// and asserts the command never errors, then unsplits cleanly.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn resize_pane_accumulates_and_clamps() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (140, 30),
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
                cols: 140,
                rows: 30,
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
    expect_ok(&mut r, 1).await;

    // Hammer grow (+50 permille each) 20 times — more than enough
    // to overshoot the 900 clamp. Then hammer shrink.
    for i in 0..20 {
        write_msg(
            &mut w,
            &ClientMsg::Command {
                id: 100 + i,
                command: Command::ResizePane { delta: 50 },
            },
        )
        .await
        .unwrap();
        expect_ok(&mut r, 100 + i).await;
    }
    for i in 0..20 {
        write_msg(
            &mut w,
            &ClientMsg::Command {
                id: 200 + i,
                command: Command::ResizePane { delta: -50 },
            },
        )
        .await
        .unwrap();
        expect_ok(&mut r, 200 + i).await;
    }

    // Unsplit + exit to tear down cleanly.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 999,
            command: Command::Unsplit,
        },
    )
    .await
    .unwrap();
    expect_ok(&mut r, 999).await;
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nested_resize_targets_nearest_split_ancestor() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (160, 36),
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
                cols: 160,
                rows: 36,
            },
            token: None,
        },
    )
    .await
    .unwrap();

    send_command(&mut w, 1, Command::SplitHorizontal).await;
    expect_ok(&mut r, 1).await;
    send_command(&mut w, 2, Command::SplitVertical).await;
    expect_ok(&mut r, 2).await;

    assert_ansi_eventually_contains(&mut w, &mut r, "stty size\n", "15 70").await;

    send_command(&mut w, 3, Command::ResizePane { delta: 300 }).await;
    expect_ok(&mut r, 3).await;

    assert_ansi_eventually_contains(&mut w, &mut r, "stty size\n", "5 70").await;

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

/// `Command::DisplayMessage { text }` replaces the status-bar label
/// with `text` for ~2 seconds. We verify the message text appears
/// in a composed frame immediately after the command fires.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn display_message_shows_text_in_status_bar() {
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

    let marker = "DISPMSG_SENTINEL_B7C4";
    // Fire DisplayMessage up-front and drain every frame into a
    // shared buffer. The marker must appear somewhere in the
    // server's output; once it does we break out.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 1,
            command: Command::DisplayMessage {
                text: marker.into(),
            },
        },
    )
    .await
    .unwrap();

    let mut saw = false;
    let end = tokio::time::Instant::now() + Duration::from_secs(3);
    while tokio::time::Instant::now() < end && !saw {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        match timeout(
            remaining.min(Duration::from_millis(300)),
            read_msg::<_, ServerMsg>(&mut r),
        )
        .await
        {
            Ok(Ok(Some(ServerMsg::PtyBytes { data, .. })))
                if String::from_utf8_lossy(&data).contains(marker) =>
            {
                saw = true;
            }
            Ok(Ok(Some(_))) => {}
            _ => {}
        }
    }
    assert!(saw, "display-message never appeared in status bar");

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

async fn wait_for_corner_count<R, F>(r: &mut R, deadline: Duration, accept: F) -> usize
where
    R: tokio::io::AsyncRead + Unpin,
    F: Fn(usize) -> bool,
{
    let end = tokio::time::Instant::now() + deadline;
    let mut last_frame_count = 0usize;
    while tokio::time::Instant::now() < end {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        match timeout(
            remaining.min(Duration::from_millis(100)),
            read_msg::<_, ServerMsg>(r),
        )
        .await
        {
            Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) => {
                // Only count full composed frames — skip OSC 52 or
                // small chrome updates by requiring the frame to
                // contain at least one `╭` AND be large enough.
                let s = String::from_utf8_lossy(&data);
                if data.len() > 1000 && s.contains('╭') {
                    last_frame_count = s.matches('╭').count();
                    if accept(last_frame_count) {
                        return last_frame_count;
                    }
                }
            }
            Ok(Ok(Some(_))) => {}
            Err(_) => {}
            _ => break,
        }
    }
    last_frame_count
}

async fn assert_ansi_eventually_contains<W, R>(w: &mut W, r: &mut R, input: &str, needle: &str)
where
    W: tokio::io::AsyncWrite + Unpin,
    R: tokio::io::AsyncRead + Unpin,
{
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut last_frame = String::new();
    while tokio::time::Instant::now() < deadline {
        write_msg(
            w,
            &ClientMsg::Input {
                data: input.as_bytes().to_vec(),
            },
        )
        .await
        .unwrap();
        let poll_until = (tokio::time::Instant::now() + Duration::from_millis(250)).min(deadline);
        while tokio::time::Instant::now() < poll_until {
            match timeout(
                poll_until.saturating_duration_since(tokio::time::Instant::now()),
                read_msg::<_, ServerMsg>(r),
            )
            .await
            {
                Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) => {
                    let frame = String::from_utf8_lossy(&data).into_owned();
                    if frame.contains(needle) {
                        return;
                    }
                    last_frame = frame;
                }
                Ok(Ok(Some(_))) => {}
                Ok(Ok(None)) => break,
                Ok(Err(e)) => panic!("protocol error: {e:?}"),
                Err(_) => break,
            }
        }
    }
    panic!("ANSI stream never contained {needle:?}; last frame:\n{last_frame}");
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
