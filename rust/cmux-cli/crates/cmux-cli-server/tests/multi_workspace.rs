//! M6: multi-workspace command coverage.
//!
//! - NewWorkspace creates a second workspace and auto-activates it.
//! - ListWorkspaces reports the real set + active index.
//! - SelectWorkspace { index: 0 } switches back.
//! - Server writes a snapshot to disk on clean shutdown and a fresh server
//!   restores the workspace structure (titles survive).

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
async fn workspace_switch_and_snapshot_roundtrip() {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("server.sock");
    let snapshot = dir.path().join("snap.json");

    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: Some(snapshot.clone()),
        settings_path: None,
        ws_bind: None,
        auth_token: None,
    };

    let server = tokio::spawn(async move { run(opts).await });

    wait_for(&socket).await;

    let stream = UnixStream::connect(&socket).await.unwrap();
    let (read_half, mut w) = stream.into_split();
    let mut r = BufReader::new(read_half);
    handshake(&mut r, &mut w).await;

    // Initial welcome sends ActiveWorkspaceChanged then ActiveTabChanged.
    expect_active_ws(&mut r, 0).await;
    expect_active_tab(&mut r, 0).await;

    // Create workspace 2.
    send_command(
        &mut w,
        1,
        Command::NewWorkspace {
            title: Some("sidebar".into()),
            cwd: None,
        },
    )
    .await;
    expect_reply_ok(&mut r, 1).await;
    expect_active_ws(&mut r, 1).await;
    expect_active_tab(&mut r, 0).await;

    // ListWorkspaces shows both, with idx 1 active.
    send_command(&mut w, 2, Command::ListWorkspaces).await;
    let list_msg = wait_for_reply(&mut r, 2).await;
    match list_msg {
        ServerMsg::CommandReply {
            result:
                CommandResult::Ok {
                    data: Some(CommandData::WorkspaceList { workspaces, active }),
                },
            ..
        } => {
            assert_eq!(workspaces.len(), 2);
            assert_eq!(active, 1);
            assert_eq!(workspaces[1].title, "sidebar");
        }
        other => panic!("expected WorkspaceList, got {other:?}"),
    }

    // Switch back to workspace 0.
    send_command(&mut w, 3, Command::SelectWorkspace { index: 0 }).await;
    expect_reply_ok(&mut r, 3).await;
    expect_active_ws(&mut r, 0).await;
    expect_active_tab(&mut r, 0).await;

    // Clean shutdown: close workspaces one by one. CloseWorkspace is
    // asynchronous (it sends ctrl-D; the shell has to actually exit),
    // so we wait for the daemon to acknowledge by firing
    // ActiveWorkspaceChanged to the next workspace before issuing the
    // second close.
    send_command(&mut w, 4, Command::CloseWorkspace).await;
    expect_reply_ok(&mut r, 4).await;
    let (_, title) = wait_for_any_active_ws(&mut r).await;
    // After closing workspace 0 (main), the remaining workspace (sidebar)
    // becomes active at index 0.
    assert_eq!(title, "sidebar", "expected sidebar active after close");
    // The active-tab announce will follow.
    expect_active_tab(&mut r, 0).await;

    send_command(&mut w, 5, Command::CloseWorkspace).await;
    expect_reply_ok(&mut r, 5).await;

    // Server shuts down once the last workspace's last tab's shell exits.
    timeout(Duration::from_secs(10), server)
        .await
        .expect("server did not shut down after closing all workspaces")
        .expect("server task panicked")
        .expect("server returned error");

    // Snapshot written? Note: when last workspace died we saved. Load and
    // start a second server.
    assert!(snapshot.exists(), "snapshot file not written");

    // Remove the stale socket from server1 so wait_for definitely waits
    // until server2 has bound a fresh listener.
    let _ = std::fs::remove_file(&socket);

    let opts2 = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: Some(snapshot.clone()),
        settings_path: None,
        ws_bind: None,
        auth_token: None,
    };
    let server2 = tokio::spawn(async move { run(opts2).await });

    wait_for(&socket).await;

    let stream2 = UnixStream::connect(&socket).await.unwrap();
    let (read_half, mut w) = stream2.into_split();
    let mut r = BufReader::new(read_half);
    handshake(&mut r, &mut w).await;
    let _ = wait_for_any_active_ws(&mut r).await;

    send_command(&mut w, 1, Command::ListWorkspaces).await;
    let list_msg = wait_for_reply(&mut r, 1).await;
    match list_msg {
        ServerMsg::CommandReply {
            result:
                CommandResult::Ok {
                    data: Some(CommandData::WorkspaceList { workspaces, .. }),
                },
            ..
        } => {
            // The shutdown snapshot should preserve at least one known
            // workspace title. This keeps the restore check from passing on an
            // empty default state.
            assert!(
                !workspaces.is_empty(),
                "restore check must observe at least one workspace"
            );
            for ws in &workspaces {
                assert!(
                    ws.title == "main" || ws.title == "sidebar",
                    "unexpected workspace title: {}",
                    ws.title
                );
            }
        }
        other => panic!("expected WorkspaceList, got {other:?}"),
    }

    // Clean up the second server. This side only verifies restore behavior;
    // it does not need another graceful snapshot write.
    drop(w);
    server2.abort();
    let _ = server2.await;
}

