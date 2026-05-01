#![cfg_attr(
    not(test),
    deny(
        clippy::expect_used,
        clippy::panic,
        clippy::todo,
        clippy::unimplemented,
        clippy::unwrap_used
    )
)]

use std::collections::HashMap;
use std::os::unix::fs::FileTypeExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex as StdMutex, OnceLock};
use std::time::Instant;

use anyhow::{Context, Result, anyhow};
use comeup_core::Model;
use comeup_protocol::{
    ClientAuth, ClientId, ClientMsg, Command, Delta, PROTOCOL_VERSION, ServerMsg, TerminalId,
    Viewport, VisibleTerminal, read_msg, write_msg,
};
use portable_pty::{ChildKiller, CommandBuilder, PtySize, native_pty_system};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream, UnixListener, UnixStream};
use tokio::sync::{mpsc, oneshot};
use tokio::task;

#[derive(Debug, Clone)]
pub struct ServerOptions {
    pub shell: String,
    pub cwd: Option<PathBuf>,
    pub initial_viewport: Viewport,
    pub auth: AuthPolicy,
}

#[derive(Clone, Default)]
pub enum AuthPolicy {
    #[default]
    Open,
    BearerToken(String),
}

impl std::fmt::Debug for AuthPolicy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Open => f.write_str("Open"),
            Self::BearerToken(_) => f.write_str("BearerToken(<redacted>)"),
        }
    }
}

impl AuthPolicy {
    pub fn bearer_token(token: impl Into<String>) -> Result<Self> {
        let token = token.into();
        if token.is_empty() {
            return Err(anyhow!("auth token must not be empty"));
        }
        Ok(Self::BearerToken(token))
    }

    fn authorize(&self, auth: Option<&ClientAuth>) -> bool {
        match self {
            Self::Open => true,
            Self::BearerToken(expected) => match auth {
                Some(ClientAuth::Bearer { token }) => {
                    constant_time_eq(expected.as_bytes(), token.as_bytes())
                }
                None => false,
            },
        }
    }
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    let max_len = left.len().max(right.len());
    let mut diff = left.len() ^ right.len();
    for index in 0..max_len {
        let left_byte = left.get(index).copied().unwrap_or(0);
        let right_byte = right.get(index).copied().unwrap_or(0);
        diff |= usize::from(left_byte ^ right_byte);
    }
    diff == 0
}

#[derive(Debug, Clone)]
pub struct ComeupServer {
    tx: mpsc::UnboundedSender<DaemonMsg>,
    auth: AuthPolicy,
}

impl ComeupServer {
    pub fn start(opts: ServerOptions) -> Result<Self> {
        let (tx, rx) = mpsc::unbounded_channel();
        let auth = opts.auth.clone();
        let mut terminals = HashMap::new();
        let terminal = PtyTerminal::spawn(
            1,
            opts.shell.clone(),
            opts.cwd.clone(),
            opts.initial_viewport,
            tx.clone(),
        )?;
        terminals.insert(1, terminal);

        let state = DaemonState {
            model: Model::new(opts.initial_viewport),
            clients: HashMap::new(),
            terminals,
            visible_terminals: HashMap::new(),
            next_client_id: 1,
            opts,
            tx: tx.clone(),
        };
        tokio::spawn(run_loop(rx, state));
        Ok(Self { tx, auth })
    }

    pub async fn connect(&self, viewport: Viewport) -> Result<LocalClient> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.tx
            .send(DaemonMsg::Attach {
                viewport,
                reply: reply_tx,
            })
            .map_err(|_| anyhow!("comeup server is not running"))?;
        reply_rx
            .await
            .context("comeup server dropped attach reply")?
    }

    pub fn shutdown(&self) {
        let _ = self.tx.send(DaemonMsg::Shutdown);
    }

    fn authorize(&self, auth: Option<&ClientAuth>) -> bool {
        self.auth.authorize(auth)
    }
}

pub async fn serve_unix_socket(socket_path: impl AsRef<Path>, opts: ServerOptions) -> Result<()> {
    let server = ComeupServer::start(opts)?;
    serve_unix_socket_with_server(socket_path, server).await
}

