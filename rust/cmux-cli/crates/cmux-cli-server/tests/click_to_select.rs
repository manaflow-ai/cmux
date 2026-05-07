//! Clicking a tab pill inside the pane's tab bar should switch tabs.
//! Clicking a workspace row in the sidebar should switch workspaces.
//! Both paths run through the server's mouse-Down handler, which routes
//! chrome-zone clicks instead of anchoring a text-selection drag.

use std::time::Duration;

use cmux_cli_protocol::{
    ClientMsg, Command, CommandData, CommandResult, MouseKind, PROTOCOL_VERSION, ServerMsg,
    Viewport, WorkspaceInfo, read_msg, write_msg,
};
use cmux_cli_server::{ServerOptions, run};
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::time::timeout;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn clicking_tab_pill_switches_active_tab() {
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
    expect_welcome(&mut r).await;
    expect_active_tab(&mut r, 0).await;

    // Create a second tab so the tab bar has two pills to click.
    send_cmd(&mut w, 1, Command::NewTab).await;
    expect_active_tab(&mut r, 1).await;

    // Compute the terminal-pill bar location for tab 0. Sidebar is 16 cols
    // wide, the space strip consumes row 0, and the pane's top border starts
    // at row 1. The pill strip sits one column inside the border, so it
    // starts at col 17. Tab 0's pill is " 0:sh " — the first column
    // inside the bar hits pill 0.
    let click_col = 17u16 + 2; // middle of " 0:sh "
    send_click(&mut w, click_col, 1).await;

    // Expect ActiveTabChanged { index: 0 } back from the server.
    let evt = read_until::<ServerMsg, _>(&mut r, |m| {
        matches!(m, ServerMsg::ActiveTabChanged { index: 0, .. })
    })
    .await;
    match evt {
        ServerMsg::ActiveTabChanged { index, .. } => assert_eq!(index, 0),
        _ => unreachable!(),
    }

    // Clean shutdown.
    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"exit\n".to_vec(),
        },
    )
    .await
    .unwrap();
    send_cmd(&mut w, 99, Command::CloseTab).await;
    server.abort();
    let _ = server.await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn clicking_sidebar_row_switches_active_workspace() {
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
    expect_welcome(&mut r).await;
    // Initial workspace + tab announcements.
    expect_active_workspace(&mut r, 0).await;
    expect_active_tab(&mut r, 0).await;

    // Create a second workspace so there's something to click back to.
    send_cmd(
        &mut w,
        1,
        Command::NewWorkspace {
            title: Some("work".into()),
            cwd: None,
        },
    )
    .await;
    expect_active_workspace(&mut r, 1).await;

    // Click workspace index 0 in the sidebar. Row 0 is its single top
    // padding row and row 1 is its title row.
    send_click(&mut w, 3, 0).await;
    let evt = read_until::<ServerMsg, _>(&mut r, |m| {
        matches!(m, ServerMsg::ActiveWorkspaceChanged { index: 0, .. })
    })
    .await;
    match evt {
        ServerMsg::ActiveWorkspaceChanged { index, .. } => assert_eq!(index, 0),
        _ => unreachable!(),
    }

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"exit\n".to_vec(),
        },
    )
    .await
    .unwrap();
    server.abort();
    let _ = server.await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn clicking_sidebar_new_button_creates_workspace() {
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
    expect_welcome(&mut r).await;
    expect_active_workspace(&mut r, 0).await;

    // With one workspace visible, [new] sits after its
    // top-padding/title/bottom-padding block plus one spacer row.
    send_click(&mut w, 3, 4).await;
    let evt = read_until::<ServerMsg, _>(&mut r, |m| {
        matches!(m, ServerMsg::ActiveWorkspaceChanged { index: 1, .. })
    })
    .await;
    match evt {
        ServerMsg::ActiveWorkspaceChanged { index, .. } => assert_eq!(index, 1),
        _ => unreachable!(),
    }

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"exit\n".to_vec(),
        },
    )
    .await
    .unwrap();
    server.abort();
    let _ = server.await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn right_click_sidebar_context_menu_pins_and_closes_workspace() {
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
    expect_welcome(&mut r).await;
    expect_active_workspace(&mut r, 0).await;

    send_cmd(
        &mut w,
        1,
        Command::NewWorkspace {
            title: Some("work".into()),
            cwd: None,
        },
    )
    .await;
    expect_active_workspace(&mut r, 1).await;

    send_right_click(&mut w, 3, 1).await;
    send_click(&mut w, 2, 1).await;
    let workspaces = request_workspace_list(&mut w, &mut r, 2).await;
    assert!(workspaces[0].pinned);

    send_right_click(&mut w, 3, 4).await;
    send_click(&mut w, 2, 5).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    let mut list_id = 3;
    loop {
        let workspaces = request_workspace_list(&mut w, &mut r, list_id).await;
        list_id += 1;
        if workspaces.len() == 1 {
            assert_eq!(workspaces[0].title, "main");
            break;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "workspace was not closed: {workspaces:?}"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    server.abort();
    let _ = server.await;
}

async fn send_cmd<W: tokio::io::AsyncWrite + Unpin>(w: &mut W, id: u32, cmd: Command) {
    write_msg(w, &ClientMsg::Command { id, command: cmd })
        .await
        .unwrap();
}

async fn request_workspace_list<W, R>(w: &mut W, r: &mut R, id: u32) -> Vec<WorkspaceInfo>
where
    W: tokio::io::AsyncWrite + Unpin,
    R: tokio::io::AsyncRead + Unpin,
{
    send_cmd(w, id, Command::ListWorkspaces).await;
    let evt = read_until::<ServerMsg, _>(
        r,
        |m| matches!(m, ServerMsg::CommandReply { id: reply_id, .. } if *reply_id == id),
    )
    .await;
    match evt {
        ServerMsg::CommandReply {
            result:
                CommandResult::Ok {
                    data:
                        Some(CommandData::WorkspaceList {
                            workspaces,
                            active: _,
                        }),
                },
            ..
        } => workspaces,
        other => panic!("unexpected workspace-list reply: {other:?}"),
    }
}

async fn send_click<W: tokio::io::AsyncWrite + Unpin>(w: &mut W, col: u16, row: u16) {
    // A real click is Down then Up on the same cell. The server acts on
    // Down for chrome zones; the Up is harmless (no selection was armed).
    write_msg(
        w,
        &ClientMsg::Mouse {
            col,
            row,
            event: MouseKind::Down,
        },
    )
    .await
    .unwrap();
    write_msg(
        w,
        &ClientMsg::Mouse {
            col,
            row,
            event: MouseKind::Up,
        },
    )
    .await
    .unwrap();
}

async fn send_right_click<W: tokio::io::AsyncWrite + Unpin>(w: &mut W, col: u16, row: u16) {
    write_msg(
        w,
        &ClientMsg::Mouse {
            col,
            row,
            event: MouseKind::RightDown,
        },
    )
    .await
    .unwrap();
    write_msg(
        w,
        &ClientMsg::Mouse {
            col,
            row,
            event: MouseKind::RightUp,
        },
    )
    .await
    .unwrap();
}

async fn expect_welcome(r: &mut (impl tokio::io::AsyncRead + Unpin)) {
    let msg = timeout(Duration::from_secs(5), read_msg::<_, ServerMsg>(r))
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(matches!(msg, ServerMsg::Welcome { .. }), "got {msg:?}");
}

async fn expect_active_tab(r: &mut (impl tokio::io::AsyncRead + Unpin), want: usize) {
    let m = read_until::<ServerMsg, _>(
        r,
        |m| matches!(m, ServerMsg::ActiveTabChanged { index, .. } if *index == want),
    )
    .await;
    drop(m);
}

async fn expect_active_workspace(r: &mut (impl tokio::io::AsyncRead + Unpin), want: usize) {
    let m = read_until::<ServerMsg, _>(
        r,
        |m| matches!(m, ServerMsg::ActiveWorkspaceChanged { index, .. } if *index == want),
    )
    .await;
    drop(m);
}

async fn read_until<T, F>(r: &mut (impl tokio::io::AsyncRead + Unpin), pred: F) -> T
where
    T: for<'de> serde::Deserialize<'de> + std::fmt::Debug,
    F: Fn(&T) -> bool,
{
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, read_msg::<_, T>(r))
            .await
            .expect("read_until timeout")
            .expect("read_until io")
            .expect("read_until eof");
        if pred(&msg) {
            return msg;
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
