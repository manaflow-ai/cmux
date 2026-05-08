//! M5: `ClientMsg::Command { NewTab, SelectTab, NextTab, ListTabs, ... }`
//! cycles through a per-panel tab stack. We validate:
//! - NewTab creates a second tab and auto-focuses it; input is routed there.
//! - ListTabs reports the real set.
//! - SelectTab { index: 0 } switches focus back to the first tab.
//! - The first tab's prompt still responds after the switch.

use std::time::Duration;

use cmux_cli_protocol::{
    ClientMsg, Command, CommandData, CommandResult, PROTOCOL_VERSION, ServerMsg, Viewport,
    read_msg, write_msg,
};
use cmux_cli_server::{ServerOptions, run};
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::time::timeout;

const TAB1_SENTINEL: &str = "CMX_TAB1_OK_8C44";
const TAB2_SENTINEL: &str = "CMX_TAB2_OK_8C44";

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tab_stack_switches_output_on_select() {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("server.sock");

    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
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

    let stream = UnixStream::connect(&socket).await.expect("connect");
    let (read_half, mut w) = stream.into_split();
    let mut r = BufReader::new(read_half);

    // Handshake.
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
    let welcome = timeout(Duration::from_secs(5), read_msg::<_, ServerMsg>(&mut r))
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    matches!(welcome, ServerMsg::Welcome { .. })
        .then_some(())
        .expect("welcome");

    // Wait for the initial ActiveTabChanged{index:0} (sent each time the
    // loop subscribes).
    let initial_active =
        read_until::<ServerMsg, _>(&mut r, |m| matches!(m, ServerMsg::ActiveTabChanged { .. }))
            .await;
    match initial_active {
        ServerMsg::ActiveTabChanged { index, .. } => assert_eq!(index, 0),
        _ => unreachable!(),
    }

    // Mark tab 0.
    send_input(&mut w, format!("echo {TAB1_SENTINEL}\n")).await;

    // Create tab 1 via command.
    send_command(&mut w, 1, Command::NewTab).await;
    let reply =
        read_until::<ServerMsg, _>(&mut r, |m| matches!(m, ServerMsg::CommandReply { .. })).await;
    match reply {
        ServerMsg::CommandReply { id, result } => {
            assert_eq!(id, 1);
            assert!(matches!(result, CommandResult::Ok { .. }), "got {result:?}");
        }
        _ => unreachable!(),
    }
    // After NewTab the server announces a new active tab.
    let active2 =
        read_until::<ServerMsg, _>(&mut r, |m| matches!(m, ServerMsg::ActiveTabChanged { .. }))
            .await;
    match active2 {
        ServerMsg::ActiveTabChanged { index, .. } => assert_eq!(index, 1),
        _ => unreachable!(),
    }

    send_input(&mut w, format!("echo {TAB2_SENTINEL}\n")).await;

    // ListTabs and verify.
    send_command(&mut w, 2, Command::ListTabs).await;
    let list = read_until::<ServerMsg, _>(&mut r, |m| {
        matches!(m, ServerMsg::CommandReply { id: 2, .. })
    })
    .await;
    match list {
        ServerMsg::CommandReply {
            result:
                CommandResult::Ok {
                    data: Some(CommandData::TabList { tabs, active }),
                },
            ..
        } => {
            assert_eq!(tabs.len(), 2, "expected 2 tabs, got {tabs:?}");
            assert_eq!(active, 1);
        }
        other => panic!("expected TabList, got {other:?}"),
    }

    // Collect output from tab 1 until the sentinel appears.
    let buf2 = read_pty_until_contains(&mut r, TAB2_SENTINEL).await;
    assert!(
        buf2.contains(TAB2_SENTINEL),
        "expected tab2 sentinel in recent output. got:\n{buf2}"
    );

    // Switch back to tab 0. Its shell is still running; the echo from earlier
    // will have scrolled but a fresh echo should appear immediately.
    send_command(&mut w, 3, Command::SelectTab { index: 0 }).await;
    let reply = read_until::<ServerMsg, _>(&mut r, |m| {
        matches!(m, ServerMsg::CommandReply { id: 3, .. })
    })
    .await;
    matches!(
        reply,
        ServerMsg::CommandReply {
            result: CommandResult::Ok { .. },
            ..
        }
    )
    .then_some(())
    .expect("SelectTab reply");
    let active_back =
        read_until::<ServerMsg, _>(&mut r, |m| matches!(m, ServerMsg::ActiveTabChanged { .. }))
            .await;
    match active_back {
        ServerMsg::ActiveTabChanged { index, .. } => assert_eq!(index, 0),
        _ => unreachable!(),
    }

    send_input(&mut w, "echo TAB1_RETURN_MARKER_4F2\n".to_string()).await;
    let buf1 = read_pty_until_contains(&mut r, "TAB1_RETURN_MARKER_4F2").await;
    assert!(
        buf1.contains("TAB1_RETURN_MARKER_4F2"),
        "expected tab1 echo after switch back; got:\n{buf1}"
    );

    send_command(&mut w, 4, Command::CloseTab).await;
    server.abort();
    let _ = server.await;
}

async fn send_input<W: tokio::io::AsyncWrite + Unpin>(w: &mut W, s: String) {
    write_msg(
        w,
        &ClientMsg::Input {
            data: s.into_bytes(),
        },
    )
    .await
    .unwrap();
}

async fn send_command<W: tokio::io::AsyncWrite + Unpin>(w: &mut W, id: u32, cmd: Command) {
    write_msg(w, &ClientMsg::Command { id, command: cmd })
        .await
        .unwrap();
}

async fn read_pty_until_contains(
    r: &mut (impl tokio::io::AsyncRead + Unpin),
    needle: &str,
) -> String {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut output = String::new();
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, read_msg::<_, ServerMsg>(r))
            .await
            .expect("read_pty_until_contains timeout")
            .expect("read_pty_until_contains io")
            .expect("read_pty_until_contains eof");
        if let ServerMsg::PtyBytes { data, .. } = msg {
            output.push_str(&String::from_utf8_lossy(&data));
            if output.contains(needle) {
                return output;
            }
        }
    }
}

async fn read_until<T, F>(r: &mut (impl tokio::io::AsyncRead + Unpin), pred: F) -> T
where
    T: for<'de> serde::Deserialize<'de> + std::fmt::Debug,
    F: Fn(&T) -> bool,
{
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
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
