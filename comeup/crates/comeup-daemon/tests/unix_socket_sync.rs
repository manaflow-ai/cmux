use std::path::Path;
use std::time::Duration;

use comeup_client::UnixClient;
use comeup_daemon::{
    AuthPolicy, ComeupServer, ServerOptions, serve_unix_socket, serve_unix_socket_with_server,
};
use comeup_protocol::{
    ClientAuth, ClientMsg, Command, Delta, PROTOCOL_VERSION, ServerMsg, Viewport, VisibleTerminal,
    WorkspaceId, read_msg, write_msg,
};
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::time::timeout;

const SENTINEL: &str = "COMEUP_SOCKET_SYNC_OK_138D";

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unix_socket_clients_sync_workspace_resize_and_terminal_output() {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("comeup.sock");
    let server_socket = socket.clone();
    let server = tokio::spawn(async move {
        let _ = serve_unix_socket(
            server_socket,
            ServerOptions {
                shell: "/bin/cat".to_string(),
                cwd: Some(dir.path().to_path_buf()),
                initial_viewport: Viewport { cols: 80, rows: 24 },
                auth: AuthPolicy::Open,
            },
        )
        .await;
    });
    wait_for_socket(&socket).await;

    let mut tui = UnixClient::connect(
        &socket,
        Viewport {
            cols: 120,
            rows: 40,
        },
    )
    .await
    .expect("connect tui");
    let mut ios = UnixClient::connect(&socket, Viewport { cols: 90, rows: 30 })
        .await
        .expect("connect ios-shaped client");

    let terminal_id = tui.snapshot().focus.terminal_id;
    assert_eq!(
        terminal_size(tui.snapshot(), terminal_id),
        Viewport {
            cols: 120,
            rows: 40
        }
    );
    assert_eq!(
        terminal_size(ios.snapshot(), terminal_id),
        Viewport { cols: 90, rows: 30 }
    );
    assert_eq!(
        recv_terminal_size(&mut tui, terminal_id).await,
        Viewport { cols: 90, rows: 30 }
    );

    ios.send(&ClientMsg::VisibleTerminals {
        terminals: vec![VisibleTerminal {
            client_id: ios.client_id(),
            terminal_id,
            cols: 72,
            rows: 22,
            visible: true,
        }],
    })
    .await
    .expect("send ios visible terminal");
    assert_eq!(
        recv_terminal_size(&mut tui, terminal_id).await,
        Viewport { cols: 72, rows: 22 }
    );
    assert_eq!(
        recv_terminal_size(&mut ios, terminal_id).await,
        Viewport { cols: 72, rows: 22 }
    );

    tui.send(&ClientMsg::Command {
        id: 1,
        command: Command::CreateWorkspace {
            title: "Socket Build".to_string(),
        },
    })
    .await
    .expect("create workspace");
    assert_eq!(
        recv_workspace(&mut tui).await,
        (2, "Socket Build".to_string())
    );
    assert_eq!(
        recv_workspace(&mut ios).await,
        (2, "Socket Build".to_string())
    );

    ios.send(&ClientMsg::TerminalInput {
        terminal_id,
        input_seq: 1,
        data: format!("{SENTINEL}\n").into_bytes(),
    })
    .await
    .expect("send terminal input");
    assert_terminal_output_contains(&mut tui, SENTINEL).await;
    assert_terminal_output_contains(&mut ios, SENTINEL).await;

    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unix_socket_refuses_to_delete_non_socket_path() {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket_path = dir.path().join("not-a-socket");
    std::fs::write(&socket_path, "keep").expect("write placeholder file");
    let server = ComeupServer::start(ServerOptions {
        shell: "/bin/cat".to_string(),
        cwd: Some(dir.path().to_path_buf()),
        initial_viewport: Viewport { cols: 80, rows: 24 },
        auth: AuthPolicy::Open,
    })
    .expect("start server");

    let err = serve_unix_socket_with_server(&socket_path, server.clone())
        .await
        .expect_err("regular file path should be rejected");
    assert!(
        err.to_string().contains("refusing to remove non-socket"),
        "unexpected error: {err}"
    );
    assert_eq!(
        std::fs::read_to_string(&socket_path).expect("read placeholder"),
        "keep"
    );

    server.shutdown();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unix_socket_requires_matching_bearer_auth() {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("comeup.sock");
    let server_socket = socket.clone();
    let server_cwd = dir.path().to_path_buf();
    let server = tokio::spawn(async move {
        let _ = serve_unix_socket(
            server_socket,
            ServerOptions {
                shell: "/bin/cat".to_string(),
                cwd: Some(server_cwd),
                initial_viewport: Viewport { cols: 80, rows: 24 },
                auth: AuthPolicy::bearer_token("socket-secret").expect("auth policy"),
            },
        )
        .await;
    });
    wait_for_socket(&socket).await;

    assert!(matches!(
        send_hello(&socket, None).await,
        ServerMsg::Error { message } if message == "unauthorized"
    ));
    assert!(matches!(
        send_hello(
            &socket,
            Some(ClientAuth::Bearer {
                token: "wrong-secret".to_string()
            })
        )
        .await,
        ServerMsg::Error { message } if message == "unauthorized"
    ));

    let client = UnixClient::connect_with_auth(
        &socket,
        Viewport { cols: 90, rows: 30 },
        Some(ClientAuth::Bearer {
            token: "socket-secret".to_string(),
        }),
    )
    .await
    .expect("connect with auth");
    assert_eq!(
        terminal_size(client.snapshot(), client.snapshot().focus.terminal_id),
        Viewport { cols: 90, rows: 30 }
    );

    server.abort();
}

async fn wait_for_socket(socket: &Path) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while !socket.exists() {
        assert!(
            tokio::time::Instant::now() <= deadline,
            "socket did not appear at {}",
            socket.display()
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

async fn send_hello(socket: &Path, auth: Option<ClientAuth>) -> ServerMsg {
    let stream = UnixStream::connect(socket).await.expect("connect socket");
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    write_msg(
        &mut write_half,
        &ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols: 80, rows: 24 },
            auth,
        },
    )
    .await
    .expect("write hello");
    read_msg::<_, ServerMsg>(&mut reader)
        .await
        .expect("read server message")
        .expect("server message")
}

fn terminal_size(snapshot: &comeup_protocol::Snapshot, terminal_id: u64) -> Viewport {
    snapshot
        .terminals
        .iter()
        .find(|terminal| terminal.id == terminal_id)
        .map(|terminal| terminal.size)
        .expect("terminal in snapshot")
}

async fn recv_terminal_size(client: &mut UnixClient, terminal_id: u64) -> Viewport {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, client.recv())
            .await
            .expect("terminal size delta timeout")
            .expect("read")
            .expect("server closed");
        if let ServerMsg::Delta {
            delta: Delta::TerminalUpsert { terminal, .. },
        } = msg
            && terminal.id == terminal_id
        {
            return terminal.size;
        }
    }
}

async fn recv_workspace(client: &mut UnixClient) -> (WorkspaceId, String) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, client.recv())
            .await
            .expect("workspace delta timeout")
            .expect("read")
            .expect("server closed");
        if let ServerMsg::Delta {
            delta: Delta::WorkspaceUpsert { workspace, .. },
        } = msg
            && workspace.title == "Socket Build"
        {
            return (workspace.id, workspace.title);
        }
    }
}

async fn assert_terminal_output_contains(client: &mut UnixClient, expected: &str) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut collected = Vec::new();
    while tokio::time::Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, client.recv())
            .await
            .expect("terminal output timeout")
            .expect("read")
            .expect("server closed");
        if let ServerMsg::TerminalOutput { data, .. } = msg {
            collected.extend_from_slice(&data);
            if String::from_utf8_lossy(&collected).contains(expected) {
                return;
            }
        }
    }
    panic!(
        "expected terminal output to contain {expected}, got {}",
        String::from_utf8_lossy(&collected)
    );
}
