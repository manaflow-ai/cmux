//! Verify that `Command::Notify` fires the user-configured shell hook
//! from settings (`notifications.command`) with the expected env vars
//! — `CMX_BELL_WORKSPACE_ID`, `CMX_BELL_TAB_ID`, `CMX_BELL_TAB_TITLE`,
//! `CMX_BELL_COUNT`, `CMX_BELL_MESSAGE`.

use std::time::Duration;

use cmux_cli_protocol::{
    ClientMsg, Command, PROTOCOL_VERSION, ServerMsg, Viewport, read_msg, write_msg,
};
use cmux_cli_server::{ServerOptions, run};
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::time::timeout;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn notify_command_fires_shell_hook_with_env_vars() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let hook_output = dir.path().join("hook.log");
    let settings_path = dir.path().join("settings.json");

    // Write a settings file that dumps all hook env vars into a
    // tempfile on each bell. Shell quoting here is intentional — we
    // need the env vars to expand inside the command passed to
    // `/bin/sh -c`.
    let settings = serde_json::json!({
        "notifications": {
            "command": format!(
                "printf 'WS=%s\\nTAB=%s\\nTITLE=%s\\nCOUNT=%s\\nMSG=%s\\n' \"$CMX_BELL_WORKSPACE_ID\" \"$CMX_BELL_TAB_ID\" \"$CMX_BELL_TAB_TITLE\" \"$CMX_BELL_COUNT\" \"$CMX_BELL_MESSAGE\" >> {}",
                hook_output.display(),
            ),
        }
    });
    std::fs::write(
        &settings_path,
        serde_json::to_string_pretty(&settings).unwrap(),
    )
    .unwrap();

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
    // Drain server messages — otherwise the macOS socket buffer
    // fills and session.send blocks before reaching the Notify branch.
    let drain =
        tokio::spawn(
            async move { while let Ok(Some(_)) = read_msg::<_, ServerMsg>(&mut r).await {} },
        );

    // Fire two notifies so we can check that the count increments
    // and both env blocks land in the output file.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 1,
            command: Command::Notify {
                message: Some("first ping".into()),
                tab: None,
            },
        },
    )
    .await
    .unwrap();
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 2,
            command: Command::Notify {
                message: Some("second ping".into()),
                tab: None,
            },
        },
    )
    .await
    .unwrap();

    let contents = wait_for_file_with_count(&hook_output, 2, Duration::from_secs(5)).await;
    // Each invocation writes a 5-line block. We expect two blocks.
    let ws_lines: Vec<_> = contents.lines().filter(|l| l.starts_with("WS=")).collect();
    let tab_lines: Vec<_> = contents.lines().filter(|l| l.starts_with("TAB=")).collect();
    let count_lines: Vec<_> = contents
        .lines()
        .filter(|l| l.starts_with("COUNT="))
        .collect();
    let msg_lines: Vec<_> = contents.lines().filter(|l| l.starts_with("MSG=")).collect();
    let title_lines: Vec<_> = contents
        .lines()
        .filter(|l| l.starts_with("TITLE="))
        .collect();
    assert_eq!(ws_lines.len(), 2, "expected two hook invocations");
    assert_eq!(tab_lines.len(), 2);
    assert_eq!(title_lines.len(), 2);
    assert_eq!(count_lines.len(), 2);
    assert_eq!(msg_lines.len(), 2);

    // COUNT should be 1 and 2 across the two invocations.
    let counts: Vec<&str> = count_lines.iter().map(|l| &l[6..]).collect();
    assert!(counts.contains(&"1"), "got counts {counts:?}");
    assert!(counts.contains(&"2"), "got counts {counts:?}");

    let msgs: Vec<&str> = msg_lines.iter().map(|l| &l[4..]).collect();
    assert!(msgs.contains(&"first ping"), "got messages {msgs:?}");
    assert!(msgs.contains(&"second ping"), "got messages {msgs:?}");

    let titles: Vec<&str> = title_lines.iter().map(|l| &l[6..]).collect();
    assert_eq!(titles, vec!["sh", "sh"], "got titles {titles:?}");

    drain.abort();
    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

