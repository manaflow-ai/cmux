//! M9: WebSocket transport.
//!
//! Brings up a cmx server with both Unix socket and WebSocket listeners and
//! verifies:
//! - a valid-token WS client completes the Hello handshake and receives
//!   Welcome + ActiveWorkspaceChanged/ActiveTabChanged as expected,
//! - a missing-token client is rejected with `ServerMsg::Error`.

use std::net::SocketAddr;
use std::time::Duration;

use cmux_cli_protocol::{
    AttachedClientKind, ClientMsg, Command, CommandResult, NativePanelNode, NativeSnapshot,
    NativeTerminalRenderer, PROTOCOL_VERSION, ServerMsg, SplitDropEdge, SplitPathStep, Viewport,
};
use cmux_cli_server::{HeartbeatConfig, ServerOptions, run, run_with_heartbeat};
use futures_util::{SinkExt, StreamExt};
use tokio::time::timeout;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

async fn recv_server_msg(
    ws: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
) -> ServerMsg {
    loop {
        let next = timeout(Duration::from_secs(5), ws.next())
            .await
            .expect("recv timeout")
            .expect("eof");
        match next.expect("ws error") {
            Message::Binary(bytes) => return rmp_serde::from_slice(&bytes).unwrap(),
            Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => continue,
            other => panic!("unexpected ws message: {other:?}"),
        }
    }
}

async fn send_client_msg(
    ws: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    msg: &ClientMsg,
) {
    let bytes = rmp_serde::to_vec_named(msg).unwrap();
    ws.send(Message::Binary(bytes)).await.unwrap();
}

async fn send_command(
    ws: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    id: u32,
    command: Command,
) {
    send_client_msg(ws, &ClientMsg::Command { id, command }).await;
}

async fn recv_command_ok(
    ws: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    want_id: u32,
) {
    loop {
        if let ServerMsg::CommandReply { id, result } = recv_server_msg(ws).await
            && id == want_id
        {
            assert!(matches!(result, CommandResult::Ok { .. }), "got {result:?}");
            return;
        }
    }
}

async fn recv_until_server_msg(
    ws: &mut TestWs,
    duration: Duration,
    mut predicate: impl FnMut(&ServerMsg) -> bool,
) -> Option<ServerMsg> {
    let deadline = tokio::time::Instant::now() + duration;
    loop {
        let now = tokio::time::Instant::now();
        if now >= deadline {
            return None;
        }
        let remaining = deadline - now;
        let next = match timeout(remaining, ws.next()).await {
            Ok(Some(Ok(message))) => message,
            Ok(Some(Err(_))) | Ok(None) | Err(_) => return None,
        };
        match next {
            Message::Binary(bytes) => {
                let message: ServerMsg = rmp_serde::from_slice(&bytes).unwrap();
                if predicate(&message) {
                    return Some(message);
                }
            }
            Message::Close(_) => {
                let bye = ServerMsg::Bye;
                return predicate(&bye).then_some(bye);
            }
            Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => {}
            other => panic!("unexpected ws message: {other:?}"),
        }
    }
}

async fn recv_bye_or_close(ws: &mut TestWs, duration: Duration) -> bool {
    recv_until_server_msg(ws, duration, |message| matches!(message, ServerMsg::Bye))
        .await
        .is_some()
}

async fn recv_pong(ws: &mut TestWs, duration: Duration) -> bool {
    recv_until_server_msg(ws, duration, |message| matches!(message, ServerMsg::Pong))
        .await
        .is_some()
}

async fn recv_pty_output_until_contains(
    ws: &mut TestWs,
    tab_id: u64,
    duration: Duration,
    needle: &str,
) {
    let mut output = Vec::new();
    recv_until_server_msg(ws, duration, |message| {
        let ServerMsg::PtyBytes {
            tab_id: got_tab_id,
            data,
        } = message
        else {
            return false;
        };
        if *got_tab_id != tab_id {
            return false;
        }
        output.extend_from_slice(data);
        String::from_utf8_lossy(&output).contains(needle)
    })
    .await
    .unwrap_or_else(|| {
        panic!(
            "timed out waiting for PTY output containing {needle:?}; saw {:?}",
            String::from_utf8_lossy(&output)
        )
    });
}

async fn recv_native_snapshot(
    ws: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
) -> NativeSnapshot {
    loop {
        if let ServerMsg::NativeSnapshot { snapshot } = recv_server_msg(ws).await {
            return snapshot;
        }
    }
}

async fn recv_native_snapshot_with_client_count(ws: &mut TestWs, count: usize) -> NativeSnapshot {
    loop {
        let snapshot = recv_native_snapshot(ws).await;
        if snapshot.attached_clients.len() == count {
            return snapshot;
        }
    }
}

async fn pick_free_port() -> SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    listener.local_addr().unwrap()
}

