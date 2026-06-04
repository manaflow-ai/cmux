//! Verify the activity indicator: a tab that emits PTY output while
//! not the active tab must report `has_activity = true` via `ListTabs`,
//! and the flag must clear when the tab becomes active.

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
async fn inactive_tab_with_new_output_reports_has_activity() {
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
    let _ = timeout(Duration::from_secs(2), read_msg::<_, ServerMsg>(&mut r))
        .await
        .unwrap();

    // Create a second tab so we have a background candidate. NewTab
    // auto-focuses the new tab; the original (tab 0) becomes inactive.
    send_cmd(&mut w, 1, Command::NewTab).await;
    read_reply(&mut r, 1).await;

    // Arm delayed output in tab 0, then switch away before the shell emits it.
    // That proves the activity flag is set by output that arrives while the tab
    // is inactive, not by stale output generated while it was focused.
    send_cmd(&mut w, 2, Command::SelectTab { index: 0 }).await;
    read_reply(&mut r, 2).await;
    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"(sleep 0.2; echo ACTIVITY_MARKER_4B) &\n".to_vec(),
        },
    )
    .await
    .unwrap();

    // Switch to tab 1 (makes tab 0 inactive). Tab 1's own PTY may
    // also have activity from spawn; we only care about tab 0.
    send_cmd(&mut w, 3, Command::SelectTab { index: 1 }).await;
    read_reply(&mut r, 3).await;

    let mut next_id = 4;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let tabs = loop {
        send_cmd(&mut w, next_id, Command::ListTabs).await;
        let reply = read_reply(&mut r, next_id).await;
        next_id += 1;
        if let CommandResult::Ok {
            data: Some(CommandData::TabList { tabs, active }),
        } = reply
        {
            assert_eq!(active, 1, "tab 1 should be active after SelectTab(1)");
            if tabs.first().is_some_and(|tab| tab.has_activity) {
                break tabs;
            }
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "tab 0 never reported has_activity after inactive output"
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    };
    assert_eq!(tabs.len(), 2, "two tabs expected");
    assert!(
        tabs[0].has_activity,
        "tab 0 should have has_activity=true (recent shell output while inactive)"
    );
    assert!(
        !tabs[1].has_activity,
        "tab 1 is the active tab; has_activity must read as false (masked)"
    );

    // Now switch back to tab 0 and confirm the flag clears.
    send_cmd(&mut w, next_id, Command::SelectTab { index: 0 }).await;
    read_reply(&mut r, next_id).await;
    next_id += 1;
    send_cmd(&mut w, next_id, Command::ListTabs).await;
    let reply = read_reply(&mut r, next_id).await;
    next_id += 1;
    let CommandResult::Ok {
        data: Some(CommandData::TabList { tabs, .. }),
    } = reply
    else {
        panic!("expected TabList");
    };
    assert!(
        !tabs[0].has_activity,
        "tab 0 should have cleared has_activity after becoming active"
    );

    // Shutdown.
    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"exit\n".to_vec(),
        },
    )
    .await
    .unwrap();
    send_cmd(&mut w, next_id, Command::CloseTab).await;
    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

async fn send_cmd<W: tokio::io::AsyncWrite + Unpin>(w: &mut W, id: u32, command: Command) {
    write_msg(w, &ClientMsg::Command { id, command })
        .await
        .unwrap();
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
