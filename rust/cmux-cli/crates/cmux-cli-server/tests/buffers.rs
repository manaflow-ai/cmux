//! M7: yank, list buffers, OSC 52 mirror, paste buffer.

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
async fn yank_sets_buffer_and_emits_osc52() {
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
            viewport: Viewport { cols: 80, rows: 24 },
            token: None,
        },
    )
    .await
    .unwrap();
    let _ = read_msg::<_, ServerMsg>(&mut r).await.unwrap().unwrap(); // Welcome

    // Yank.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 1,
            command: Command::Yank {
                buffer_name: Some("clip".into()),
                data: "hello clipboard".into(),
            },
        },
    )
    .await
    .unwrap();

    // Expect: reply + OSC 52 host-control side effect.
    let mut saw_reply = false;
    let mut saw_osc = false;
    let end = tokio::time::Instant::now() + Duration::from_secs(3);
    while tokio::time::Instant::now() < end && !(saw_reply && saw_osc) {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        if let Ok(Ok(Some(msg))) = timeout(remaining, read_msg::<_, ServerMsg>(&mut r)).await {
            match msg {
                ServerMsg::CommandReply {
                    id: 1,
                    result: CommandResult::Ok { .. },
                } => saw_reply = true,
                ServerMsg::HostControl { data } => {
                    let s = String::from_utf8_lossy(&data);
                    if s.contains("\x1b]52;c;") {
                        saw_osc = true;
                    }
                }
                _ => {}
            }
        } else {
            break;
        }
    }
    assert!(saw_reply, "missing Yank CommandReply");
    assert!(saw_osc, "missing OSC 52 HostControl after Yank");

    // ListBuffers should show the clip we just made.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 2,
            command: Command::ListBuffers,
        },
    )
    .await
    .unwrap();

    let reply = loop {
        let msg = timeout(Duration::from_secs(3), read_msg::<_, ServerMsg>(&mut r))
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        if let ServerMsg::CommandReply { id: 2, .. } = &msg {
            break msg;
        }
    };
    match reply {
        ServerMsg::CommandReply {
            result:
                CommandResult::Ok {
                    data: Some(CommandData::BufferList { buffers }),
                },
            ..
        } => {
            assert_eq!(buffers.len(), 1);
            assert_eq!(buffers[0].name.as_deref(), Some("clip"));
            assert!(buffers[0].preview.contains("hello"));
        }
        other => panic!("expected BufferList, got {other:?}"),
    }

    // PasteBuffer types the yanked text into the active PTY. We should
    // observe those bytes arriving in the rendered grid (echoed by the shell).
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 3,
            command: Command::PasteBuffer {
                index: None,
                buffer_name: Some("clip".into()),
            },
        },
    )
    .await
    .unwrap();

    let mut paste_buf = String::new();
    let end = tokio::time::Instant::now() + Duration::from_secs(3);
    while tokio::time::Instant::now() < end && !paste_buf.contains("hello clipboard") {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        if let Ok(Ok(Some(msg))) = timeout(remaining, read_msg::<_, ServerMsg>(&mut r)).await
            && let ServerMsg::PtyBytes { data, .. } = msg
        {
            paste_buf.push_str(&String::from_utf8_lossy(&data));
        }
    }
    assert!(
        paste_buf.contains("hello clipboard"),
        "expected pasted text to echo; got accumulated output:\n{paste_buf}"
    );

    // Clean shutdown by closing the only workspace's only tab.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 4,
            command: Command::CloseWorkspace,
        },
    )
    .await
    .unwrap();

    server.abort();
    let _ = server.await;
}
