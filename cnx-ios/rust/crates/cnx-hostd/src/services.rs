//! Link services (PROTOCOL.md "Services"). Default deny: a service not
//! listed here is closed with `unknown_service`.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use bytes::Bytes;
use cnx_link::link::{ChannelReceiver, ChannelSender};
use cnx_link::{ChannelEvent, IncomingChannel};
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::config::{AcpmuxTarget, ServiceConfig};
use crate::policy::{DaemonPolicy, MAXIMUM_LINE_BYTES, Verdict};

/// Who opened the channel.
#[derive(Debug, Clone)]
pub struct Peer {
    pub device_id: String,
}

/// Serve one incoming channel to completion.
pub async fn serve(config: Arc<ServiceConfig>, peer: Peer, incoming: IncomingChannel) {
    let IncomingChannel { service, args, channel } = incoming;
    let (sender, receiver) = channel.split();
    tracing::info!(service, channel = sender.id(), peer = peer.device_id, "channel opened");
    let result = match service.as_str() {
        "echo" => echo(&sender, receiver).await,
        "daemon" => daemon(&config, &peer, &args, &sender, receiver).await,
        "acpmux" => acpmux(&config, &sender, receiver).await,
        "file" => file(&config, &args, &sender).await,
        _ => Err(Refusal::new("unknown_service", format!("no service {service}"))),
    };
    match result {
        Ok(()) => sender.close("eof", "").await,
        Err(refusal) => {
            tracing::info!(
                service,
                code = refusal.code,
                reason = refusal.reason,
                "channel refused or failed"
            );
            sender.close(refusal.code, &refusal.reason).await;
        }
    }
}

#[derive(Debug)]
pub struct Refusal {
    pub code: &'static str,
    pub reason: String,
}

impl Refusal {
    fn new(code: &'static str, reason: impl Into<String>) -> Self {
        Self { code, reason: reason.into() }
    }
}

async fn echo(sender: &ChannelSender, mut receiver: ChannelReceiver) -> Result<(), Refusal> {
    while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
        if sender.send(bytes).await.is_err() {
            break;
        }
    }
    Ok(())
}

fn valid_session_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && !name.starts_with('.')
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

