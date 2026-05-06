//! M8: server-side prefix key dispatch + hot reload.
//!
//! We drive the dispatch by stuffing prefix-bytes into a ClientMsg::Input,
//! then verify the corresponding command fires by inspecting command
//! replies and space or terminal lists.

use std::time::Duration;

use cmux_cli_core::settings::{self, Settings};
use cmux_cli_protocol::{
    ClientMsg, Command, CommandData, CommandResult, PROTOCOL_VERSION, ServerMsg, Viewport,
    read_msg, write_msg,
};
use cmux_cli_server::{ServerOptions, run};
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::time::timeout;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn default_prefix_c_creates_space() {
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

    handshake(&mut w, &mut r, Viewport { cols: 80, rows: 24 }).await;
    drain_announcements(&mut r).await;

    // Ctrl-B (0x02) then 'c' → NewSpace.
    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: vec![0x02, b'c'],
        },
    )
    .await
    .unwrap();

    // Daemon should now announce the new active space (index 1).
    let active = read_until(&mut r, |m| {
        matches!(m, ServerMsg::ActiveSpaceChanged { .. })
    })
    .await;
    match active {
        ServerMsg::ActiveSpaceChanged { index, .. } => assert_eq!(index, 1),
        _ => unreachable!(),
    }

    // Confirm via ListSpaces.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 1,
            command: Command::ListSpaces,
        },
    )
    .await
    .unwrap();
    let list = wait_for_reply(&mut r, 1).await;
    match list {
        ServerMsg::CommandReply {
            result:
                CommandResult::Ok {
                    data: Some(CommandData::SpaceList { spaces, active }),
                },
            ..
        } => {
            assert_eq!(spaces.len(), 2, "expected 2 spaces after prefix+c");
            assert_eq!(active, 1);
        }
        other => panic!("expected SpaceList, got {other:?}"),
    }
    assert_eq!(list_space_count(&mut w, &mut r, 2).await, 2);

    drop(r);
    drop(w);
    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn default_ctrl_t_digit_selects_terminal_in_focused_pane() {
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

    handshake(&mut w, &mut r, Viewport { cols: 80, rows: 24 }).await;
    drain_announcements(&mut r).await;

    send_command(&mut w, 1, Command::NewTab).await;
    expect_ok(&mut r, 1).await;
    let active = read_until(&mut r, |m| {
        matches!(m, ServerMsg::ActiveTabChanged { index: 1, .. })
    })
    .await;
    match active {
        ServerMsg::ActiveTabChanged { index, .. } => assert_eq!(index, 1),
        _ => unreachable!(),
    }

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"\x140".to_vec(),
        },
    )
    .await
    .unwrap();

    let active = read_until(&mut r, |m| {
        matches!(m, ServerMsg::ActiveTabChanged { index: 0, .. })
    })
    .await;
    match active {
        ServerMsg::ActiveTabChanged { index, .. } => assert_eq!(index, 0),
        _ => unreachable!(),
    }

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn default_alt_navigation_focuses_split_panes() {
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

    handshake(
        &mut w,
        &mut r,
        Viewport {
            cols: 120,
            rows: 24,
        },
    )
    .await;
    drain_announcements(&mut r).await;

    send_command(&mut w, 1, Command::SplitHorizontal).await;
    expect_ok(&mut r, 1).await;
    send_command(&mut w, 2, Command::NewTab).await;
    expect_ok(&mut r, 2).await;
    assert_eq!(list_tab_count(&mut w, &mut r, 3).await, 2);

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"\x1bh".to_vec(),
        },
    )
    .await
    .unwrap();
    assert_eq!(list_tab_count(&mut w, &mut r, 4).await, 1);

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"\x1b\x1b[C".to_vec(),
        },
    )
    .await
    .unwrap();
    assert_eq!(list_tab_count(&mut w, &mut r, 5).await, 2);

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn default_alt_left_is_noop_when_only_diagonal_panes_exist() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
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

    handshake(
        &mut w,
        &mut r,
        Viewport {
            cols: 160,
            rows: 36,
        },
    )
    .await;
    drain_announcements(&mut r).await;

    send_command(&mut w, 1, Command::SplitVertical).await;
    expect_ok(&mut r, 1).await;
    send_command(&mut w, 2, Command::NewTab).await;
    expect_ok(&mut r, 2).await;
    assert_eq!(list_tab_count(&mut w, &mut r, 3).await, 2);

    send_command(&mut w, 4, Command::FocusUp).await;
    expect_ok(&mut r, 4).await;
    send_command(&mut w, 5, Command::SplitHorizontal).await;
    expect_ok(&mut r, 5).await;
    send_command(&mut w, 6, Command::FocusDown).await;
    expect_ok(&mut r, 6).await;
    assert_eq!(list_tab_count(&mut w, &mut r, 7).await, 2);

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"\x1bh".to_vec(),
        },
    )
    .await
    .unwrap();
    assert_eq!(
        list_tab_count(&mut w, &mut r, 8).await,
        2,
        "Alt-h should stay on the bottom pane when only diagonal panes exist to the left"
    );

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn default_workspace_sidebar_mode_uses_jk_and_ctrl_np() {
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

    handshake(
        &mut w,
        &mut r,
        Viewport {
            cols: 120,
            rows: 24,
        },
    )
    .await;
    drain_announcements(&mut r).await;

    send_command(
        &mut w,
        1,
        Command::NewWorkspace {
            title: Some("work".into()),
            cwd: None,
        },
    )
    .await;
    expect_ok(&mut r, 1).await;
    let active = read_until(&mut r, |m| {
        matches!(m, ServerMsg::ActiveWorkspaceChanged { index: 1, .. })
    })
    .await;
    match active {
        ServerMsg::ActiveWorkspaceChanged { index, .. } => assert_eq!(index, 1),
        _ => unreachable!(),
    }

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"\x02b".to_vec(),
        },
    )
    .await
    .unwrap();

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"k".to_vec(),
        },
    )
    .await
    .unwrap();
    let prev = read_until(&mut r, |m| {
        matches!(m, ServerMsg::ActiveWorkspaceChanged { index: 0, .. })
    })
    .await;
    match prev {
        ServerMsg::ActiveWorkspaceChanged { index, .. } => assert_eq!(index, 0),
        _ => unreachable!(),
    }

    write_msg(&mut w, &ClientMsg::Input { data: vec![0x0e] })
        .await
        .unwrap();
    let next = read_until(&mut r, |m| {
        matches!(m, ServerMsg::ActiveWorkspaceChanged { index: 1, .. })
    })
    .await;
    match next {
        ServerMsg::ActiveWorkspaceChanged { index, .. } => assert_eq!(index, 1),
        _ => unreachable!(),
    }

    write_msg(&mut w, &ClientMsg::Input { data: vec![b'\r'] })
        .await
        .unwrap();

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn workspace_sidebar_mode_can_create_a_new_workspace() {
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

    handshake(
        &mut w,
        &mut r,
        Viewport {
            cols: 120,
            rows: 24,
        },
    )
    .await;
    drain_announcements(&mut r).await;

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"\x02w".to_vec(),
        },
    )
    .await
    .unwrap();

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"c".to_vec(),
        },
    )
    .await
    .unwrap();

    let active = read_until(&mut r, |m| {
        matches!(m, ServerMsg::ActiveWorkspaceChanged { index: 1, .. })
    })
    .await;
    match active {
        ServerMsg::ActiveWorkspaceChanged { index, .. } => assert_eq!(index, 1),
        _ => unreachable!(),
    }

    send_command(&mut w, 1, Command::ListWorkspaces).await;
    match wait_for_reply(&mut r, 1).await {
        ServerMsg::CommandReply {
            result:
                CommandResult::Ok {
                    data: Some(CommandData::WorkspaceList { workspaces, active }),
                },
            ..
        } => {
            assert_eq!(workspaces.len(), 2);
            assert_eq!(active, 1);
        }
        other => panic!("expected workspace list reply, got {other:?}"),
    }

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn zellij_ctrl_p_split_chords_spawn_and_focus_new_panes() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let settings_path = dir.path().join("settings.json");
    let mut settings = Settings::default();
    settings.shortcuts.preset = "zellij".into();
    settings::save(&settings_path, &settings).unwrap();

    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (120, 24),
        snapshot_path: None,
        settings_path: Some(settings_path),
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

    handshake(
        &mut w,
        &mut r,
        Viewport {
            cols: 120,
            rows: 24,
        },
    )
    .await;
    drain_announcements(&mut r).await;

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"\x10r".to_vec(),
        },
    )
    .await
    .unwrap();
    let right = read_until(&mut r, |m| matches!(m, ServerMsg::ActiveTabChanged { .. })).await;
    let right_tab_id = match right {
        ServerMsg::ActiveTabChanged { tab_id, .. } => tab_id,
        _ => unreachable!(),
    };

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"\x10d".to_vec(),
        },
    )
    .await
    .unwrap();
    let bottom = read_until(&mut r, |m| matches!(m, ServerMsg::ActiveTabChanged { .. })).await;
    match bottom {
        ServerMsg::ActiveTabChanged { tab_id, .. } => {
            assert_ne!(tab_id, right_tab_id, "Ctrl-p d should create a new pane");
        }
        _ => unreachable!(),
    }

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hot_reload_rebinds_prefix() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let settings_path = dir.path().join("settings.json");

    // Seed a settings file with Ctrl-A as the prefix.
    let mut s = Settings::default();
    s.shortcuts.prefix = "C-a".into();
    settings::save(&settings_path, &s).unwrap();

    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: Some(settings_path.clone()),
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

    handshake(&mut w, &mut r, Viewport { cols: 80, rows: 24 }).await;
    drain_announcements(&mut r).await;

    // Ctrl-A (0x01) + 'c' should create a space.
    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: vec![0x01, b'c'],
        },
    )
    .await
    .unwrap();
    let active = read_until(&mut r, |m| {
        matches!(m, ServerMsg::ActiveSpaceChanged { .. })
    })
    .await;
    match active {
        ServerMsg::ActiveSpaceChanged { index, .. } => assert_eq!(index, 1),
        _ => unreachable!(),
    }

    // Now rewrite settings to use Ctrl-X as the prefix.
    let mut s = Settings::default();
    s.shortcuts.prefix = "C-x".into();
    settings::save(&settings_path, &s).unwrap();

    // Poll: Ctrl-X + 'c' should eventually create another space (the watcher
    // takes a small amount of time to fire; notify debounces at the OS
    // level, and under parallel test load on macOS it can take a second or
    // two). Generous overall budget; per-attempt window drains messages so
    // we don't spin hot.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    'outer: loop {
        if tokio::time::Instant::now() > deadline {
            panic!("hot reload never took effect");
        }
        write_msg(
            &mut w,
            &ClientMsg::Input {
                data: vec![0x18, b'c'],
            },
        )
        .await
        .unwrap();
        let window = tokio::time::Instant::now() + Duration::from_millis(600);
        while tokio::time::Instant::now() < window {
            let remaining = window.saturating_duration_since(tokio::time::Instant::now());
            match timeout(remaining, read_msg::<_, ServerMsg>(&mut r)).await {
                Ok(Ok(Some(ServerMsg::ActiveSpaceChanged { index, .. }))) if index >= 2 => {
                    break 'outer;
                }
                Ok(Ok(Some(_))) => continue,
                _ => break,
            }
        }
    }
    assert_eq!(list_space_count(&mut w, &mut r, 3).await, 3);

    drop(r);
    drop(w);
    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