pub async fn serve_unix_socket_with_server(
    socket_path: impl AsRef<Path>,
    server: ComeupServer,
) -> Result<()> {
    let socket_path = socket_path.as_ref();
    if socket_path.exists() {
        let file_type = std::fs::symlink_metadata(socket_path)
            .with_context(|| format!("inspect socket path {}", socket_path.display()))?
            .file_type();
        if !file_type.is_socket() {
            return Err(anyhow!(
                "refusing to remove non-socket path {}",
                socket_path.display()
            ));
        }
        std::fs::remove_file(socket_path)
            .with_context(|| format!("remove stale socket {}", socket_path.display()))?;
    }
    if let Some(parent) = socket_path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("create socket parent {}", parent.display()))?;
    }

    let listener = UnixListener::bind(socket_path)
        .with_context(|| format!("bind unix socket {}", socket_path.display()))?;

    loop {
        let (stream, _) = listener.accept().await.context("accept unix client")?;
        let server = server.clone();
        tokio::spawn(async move {
            let _ = handle_unix_client(server, stream).await;
        });
    }
}

async fn handle_unix_client(server: ComeupServer, stream: UnixStream) -> Result<()> {
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);

    let Some(hello) = read_msg::<_, ClientMsg>(&mut reader)
        .await
        .context("read unix client hello")?
    else {
        return Ok(());
    };
    let ClientMsg::Hello {
        version,
        viewport,
        auth,
    } = hello
    else {
        write_msg(
            &mut write_half,
            &ServerMsg::Error {
                message: "first message must be hello".to_string(),
            },
        )
        .await
        .ok();
        return Ok(());
    };
    if !server.authorize(auth.as_ref()) {
        write_msg(
            &mut write_half,
            &ServerMsg::Error {
                message: "unauthorized".to_string(),
            },
        )
        .await
        .ok();
        return Ok(());
    }
    if version != PROTOCOL_VERSION {
        write_msg(
            &mut write_half,
            &ServerMsg::Error {
                message: format!("unsupported protocol version {version}"),
            },
        )
        .await
        .ok();
        return Ok(());
    }

    let LocalClient {
        client_id,
        tx,
        mut rx,
    } = server.connect(viewport).await?;

    let writer = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if write_msg(&mut write_half, &msg).await.is_err() {
                break;
            }
        }
    });

    loop {
        let msg = read_msg::<_, ClientMsg>(&mut reader).await?;
        let Some(msg) = msg else {
            break;
        };
        if tx.send(DaemonMsg::Client { client_id, msg }).is_err() {
            break;
        }
    }

    let _ = tx.send(DaemonMsg::Client {
        client_id,
        msg: ClientMsg::Detach,
    });
    writer.abort();
    Ok(())
}

pub async fn serve_tcp_text_harness(
    bind_addr: impl tokio::net::ToSocketAddrs,
    server: ComeupServer,
) -> Result<()> {
    let listener = TcpListener::bind(bind_addr)
        .await
        .context("bind tcp text harness")?;
    loop {
        let (stream, _) = listener.accept().await.context("accept tcp text client")?;
        stream.set_nodelay(true).ok();
        let server = server.clone();
        tokio::spawn(async move {
            let _ = handle_tcp_text_client(server, stream).await;
        });
    }
}

async fn handle_tcp_text_client(server: ComeupServer, stream: TcpStream) -> Result<()> {
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half).lines();
    let Some(hello) = reader.next_line().await.context("read text hello")? else {
        return Ok(());
    };
    let Some(rest) = hello.strip_prefix("HELLO ") else {
        write_half
            .write_all(b"ERROR first line must be HELLO\n")
            .await
            .ok();
        return Ok(());
    };
    let (viewport, auth) = parse_text_hello(rest)?;
    if !server.authorize(auth.as_ref()) {
        write_half.write_all(b"ERROR unauthorized\n").await.ok();
        return Ok(());
    }
    let LocalClient {
        client_id,
        tx,
        mut rx,
    } = server.connect(viewport).await?;
    let welcome = rx
        .recv()
        .await
        .ok_or_else(|| anyhow!("server closed before text welcome"))?;
    write_text_server_msg(&mut write_half, &welcome).await?;

    let writer = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if write_text_server_msg(&mut write_half, &msg).await.is_err() {
                break;
            }
        }
    });

    while let Some(line) = reader.next_line().await.context("read text client line")? {
        let msg = parse_text_client_msg(client_id, &line)?;
        let should_quit = matches!(msg, ClientMsg::Detach);
        if tx.send(DaemonMsg::Client { client_id, msg }).is_err() || should_quit {
            break;
        }
    }

    let _ = tx.send(DaemonMsg::Client {
        client_id,
        msg: ClientMsg::Detach,
    });
    writer.abort();
    Ok(())
}