/// `daemon`: splice to the cmux-tui session socket, filtering every phone
/// request line through [`DaemonPolicy`]. Responses and refusals reach the
/// phone as whole lines, never interleaved.
async fn daemon(
    config: &ServiceConfig,
    peer: &Peer,
    args: &Value,
    sender: &ChannelSender,
    mut receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    let session = args.get("session").and_then(Value::as_str).unwrap_or(&config.default_session);
    if !valid_session_name(session) {
        return Err(Refusal::new("bad_request", "invalid session name"));
    }
    let path = config.tui_socket_dir.join(format!("{session}.sock"));
    let socket = UnixStream::connect(&path)
        .await
        .map_err(|e| Refusal::new("unavailable", format!("cmux-tui session {session}: {e}")))?;
    let (daemon_read, mut daemon_write) = socket.into_split();
    let policy = DaemonPolicy::new(&peer.device_id);
    let (lines_tx, mut lines_rx) = mpsc::channel::<Vec<u8>>(256);

    // Daemon → phone, whole lines.
    let daemon_lines = lines_tx.clone();
    let mut from_daemon = tokio::spawn(async move {
        let mut reader = BufReader::with_capacity(64 * 1024, daemon_read);
        loop {
            let mut line = Vec::new();
            match reader.read_until(b'\n', &mut line).await {
                Ok(0) | Err(_) => return,
                Ok(_) => {
                    if daemon_lines.send(line).await.is_err() {
                        return;
                    }
                }
            }
        }
    });

    // Phone → daemon, filtered.
    let refusals = lines_tx;
    let mut to_daemon = tokio::spawn(async move {
        let mut pending: Vec<u8> = Vec::new();
        while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
            pending.extend_from_slice(&bytes);
            while let Some(newline) = pending.iter().position(|&b| b == b'\n') {
                let mut line: Vec<u8> = pending.drain(..=newline).collect();
                line.pop();
                if line.last() == Some(&b'\r') {
                    line.pop();
                }
                if line.iter().all(u8::is_ascii_whitespace) {
                    continue;
                }
                match policy.evaluate(&line) {
                    Verdict::Forward => {
                        line.push(b'\n');
                        if daemon_write.write_all(&line).await.is_err() {
                            return;
                        }
                    }
                    Verdict::Refuse(answer) => {
                        let mut answer = answer.into_bytes();
                        answer.push(b'\n');
                        if refusals.send(answer).await.is_err() {
                            return;
                        }
                    }
                }
            }
            if pending.len() > MAXIMUM_LINE_BYTES {
                let mut answer =
                    crate::policy::error_line(None, "too_large", "request exceeds 4 MiB").into_bytes();
                answer.push(b'\n');
                let _ = refusals.send(answer).await;
                return;
            }
        }
    });

    loop {
        tokio::select! {
            line = lines_rx.recv() => match line {
                Some(line) => {
                    if sender.send(Bytes::from(line)).await.is_err() {
                        break;
                    }
                }
                None => break,
            },
            _ = &mut to_daemon => {
                // The phone closed or broke policy; drain what the daemon
                // already answered, briefly, then end.
                while let Ok(Some(line)) = tokio::time::timeout(std::time::Duration::from_millis(200), lines_rx.recv()).await {
                    let _ = sender.send(Bytes::from(line)).await;
                }
                break;
            }
            _ = &mut from_daemon => {
                while let Ok(line) = lines_rx.try_recv() {
                    let _ = sender.send(Bytes::from(line)).await;
                }
                break;
            }
        }
    }
    to_daemon.abort();
    from_daemon.abort();
    Ok(())
}

/// The acpmux WebSocket address and token.
fn acpmux_endpoint(target: &AcpmuxTarget) -> Result<(String, Option<String>), Refusal> {
    match target {
        AcpmuxTarget::Fixed { url, token } => Ok((url.clone(), token.clone())),
        AcpmuxTarget::Home(home) => {
            let path = home.join("config.json");
            let text = std::fs::read_to_string(&path)
                .map_err(|e| Refusal::new("unavailable", format!("acpmux config {}: {e}", path.display())))?;
            let config: Value = serde_json::from_str(&text)
                .map_err(|_| Refusal::new("unavailable", "acpmux config is not JSON"))?;
            let websocket = config
                .get("websocket")
                .ok_or_else(|| Refusal::new("unavailable", "acpmux has no web listener"))?;
            let listen = websocket
                .get("listen")
                .and_then(Value::as_str)
                .ok_or_else(|| Refusal::new("unavailable", "acpmux web listener has no address"))?;
            let token = websocket.get("token").and_then(Value::as_str).map(str::to_owned);
            Ok((format!("ws://{listen}/"), token))
        }
    }
}

/// `acpmux`: splice to the acpmux loopback WebSocket. One link data frame
/// carries one WebSocket text message in each direction.
async fn acpmux(
    config: &ServiceConfig,
    sender: &ChannelSender,
    mut receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    let (url, token) = acpmux_endpoint(&config.acpmux)?;
    let mut request = url.into_client_request().map_err(|e| Refusal::new("unavailable", e.to_string()))?;
    if !request.uri().host().is_some_and(is_loopback_host) {
        return Err(Refusal::new("forbidden", "acpmux listener is not on loopback"));
    }
    if let Some(token) = token {
        request.headers_mut().insert(
            "authorization",
            format!("Bearer {token}").parse().map_err(|_| Refusal::new("unavailable", "bad acpmux token"))?,
        );
    }
    let (socket, _) = tokio_tungstenite::connect_async(request)
        .await
        .map_err(|e| Refusal::new("unavailable", format!("acpmux: {e}")))?;
    let (mut ws_sink, mut ws_source) = socket.split();
    loop {
        tokio::select! {
            event = receiver.recv() => match event {
                Some(ChannelEvent::Data(bytes)) => {
                    let text = String::from_utf8(bytes.to_vec())
                        .map_err(|_| Refusal::new("bad_request", "acpmux frames are UTF-8 JSON"))?;
                    if ws_sink.send(Message::Text(text.into())).await.is_err() {
                        break;
                    }
                }
                _ => break,
            },
            message = ws_source.next() => match message {
                Some(Ok(Message::Text(text))) => {
                    if sender.send(Bytes::copy_from_slice(text.as_bytes())).await.is_err() {
                        break;
                    }
                }
                Some(Ok(Message::Binary(bytes))) => {
                    if sender.send(bytes).await.is_err() {
                        break;
                    }
                }
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {}
            },
        }
    }
    let _ = ws_sink.close().await;
    Ok(())
}