/// `cmx notify` must animate the pane border in the attention colour
/// for multiple pulses and then revert. We assert that the SGR for
/// the flash colour (255, 200, 70) appears, drops to the focused pane
/// ring colour (120, 210, 255), then appears again before the pulse
/// window ends.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn notify_flashes_pane_border() {
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

    // Drain a few initial frames so the next burst we collect starts
    // after handshake-era repaints.
    for _ in 0..6 {
        let _ = timeout(Duration::from_millis(150), read_msg::<_, ServerMsg>(&mut r)).await;
    }

    // Fire notify + immediately scan the following frames for the
    // flash SGR. Truecolor SGR for (255,200,70) foreground is
    // `\x1b[38;2;255;200;70m`.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 42,
            command: Command::Notify {
                message: None,
                tab: None,
            },
        },
    )
    .await
    .unwrap();

    let flash_sgr = "\x1b[38;2;255;200;70m";
    let focus_sgr = "\x1b[38;2;120;210;255m";
    let mut flash_frames = 0usize;
    let mut saw_focus_between_flashes = false;
    let mut saw_second_flash_after_focus = false;
    let mut saw_final_focus = false;
    let end = tokio::time::Instant::now() + Duration::from_secs(3);
    while tokio::time::Instant::now() < end {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        match timeout(remaining, read_msg::<_, ServerMsg>(&mut r)).await {
            Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) => {
                let s = String::from_utf8_lossy(&data);
                if s.contains(flash_sgr) {
                    if saw_focus_between_flashes {
                        saw_second_flash_after_focus = true;
                    }
                    flash_frames += 1;
                }
                if flash_frames >= 1 && s.contains(focus_sgr) && !s.contains(flash_sgr) {
                    if saw_second_flash_after_focus {
                        saw_final_focus = true;
                        break;
                    }
                    saw_focus_between_flashes = true;
                }
            }
            Ok(Ok(Some(_))) => {}
            _ => break,
        }
    }
    assert!(
        flash_frames >= 2,
        "border did not emit multiple flash pulses after Command::Notify",
    );
    assert!(
        saw_focus_between_flashes,
        "border never dropped to focused ring colour between flash pulses",
    );
    assert!(
        saw_second_flash_after_focus,
        "border never flashed again after dropping to focused ring colour",
    );
    assert!(
        saw_final_focus,
        "border never emitted a complete animated pulse sequence",
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn notify_flash_only_draws_on_focused_panel() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (100, 24),
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
                cols: 100,
                rows: 24,
            },
            token: None,
        },
    )
    .await
    .unwrap();
    drain_pending_messages(&mut r).await;

    send_command(&mut w, 1, Command::SplitHorizontal).await;
    let right_tab = expect_reply_and_active_tab(&mut r, 1).await;

    send_command(&mut w, 2, Command::FocusLeft).await;
    let left_tab = expect_reply_and_active_tab(&mut r, 2).await;
    assert_ne!(left_tab, right_tab);

    send_command(
        &mut w,
        3,
        Command::Notify {
            message: None,
            tab: None,
        },
    )
    .await;
    expect_reply(&mut r, 3).await;

    send_command(&mut w, 4, Command::FocusRight).await;
    let focused_right = expect_reply_and_active_tab(&mut r, 4).await;
    assert_eq!(focused_right, right_tab);
    let right_frame = next_ansi_frame(&mut r).await;
    let flash_sgr = "\x1b[38;2;255;200;70m";
    assert!(
        !right_frame.contains(flash_sgr),
        "background panel flash leaked into focused right panel frame"
    );

    send_command(&mut w, 5, Command::FocusLeft).await;
    let focused_left = expect_reply_and_active_tab(&mut r, 5).await;
    assert_eq!(focused_left, left_tab);
    let saw_flash = wait_for_ansi_containing(&mut r, flash_sgr, Duration::from_secs(2)).await;
    assert!(
        saw_flash,
        "focused notified panel did not flash after navigation"
    );

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

async fn send_command<W: tokio::io::AsyncWrite + Unpin>(w: &mut W, id: u32, command: Command) {
    write_msg(w, &ClientMsg::Command { id, command })
        .await
        .unwrap();
}

async fn expect_reply(r: &mut (impl tokio::io::AsyncRead + Unpin), want_id: u32) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, read_msg::<_, ServerMsg>(r))
            .await
            .expect("reply timeout")
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

async fn drain_pending_messages(r: &mut (impl tokio::io::AsyncRead + Unpin)) {
    while let Ok(Ok(Some(_))) =
        timeout(Duration::from_millis(20), read_msg::<_, ServerMsg>(r)).await
    {}
}

async fn expect_reply_and_active_tab(
    r: &mut (impl tokio::io::AsyncRead + Unpin),
    want_id: u32,
) -> u64 {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut saw_reply = false;
    let mut active_tab = None;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, read_msg::<_, ServerMsg>(r))
            .await
            .expect("active tab timeout")
            .unwrap()
            .unwrap();
        match msg {
            ServerMsg::CommandReply { id, result } if id == want_id => {
                assert!(
                    matches!(result, cmux_cli_protocol::CommandResult::Ok { .. }),
                    "command {want_id} failed: {result:?}"
                );
                saw_reply = true;
            }
            ServerMsg::ActiveTabChanged { tab_id, .. } => {
                active_tab = Some(tab_id);
            }
            _ => {}
        }
        if saw_reply && let Some(tab_id) = active_tab {
            return tab_id;
        }
    }
}

async fn next_ansi_frame(r: &mut (impl tokio::io::AsyncRead + Unpin)) -> String {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, read_msg::<_, ServerMsg>(r))
            .await
            .expect("ansi timeout")
            .unwrap()
            .unwrap();
        if let ServerMsg::PtyBytes { data, .. } = msg {
            return String::from_utf8_lossy(&data).into_owned();
        }
    }
}

async fn wait_for_ansi_containing(
    r: &mut (impl tokio::io::AsyncRead + Unpin),
    needle: &str,
    deadline: Duration,
) -> bool {
    let end = tokio::time::Instant::now() + deadline;
    while tokio::time::Instant::now() < end {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        match timeout(remaining, read_msg::<_, ServerMsg>(r)).await {
            Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) => {
                if String::from_utf8_lossy(&data).contains(needle) {
                    return true;
                }
            }
            Ok(Ok(Some(_))) => {}
            _ => return false,
        }
    }
    false
}

async fn wait_for_file_with_count(
    path: &std::path::Path,
    expected_lines_starting_with_ws: usize,
    deadline: Duration,
) -> String {
    let end = tokio::time::Instant::now() + deadline;
    loop {
        if let Ok(s) = std::fs::read_to_string(path) {
            let ws_count = s.lines().filter(|l| l.starts_with("WS=")).count();
            if ws_count >= expected_lines_starting_with_ws {
                return s;
            }
        }
        if tokio::time::Instant::now() > end {
            let got = std::fs::read_to_string(path).unwrap_or_default();
            panic!(
                "{} never reached {} WS= lines; got:\n{}",
                path.display(),
                expected_lines_starting_with_ws,
                got
            );
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
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