fn parse_text_client_msg(client_id: ClientId, line: &str) -> Result<ClientMsg> {
    if line == "QUIT" {
        return Ok(ClientMsg::Detach);
    }
    if let Some(rest) = line.strip_prefix("VISIBLE ") {
        let mut parts = rest.split_whitespace();
        let terminal_id = parse_next::<TerminalId>(&mut parts, "terminal id")?;
        let cols = parse_next::<u16>(&mut parts, "cols")?;
        let rows = parse_next::<u16>(&mut parts, "rows")?;
        return Ok(ClientMsg::VisibleTerminals {
            terminals: vec![VisibleTerminal {
                client_id,
                terminal_id,
                cols,
                rows,
                visible: true,
            }],
        });
    }
    if let Some(title) = line.strip_prefix("WORKSPACE ") {
        return Ok(ClientMsg::Command {
            id: 1,
            command: Command::CreateWorkspace {
                title: title.to_string(),
            },
        });
    }
    if let Some(rest) = line.strip_prefix("SEND ") {
        let Some((terminal_id, text)) = rest.split_once(' ') else {
            return Err(anyhow!("SEND requires terminal id and text"));
        };
        return Ok(ClientMsg::TerminalInput {
            terminal_id: terminal_id.parse()?,
            input_seq: 1,
            data: format!("{text}\n").into_bytes(),
        });
    }
    if let Some(rest) = line.strip_prefix("SEND_HEX ") {
        let Some((terminal_id, hex)) = rest.split_once(' ') else {
            return Err(anyhow!("SEND_HEX requires terminal id and hex data"));
        };
        return Ok(ClientMsg::TerminalInput {
            terminal_id: terminal_id.parse()?,
            input_seq: 1,
            data: decode_hex_bytes(hex)?,
        });
    }
    if let Some(ping_id) = line.strip_prefix("PING ") {
        return Ok(ClientMsg::Ping {
            ping_id: ping_id.parse()?,
            client_sent_monotonic_ns: 0,
        });
    }
    Err(anyhow!("unknown text harness command: {line}"))
}

fn decode_hex_bytes(hex: &str) -> Result<Vec<u8>> {
    let bytes = hex.as_bytes();
    if !bytes.len().is_multiple_of(2) {
        return Err(anyhow!("hex data length must be even"));
    }

    let mut decoded = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks_exact(2) {
        decoded.push((decode_hex_nibble(pair[0])? << 4) | decode_hex_nibble(pair[1])?);
    }
    Ok(decoded)
}

