use std::time::Duration;

use cmux_cli_protocol::{
    ClientMsg, Command, CommandData, CommandResult, PROTOCOL_VERSION, ServerMsg, Viewport,
    read_msg, write_msg,
};
use cmux_cli_server::{ServerOptions, chrome_layout, run};
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::time::timeout;

struct TestClient {
    reader: BufReader<OwnedReadHalf>,
    writer: OwnedWriteHalf,
    next_id: u32,
}

impl TestClient {
    async fn command(&mut self, command: Command) -> CommandResult {
        let id = self.next_id;
        self.next_id += 1;
        write_msg(&mut self.writer, &ClientMsg::Command { id, command })
            .await
            .unwrap();
        wait_for_reply(&mut self.reader, id).await
    }

    async fn input(&mut self, data: &str) {
        write_msg(
            &mut self.writer,
            &ClientMsg::Input {
                data: data.as_bytes().to_vec(),
            },
        )
        .await
        .unwrap();
    }

    async fn detach(&mut self) {
        write_msg(&mut self.writer, &ClientMsg::Detach)
            .await
            .unwrap();
    }
}

struct PassiveClient {
    writer: OwnedWriteHalf,
    drain: tokio::task::JoinHandle<()>,
}

impl PassiveClient {
    async fn resize(&mut self, cols: u16, rows: u16) {
        write_msg(
            &mut self.writer,
            &ClientMsg::Resize {
                viewport: Viewport { cols, rows },
            },
        )
        .await
        .unwrap();
    }

    async fn detach(&mut self) {
        write_msg(&mut self.writer, &ClientMsg::Detach)
            .await
            .unwrap();
    }

    fn abort_drain(self) {
        self.drain.abort();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn selected_workspace_and_tab_are_per_client() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let server = start_server(socket.clone(), dir.path().to_path_buf(), (100, 24)).await;

    let mut a = connect_client(&socket, 100, 24).await;
    let mut b = connect_client(&socket, 100, 24).await;

    expect_ok(
        a.command(Command::NewWorkspace {
            title: Some("client-a".into()),
            cwd: None,
        })
        .await,
    );

    let (a_workspaces, a_active) = list_workspaces(&mut a).await;
    let (b_workspaces, b_active) = list_workspaces(&mut b).await;
    assert_eq!(a_workspaces, 2);
    assert_eq!(b_workspaces, 2);
    assert_eq!(a_active, 1, "client A should focus its new workspace");
    assert_eq!(b_active, 0, "client B should keep its own workspace focus");

    expect_ok(a.command(Command::SelectWorkspace { index: 0 }).await);
    expect_ok(a.command(Command::NewTab).await);

    let (a_tabs, a_tab_active) = list_tabs(&mut a).await;
    let (b_tabs, b_tab_active) = list_tabs(&mut b).await;
    assert_eq!(a_tabs, 2);
    assert_eq!(b_tabs, 2);
    assert_eq!(a_tab_active, 1, "client A should focus its new tab");
    assert_eq!(b_tab_active, 0, "client B should keep its selected tab");

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn smallest_visible_client_size_wins_until_detach() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let server = start_server(socket.clone(), dir.path().to_path_buf(), (120, 24)).await;

    let mut large = connect_client(&socket, 120, 24).await;
    let mut small = connect_client(&socket, 80, 10).await;

    let small_size = unsplit_terminal_size((80, 10));
    assert_ansi_eventually_contains(&mut large, "stty size\n", &small_size).await;

    small.detach().await;
    drop(small);

    let large_size = unsplit_terminal_size((120, 24));
    assert_ansi_eventually_contains(&mut large, "stty size\n", &large_size).await;

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nested_panel_sizes_use_smallest_visible_client_until_resize_or_detach() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let server = start_server(socket.clone(), dir.path().to_path_buf(), (160, 36)).await;

    let mut large = connect_client(&socket, 160, 36).await;
    let mut medium = connect_passive_client(&socket, 120, 24).await;
    let mut small = connect_passive_client(&socket, 72, 14).await;

    expect_ok(large.command(Command::SplitHorizontal).await);
    expect_ok(large.command(Command::SplitVertical).await);

    assert_ansi_eventually_contains(&mut large, "stty size\n", "4 26").await;

    small.resize(100, 20).await;
    assert_ansi_eventually_contains(&mut large, "stty size\n", "7 40").await;

    small.detach().await;
    small.abort_drain();
    assert_ansi_eventually_contains(&mut large, "stty size\n", "9 50").await;

    medium.detach().await;
    medium.abort_drain();
    assert_ansi_eventually_contains(&mut large, "stty size\n", "15 70").await;

    server.abort();
    let _ = timeout(Duration::from_millis(500), server).await;
}

async fn start_server(
    socket: std::path::PathBuf,
    cwd: std::path::PathBuf,
    initial_viewport: (u16, u16),
) -> tokio::task::JoinHandle<()> {
    let opts = ServerOptions {
        socket_path: socket.clone(),
        compatibility_socket_path: None,
        shell: "/bin/sh".into(),
        cwd: Some(cwd),
        initial_viewport,
        snapshot_path: None,
        settings_path: None,
        ws_bind: None,
        auth_token: None,
    };
    let server = tokio::spawn(async move {
        let _ = run(opts).await;
    });
    wait_for_socket(&socket).await;
    server
}

async fn connect_client(socket: &std::path::Path, cols: u16, rows: u16) -> TestClient {
    let stream = UnixStream::connect(socket).await.unwrap();
    let (read_half, mut writer) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    write_msg(
        &mut writer,
        &ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols, rows },
            token: None,
        },
    )
    .await
    .unwrap();
    let msg = timeout(
        Duration::from_secs(5),
        read_msg::<_, ServerMsg>(&mut reader),
    )
    .await
    .unwrap()
    .unwrap()
    .unwrap();
    assert!(matches!(msg, ServerMsg::Welcome { .. }), "got {msg:?}");
    TestClient {
        reader,
        writer,
        next_id: 1,
    }
}

