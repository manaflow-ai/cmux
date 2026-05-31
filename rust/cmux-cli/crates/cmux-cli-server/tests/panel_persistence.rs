use std::time::Duration;

use cmux_cli_protocol::MouseKind;
use cmux_cli_protocol::{
    ClientMsg, Command, CommandData, CommandResult, PROTOCOL_VERSION, ServerMsg, TabInfo, Viewport,
    read_msg, write_msg,
};
use cmux_cli_server::snapshot::{self, PanelSnapshot, TabSnapshot};
use cmux_cli_server::{ServerOptions, run};
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

    async fn detach(&mut self) {
        write_msg(&mut self.writer, &ClientMsg::Detach)
            .await
            .unwrap();
    }

    async fn mouse_down(&mut self, col: u16, row: u16) {
        write_msg(
            &mut self.writer,
            &ClientMsg::Mouse {
                col,
                row,
                event: MouseKind::Down,
            },
        )
        .await
        .unwrap();
    }

    async fn list_tabs(&mut self) -> (Vec<TabInfo>, usize) {
        match self.command(Command::ListTabs).await {
            CommandResult::Ok {
                data: Some(CommandData::TabList { tabs, active }),
            } => (tabs, active),
            other => panic!("expected tab list, got {other:?}"),
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nested_panel_tree_survives_reattach_and_restart() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("server.sock");
    let snapshot_path = dir.path().join("snapshot.json");
    let server = start_server(
        socket.clone(),
        dir.path().to_path_buf(),
        snapshot_path.clone(),
    )
    .await;

    let mut client = connect_client(&socket, 160, 36).await;
    build_nested_panel_tree(&mut client).await;

    client.detach().await;
    drop(client);

    let mut reattached = connect_client(&socket, 160, 36).await;
    let corners = wait_for_corner_count(&mut reattached.reader, Duration::from_secs(3), |count| {
        count >= 3
    })
    .await;
    assert!(
        corners >= 3,
        "reattached client should render the existing nested panel tree, got {corners}"
    );
    assert_right_panel_tab_stack(&mut reattached).await;

    expect_ok(reattached.command(Command::KillServer).await);
    let _ = timeout(Duration::from_secs(5), server)
        .await
        .expect("server did not stop after KillServer");

    assert_snapshot_contains_nested_panels(&snapshot_path);

    std::fs::remove_file(&socket).ok();
    let server2 = start_server(
        socket.clone(),
        dir.path().to_path_buf(),
        snapshot_path.clone(),
    )
    .await;
    let mut restored = connect_client(&socket, 160, 36).await;
    let corners = wait_for_corner_count(&mut restored.reader, Duration::from_secs(3), |count| {
        count >= 3
    })
    .await;
    assert!(
        corners >= 3,
        "restored client should render the snapshotted nested panel tree, got {corners}"
    );
    assert_right_panel_tab_stack(&mut restored).await;

    expect_ok(restored.command(Command::KillServer).await);
    let _ = timeout(Duration::from_secs(5), server2)
        .await
        .expect("restored server did not stop after KillServer");
}

async fn build_nested_panel_tree(client: &mut TestClient) {
    expect_ok(client.command(Command::SplitHorizontal).await);
    expect_ok(
        client
            .command(Command::RenameTab {
                title: "right-a".into(),
            })
            .await,
    );
    expect_ok(client.command(Command::NewTab).await);
    expect_ok(
        client
            .command(Command::RenameTab {
                title: "right-b".into(),
            })
            .await,
    );
    client.mouse_down(30, 10).await;
    expect_ok(client.command(Command::SplitVertical).await);
    expect_ok(
        client
            .command(Command::RenameTab {
                title: "bottom".into(),
            })
            .await,
    );
    client.mouse_down(30, 5).await;
    expect_ok(
        client
            .command(Command::RenameTab {
                title: "top".into(),
            })
            .await,
    );
    client.mouse_down(120, 10).await;
    assert_right_panel_tab_stack(client).await;
}

async fn assert_right_panel_tab_stack(client: &mut TestClient) {
    let (tabs, active) = client.list_tabs().await;
    let titles: Vec<&str> = tabs.iter().map(|tab| tab.title.as_str()).collect();
    assert_eq!(titles, ["right-a", "right-b"]);
    assert_eq!(active, 1);
}

fn assert_snapshot_contains_nested_panels(path: &std::path::Path) {
    let snap = snapshot::load(path).expect("snapshot should load");
    assert_eq!(snap.workspaces.len(), 1);
    let ws = &snap.workspaces[0];
    assert_eq!(ws.spaces.len(), 1, "workspace should snapshot one space");
    let space = &ws.spaces[0];
    let tree = space
        .panel_tree
        .as_ref()
        .expect("space should snapshot panels");

    let mut leaf_title_groups = Vec::new();
    collect_leaf_title_groups(tree, &space.tabs, &mut leaf_title_groups);
    leaf_title_groups.sort();
    assert_eq!(
        leaf_title_groups,
        vec![
            vec!["bottom".to_string()],
            vec!["right-a".to_string(), "right-b".to_string()],
            vec!["top".to_string()],
        ]
    );

    let active_panel = space
        .active_panel
        .expect("snapshot should record active panel");
    let active_leaf = find_leaf(tree, active_panel).expect("active panel should exist");
    match active_leaf {
        PanelSnapshot::Leaf {
            active_tab, tabs, ..
        } => {
            assert_eq!(leaf_titles(tabs, &space.tabs), ["right-a", "right-b"]);
            let active_title = active_tab
                .and_then(|idx| space.tabs.get(idx))
                .map(|tab| tab.title.as_str());
            assert_eq!(active_title, Some("right-b"));
        }
        PanelSnapshot::Split { .. } => panic!("active panel id pointed at a split node"),
    }
}

fn collect_leaf_title_groups(
    node: &PanelSnapshot,
    tabs: &[TabSnapshot],
    out: &mut Vec<Vec<String>>,
) {
    match node {
        PanelSnapshot::Leaf {
            tabs: tab_indexes, ..
        } => out.push(leaf_titles(tab_indexes, tabs)),
        PanelSnapshot::Split { first, second, .. } => {
            collect_leaf_title_groups(first, tabs, out);
            collect_leaf_title_groups(second, tabs, out);
        }
    }
}

fn find_leaf(node: &PanelSnapshot, panel_id: u64) -> Option<&PanelSnapshot> {
    match node {
        PanelSnapshot::Leaf { id, .. } if *id == panel_id => Some(node),
        PanelSnapshot::Leaf { .. } => None,
        PanelSnapshot::Split { first, second, .. } => {
            find_leaf(first, panel_id).or_else(|| find_leaf(second, panel_id))
        }
    }
}

fn leaf_titles(tab_indexes: &[usize], tabs: &[TabSnapshot]) -> Vec<String> {
    tab_indexes
        .iter()
        .filter_map(|idx| tabs.get(*idx).map(|tab| tab.title.clone()))
        .collect()
}

fn expect_ok(result: CommandResult) {
    assert!(matches!(result, CommandResult::Ok { .. }), "got {result:?}");
}

async fn start_server(
    socket: std::path::PathBuf,
    cwd: std::path::PathBuf,
    snapshot_path: std::path::PathBuf,
) -> tokio::task::JoinHandle<()> {
    let opts = ServerOptions {
        socket_path: socket.clone(),
        shell: "/bin/sh".into(),
        cwd: Some(cwd),
        initial_viewport: (160, 36),
        snapshot_path: Some(snapshot_path),
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

async fn wait_for_corner_count<R, F>(r: &mut R, deadline: Duration, accept: F) -> usize
where
    R: tokio::io::AsyncRead + Unpin,
    F: Fn(usize) -> bool,
{
    let end = tokio::time::Instant::now() + deadline;
    let mut last_frame_count = 0usize;
    while tokio::time::Instant::now() < end {
        let remaining = end.saturating_duration_since(tokio::time::Instant::now());
        match timeout(
            remaining.min(Duration::from_millis(100)),
            read_msg::<_, ServerMsg>(r),
        )
        .await
        {
            Ok(Ok(Some(ServerMsg::PtyBytes { data, .. }))) => {
                let s = String::from_utf8_lossy(&data);
                if data.len() > 1000 && s.contains('╭') {
                    last_frame_count = s.matches('╭').count();
                    if accept(last_frame_count) {
                        return last_frame_count;
                    }
                }
            }
            Ok(Ok(Some(_))) => {}
            Err(_) => {}
            _ => break,
        }
    }
    last_frame_count
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
