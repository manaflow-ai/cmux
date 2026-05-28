use std::io::{Read, Write};
use std::path::Path;
use std::sync::mpsc;
use std::time::Duration;

use comeup_client::UnixClient;
use comeup_daemon::{ServerOptions, serve_unix_socket};
use comeup_protocol::{
    ClientMsg, Delta, ServerMsg, TerminalId, Viewport, VisibleTerminal, WorkspaceId,
};
use portable_pty::{CommandBuilder, PtySize, native_pty_system};
use tokio::time::timeout;

const TUI_SENTINEL: &str = "COMEUP_TUI_TO_IOS_OK_31C8";
const IOS_SENTINEL: &str = "COMEUP_IOS_TO_TUI_OK_725B";
const QUEUED_TUI_SENTINEL: &str = "COMEUP_TUI_QUEUED_FOCUS_OK_C9E1";

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn real_cmx_tui_process_syncs_with_ios_shaped_client() {
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
            },
        )
        .await;
    });
    wait_for_socket(&socket).await;

    let mut tui = spawn_cmx_tui(&socket, 120, 40);
    tui.read_until("COMEUP_TUI_READY client=1 terminal=1 size=120x40");

    let mut ios = UnixClient::connect(&socket, Viewport { cols: 90, rows: 30 })
        .await
        .expect("connect ios-shaped client");
    let terminal_id = ios.snapshot().focus.terminal_id;
    tui.read_until("SIZE terminal=1 90x30");

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
    tui.read_until("SIZE terminal=1 72x22");
    assert_eq!(
        recv_terminal_size(&mut ios, terminal_id).await,
        Viewport { cols: 72, rows: 22 }
    );

    tui.write_line("new-workspace TUI Build");
    assert_eq!(
        recv_workspace(&mut ios, "TUI Build").await,
        (2, "TUI Build".to_string())
    );
    tui.read_until("WORKSPACE id=2 title=TUI Build");
    let terminal_id = recv_focus_terminal(&mut ios).await;
    tui.read_until(&format!("FOCUS terminal={terminal_id}"));

    tui.write_line(&format!("send {TUI_SENTINEL}"));
    assert_terminal_output_contains(&mut ios, TUI_SENTINEL).await;

    ios.send(&ClientMsg::TerminalInput {
        terminal_id,
        input_seq: 1,
        data: format!("{IOS_SENTINEL}\n").into_bytes(),
    })
    .await
    .expect("send ios terminal input");
    tui.read_until(IOS_SENTINEL);

    tui.write_line("ping 44");
    tui.read_until("PONG id=44");

    tui.write_line("new-workspace Queued Focus");
    tui.write_line(&format!("send {QUEUED_TUI_SENTINEL}"));
    assert_eq!(
        recv_workspace(&mut ios, "Queued Focus").await.1,
        "Queued Focus"
    );
    let queued_terminal_id = recv_focus_terminal(&mut ios).await;
    assert_terminal_output_from_terminal_contains(
        &mut ios,
        queued_terminal_id,
        QUEUED_TUI_SENTINEL,
    )
    .await;

    ios.send(&ClientMsg::Ping {
        ping_id: 45,
        client_sent_monotonic_ns: 0,
    })
    .await
    .expect("send ios ping");
    assert!(matches!(
        recv_until(&mut ios, |msg| matches!(
            msg,
            ServerMsg::Pong { ping_id: 45, .. }
        ))
        .await,
        ServerMsg::Pong { ping_id: 45, .. }
    ));

    tui.write_line("quit");
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

async fn recv_terminal_size(client: &mut UnixClient, terminal_id: TerminalId) -> Viewport {
    match recv_until(client, |msg| {
        matches!(
            msg,
            ServerMsg::Delta {
                delta: Delta::TerminalUpsert { terminal, .. },
            } if terminal.id == terminal_id
        )
    })
    .await
    {
        ServerMsg::Delta {
            delta: Delta::TerminalUpsert { terminal, .. },
        } => terminal.size,
        other => panic!("expected terminal delta, got {other:?}"),
    }
}

