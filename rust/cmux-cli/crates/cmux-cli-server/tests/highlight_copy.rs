//! Highlight-to-copy: a client sends a Mouse down → drag → up over a
//! region of the pane, and the server yanks the selected text into the
//! paste-buffer stack plus emits OSC 52 for the host's system clipboard.

use std::time::Duration;

use cmux_cli_protocol::{
    ClientMsg, Command, CommandData, CommandResult, MouseKind, PROTOCOL_VERSION, ServerMsg,
    Viewport, read_msg, write_msg,
};
use cmux_cli_server::{ServerOptions, chrome_layout, run};
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::time::timeout;

const SENTINEL: &str = "HLCPY_9E3";
const DOUBLE_CLICK_URL: &str = "https://example.com/a/b?x=1#frag";
const DOUBLE_CLICK_PATH: &str = "~/src/cmux-cli/crates";

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn drag_selection_yanks_into_buffer_and_osc52() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
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

    // Drive a sentinel into the shell. The sentinel lands on its own row
    // inside the pane.
    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: format!("echo {SENTINEL}\n").into_bytes(),
        },
    )
    .await
    .unwrap();

    // Wait until the sentinel shows up in some composited frame so we
    // know the server-side Terminal has the text.
    let mut seen = false;
    let end = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < end && !seen {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        if let Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) =
            timeout(remaining, read_msg::<_, ServerMsg>(&mut r)).await
            && String::from_utf8_lossy(&data).contains(SENTINEL)
        {
            seen = true;
        }
    }
    assert!(seen, "sentinel never reached the grid");

    // Drag over a wide region of the viewport that should cover the
    // sentinel line. Sidebar is 16 cols wide, so anything col >= 16 is
    // inside the pane.
    let pane_row = pane_origin_row((120, 24));
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 16,
            row: pane_row,
            event: MouseKind::Down,
        },
    )
    .await
    .unwrap();
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 115,
            row: 10,
            event: MouseKind::Drag,
        },
    )
    .await
    .unwrap();
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 115,
            row: 10,
            event: MouseKind::Up,
        },
    )
    .await
    .unwrap();

    // After Up, an OSC 52 host-control message is emitted before the
    // selection-clear repaint. Watch for both the OSC 52 and the sentinel
    // in the encoded text.
    let mut saw_osc = false;
    let mut seen_sentinel_in_osc = false;
    let end = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < end && !(saw_osc && seen_sentinel_in_osc) {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        match timeout(remaining, read_msg::<_, ServerMsg>(&mut r)).await {
            Ok(Ok(Some(ServerMsg::HostControl { data }))) => {
                let s = String::from_utf8_lossy(&data);
                if let Some(start) = s.find("\x1b]52;c;") {
                    saw_osc = true;
                    let rest = &s[start..];
                    if let Some(end_marker) = rest.find("\x1b\\") {
                        use base64::Engine;
                        let b64 = &rest["\x1b]52;c;".len()..end_marker];
                        if let Ok(decoded) =
                            base64::engine::general_purpose::STANDARD.decode(b64.as_bytes())
                        {
                            let payload = String::from_utf8_lossy(&decoded);
                            if payload.contains(SENTINEL) {
                                seen_sentinel_in_osc = true;
                            }
                        }
                    }
                }
            }
            Ok(Ok(Some(_))) => {}
            _ => break,
        }
    }
    assert!(saw_osc, "OSC 52 never emitted after MouseUp");
    assert!(
        seen_sentinel_in_osc,
        "OSC 52 payload did not contain the sentinel"
    );

    // Confirm via ListBuffers that the yank made it onto the buffer stack.
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: 99,
            command: Command::ListBuffers,
        },
    )
    .await
    .unwrap();
    let reply = loop {
        let msg = timeout(Duration::from_secs(5), read_msg::<_, ServerMsg>(&mut r))
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        if let ServerMsg::CommandReply { id: 99, .. } = &msg {
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
            assert!(!buffers.is_empty(), "no buffers after yank");
            assert!(
                buffers.iter().any(|b| b.preview.contains(SENTINEL)),
                "sentinel missing from top buffer; buffers={buffers:?}"
            );
        }
        other => panic!("expected BufferList, got {other:?}"),
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
    let _ = timeout(Duration::from_secs(5), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn scroll_during_selection_yanks_logical_rows_not_final_viewport() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 10),
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
            viewport: Viewport { cols: 80, rows: 10 },
            token: None,
        },
    )
    .await
    .unwrap();

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data:
                b"i=1; while [ $i -le 50 ]; do printf 'LOGSEL_%02d\\n' \"$i\"; i=$((i+1)); done\n"
                    .to_vec(),
        },
    )
    .await
    .unwrap();
    wait_for_ansi(&mut r, |s| s.contains("LOGSEL_50")).await;

    let screen = read_screen_text(&mut w, &mut r, 201).await;
    let marker_rows: Vec<(usize, String)> = screen
        .lines()
        .enumerate()
        .filter_map(|(idx, line)| marker_in_line(line).map(|marker| (idx, marker)))
        .collect();
    assert!(
        marker_rows.len() >= 3,
        "expected several visible markers before selection, screen={screen:?}"
    );
    let (pane_row, anchor_marker) = marker_rows[marker_rows.len() / 2].clone();
    let viewport_row = pane_origin_row((80, 10)).saturating_add(pane_row as u16);

    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 40,
            row: viewport_row,
            event: MouseKind::Down,
        },
    )
    .await
    .unwrap();
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 17,
            row: viewport_row,
            event: MouseKind::Drag,
        },
    )
    .await
    .unwrap();
    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 17,
            row: viewport_row,
            event: MouseKind::Wheel { lines: -3 },
        },
    )
    .await
    .unwrap();

    let scrolled_screen = read_screen_text(&mut w, &mut r, 202).await;
    let endpoint_marker = scrolled_screen
        .lines()
        .nth(pane_row)
        .and_then(marker_in_line)
        .unwrap_or_else(|| {
            panic!(
                "expected marker at selected row after wheel scroll, row={pane_row}, screen={scrolled_screen:?}"
            )
        });
    assert_ne!(
        anchor_marker, endpoint_marker,
        "wheel scroll should move a different logical row under the mouse"
    );

    write_msg(
        &mut w,
        &ClientMsg::Mouse {
            col: 17,
            row: viewport_row,
            event: MouseKind::Up,
        },
    )
    .await
    .unwrap();

    let payload = wait_for_osc52_payload(&mut r).await;
    assert!(
        payload.contains(&anchor_marker),
        "yanked text lost original anchor marker {anchor_marker}; payload={payload:?}"
    );
    assert!(
        payload.contains(&endpoint_marker),
        "yanked text lost scrolled endpoint marker {endpoint_marker}; payload={payload:?}"
    );

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"exit\n".to_vec(),
        },
    )
    .await
    .unwrap();
    let _ = timeout(Duration::from_secs(5), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn double_click_yanks_url_like_word() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
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

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: format!("printf 'DCSEL {DOUBLE_CLICK_URL} PATH {DOUBLE_CLICK_PATH}\\n'\n")
                .into_bytes(),
        },
    )
    .await
    .unwrap();
    wait_for_ansi(&mut r, |s| s.contains(DOUBLE_CLICK_URL)).await;

    let screen = read_screen_text(&mut w, &mut r, 301).await;
    let (screen_row, line) = screen
        .lines()
        .enumerate()
        .find(|(_, line)| line.trim_start().starts_with("DCSEL "))
        .unwrap_or_else(|| panic!("could not find DCSEL output row; screen={screen:?}"));
    let url_col = line
        .find(DOUBLE_CLICK_URL)
        .unwrap_or_else(|| panic!("could not find URL in line {line:?}"));
    let (pane_col, pane_row) = pane_origin((120, 24));
    let click_col = pane_col
        .saturating_add(url_col as u16)
        .saturating_add("https://".len() as u16);
    let click_row = pane_row.saturating_add(screen_row as u16);

    for event in [
        MouseKind::Down,
        MouseKind::Up,
        MouseKind::Down,
        MouseKind::Up,
    ] {
        write_msg(
            &mut w,
            &ClientMsg::Mouse {
                col: click_col,
                row: click_row,
                event,
            },
        )
        .await
        .unwrap();
    }

    let payload = wait_for_osc52_payload(&mut r).await;
    assert_eq!(
        payload, DOUBLE_CLICK_URL,
        "double-click should yank exactly the URL-like chunk"
    );

    let path_col = line
        .find(DOUBLE_CLICK_PATH)
        .unwrap_or_else(|| panic!("could not find path in line {line:?}"));
    let click_col = pane_col
        .saturating_add(path_col as u16)
        .saturating_add("~/src/".len() as u16);
    for event in [
        MouseKind::Down,
        MouseKind::Up,
        MouseKind::Down,
        MouseKind::Up,
    ] {
        write_msg(
            &mut w,
            &ClientMsg::Mouse {
                col: click_col,
                row: click_row,
                event,
            },
        )
        .await
        .unwrap();
    }

    let payload = wait_for_osc52_payload(&mut r).await;
    assert_eq!(
        payload, DOUBLE_CLICK_PATH,
        "double-click should yank exactly the path-like chunk"
    );

    write_msg(
        &mut w,
        &ClientMsg::Input {
            data: b"exit\n".to_vec(),
        },
    )
    .await
    .unwrap();
    let _ = timeout(Duration::from_secs(5), server).await;
}

