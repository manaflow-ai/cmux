//! Pinning prevents a workspace from dying when its last tab exits.
//! We verify the pinned state is exposed via `ListWorkspaces` and
//! toggles via `Command::TogglePin`.

use std::time::Duration;

use cmux_cli_protocol::{
    ClientMsg, Command, CommandData, CommandResult, PROTOCOL_VERSION, ServerMsg, Viewport,
    read_msg, write_msg,
};
use cmux_cli_server::{ServerOptions, run};
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::time::timeout;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn toggle_pin_flips_the_pinned_flag_on_list() {
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

    // Baseline: workspace 0 unpinned.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 1,
            command: Command::ListWorkspaces,
        },
    )
    .await
    .unwrap();
    let first = read_reply(&mut r, 1).await;
    match first {
        CommandResult::Ok {
            data: Some(CommandData::WorkspaceList { workspaces, .. }),
        } => assert!(
            !workspaces[0].pinned,
            "default workspace should start unpinned"
        ),
        other => panic!("expected WorkspaceList, got {other:?}"),
    }

    // Pin it.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 2,
            command: Command::TogglePin,
        },
    )
    .await
    .unwrap();
    let _ = read_reply(&mut r, 2).await;

    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 3,
            command: Command::ListWorkspaces,
        },
    )
    .await
    .unwrap();
    let second = read_reply(&mut r, 3).await;
    match second {
        CommandResult::Ok {
            data: Some(CommandData::WorkspaceList { workspaces, .. }),
        } => assert!(
            workspaces[0].pinned,
            "after TogglePin workspace should be pinned"
        ),
        other => panic!("expected WorkspaceList, got {other:?}"),
    }

    // Toggle off → back to unpinned.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 4,
            command: Command::TogglePin,
        },
    )
    .await
    .unwrap();
    let _ = read_reply(&mut r, 4).await;
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 5,
            command: Command::ListWorkspaces,
        },
    )
    .await
    .unwrap();
    let third = read_reply(&mut r, 5).await;
    match third {
        CommandResult::Ok {
            data: Some(CommandData::WorkspaceList { workspaces, .. }),
        } => assert!(!workspaces[0].pinned),
        other => panic!("expected WorkspaceList, got {other:?}"),
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
    let _ = timeout(Duration::from_millis(500), server).await;
}

/// `Command::SetWorkspaceColor` normalises `#RRGGBB` and rejects
/// garbage. `ListWorkspaces` exposes the stored value back.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn set_workspace_color_persists_and_normalises() {
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

    // Accepts bare 6-char hex; stores normalised uppercase with `#`.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 1,
            command: Command::SetWorkspaceColor {
                color: Some("ff6b6b".into()),
            },
        },
    )
    .await
    .unwrap();
    let _ = read_reply(&mut r, 1).await;

    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 2,
            command: Command::ListWorkspaces,
        },
    )
    .await
    .unwrap();
    let r2 = read_reply(&mut r, 2).await;
    match r2 {
        CommandResult::Ok {
            data: Some(CommandData::WorkspaceList { workspaces, .. }),
        } => assert_eq!(workspaces[0].color.as_deref(), Some("#FF6B6B")),
        other => panic!("expected WorkspaceList, got {other:?}"),
    }

    // Malformed color rejected.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 3,
            command: Command::SetWorkspaceColor {
                color: Some("not-a-color".into()),
            },
        },
    )
    .await
    .unwrap();
    match read_reply(&mut r, 3).await {
        CommandResult::Err { message } => {
            assert!(message.contains("invalid color"), "got {message:?}");
        }
        other => panic!("expected Err, got {other:?}"),
    }

    // Clearing works with None.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 4,
            command: Command::SetWorkspaceColor { color: None },
        },
    )
    .await
    .unwrap();
    let _ = read_reply(&mut r, 4).await;
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 5,
            command: Command::ListWorkspaces,
        },
    )
    .await
    .unwrap();
    match read_reply(&mut r, 5).await {
        CommandResult::Ok {
            data: Some(CommandData::WorkspaceList { workspaces, .. }),
        } => assert_eq!(workspaces[0].color, None),
        other => panic!("expected WorkspaceList, got {other:?}"),
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
    let _ = timeout(Duration::from_millis(500), server).await;
}

async fn read_reply(r: &mut (impl tokio::io::AsyncRead + Unpin), want_id: u32) -> CommandResult {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, read_msg::<_, ServerMsg>(r))
            .await
            .expect("timeout")
            .unwrap()
            .unwrap();
        if let ServerMsg::CommandReply { id, result } = msg
            && id == want_id
        {
            return result;
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