async fn recv_workspace(client: &mut UnixClient, title: &str) -> (WorkspaceId, String) {
    match recv_until(client, |msg| {
        matches!(
            msg,
            ServerMsg::Delta {
                delta: Delta::WorkspaceUpsert { workspace, .. },
            } if workspace.title == title
        )
    })
    .await
    {
        ServerMsg::Delta {
            delta: Delta::WorkspaceUpsert { workspace, .. },
        } => (workspace.id, workspace.title),
        other => panic!("expected workspace delta, got {other:?}"),
    }
}

async fn recv_focus_terminal(client: &mut UnixClient) -> TerminalId {
    match recv_until(client, |msg| {
        matches!(
            msg,
            ServerMsg::Delta {
                delta: Delta::FocusChanged { .. },
            }
        )
    })
    .await
    {
        ServerMsg::Delta {
            delta: Delta::FocusChanged { focus, .. },
        } => focus.terminal_id,
        other => panic!("expected focus delta, got {other:?}"),
    }
}

async fn assert_terminal_output_contains(client: &mut UnixClient, expected: &str) {
    let mut collected = Vec::new();
    let _ = recv_until(client, |msg| {
        if let ServerMsg::TerminalOutput { data, .. } = msg {
            collected.extend_from_slice(data);
            String::from_utf8_lossy(&collected).contains(expected)
        } else {
            false
        }
    })
    .await;
}

async fn assert_terminal_output_from_terminal_contains(
    client: &mut UnixClient,
    terminal_id: TerminalId,
    expected: &str,
) {
    let mut collected = Vec::new();
    let _ = recv_until(client, |msg| {
        if let ServerMsg::TerminalOutput {
            terminal_id: output_terminal_id,
            data,
        } = msg
            && *output_terminal_id == terminal_id
        {
            collected.extend_from_slice(data);
            String::from_utf8_lossy(&collected).contains(expected)
        } else {
            false
        }
    })
    .await;
}

async fn recv_until(
    client: &mut UnixClient,
    mut predicate: impl FnMut(&ServerMsg) -> bool,
) -> ServerMsg {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = timeout(remaining, client.recv())
            .await
            .expect("server message timeout")
            .expect("read")
            .expect("server closed");
        if predicate(&msg) {
            return msg;
        }
    }
}

struct TuiProcess {
    writer: Box<dyn Write + Send>,
    output: mpsc::Receiver<Vec<u8>>,
    buffer: Vec<u8>,
}

impl TuiProcess {
    fn write_line(&mut self, line: &str) {
        writeln!(self.writer, "{line}").expect("write tui input");
        self.writer.flush().expect("flush tui input");
    }

    fn read_until(&mut self, expected: &str) {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            let text = String::from_utf8_lossy(&self.buffer);
            if text.contains(expected) {
                return;
            }
            let now = std::time::Instant::now();
            assert!(
                now < deadline,
                "timed out waiting for {expected}, saw:\n{text}"
            );
            let remaining = deadline.saturating_duration_since(now);
            let chunk = self.output.recv_timeout(remaining).expect("tui output");
            self.buffer.extend_from_slice(&chunk);
        }
    }
}

fn spawn_cmx_tui(socket: &Path, cols: u16, rows: u16) -> TuiProcess {
    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .expect("open pty");
    let bin = env!("CARGO_BIN_EXE_cmx");
    let mut command = CommandBuilder::new(bin);
    command.arg("--socket");
    command.arg(socket);
    command.arg("--cols");
    command.arg(cols.to_string());
    command.arg("--rows");
    command.arg(rows.to_string());
    let _child = pair.slave.spawn_command(command).expect("spawn cmx");
    drop(pair.slave);

    let mut reader = pair.master.try_clone_reader().expect("clone pty reader");
    let writer = pair.master.take_writer().expect("take pty writer");
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut buf = [0; 8192];
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if tx.send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
            }
        }
    });

    TuiProcess {
        writer,
        output: rx,
        buffer: Vec::new(),
    }
}