async fn wait_for_ansi(
    r: &mut (impl tokio::io::AsyncRead + Unpin),
    predicate: impl Fn(&str) -> bool,
) {
    let end = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < end {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        if let Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) =
            timeout(remaining, read_msg::<_, ServerMsg>(r)).await
        {
            let s = String::from_utf8_lossy(&data);
            if predicate(&s) {
                return;
            }
        }
    }
    panic!("timed out waiting for matching rendered frame");
}

fn pane_origin_row(viewport: (u16, u16)) -> u16 {
    pane_origin(viewport).1
}

fn pane_origin(viewport: (u16, u16)) -> (u16, u16) {
    let (_, _, _, pane, _, _) = chrome_layout(viewport);
    (pane.col, pane.row)
}

async fn read_screen_text(
    w: &mut (impl tokio::io::AsyncWrite + Unpin),
    r: &mut (impl tokio::io::AsyncRead + Unpin),
    id: u32,
) -> String {
    write_msg(
        w,
        &ClientMsg::Command {
            id,
            command: Command::ReadScreen {
                lines: None,
                scrollback: false,
            },
        },
    )
    .await
    .unwrap();

    loop {
        let msg = timeout(Duration::from_secs(5), read_msg::<_, ServerMsg>(r))
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        if let ServerMsg::CommandReply {
            id: reply_id,
            result:
                CommandResult::Ok {
                    data: Some(CommandData::ScreenText { text, .. }),
                },
        } = msg
            && reply_id == id
        {
            return text;
        }
    }
}

async fn wait_for_osc52_payload(r: &mut (impl tokio::io::AsyncRead + Unpin)) -> String {
    let end = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < end {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        if let Ok(Ok(Some(ServerMsg::HostControl { data }))) =
            timeout(remaining, read_msg::<_, ServerMsg>(r)).await
        {
            let s = String::from_utf8_lossy(&data);
            if let Some(payload) = decode_osc52_payload(&s) {
                return payload;
            }
        }
    }
    panic!("OSC 52 never emitted after MouseUp");
}

fn decode_osc52_payload(s: &str) -> Option<String> {
    let start = s.find("\x1b]52;c;")?;
    let rest = &s[start..];
    let end_marker = rest.find("\x1b\\")?;
    use base64::Engine;
    let b64 = &rest["\x1b]52;c;".len()..end_marker];
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(b64.as_bytes())
        .ok()?;
    Some(String::from_utf8_lossy(&decoded).into_owned())
}

fn marker_in_line(line: &str) -> Option<String> {
    line.split_whitespace()
        .find(|part| part.starts_with("LOGSEL_"))
        .map(ToOwned::to_owned)
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