fn is_loopback_host(host: &str) -> bool {
    let host = host.trim_start_matches('[').trim_end_matches(']');
    host == "localhost" || host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback())
}

/// Resolve `requested` inside one of `roots`; symlinks may not escape.
pub fn confine(roots: &[PathBuf], requested: &Path) -> Result<PathBuf, Refusal> {
    if roots.is_empty() {
        return Err(Refusal::new("forbidden", "no workspace roots are shared"));
    }
    if !requested.is_absolute() {
        return Err(Refusal::new("bad_request", "path must be absolute"));
    }
    let resolved = std::fs::canonicalize(requested).map_err(|_| Refusal::new("not_found", "no such file"))?;
    let inside = roots
        .iter()
        .filter_map(|root| std::fs::canonicalize(root).ok())
        .any(|root| resolved.starts_with(&root));
    if !inside {
        return Err(Refusal::new("forbidden", "path is outside the workspace roots"));
    }
    Ok(resolved)
}

/// `file`: stream one regular file inside a workspace root, then close
/// with `eof`.
async fn file(config: &ServiceConfig, args: &Value, sender: &ChannelSender) -> Result<(), Refusal> {
    let requested = args
        .get("path")
        .and_then(Value::as_str)
        .ok_or_else(|| Refusal::new("bad_request", "missing path"))?;
    let resolved = confine(&config.file_roots, Path::new(requested))?;
    let mut file =
        tokio::fs::File::open(&resolved).await.map_err(|_| Refusal::new("not_found", "cannot open"))?;
    let metadata = file.metadata().await.map_err(|_| Refusal::new("not_found", "cannot stat"))?;
    if !metadata.is_file() {
        return Err(Refusal::new("bad_request", "not a regular file"));
    }
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).await.map_err(|e| Refusal::new("io", e.to_string()))?;
        if read == 0 {
            return Ok(());
        }
        if sender.send(Bytes::copy_from_slice(&buffer[..read])).await.is_err() {
            return Ok(());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_names() {
        assert!(valid_session_name("main"));
        assert!(valid_session_name("dev-1.x"));
        assert!(!valid_session_name("../x"));
        assert!(!valid_session_name(".hidden"));
        assert!(!valid_session_name(""));
    }

    #[test]
    fn confine_keeps_reads_inside_roots() {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("a.txt"), "a").unwrap();
        std::fs::write(outside.path().join("secret"), "s").unwrap();
        std::os::unix::fs::symlink(outside.path().join("secret"), root.path().join("link")).unwrap();
        let roots = vec![root.path().to_path_buf()];
        assert!(confine(&roots, &root.path().join("a.txt")).is_ok());
        assert_eq!(confine(&roots, &root.path().join("link")).unwrap_err().code, "forbidden");
        assert_eq!(confine(&roots, &root.path().join("../x")).unwrap_err().code, "not_found");
        assert_eq!(confine(&roots, Path::new("a.txt")).unwrap_err().code, "bad_request");
        assert_eq!(confine(&[], &root.path().join("a.txt")).unwrap_err().code, "forbidden");
    }
}