type TestWs =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect_ws(ws_addr: SocketAddr) -> TestWs {
    let url = format!("ws://{ws_addr}/attach");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut last_error = String::new();
    while tokio::time::Instant::now() < deadline {
        match timeout(Duration::from_millis(500), connect_async(&url)).await {
            Ok(Ok((ws, _))) => return ws,
            Ok(Err(err)) => last_error = err.to_string(),
            Err(_) => last_error = "connect attempt timed out".to_string(),
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("ws connect failed for {url}: {last_error}");
}

#[derive(Debug)]
struct NativeLeaf {
    panel_id: u64,
    tabs: Vec<u64>,
    active_tab_id: u64,
}

fn collect_native_leaves(node: &NativePanelNode) -> Vec<NativeLeaf> {
    let mut leaves = Vec::new();
    collect_native_leaves_inner(node, &mut leaves);
    leaves
}

fn collect_native_leaves_inner(node: &NativePanelNode, leaves: &mut Vec<NativeLeaf>) {
    match node {
        NativePanelNode::Leaf {
            panel_id,
            tabs,
            active_tab_id,
            ..
        } => leaves.push(NativeLeaf {
            panel_id: *panel_id,
            tabs: tabs.iter().map(|tab| tab.id).collect(),
            active_tab_id: *active_tab_id,
        }),
        NativePanelNode::Split { first, second, .. } => {
            collect_native_leaves_inner(first, leaves);
            collect_native_leaves_inner(second, leaves);
        }
    }
}

async fn recv_native_snapshot_with_leaf_count(
    ws: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    leaf_count: usize,
) -> NativeSnapshot {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < deadline {
        let snapshot = recv_native_snapshot(ws).await;
        if collect_native_leaves(&snapshot.panels).len() == leaf_count {
            return snapshot;
        }
    }
    panic!("timed out waiting for native snapshot with {leaf_count} leaves");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_attach_with_token_works() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let ws_addr = pick_free_port().await;
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: Some(ws_addr),
        auth_token: Some("sekrit".into()),
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });

    // Tiny wait for both listeners to be up.
    tokio::time::sleep(Duration::from_millis(100)).await;

    let mut ws = connect_ws(ws_addr).await;

    send_client_msg(
        &mut ws,
        &ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: Some("sekrit".into()),
        },
    )
    .await;

    match recv_server_msg(&mut ws).await {
        ServerMsg::Welcome { .. } => {}
        other => panic!("expected Welcome, got {other:?}"),
    }

    // Drain initial workspace/tab announcements, then request a ListBuffers
    // command (empty list, fast reply) to confirm the command pipe works.
    let _ = recv_server_msg(&mut ws).await; // ActiveWorkspaceChanged
    let _ = recv_server_msg(&mut ws).await; // ActiveTabChanged

    send_client_msg(
        &mut ws,
        &ClientMsg::Command {
            id: 42,
            command: Command::ListBuffers,
        },
    )
    .await;

    loop {
        match recv_server_msg(&mut ws).await {
            ServerMsg::CommandReply { id: 42, result } => {
                assert!(matches!(result, CommandResult::Ok { .. }), "got {result:?}");
                break;
            }
            _ => continue,
        }
    }

    drop(ws);
    // Clean up: close the only workspace by sending Detach, then killing server.
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_native_mode_streams_structured_state_and_terminal_grid() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let ws_addr = pick_free_port().await;
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: Some(ws_addr),
        auth_token: Some("sekrit".into()),
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });

    tokio::time::sleep(Duration::from_millis(100)).await;

    let mut ws = connect_ws(ws_addr).await;

    send_client_msg(
        &mut ws,
        &ClientMsg::HelloNative {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: Some("sekrit".into()),
            terminal_renderer: NativeTerminalRenderer::ServerGrid,
        },
    )
    .await;

    match recv_server_msg(&mut ws).await {
        ServerMsg::Welcome { .. } => {}
        other => panic!("expected Welcome, got {other:?}"),
    }

    let tab_id = match recv_server_msg(&mut ws).await {
        ServerMsg::NativeSnapshot { snapshot } => {
            assert_eq!(snapshot.workspaces.len(), 1);
            assert_eq!(snapshot.spaces.len(), 1);
            snapshot.focused_tab_id
        }
        other => panic!("expected NativeSnapshot, got {other:?}"),
    };

    assert!(
        timeout(Duration::from_millis(150), recv_server_msg(&mut ws))
            .await
            .is_err(),
        "native clients should not receive stale terminal grids before reporting layout"
    );

    send_client_msg(
        &mut ws,
        &ClientMsg::NativeLayout {
            terminals: vec![cmux_cli_protocol::NativeTerminalViewport {
                tab_id,
                cols: 132,
                rows: 44,
            }],
        },
    )
    .await;

    loop {
        match recv_server_msg(&mut ws).await {
            ServerMsg::TerminalGridSnapshot { snapshot } => {
                assert_eq!(snapshot.tab_id, tab_id);
                assert_eq!(snapshot.cols, 132);
                assert_eq!(snapshot.rows, 44);
                assert!(
                    !snapshot.cells.is_empty(),
                    "native terminal grid snapshot should seed graphical clients after layout"
                );
                break;
            }
            _ => continue,
        }
    }

    send_client_msg(
        &mut ws,
        &ClientMsg::NativeLayout {
            terminals: vec![cmux_cli_protocol::NativeTerminalViewport {
                tab_id,
                cols: 200,
                rows: 60,
            }],
        },
    )
    .await;

    loop {
        match recv_server_msg(&mut ws).await {
            ServerMsg::TerminalGridSnapshot { snapshot } => {
                if snapshot.tab_id != tab_id {
                    continue;
                }
                if snapshot.cols == 200 && snapshot.rows == 60 {
                    break;
                }
            }
            _ => continue,
        }
    }

    send_client_msg(
        &mut ws,
        &ClientMsg::NativeInput {
            tab_id,
            data: b"printf native-ok\\n\n".to_vec(),
        },
    )
    .await;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut seen = String::new();
    while tokio::time::Instant::now() < deadline {
        match recv_server_msg(&mut ws).await {
            ServerMsg::TerminalGridSnapshot { snapshot } => {
                assert_eq!(snapshot.tab_id, tab_id);
                seen = snapshot
                    .cells
                    .iter()
                    .map(|cell| cell.text.as_str())
                    .collect::<String>();
                if seen.contains("native-ok") {
                    server.abort();
                    return;
                }
            }
            _ => continue,
        }
    }
    panic!("timed out waiting for native terminal grid output, saw {seen:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_native_libghostty_mode_streams_pty_bytes_instead_of_terminal_grid() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let ws_addr = pick_free_port().await;
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: Some(ws_addr),
        auth_token: Some("sekrit".into()),
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });

    tokio::time::sleep(Duration::from_millis(100)).await;

    let mut ws = connect_ws(ws_addr).await;
    send_client_msg(
        &mut ws,
        &ClientMsg::HelloNative {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: Some("sekrit".into()),
            terminal_renderer: NativeTerminalRenderer::Libghostty,
        },
    )
    .await;

    match recv_server_msg(&mut ws).await {
        ServerMsg::Welcome { .. } => {}
        other => panic!("expected Welcome, got {other:?}"),
    }
    let tab_id = recv_native_snapshot(&mut ws).await.focused_tab_id;
    send_client_msg(
        &mut ws,
        &ClientMsg::NativeLayout {
            terminals: vec![cmux_cli_protocol::NativeTerminalViewport {
                tab_id,
                cols: 80,
                rows: 24,
            }],
        },
    )
    .await;
    send_client_msg(
        &mut ws,
        &ClientMsg::NativeInput {
            tab_id,
            data: b"printf __cmux_ios_libghostty__\\n\r".to_vec(),
        },
    )
    .await;

    let needle = b"__cmux_ios_libghostty__";
    let seen = recv_until_server_msg(&mut ws, Duration::from_secs(3), |message| match message {
        ServerMsg::TerminalGridSnapshot { .. } => true,
        ServerMsg::PtyBytes { data, .. } => {
            data.windows(needle.len()).any(|window| window == needle)
        }
        _ => false,
    })
    .await
    .expect("expected libghostty native mode to stream PTY bytes");
    match seen {
        ServerMsg::PtyBytes {
            tab_id: got_tab_id,
            data,
        } => {
            assert_eq!(got_tab_id, tab_id);
            assert!(data.windows(needle.len()).any(|window| window == needle));
        }
        other => {
            panic!("libghostty native mode must not send server-grid snapshots, got {other:?}")
        }
    }

    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_native_libghostty_mode_broadcasts_pty_bytes_to_multiple_clients() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let ws_addr = pick_free_port().await;
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: Some(ws_addr),
        auth_token: Some("sekrit".into()),
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });

    tokio::time::sleep(Duration::from_millis(100)).await;

    let mut first = connect_ws(ws_addr).await;
    send_client_msg(
        &mut first,
        &ClientMsg::HelloNative {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: Some("sekrit".into()),
            terminal_renderer: NativeTerminalRenderer::Libghostty,
        },
    )
    .await;
    match recv_server_msg(&mut first).await {
        ServerMsg::Welcome { .. } => {}
        other => panic!("expected Welcome, got {other:?}"),
    }
    let first_tab_id = recv_native_snapshot(&mut first).await.focused_tab_id;
    send_client_msg(
        &mut first,
        &ClientMsg::NativeLayout {
            terminals: vec![cmux_cli_protocol::NativeTerminalViewport {
                tab_id: first_tab_id,
                cols: 80,
                rows: 24,
            }],
        },
    )
    .await;

    let mut second = connect_ws(ws_addr).await;
    send_client_msg(
        &mut second,
        &ClientMsg::HelloNative {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: Some("sekrit".into()),
            terminal_renderer: NativeTerminalRenderer::Libghostty,
        },
    )
    .await;
    match recv_server_msg(&mut second).await {
        ServerMsg::Welcome { .. } => {}
        other => panic!("expected Welcome, got {other:?}"),
    }
    let second_tab_id = recv_native_snapshot(&mut second).await.focused_tab_id;
    assert_eq!(second_tab_id, first_tab_id);
    send_client_msg(
        &mut second,
        &ClientMsg::NativeLayout {
            terminals: vec![cmux_cli_protocol::NativeTerminalViewport {
                tab_id: second_tab_id,
                cols: 80,
                rows: 24,
            }],
        },
    )
    .await;

    send_client_msg(
        &mut first,
        &ClientMsg::NativeInput {
            tab_id: first_tab_id,
            data: b"printf __cmux_ios_broadcast__\\n\r".to_vec(),
        },
    )
    .await;

    let needle = b"__cmux_ios_broadcast__";
    for ws in [&mut first, &mut second] {
        let seen = recv_until_server_msg(ws, Duration::from_secs(3), |message| match message {
            ServerMsg::PtyBytes { data, .. } => {
                data.windows(needle.len()).any(|window| window == needle)
            }
            _ => false,
        })
        .await
        .expect("expected every libghostty native client to receive PTY bytes");
        match seen {
            ServerMsg::PtyBytes { tab_id, data } => {
                assert_eq!(tab_id, first_tab_id);
                assert!(data.windows(needle.len()).any(|window| window == needle));
            }
            other => panic!("expected PTY bytes, got {other:?}"),
        }
    }

    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_native_layout_resizes_pty_to_visible_client_size() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let ws_addr = pick_free_port().await;
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: Some(ws_addr),
        auth_token: Some("sekrit".into()),
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });

    tokio::time::sleep(Duration::from_millis(100)).await;

    let mut ws = connect_ws(ws_addr).await;
    send_client_msg(
        &mut ws,
        &ClientMsg::HelloNative {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: Some("sekrit".into()),
            terminal_renderer: NativeTerminalRenderer::Libghostty,
        },
    )
    .await;

    match recv_server_msg(&mut ws).await {
        ServerMsg::Welcome { .. } => {}
        other => panic!("expected Welcome, got {other:?}"),
    }
    let tab_id = recv_native_snapshot(&mut ws).await.focused_tab_id;
    send_client_msg(
        &mut ws,
        &ClientMsg::NativeLayout {
            terminals: vec![cmux_cli_protocol::NativeTerminalViewport {
                tab_id,
                cols: 111,
                rows: 33,
            }],
        },
    )
    .await;
    send_client_msg(
        &mut ws,
        &ClientMsg::NativeInput {
            tab_id,
            data: b"stty size\n".to_vec(),
        },
    )
    .await;

    let needle = b"33 111";
    let seen = recv_until_server_msg(&mut ws, Duration::from_secs(3), |message| match message {
        ServerMsg::PtyBytes { data, .. } => {
            data.windows(needle.len()).any(|window| window == needle)
        }
        _ => false,
    })
    .await
    .expect("expected native layout to resize the PTY");
    match seen {
        ServerMsg::PtyBytes {
            tab_id: got_tab_id,
            data,
        } => {
            assert_eq!(got_tab_id, tab_id);
            assert!(data.windows(needle.len()).any(|window| window == needle));
        }
        other => panic!("expected PTY bytes, got {other:?}"),
    }

    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_native_smallest_visible_client_size_wins_until_detach() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let ws_addr = pick_free_port().await;
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: Some(ws_addr),
        auth_token: Some("sekrit".into()),
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });

    tokio::time::sleep(Duration::from_millis(100)).await;

    let mut wide = connect_ws(ws_addr).await;
    send_client_msg(
        &mut wide,
        &ClientMsg::HelloNative {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: Some("sekrit".into()),
            terminal_renderer: NativeTerminalRenderer::Libghostty,
        },
    )
    .await;
    assert!(matches!(
        recv_server_msg(&mut wide).await,
        ServerMsg::Welcome { .. }
    ));
    let tab_id = recv_native_snapshot(&mut wide).await.focused_tab_id;
    send_client_msg(
        &mut wide,
        &ClientMsg::NativeLayout {
            terminals: vec![cmux_cli_protocol::NativeTerminalViewport {
                tab_id,
                cols: 180,
                rows: 60,
            }],
        },
    )
    .await;

    let mut narrow = connect_ws(ws_addr).await;
    send_client_msg(
        &mut narrow,
        &ClientMsg::HelloNative {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: Some("sekrit".into()),
            terminal_renderer: NativeTerminalRenderer::Libghostty,
        },
    )
    .await;
    assert!(matches!(
        recv_server_msg(&mut narrow).await,
        ServerMsg::Welcome { .. }
    ));
    assert_eq!(
        recv_native_snapshot(&mut narrow).await.focused_tab_id,
        tab_id
    );
    send_client_msg(
        &mut narrow,
        &ClientMsg::NativeLayout {
            terminals: vec![cmux_cli_protocol::NativeTerminalViewport {
                tab_id,
                cols: 90,
                rows: 20,
            }],
        },
    )
    .await;

    send_client_msg(
        &mut wide,
        &ClientMsg::NativeInput {
            tab_id,
            data: b"printf __cmux_before_detach__:; stty size\n".to_vec(),
        },
    )
    .await;
    recv_pty_output_until_contains(
        &mut wide,
        tab_id,
        Duration::from_secs(5),
        "__cmux_before_detach__:20 90",
    )
    .await;

    send_client_msg(&mut narrow, &ClientMsg::Detach).await;

    send_client_msg(
        &mut wide,
        &ClientMsg::NativeInput {
            tab_id,
            data: b"printf __cmux_after_detach__:; stty size\n".to_vec(),
        },
    )
    .await;
    recv_pty_output_until_contains(
        &mut wide,
        tab_id,
        Duration::from_secs(5),
        "__cmux_after_detach__:60 180",
    )
    .await;

    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_native_snapshot_reports_attached_client_layouts() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let ws_addr = pick_free_port().await;
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: Some(ws_addr),
        auth_token: Some("sekrit".into()),
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });

    tokio::time::sleep(Duration::from_millis(100)).await;

    let mut wide = connect_ws(ws_addr).await;
    send_client_msg(
        &mut wide,
        &ClientMsg::HelloNative {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: Some("sekrit".into()),
            terminal_renderer: NativeTerminalRenderer::ServerGrid,
        },
    )
    .await;
    let wide_id = match recv_server_msg(&mut wide).await {
        ServerMsg::Welcome { session_id, .. } => session_id,
        other => panic!("expected Welcome, got {other:?}"),
    };
    let tab_id = recv_native_snapshot(&mut wide).await.focused_tab_id;
    send_client_msg(
        &mut wide,
        &ClientMsg::NativeLayout {
            terminals: vec![cmux_cli_protocol::NativeTerminalViewport {
                tab_id,
                cols: 180,
                rows: 60,
            }],
        },
    )
    .await;
    let wide_snapshot = recv_native_snapshot_with_client_count(&mut wide, 1).await;
    let wide_client = wide_snapshot
        .attached_clients
        .iter()
        .find(|client| client.client_id == wide_id)
        .expect("wide client should be reported");
    assert_eq!(wide_client.kind, AttachedClientKind::Native);
    assert_eq!(wide_client.visible_terminal_count, 1);
    assert_eq!(wide_client.terminals[0].cols, 180);
    assert_eq!(wide_client.terminals[0].rows, 60);

    let mut narrow = connect_ws(ws_addr).await;
    send_client_msg(
        &mut narrow,
        &ClientMsg::HelloNative {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: Some("sekrit".into()),
            terminal_renderer: NativeTerminalRenderer::ServerGrid,
        },
    )
    .await;
    let narrow_id = match recv_server_msg(&mut narrow).await {
        ServerMsg::Welcome { session_id, .. } => session_id,
        other => panic!("expected Welcome, got {other:?}"),
    };
    let _ = recv_native_snapshot(&mut narrow).await;
    send_client_msg(
        &mut narrow,
        &ClientMsg::NativeLayout {
            terminals: vec![cmux_cli_protocol::NativeTerminalViewport {
                tab_id,
                cols: 120,
                rows: 40,
            }],
        },
    )
    .await;
    let narrow_snapshot = recv_native_snapshot_with_client_count(&mut narrow, 2).await;
    let narrow_client = narrow_snapshot
        .attached_clients
        .iter()
        .find(|client| client.client_id == narrow_id)
        .expect("narrow client should be reported");
    assert_eq!(narrow_client.terminals[0].cols, 120);
    assert_eq!(narrow_client.terminals[0].rows, 40);

    drop(wide);
    drop(narrow);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_native_visible_client_times_out_without_heartbeat() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let ws_addr = pick_free_port().await;
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: Some(ws_addr),
        auth_token: Some("sekrit".into()),
    };
    let heartbeat = HeartbeatConfig {
        enabled: true,
        check_interval: Duration::from_millis(20),
        visible_timeout: Duration::from_millis(120),
        hidden_timeout: Duration::from_millis(500),
    };
    let server = tokio::spawn(async move {
        let _ = run_with_heartbeat(opts, heartbeat).await;
    });

    tokio::time::sleep(Duration::from_millis(100)).await;

    let mut ws = connect_ws(ws_addr).await;
    send_client_msg(
        &mut ws,
        &ClientMsg::HelloNative {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: Some("sekrit".into()),
            terminal_renderer: NativeTerminalRenderer::ServerGrid,
        },
    )
    .await;
    assert!(matches!(
        recv_server_msg(&mut ws).await,
        ServerMsg::Welcome { .. }
    ));
    let tab_id = recv_native_snapshot(&mut ws).await.focused_tab_id;
    send_client_msg(
        &mut ws,
        &ClientMsg::NativeLayout {
            terminals: vec![cmux_cli_protocol::NativeTerminalViewport {
                tab_id,
                cols: 120,
                rows: 40,
            }],
        },
    )
    .await;

    assert!(
        recv_bye_or_close(&mut ws, Duration::from_secs(2)).await,
        "visible websocket clients that stop sending heartbeat traffic should be removed"
    );

    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_native_ping_keeps_quiet_client_alive() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let ws_addr = pick_free_port().await;
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: Some(ws_addr),
        auth_token: Some("sekrit".into()),
    };
    let heartbeat = HeartbeatConfig {
        enabled: true,
        check_interval: Duration::from_millis(20),
        visible_timeout: Duration::from_millis(140),
        hidden_timeout: Duration::from_millis(500),
    };
    let server = tokio::spawn(async move {
        let _ = run_with_heartbeat(opts, heartbeat).await;
    });

    tokio::time::sleep(Duration::from_millis(100)).await;

    let mut ws = connect_ws(ws_addr).await;
    send_client_msg(
        &mut ws,
        &ClientMsg::HelloNative {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: Some("sekrit".into()),
            terminal_renderer: NativeTerminalRenderer::ServerGrid,
        },
    )
    .await;
    assert!(matches!(
        recv_server_msg(&mut ws).await,
        ServerMsg::Welcome { .. }
    ));
    let tab_id = recv_native_snapshot(&mut ws).await.focused_tab_id;
    send_client_msg(
        &mut ws,
        &ClientMsg::NativeLayout {
            terminals: vec![cmux_cli_protocol::NativeTerminalViewport {
                tab_id,
                cols: 120,
                rows: 40,
            }],
        },
    )
    .await;

    let deadline = tokio::time::Instant::now() + Duration::from_millis(360);
    while tokio::time::Instant::now() < deadline {
        send_client_msg(&mut ws, &ClientMsg::Ping).await;
        assert!(
            recv_pong(&mut ws, Duration::from_millis(250)).await,
            "server should answer heartbeat pings"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    assert!(
        !recv_bye_or_close(&mut ws, Duration::from_millis(80)).await,
        "client should remain connected while ping traffic stays under the stale timeout"
    );

    drop(ws);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_native_can_move_tabs_between_panels() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let ws_addr = pick_free_port().await;
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: Some(ws_addr),
        auth_token: Some("sekrit".into()),
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });

    tokio::time::sleep(Duration::from_millis(100)).await;

    let mut ws = connect_ws(ws_addr).await;

    send_client_msg(
        &mut ws,
        &ClientMsg::HelloNative {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: Some("sekrit".into()),
            terminal_renderer: NativeTerminalRenderer::ServerGrid,
        },
    )
    .await;

    match recv_server_msg(&mut ws).await {
        ServerMsg::Welcome { .. } => {}
        other => panic!("expected Welcome, got {other:?}"),
    }
    let _ = recv_native_snapshot(&mut ws).await;

    send_command(&mut ws, 10, Command::NewTab).await;
    recv_command_ok(&mut ws, 10).await;
    send_command(&mut ws, 20, Command::SplitHorizontal).await;
    recv_command_ok(&mut ws, 20).await;

    let snapshot = loop {
        let snapshot = recv_native_snapshot(&mut ws).await;
        let leaves = collect_native_leaves(&snapshot.panels);
        if leaves.len() == 2 && leaves.iter().any(|leaf| leaf.tabs.len() == 2) {
            break snapshot;
        }
    };
    let leaves = collect_native_leaves(&snapshot.panels);
    let source = leaves
        .iter()
        .find(|leaf| leaf.tabs.len() == 2)
        .expect("source panel with two tabs");
    let target = leaves
        .iter()
        .find(|leaf| leaf.panel_id != source.panel_id)
        .expect("target panel");
    let moved_tab_id = source.tabs[0];

    send_command(
        &mut ws,
        30,
        Command::MoveTabToPanel {
            from_panel_id: source.panel_id,
            from: 0,
            to_panel_id: target.panel_id,
            to: 0,
        },
    )
    .await;
    recv_command_ok(&mut ws, 30).await;

    let after = loop {
        let snapshot = recv_native_snapshot(&mut ws).await;
        let leaves = collect_native_leaves(&snapshot.panels);
        let Some(target_leaf) = leaves.iter().find(|leaf| leaf.panel_id == target.panel_id) else {
            continue;
        };
        if target_leaf.tabs.first() == Some(&moved_tab_id) {
            break leaves;
        }
    };
    let source_after = after
        .iter()
        .find(|leaf| leaf.panel_id == source.panel_id)
        .expect("source panel still has its remaining tab");
    let target_after = after
        .iter()
        .find(|leaf| leaf.panel_id == target.panel_id)
        .expect("target panel");
    assert!(!source_after.tabs.contains(&moved_tab_id));
    assert_eq!(target_after.tabs.first(), Some(&moved_tab_id));
    assert_eq!(target_after.active_tab_id, moved_tab_id);

    drop(ws);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_native_split_exits_zoom_so_new_pane_is_visible() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let ws_addr = pick_free_port().await;
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: Some(ws_addr),
        auth_token: Some("sekrit".into()),
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });

    tokio::time::sleep(Duration::from_millis(100)).await;

    let mut ws = connect_ws(ws_addr).await;

    send_client_msg(
        &mut ws,
        &ClientMsg::HelloNative {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: Some("sekrit".into()),
            terminal_renderer: NativeTerminalRenderer::ServerGrid,
        },
    )
    .await;

    match recv_server_msg(&mut ws).await {
        ServerMsg::Welcome { .. } => {}
        other => panic!("expected Welcome, got {other:?}"),
    }
    let _ = recv_native_snapshot(&mut ws).await;

    send_command(&mut ws, 10, Command::SplitHorizontal).await;
    recv_command_ok(&mut ws, 10).await;
    let _ = recv_native_snapshot_with_leaf_count(&mut ws, 2).await;

    send_command(&mut ws, 20, Command::ToggleZoom).await;
    recv_command_ok(&mut ws, 20).await;
    let _ = recv_native_snapshot_with_leaf_count(&mut ws, 1).await;

    send_command(&mut ws, 30, Command::SplitVertical).await;
    recv_command_ok(&mut ws, 30).await;
    let snapshot = recv_native_snapshot_with_leaf_count(&mut ws, 3).await;
    assert!(
        matches!(snapshot.panels, NativePanelNode::Split { .. }),
        "split while zoomed must unzoom the visible native panel tree"
    );

    drop(ws);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_native_can_move_tab_into_new_split() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let ws_addr = pick_free_port().await;
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: Some(ws_addr),
        auth_token: Some("sekrit".into()),
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });

    tokio::time::sleep(Duration::from_millis(100)).await;

    let mut ws = connect_ws(ws_addr).await;

    send_client_msg(
        &mut ws,
        &ClientMsg::HelloNative {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: Some("sekrit".into()),
            terminal_renderer: NativeTerminalRenderer::ServerGrid,
        },
    )
    .await;

    match recv_server_msg(&mut ws).await {
        ServerMsg::Welcome { .. } => {}
        other => panic!("expected Welcome, got {other:?}"),
    }
    let snapshot = recv_native_snapshot(&mut ws).await;
    let source_panel_id = snapshot.focused_panel_id;

    send_command(&mut ws, 10, Command::NewTab).await;
    recv_command_ok(&mut ws, 10).await;
    let snapshot = loop {
        let snapshot = recv_native_snapshot(&mut ws).await;
        let leaves = collect_native_leaves(&snapshot.panels);
        if leaves.len() == 1 && leaves[0].tabs.len() == 2 {
            break snapshot;
        }
    };
    let moved_tab_id = collect_native_leaves(&snapshot.panels)[0].tabs[0];

    send_command(
        &mut ws,
        20,
        Command::MoveTabToSplit {
            from_panel_id: source_panel_id,
            from: 0,
            target_panel_id: source_panel_id,
            edge: SplitDropEdge::Right,
        },
    )
    .await;
    recv_command_ok(&mut ws, 20).await;

    let snapshot = recv_native_snapshot_with_leaf_count(&mut ws, 2).await;
    let leaves = collect_native_leaves(&snapshot.panels);
    assert!(
        leaves.iter().any(|leaf| leaf.tabs == vec![moved_tab_id]),
        "moved tab should become the only tab in a new split leaf"
    );
    assert_eq!(snapshot.focused_tab_id, moved_tab_id);

    drop(ws);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_native_can_split_single_tab_by_replacing_source_panel() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let ws_addr = pick_free_port().await;
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: Some(ws_addr),
        auth_token: Some("sekrit".into()),
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });

    tokio::time::sleep(Duration::from_millis(100)).await;

    let mut ws = connect_ws(ws_addr).await;

    send_client_msg(
        &mut ws,
        &ClientMsg::HelloNative {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: Some("sekrit".into()),
            terminal_renderer: NativeTerminalRenderer::ServerGrid,
        },
    )
    .await;

    match recv_server_msg(&mut ws).await {
        ServerMsg::Welcome { .. } => {}
        other => panic!("expected Welcome, got {other:?}"),
    }
    let snapshot = recv_native_snapshot(&mut ws).await;
    let source_panel_id = snapshot.focused_panel_id;
    let source_tab_id = snapshot.focused_tab_id;

    send_command(
        &mut ws,
        10,
        Command::MoveTabToSplit {
            from_panel_id: source_panel_id,
            from: 0,
            target_panel_id: source_panel_id,
            edge: SplitDropEdge::Right,
        },
    )
    .await;
    recv_command_ok(&mut ws, 10).await;

    let snapshot = recv_native_snapshot_with_leaf_count(&mut ws, 2).await;
    let leaves = collect_native_leaves(&snapshot.panels);
    assert!(
        leaves.iter().any(|leaf| leaf.tabs == vec![source_tab_id]),
        "dragged tab should move into its own split leaf"
    );
    assert!(
        leaves
            .iter()
            .any(|leaf| leaf.panel_id == source_panel_id && leaf.tabs != vec![source_tab_id]),
        "source panel should keep a replacement terminal"
    );
    assert_eq!(snapshot.focused_tab_id, source_tab_id);

    drop(ws);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_native_can_resize_split_by_path() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let ws_addr = pick_free_port().await;
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (120, 32),
        snapshot_path: None,
        settings_path: None,
        ws_bind: Some(ws_addr),
        auth_token: Some("sekrit".into()),
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });

    tokio::time::sleep(Duration::from_millis(100)).await;

    let mut ws = connect_ws(ws_addr).await;

    send_client_msg(
        &mut ws,
        &ClientMsg::HelloNative {
            version: PROTOCOL_VERSION,
            viewport: Viewport {
                cols: 120,
                rows: 32,
            },
            token: Some("sekrit".into()),
            terminal_renderer: NativeTerminalRenderer::ServerGrid,
        },
    )
    .await;

    match recv_server_msg(&mut ws).await {
        ServerMsg::Welcome { .. } => {}
        other => panic!("expected Welcome, got {other:?}"),
    }
    let _ = recv_native_snapshot(&mut ws).await;

    send_command(&mut ws, 10, Command::SplitHorizontal).await;
    recv_command_ok(&mut ws, 10).await;
    let _ = recv_native_snapshot_with_leaf_count(&mut ws, 2).await;

    send_command(&mut ws, 20, Command::SplitVertical).await;
    recv_command_ok(&mut ws, 20).await;
    let _ = recv_native_snapshot_with_leaf_count(&mut ws, 3).await;

    send_command(
        &mut ws,
        30,
        Command::ResizeSplit {
            path: vec![],
            ratio_permille: 650,
        },
    )
    .await;
    recv_command_ok(&mut ws, 30).await;
    let snapshot = recv_native_snapshot(&mut ws).await;
    match &snapshot.panels {
        NativePanelNode::Split { ratio_permille, .. } => assert_eq!(*ratio_permille, 650),
        other => panic!("expected root split, got {other:?}"),
    }

    send_command(
        &mut ws,
        40,
        Command::ResizeSplit {
            path: vec![SplitPathStep::Second],
            ratio_permille: 300,
        },
    )
    .await;
    recv_command_ok(&mut ws, 40).await;
    let snapshot = recv_native_snapshot(&mut ws).await;
    match &snapshot.panels {
        NativePanelNode::Split { second, .. } => match second.as_ref() {
            NativePanelNode::Split { ratio_permille, .. } => assert_eq!(*ratio_permille, 300),
            other => panic!("expected nested split, got {other:?}"),
        },
        other => panic!("expected root split, got {other:?}"),
    }

    drop(ws);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_rejects_missing_token() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let ws_addr = pick_free_port().await;
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: (80, 24),
        snapshot_path: None,
        settings_path: None,
        ws_bind: Some(ws_addr),
        auth_token: Some("sekrit".into()),
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });

    tokio::time::sleep(Duration::from_millis(100)).await;

    let mut ws = connect_ws(ws_addr).await;

    send_client_msg(
        &mut ws,
        &ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            token: None,
        },
    )
    .await;

    match recv_server_msg(&mut ws).await {
        ServerMsg::Error { message } => {
            assert!(
                message.contains("token"),
                "expected token error, got: {message}"
            );
        }
        other => panic!("expected Error, got {other:?}"),
    }

    server.abort();
}