fn decode_hex_nibble(byte: u8) -> Result<u8> {
    match byte {
        b'0'..=b'9' => Ok(byte - b'0'),
        b'a'..=b'f' => Ok(byte - b'a' + 10),
        b'A'..=b'F' => Ok(byte - b'A' + 10),
        _ => Err(anyhow!("invalid hex byte")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_harness_send_hex_preserves_terminal_bytes() {
        let msg = parse_text_client_msg(7, "SEND_HEX 3 53494d5f53454e54494e454c0d").unwrap();
        match msg {
            ClientMsg::TerminalInput {
                terminal_id, data, ..
            } => {
                assert_eq!(terminal_id, 3);
                assert_eq!(data, b"SIM_SENTINEL\r");
            }
            other => panic!("unexpected message: {other:?}"),
        }
    }

    #[test]
    fn text_harness_hello_accepts_optional_bearer_auth() {
        let (viewport, auth) =
            parse_text_hello("90 30 AUTH bearer test-token").expect("parse hello");
        assert_eq!(viewport, Viewport { cols: 90, rows: 30 });
        assert_eq!(
            auth,
            Some(ClientAuth::Bearer {
                token: "test-token".to_string()
            })
        );

        let (viewport, auth) = parse_text_hello("80 24").expect("parse hello without auth");
        assert_eq!(viewport, Viewport { cols: 80, rows: 24 });
        assert_eq!(auth, None);
    }

    #[test]
    fn text_harness_hello_rejects_unknown_options() {
        assert!(parse_text_hello("90 30 TOKEN test-token").is_err());
        assert!(parse_text_hello("90 30 AUTH basic test-token").is_err());
        assert!(parse_text_hello("90 30 AUTH bearer").is_err());
        assert!(parse_text_hello("90 30 AUTH bearer test-token extra").is_err());
    }

    #[test]
    fn auth_policy_uses_constant_time_token_check() {
        let policy = AuthPolicy::bearer_token("expected-token").expect("policy");
        assert!(policy.authorize(Some(&ClientAuth::Bearer {
            token: "expected-token".to_string()
        })));
        assert!(!policy.authorize(Some(&ClientAuth::Bearer {
            token: "wrong-token".to_string()
        })));
        assert!(!policy.authorize(None));
    }
}

fn parse_text_hello(rest: &str) -> Result<(Viewport, Option<ClientAuth>)> {
    let mut parts = rest.split_whitespace();
    let viewport = Viewport {
        cols: parse_next::<u16>(&mut parts, "cols")?,
        rows: parse_next::<u16>(&mut parts, "rows")?,
    };
    let Some(option) = parts.next() else {
        return Ok((viewport, None));
    };
    if option != "AUTH" {
        return Err(anyhow!("unknown HELLO option: {option}"));
    }
    let scheme = parts
        .next()
        .ok_or_else(|| anyhow!("AUTH requires a scheme"))?;
    if scheme != "bearer" {
        return Err(anyhow!("unsupported AUTH scheme: {scheme}"));
    }
    let token = parts
        .next()
        .ok_or_else(|| anyhow!("AUTH bearer requires a token"))?;
    if parts.next().is_some() {
        return Err(anyhow!("unexpected trailing HELLO field"));
    }
    Ok((
        viewport,
        Some(ClientAuth::Bearer {
            token: token.to_string(),
        }),
    ))
}

fn parse_next<T: std::str::FromStr>(
    parts: &mut std::str::SplitWhitespace<'_>,
    label: &str,
) -> Result<T>
where
    T::Err: std::error::Error + Send + Sync + 'static,
{
    parts
        .next()
        .ok_or_else(|| anyhow!("missing {label}"))?
        .parse::<T>()
        .with_context(|| format!("parse {label}"))
}

async fn write_text_server_msg(
    writer: &mut tokio::net::tcp::OwnedWriteHalf,
    msg: &ServerMsg,
) -> Result<()> {
    let Some(line) = text_server_line(msg) else {
        return Ok(());
    };
    writer.write_all(line.as_bytes()).await?;
    writer.write_all(b"\n").await?;
    writer.flush().await?;
    Ok(())
}

fn text_server_line(msg: &ServerMsg) -> Option<String> {
    match msg {
        ServerMsg::Welcome {
            client_id,
            snapshot,
        } => {
            let terminal_id = snapshot.focus.terminal_id;
            let size = snapshot
                .terminals
                .iter()
                .find(|terminal| terminal.id == terminal_id)
                .map_or(Viewport { cols: 80, rows: 24 }, |terminal| terminal.size);
            Some(format!(
                "WELCOME client={client_id} terminal={terminal_id} size={}x{}",
                size.cols, size.rows
            ))
        }
        ServerMsg::Delta { delta } => match delta {
            Delta::WorkspaceUpsert { workspace, .. } => Some(format!(
                "WORKSPACE id={} title={}",
                workspace.id, workspace.title
            )),
            Delta::SpaceUpsert { space, .. } => {
                Some(format!("SPACE id={} title={}", space.id, space.title))
            }
            Delta::PaneUpsert { pane, .. } => Some(format!(
                "PANE id={} active={}",
                pane.id, pane.active_terminal_id
            )),
            Delta::TerminalUpsert { terminal, .. } => Some(format!(
                "SIZE terminal={} {}x{}",
                terminal.id, terminal.size.cols, terminal.size.rows
            )),
            Delta::FocusChanged { focus, .. } => {
                Some(format!("FOCUS terminal={}", focus.terminal_id))
            }
        },
        ServerMsg::TerminalOutput { terminal_id, data } => {
            let text = String::from_utf8_lossy(data)
                .replace('\r', "\\r")
                .replace('\n', "\\n");
            Some(format!("OUTPUT terminal={terminal_id} {text}"))
        }
        ServerMsg::CommandAck { id, seq } => Some(format!("ACK id={id} seq={seq}")),
        ServerMsg::Pong { ping_id, .. } => Some(format!("PONG id={ping_id}")),
        ServerMsg::Bye => Some("BYE".to_string()),
        ServerMsg::Error { message } => Some(format!("ERROR {message}")),
    }
}

#[derive(Debug)]
pub struct LocalClient {
    client_id: ClientId,
    tx: mpsc::UnboundedSender<DaemonMsg>,
    rx: mpsc::UnboundedReceiver<ServerMsg>,
}

impl LocalClient {
    #[must_use]
    pub fn client_id(&self) -> ClientId {
        self.client_id
    }

    pub fn send(&self, msg: ClientMsg) -> Result<()> {
        self.tx
            .send(DaemonMsg::Client {
                client_id: self.client_id,
                msg,
            })
            .map_err(|_| anyhow!("comeup server is not running"))
    }

    pub async fn recv(&mut self) -> Option<ServerMsg> {
        self.rx.recv().await
    }
}

struct DaemonState {
    model: Model,
    clients: HashMap<ClientId, mpsc::UnboundedSender<ServerMsg>>,
    terminals: HashMap<TerminalId, PtyTerminal>,
    visible_terminals: HashMap<(ClientId, TerminalId), VisibleTerminal>,
    next_client_id: ClientId,
    opts: ServerOptions,
    tx: mpsc::UnboundedSender<DaemonMsg>,
}

enum DaemonMsg {
    Attach {
        viewport: Viewport,
        reply: oneshot::Sender<Result<LocalClient>>,
    },
    Client {
        client_id: ClientId,
        msg: ClientMsg,
    },
    TerminalOutput {
        terminal_id: TerminalId,
        data: Vec<u8>,
    },
    Shutdown,
}

async fn run_loop(mut rx: mpsc::UnboundedReceiver<DaemonMsg>, mut state: DaemonState) {
    while let Some(msg) = rx.recv().await {
        match msg {
            DaemonMsg::Attach { viewport, reply } => {
                let client = attach_client(&mut state, viewport);
                let _ = reply.send(client);
            }
            DaemonMsg::Client { client_id, msg } => {
                handle_client_msg(&mut state, client_id, msg);
            }
            DaemonMsg::TerminalOutput { terminal_id, data } => {
                broadcast(&mut state, ServerMsg::TerminalOutput { terminal_id, data });
            }
            DaemonMsg::Shutdown => break,
        }
    }
    for terminal in state.terminals.values() {
        terminal.kill();
    }
}

fn attach_client(state: &mut DaemonState, viewport: Viewport) -> Result<LocalClient> {
    let client_id = state.next_client_id;
    state.next_client_id = state.next_client_id.saturating_add(1);
    let (client_tx, client_rx) = mpsc::unbounded_channel();
    let terminal_id = state.model.focus().terminal_id;
    state.visible_terminals.insert(
        (client_id, terminal_id),
        VisibleTerminal {
            client_id,
            terminal_id,
            cols: viewport.cols,
            rows: viewport.rows,
            visible: true,
        },
    );
    apply_visible_resize_for_terminal(state, terminal_id);

    let welcome = ServerMsg::Welcome {
        client_id,
        snapshot: state.model.snapshot(),
    };
    client_tx
        .send(welcome)
        .map_err(|_| anyhow!("failed to send welcome to local client"))?;
    state.clients.insert(client_id, client_tx);

    Ok(LocalClient {
        client_id,
        tx: state.tx.clone(),
        rx: client_rx,
    })
}

fn handle_client_msg(state: &mut DaemonState, client_id: ClientId, msg: ClientMsg) {
    match msg {
        ClientMsg::Hello { version, .. } => {
            if version != PROTOCOL_VERSION {
                send_to_client(
                    state,
                    client_id,
                    ServerMsg::Error {
                        message: format!("unsupported protocol version {version}"),
                    },
                );
            }
        }
        ClientMsg::Command { id, command } => handle_command(state, client_id, id, command),
        ClientMsg::TerminalInput {
            terminal_id, data, ..
        } => {
            let Some(terminal) = state.terminals.get(&terminal_id) else {
                send_to_client(
                    state,
                    client_id,
                    ServerMsg::Error {
                        message: format!("unknown terminal {terminal_id}"),
                    },
                );
                return;
            };
            if let Err(err) = terminal.write(data) {
                send_to_client(
                    state,
                    client_id,
                    ServerMsg::Error {
                        message: err.to_string(),
                    },
                );
            }
        }
        ClientMsg::VisibleTerminals { terminals } => {
            let mut changed = Vec::new();
            state
                .visible_terminals
                .retain(|(visible_client_id, terminal_id), _| {
                    if *visible_client_id == client_id {
                        changed.push(*terminal_id);
                        false
                    } else {
                        true
                    }
                });
            for mut visible in terminals {
                changed.push(visible.terminal_id);
                if visible.visible {
                    visible.client_id = client_id;
                    state
                        .visible_terminals
                        .insert((client_id, visible.terminal_id), visible);
                }
            }
            changed.sort_unstable();
            changed.dedup();
            for terminal_id in changed {
                apply_visible_resize_for_terminal(state, terminal_id);
            }
        }
        ClientMsg::Ping {
            ping_id,
            client_sent_monotonic_ns,
        } => send_to_client(
            state,
            client_id,
            ServerMsg::Pong {
                ping_id,
                client_sent_monotonic_ns,
                node_sent_monotonic_ns: monotonicish_ns(),
            },
        ),
        ClientMsg::Detach => {
            remove_client(state, client_id);
        }
    }
}

fn apply_visible_resize_for_terminal(state: &mut DaemonState, terminal_id: TerminalId) {
    let fallback = state
        .model
        .terminal_size(terminal_id)
        .unwrap_or(Viewport { cols: 80, rows: 24 });
    let visible = state
        .visible_terminals
        .values()
        .copied()
        .collect::<Vec<_>>();
    let size = comeup_core::effective_terminal_size(terminal_id, &visible, fallback);
    if size == fallback {
        return;
    }
    if let Some(delta) = state.model.resize_terminal(terminal_id, size) {
        if let Some(terminal) = state.terminals.get(&terminal_id) {
            terminal.resize(size).ok();
        }
        broadcast(state, ServerMsg::Delta { delta });
    }
}

fn remove_visible_client(state: &mut DaemonState, client_id: ClientId) {
    let mut terminal_ids = Vec::new();
    state
        .visible_terminals
        .retain(|(visible_client_id, terminal_id), _| {
            if *visible_client_id == client_id {
                terminal_ids.push(*terminal_id);
                false
            } else {
                true
            }
        });
    terminal_ids.sort_unstable();
    terminal_ids.dedup();
    for terminal_id in terminal_ids {
        apply_visible_resize_for_terminal(state, terminal_id);
    }
}

fn remove_client(state: &mut DaemonState, client_id: ClientId) {
    state.clients.remove(&client_id);
    remove_visible_client(state, client_id);
}

fn handle_command(state: &mut DaemonState, client_id: ClientId, id: u64, command: Command) {
    match command {
        Command::CreateWorkspace { title } => {
            let deltas = state.model.create_workspace(title);
            for delta in deltas {
                broadcast(state, ServerMsg::Delta { delta });
            }
            let terminal_id = state.model.focus().terminal_id;
            if !state.terminals.contains_key(&terminal_id) {
                let terminal_size = state
                    .model
                    .terminal_size(terminal_id)
                    .unwrap_or(state.opts.initial_viewport);
                match PtyTerminal::spawn(
                    terminal_id,
                    state.opts.shell.clone(),
                    state.opts.cwd.clone(),
                    terminal_size,
                    state.tx.clone(),
                ) {
                    Ok(terminal) => {
                        state.terminals.insert(terminal_id, terminal);
                    }
                    Err(err) => {
                        send_to_client(
                            state,
                            client_id,
                            ServerMsg::Error {
                                message: err.to_string(),
                            },
                        );
                    }
                }
            }
            send_to_client(
                state,
                client_id,
                ServerMsg::CommandAck {
                    id,
                    seq: state.model.seq(),
                },
            );
        }
    }
}

fn send_to_client(state: &mut DaemonState, client_id: ClientId, msg: ServerMsg) {
    let Some(tx) = state.clients.get(&client_id) else {
        remove_visible_client(state, client_id);
        return;
    };
    if tx.send(msg).is_err() {
        remove_client(state, client_id);
    }
}

fn broadcast(state: &mut DaemonState, msg: ServerMsg) {
    let mut closed = Vec::new();
    for (client_id, tx) in &state.clients {
        if tx.send(msg.clone()).is_err() {
            closed.push(*client_id);
        }
    }
    for client_id in closed {
        remove_client(state, client_id);
    }
}

fn monotonicish_ns() -> u64 {
    static START: OnceLock<Instant> = OnceLock::new();
    let elapsed = START.get_or_init(Instant::now).elapsed().as_nanos();
    match u64::try_from(elapsed) {
        Ok(value) => value,
        Err(_) => u64::MAX,
    }
}

struct PtyTerminal {
    tx: mpsc::UnboundedSender<TerminalOp>,
    killer: Arc<StdMutex<Box<dyn ChildKiller + Send + Sync>>>,
}

impl PtyTerminal {
    fn spawn(
        id: TerminalId,
        shell: String,
        cwd: Option<PathBuf>,
        size: Viewport,
        daemon_tx: mpsc::UnboundedSender<DaemonMsg>,
    ) -> Result<Self> {
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize {
                cols: size.cols.max(1),
                rows: size.rows.max(1),
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("open pty")?;
        let mut cmd = CommandBuilder::new(shell);
        if let Some(cwd) = cwd {
            cmd.cwd(cwd);
        }
        cmd.env("TERM", "xterm-256color");
        let child = pair.slave.spawn_command(cmd).context("spawn pty command")?;
        let killer = Arc::new(StdMutex::new(child.clone_killer()));
        drop(pair.slave);

        let reader = pair.master.try_clone_reader().context("clone pty reader")?;
        let master = pair.master;
        let (tx, mut rx) = mpsc::unbounded_channel::<TerminalOp>();

        let output_tx = daemon_tx.clone();
        task::spawn_blocking(move || {
            use std::io::Read;
            let mut reader = reader;
            let mut buf = [0; 8192];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        let _ = output_tx.send(DaemonMsg::TerminalOutput {
                            terminal_id: id,
                            data: buf[..n].to_vec(),
                        });
                    }
                }
            }
        });

        task::spawn_blocking(move || {
            use std::io::Write;
            let mut writer = match master.take_writer() {
                Ok(writer) => writer,
                Err(_) => return,
            };
            while let Some(op) = rx.blocking_recv() {
                match op {
                    TerminalOp::Write(data) => {
                        if writer.write_all(&data).is_err() {
                            break;
                        }
                        let _ = writer.flush();
                    }
                    TerminalOp::Resize(size) => {
                        let _ = master.resize(PtySize {
                            cols: size.cols.max(1),
                            rows: size.rows.max(1),
                            pixel_width: 0,
                            pixel_height: 0,
                        });
                    }
                }
            }
        });

        Ok(Self { tx, killer })
    }

    fn write(&self, data: Vec<u8>) -> Result<()> {
        self.tx
            .send(TerminalOp::Write(data))
            .map_err(|_| anyhow!("terminal writer is closed"))
    }

    fn resize(&self, size: Viewport) -> Result<()> {
        self.tx
            .send(TerminalOp::Resize(size))
            .map_err(|_| anyhow!("terminal writer is closed"))
    }

    fn kill(&self) {
        if let Ok(mut killer) = self.killer.lock() {
            let _ = killer.kill();
        }
    }
}

enum TerminalOp {
    Write(Vec<u8>),
    Resize(Viewport),
}