// ------------------------------- helpers -------------------------------

async fn wait_for_socket(socket: &std::path::Path) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while !socket.exists() {
        if tokio::time::Instant::now() > deadline {
            panic!("socket did not appear");
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

async fn send_command<W>(w: &mut W, id: u32, command: Command)
where
    W: tokio::io::AsyncWrite + Unpin,
{
    write_msg(w, &ClientMsg::Command { id, command })
        .await
        .unwrap();
}

async fn expect_ok<R>(r: &mut R, want_id: u32)
where
    R: tokio::io::AsyncRead + Unpin,
{
    match wait_for_reply(r, want_id).await {
        ServerMsg::CommandReply {
            result: CommandResult::Ok { .. },
            ..
        } => {}
        other => panic!("expected ok reply for {want_id}, got {other:?}"),
    }
}

async fn list_tab_count<R, W>(w: &mut W, r: &mut R, id: u32) -> usize
where
    R: tokio::io::AsyncRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
{
    send_command(w, id, Command::ListTabs).await;
    match wait_for_reply(r, id).await {
        ServerMsg::CommandReply {
            result:
                CommandResult::Ok {
                    data: Some(CommandData::TabList { tabs, .. }),
                },
            ..
        } => tabs.len(),
        other => panic!("expected tab list reply for {id}, got {other:?}"),
    }
}

async fn list_space_count<R, W>(w: &mut W, r: &mut R, id: u32) -> usize
where
    R: tokio::io::AsyncRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
{
    send_command(w, id, Command::ListSpaces).await;
    match wait_for_reply(r, id).await {
        ServerMsg::CommandReply {
            result:
                CommandResult::Ok {
                    data: Some(CommandData::SpaceList { spaces, .. }),
                },
            ..
        } => spaces.len(),
        other => panic!("expected space list reply for {id}, got {other:?}"),
    }
}

async fn handshake<R, W>(w: &mut W, r: &mut R, viewport: Viewport)
where
    R: tokio::io::AsyncRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
{
    write_msg(
        w,
        &ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            viewport,
            token: None,
        },
    )
    .await
    .unwrap();
    let welcome = timeout(Duration::from_secs(5), read_msg::<_, ServerMsg>(r))
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    matches!(welcome, ServerMsg::Welcome { .. })
        .then_some(())
        .expect("Welcome");
}

async fn drain_announcements<R>(r: &mut R)
where
    R: tokio::io::AsyncRead + Unpin,
{
    // Drain the initial active-object announcements.
    while let Ok(Ok(Some(_))) =
        timeout(Duration::from_millis(50), read_msg::<_, ServerMsg>(r)).await
    {}
}

async fn read_until<R, F>(r: &mut R, pred: F) -> ServerMsg
where
    R: tokio::io::AsyncRead + Unpin,
    F: Fn(&ServerMsg) -> bool,
{
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, read_msg::<_, ServerMsg>(r))
            .await
            .expect("read_until timeout")
            .expect("io")
            .expect("eof");
        if pred(&msg) {
            return msg;
        }
    }
}

async fn wait_for_reply<R>(r: &mut R, want_id: u32) -> ServerMsg
where
    R: tokio::io::AsyncRead + Unpin,
{
    read_until(
        r,
        |m| matches!(m, ServerMsg::CommandReply { id, .. } if *id == want_id),
    )
    .await
}
