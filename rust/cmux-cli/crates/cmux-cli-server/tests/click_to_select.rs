//! Clicking a tab pill inside the pane's tab bar should switch tabs.
//! Clicking a workspace row in the sidebar should switch workspaces.
//! Both paths run through the server's mouse-Down handler, which routes
//! chrome-zone clicks instead of anchoring a text-selection drag.

use std::time::Duration;

use cmux_cli_protocol::{
    ClientMsg, Command, MouseKind, PROTOCOL_VERSION, ServerMsg, Viewport, read_msg, write_msg,
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

    // Click workspace index 0 in the sidebar. Item rows start at row 2;
    // workspace index 0 sits on row 2. Any col < 16 is in the sidebar.
    send_click(&mut w, 3, 2).await;
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

async fn send_cmd<W: tokio::io::AsyncWrite + Unpin>(w: &mut W, id: u32, cmd: Command) {
    write_msg(w, &ClientMsg::Command { id, command: cmd })
        .await
        .unwrap();
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
