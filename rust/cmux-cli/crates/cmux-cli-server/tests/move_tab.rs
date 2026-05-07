//! `Command::MoveTab { from, to }` reorders tabs within the active
//! workspace. Verify the list observed via `ListTabs` reflects the
//! new order and out-of-bounds `to` indices clamp to the end.

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
async fn move_tab_shuffles_the_tab_list() {
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

    // Spawn 3 tabs so we have something to shuffle.
    for id in 1..=2 {
        write_msg(
            &mut w,
            &ClientMsg::Command {
                id,
                command: Command::NewTab,
            },
        )
        .await
        .unwrap();
        let _ = read_reply(&mut r, id).await;
    }
    // ListTabs baseline: tab ids are 0, 1, 2 in that order.
    let first = list_tabs(&mut w, &mut r, 10).await;
    let baseline_ids: Vec<u64> = first.iter().map(|t| t.id).collect();
    assert_eq!(baseline_ids, vec![0, 1, 2]);

    // Move tab 0 → index 2 (end). Expect [1, 2, 0].
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 20,
            command: Command::MoveTab { from: 0, to: 2 },
        },
    )
    .await
    .unwrap();
    let _ = read_reply(&mut r, 20).await;
    let after = list_tabs(&mut w, &mut r, 30).await;
    let ids: Vec<u64> = after.iter().map(|t| t.id).collect();
    assert_eq!(ids, vec![1, 2, 0], "after move(0→2) expected [1, 2, 0]");

    // Out-of-bounds `to` clamps: move tab at 0 → 99 → end again.
    // After [1, 2, 0], move(0, 99) → [2, 0, 1].
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 40,
            command: Command::MoveTab { from: 0, to: 99 },
        },
    )
    .await
    .unwrap();
    let _ = read_reply(&mut r, 40).await;
    let after2 = list_tabs(&mut w, &mut r, 50).await;
    let ids2: Vec<u64> = after2.iter().map(|t| t.id).collect();
    assert_eq!(ids2, vec![2, 0, 1], "after move(0→99) expected [2, 0, 1]");

    // Out-of-bounds `from` errors.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 60,
            command: Command::MoveTab { from: 99, to: 0 },
        },
    )
    .await
    .unwrap();
    match read_reply(&mut r, 60).await {
        CommandResult::Err { message } => assert!(message.contains("no tab")),
        other => panic!("expected Err for out-of-bounds from, got {other:?}"),
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

async fn list_tabs(
    w: &mut (impl tokio::io::AsyncWrite + Unpin),
    r: &mut (impl tokio::io::AsyncRead + Unpin),
    id: u32,
) -> Vec<cmux_cli_protocol::TabInfo> {
    write_msg(
        w,
        &ClientMsg::Command {
            id,
            command: Command::ListTabs,
        },
    )
    .await
    .unwrap();
    match read_reply(r, id).await {
        CommandResult::Ok {
            data: Some(CommandData::TabList { tabs, .. }),
        } => tabs,
        other => panic!("expected TabList, got {other:?}"),
    }
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