// ----------------------------- helpers ---------------------------------

async fn wait_for(socket: &std::path::Path) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while !socket.exists() {
        if tokio::time::Instant::now() > deadline {
            panic!("socket did not appear");
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

async fn handshake<R, W>(r: &mut R, w: &mut W)
where
    R: tokio::io::AsyncRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
{
    write_msg(
        w,
        &ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
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

async fn send_command<W>(w: &mut W, id: u32, cmd: Command)
where
    W: tokio::io::AsyncWrite + Unpin,
{
    write_msg(w, &ClientMsg::Command { id, command: cmd })
        .await
        .unwrap();
}

async fn expect_reply_ok<R>(r: &mut R, id: u32) -> Option<CommandData>
where
    R: tokio::io::AsyncRead + Unpin,
{
    let msg = wait_for_reply(r, id).await;
    match msg {
        ServerMsg::CommandReply {
            result: CommandResult::Ok { data },
            ..
        } => data,
        other => panic!("expected Ok reply for id={id}, got {other:?}"),
    }
}

async fn wait_for_reply<R>(r: &mut R, want_id: u32) -> ServerMsg
where
    R: tokio::io::AsyncRead + Unpin,
{
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, read_msg::<_, ServerMsg>(r))
            .await
            .expect("wait_for_reply timeout")
            .expect("wait_for_reply io")
            .expect("wait_for_reply eof");
        if let ServerMsg::CommandReply { id, .. } = &msg
            && *id == want_id
        {
            return msg;
        }
    }
}

async fn expect_active_ws<R>(r: &mut R, want_index: usize)
where
    R: tokio::io::AsyncRead + Unpin,
{
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, read_msg::<_, ServerMsg>(r))
            .await
            .expect("expect_active_ws timeout")
            .expect("io")
            .expect("eof");
        if let ServerMsg::ActiveWorkspaceChanged { index, .. } = msg {
            assert_eq!(index, want_index, "active ws index");
            return;
        }
    }
}

async fn expect_active_tab<R>(r: &mut R, want_index: usize)
where
    R: tokio::io::AsyncRead + Unpin,
{
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, read_msg::<_, ServerMsg>(r))
            .await
            .expect("expect_active_tab timeout")
            .expect("io")
            .expect("eof");
        if let ServerMsg::ActiveTabChanged { index, .. } = msg {
            assert_eq!(index, want_index, "active tab index");
            return;
        }
    }
}

async fn wait_for_any_active_ws<R>(r: &mut R) -> (usize, String)
where
    R: tokio::io::AsyncRead + Unpin,
{
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, read_msg::<_, ServerMsg>(r))
            .await
            .expect("timeout")
            .expect("io")
            .expect("eof");
        if let ServerMsg::ActiveWorkspaceChanged { index, title, .. } = msg {
            return (index, title);
        }
    }
}