async fn connect_passive_client(socket: &std::path::Path, cols: u16, rows: u16) -> PassiveClient {
    let client = connect_client(socket, cols, rows).await;
    let TestClient {
        reader,
        writer,
        next_id: _,
    } = client;
    let drain = tokio::spawn(async move {
        let mut reader = reader;
        while let Ok(Some(_)) = read_msg::<_, ServerMsg>(&mut reader).await {}
    });
    PassiveClient { writer, drain }
}

async fn list_workspaces(client: &mut TestClient) -> (usize, usize) {
    match client.command(Command::ListWorkspaces).await {
        CommandResult::Ok {
            data: Some(CommandData::WorkspaceList { workspaces, active }),
        } => (workspaces.len(), active),
        other => panic!("expected WorkspaceList, got {other:?}"),
    }
}

async fn list_tabs(client: &mut TestClient) -> (usize, usize) {
    match client.command(Command::ListTabs).await {
        CommandResult::Ok {
            data: Some(CommandData::TabList { tabs, active }),
        } => (tabs.len(), active),
        other => panic!("expected TabList, got {other:?}"),
    }
}

fn expect_ok(result: CommandResult) {
    assert!(matches!(result, CommandResult::Ok { .. }), "got {result:?}");
}

async fn assert_ansi_eventually_contains(client: &mut TestClient, input: &str, needle: &str) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut last_frame = String::new();
    while tokio::time::Instant::now() < deadline {
        client.input(input).await;
        let poll_until = (tokio::time::Instant::now() + Duration::from_millis(250)).min(deadline);
        while tokio::time::Instant::now() < poll_until {
            match timeout(
                poll_until.saturating_duration_since(tokio::time::Instant::now()),
                read_msg::<_, ServerMsg>(&mut client.reader),
            )
            .await
            {
                Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) => {
                    let frame = String::from_utf8_lossy(&data).into_owned();
                    if frame.contains(needle) {
                        return;
                    }
                    last_frame = frame;
                }
                Ok(Ok(Some(_))) => {}
                Ok(Ok(None)) => break,
                Ok(Err(e)) => panic!("protocol error: {e:?}"),
                Err(_) => break,
            }
        }
    }
    panic!("ANSI stream never contained {needle:?}; last frame:\n{last_frame}");
}

async fn wait_for_reply(
    r: &mut (impl tokio::io::AsyncRead + Unpin),
    want_id: u32,
) -> CommandResult {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, read_msg::<_, ServerMsg>(r))
            .await
            .expect("wait_for_reply timeout")
            .expect("wait_for_reply io")
            .expect("wait_for_reply eof");
        if let ServerMsg::CommandReply { id, result } = msg
            && id == want_id
        {
            return result;
        }
    }
}

async fn wait_for_socket(socket: &std::path::Path) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        if UnixStream::connect(socket).await.is_ok() {
            return;
        }
        if tokio::time::Instant::now() > deadline {
            panic!("socket did not become connectable");
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

fn unsplit_terminal_size(viewport: (u16, u16)) -> String {
    let (_, _, _, pane, _, _) = chrome_layout(viewport);
    format!("{} {}", pane.rows, pane.cols)
}
