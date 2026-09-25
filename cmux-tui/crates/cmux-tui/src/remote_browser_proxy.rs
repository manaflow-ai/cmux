//! Authenticated per-VM browser proxy over the cmux remote TCP tunnel.

use std::collections::BTreeMap;
use std::io::{self, Write};
use std::sync::Arc;
use std::time::Duration;

use anyhow::anyhow;
use base64::Engine;
use bytes::Bytes;
use cmux_remote::client::WorkspaceClient;
use cmux_remote_protocol::{
    RoutePolicy, Service, ServiceControl, WorkspaceRequest, WorkspaceResponse,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const BROWSER_PROXY_MAX_CONNECTIONS: usize = 64;
const BROWSER_PROXY_HEADER_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug)]
pub(super) struct BrowserProxyArgs {
    pub(super) connect: Vec<String>,
    pub(super) allowed_hosts: Vec<String>,
    pub(super) workspace_root: String,
    pub(super) allow_loopback: bool,
    owner: u32,
}

#[derive(Debug)]
struct BrowserProxyPolicy {
    allowed_hosts: Vec<String>,
    allow_loopback: bool,
}

pub(super) fn parse_browser_proxy_args(args: &[String]) -> anyhow::Result<BrowserProxyArgs> {
    let mut connect = Vec::new();
    let mut allowed_hosts = Vec::new();
    let mut workspace_root = None;
    let mut allow_loopback = false;
    let mut index = 0;
    while index < args.len() {
        let argument = &args[index];
        match argument.as_str() {
            "--allowed-host" => {
                let value =
                    args.get(index + 1).ok_or_else(|| anyhow!("--allowed-host needs a value"))?;
                allowed_hosts.push(normalize_proxy_host(value, allow_loopback)?);
                index += 2;
            }
            "--allow-loopback" => {
                if allow_loopback {
                    return Err(anyhow!("duplicate flag --allow-loopback"));
                }
                allow_loopback = true;
                index += 1;
            }
            "--workspace-root" => {
                if workspace_root.is_some() {
                    return Err(anyhow!("duplicate flag --workspace-root"));
                }
                workspace_root = Some(
                    args.get(index + 1)
                        .ok_or_else(|| anyhow!("--workspace-root needs a value"))?
                        .clone(),
                );
                index += 2;
            }
            "-h" | "--help" => {
                return Err(anyhow!(
                    crate::localization::catalog().remote_client.browser_proxy_help
                ));
            }
            value if value.starts_with('-') => {
                // Keep all connection options for the normal authenticated route parser.
                if value == "--carrier" || value == "--exit-with-parent" {
                    connect.push(argument.clone());
                    index += 1;
                } else {
                    connect.push(argument.clone());
                    let takes_value = !matches!(
                        value,
                        "--headless"
                            | "--json"
                            | "--carrier"
                            | "--exit-with-parent"
                            | "--no-install"
                            | "--upgrade"
                    ) && !value.contains('=');
                    if takes_value {
                        connect.push(
                            args.get(index + 1)
                                .ok_or_else(|| anyhow!(format!("{value} needs a value")))?
                                .clone(),
                        );
                        index += 2;
                    } else {
                        index += 1;
                    }
                }
            }
            _value => {
                connect.push(argument.clone());
                index += 1;
            }
        }
    }
    if allowed_hosts.is_empty() {
        return Err(anyhow!("at least one --allowed-host is required"));
    }
    let workspace_root = workspace_root.ok_or_else(|| anyhow!("--workspace-root is required"))?;
    Ok(BrowserProxyArgs {
        connect,
        allowed_hosts,
        workspace_root,
        allow_loopback,
        owner: super::current_parent_process_id(),
    })
}

fn normalize_proxy_host(value: &str, allow_loopback: bool) -> anyhow::Result<String> {
    let value = value.trim();
    if allow_loopback && value.eq_ignore_ascii_case("localhost") {
        return Ok("127.0.0.1".into());
    }
    let value = value.strip_prefix('[').and_then(|value| value.strip_suffix(']')).unwrap_or(value);
    let ip = value
        .parse::<std::net::IpAddr>()
        .map_err(|_| anyhow!("--allowed-host must be an IP address"))?;
    if ip.is_unspecified() || ip.is_multicast() || (ip.is_loopback() && !allow_loopback) {
        return Err(anyhow!("--allowed-host must be a private VM address"));
    }
    if ip.is_loopback() {
        return Ok(ip.to_string());
    }
    match ip {
        std::net::IpAddr::V4(address) if address.is_private() => Ok(address.to_string()),
        std::net::IpAddr::V6(address)
            if address.is_unique_local() || address.is_unicast_link_local() =>
        {
            Ok(address.to_string())
        }
        _ => Err(anyhow!("--allowed-host must be a private VM address")),
    }
}

pub(super) async fn serve_browser_proxy(
    runtime: &crate::remote_runtime::ClientRuntimeHandle,
    parsed: BrowserProxyArgs,
) -> anyhow::Result<()> {
    let client = WorkspaceClient::connect(runtime.multiplexer().clone()).await?;
    let workspace = match client
        .request(WorkspaceRequest::OpenWorkspace { root: parsed.workspace_root })
        .await?
    {
        WorkspaceResponse::Workspace { id, .. } => id,
        _ => return Err(anyhow!("unexpected open-workspace response")),
    };
    let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
    let address = listener.local_addr()?;
    let username = format!("cmux-{}", uuid::Uuid::new_v4().simple());
    let password = uuid::Uuid::new_v4().to_string();
    let websocket_token = uuid::Uuid::new_v4().simple().to_string();
    println!(
        "{}",
        serde_json::json!({"event":"browser-proxy-ready","host":"127.0.0.1","port":address.port(),"username":username,"password":password,"websocketToken":websocket_token})
    );
    io::stdout().flush()?;
    let credentials = format!("{username}:{password}");
    let policy = Arc::new(BrowserProxyPolicy {
        allowed_hosts: parsed.allowed_hosts,
        allow_loopback: parsed.allow_loopback,
    });
    let mut finished = runtime.subscribe_finished();
    let parent = parsed.owner;
    let mut tasks = tokio::task::JoinSet::new();
    let mut parent_check = tokio::time::interval(Duration::from_millis(250));
    parent_check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            _ = crate::wait_for_shutdown_signal_async() => break,
            _ = finished.changed() => break,
            accepted = listener.accept() => {
                let Ok((socket, _)) = accepted else { break };
                if socket.set_nodelay(true).is_err() {
                    continue;
                }
                while tasks.try_join_next().is_some() {}
                if tasks.len() >= BROWSER_PROXY_MAX_CONNECTIONS {
                    drop(socket);
                    continue;
                }
                let client = client.clone();
                let proxy_port = address.port();
                let policy = policy.clone();
                let credentials = credentials.clone();
                let workspace = workspace.clone();
                let websocket_token = websocket_token.clone();
                tasks.spawn(async move {
                    let _ = serve_browser_connection(
                        socket,
                        client,
                        workspace,
                        policy,
                        credentials,
                        websocket_token,
                        proxy_port,
                    )
                    .await;
                });
            }
            _ = parent_check.tick() => {
                if !super::parent_process_is(parent) { break; }
            }
        }
    }
    tasks.shutdown().await;
    let _ = client.request(WorkspaceRequest::CloseWorkspace { workspace }).await;
    Ok(())
}

async fn serve_browser_connection(
    socket: TcpStream,
    client: Arc<WorkspaceClient>,
    workspace: cmux_remote_protocol::WorkspaceId,
    policy: Arc<BrowserProxyPolicy>,
    credentials: String,
    websocket_token: String,
    proxy_port: u16,
) -> anyhow::Result<()> {
    let mut first = [0_u8; 1];
    tokio::time::timeout(BROWSER_PROXY_HEADER_TIMEOUT, socket.peek(&mut first)).await??;
    if first[0] == b'G' {
        return serve_websocket_bridge(
            socket,
            client,
            workspace,
            policy,
            websocket_token,
            Vec::new(),
        )
        .await;
    }
    serve_connect_connection(
        socket,
        client,
        workspace,
        policy,
        credentials,
        websocket_token,
        proxy_port,
    )
    .await
}

async fn serve_connect_connection(
    mut socket: TcpStream,
    client: Arc<WorkspaceClient>,
    workspace: cmux_remote_protocol::WorkspaceId,
    policy: Arc<BrowserProxyPolicy>,
    credentials: String,
    websocket_token: String,
    proxy_port: u16,
) -> anyhow::Result<()> {
    let handshake_deadline = tokio::time::Instant::now() + BROWSER_PROXY_HEADER_TIMEOUT;
    let mut request = Vec::with_capacity(4096);
    let mut buffer = [0_u8; 1024];
    let header_end = loop {
        let read = tokio::time::timeout_at(
            handshake_deadline,
            AsyncReadExt::read(&mut socket, &mut buffer),
        )
        .await??;
        if read == 0 {
            return Ok(());
        }
        request.extend_from_slice(&buffer[..read]);
        if request.len() > 16 * 1024 {
            return Err(anyhow!("proxy request headers too large"));
        }
        if let Some(position) = request.windows(4).position(|window| window == b"\r\n\r\n") {
            break position + 4;
        }
    };
    let header = std::str::from_utf8(&request[..header_end])
        .map_err(|_| anyhow!("proxy request is not UTF-8"))?;
    let mut lines = header.split("\r\n");
    let request_line = lines.next().ok_or_else(|| anyhow!("missing proxy request line"))?;
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts.next().ok_or_else(|| anyhow!("missing proxy method"))?;
    let target = request_parts.next().ok_or_else(|| anyhow!("missing proxy target"))?;
    if method != "CONNECT" {
        socket.write_all(b"HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\n\r\n").await?;
        return Ok(());
    }
    let (host, port) = parse_connect_authority_with_loopback(target, policy.allow_loopback)?;
    let initial_payload = request[header_end..].to_vec();
    let auth = lines.find_map(|line| {
        line.split_once(':')
            .filter(|(name, _)| name.eq_ignore_ascii_case("Proxy-Authorization"))
            .map(|(_, value)| value.trim())
    });
    let expected =
        format!("Basic {}", base64::engine::general_purpose::STANDARD.encode(credentials));
    if !auth.is_some_and(|provided| constant_time_equal(provided.as_bytes(), expected.as_bytes())) {
        socket.write_all(b"HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=cmux\r\nConnection: close\r\n\r\n").await?;
        return Ok(());
    }
    if port == proxy_port {
        socket.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n").await?;
        return serve_websocket_bridge(
            socket,
            client,
            workspace,
            policy,
            websocket_token,
            initial_payload,
        )
        .await;
    }
    if !policy.allowed_hosts.iter().any(|allowed| allowed == &host) {
        socket.write_all(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n").await?;
        return Ok(());
    }
    if port == 0 || port == 1337 {
        socket.write_all(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n").await?;
        return Ok(());
    }
    let route = match tokio::time::timeout_at(
        handshake_deadline,
        client.request(WorkspaceRequest::CreateRoute {
            workspace,
            host: loopback_route_host(&host),
            port,
            policy: RoutePolicy::LoopbackOnly,
        }),
    )
    .await
    .map_err(|_| anyhow!("browser proxy route creation timed out"))??
    {
        WorkspaceResponse::RouteCreated { route, .. } => route,
        _ => return Err(anyhow!("unexpected create-route response")),
    };
    let mut metadata = BTreeMap::new();
    metadata.insert("route".into(), route.0.to_string());
    let stream = match tokio::time::timeout_at(
        handshake_deadline,
        client.multiplexer().open(Service::TcpTunnel, metadata),
    )
    .await
    {
        Ok(Ok(stream)) => stream,
        Ok(Err(error)) => {
            let _ = client.request(WorkspaceRequest::CloseRoute { route }).await;
            return Err(error.into());
        }
        Err(_) => {
            let _ = client.request(WorkspaceRequest::CloseRoute { route }).await;
            return Err(anyhow!("browser proxy tunnel open timed out"));
        }
    };
    let opened = match tokio::time::timeout_at(handshake_deadline, stream.receive()).await {
        Ok(Ok(Some(opened))) => opened,
        Ok(Ok(None)) => {
            let _ = stream.close().await;
            let _ = client.request(WorkspaceRequest::CloseRoute { route }).await;
            return Err(anyhow!("tunnel closed during open"));
        }
        Ok(Err(error)) => {
            let _ = stream.close().await;
            let _ = client.request(WorkspaceRequest::CloseRoute { route }).await;
            return Err(error.into());
        }
        Err(_) => {
            let _ = stream.close().await;
            let _ = client.request(WorkspaceRequest::CloseRoute { route }).await;
            return Err(anyhow!("browser proxy tunnel handshake timed out"));
        }
    };
    let opened_ok = serde_json::from_slice::<ServiceControl>(&opened.payload)
        .map(|control| control == (ServiceControl::Opened { service: Service::TcpTunnel }))
        .unwrap_or(false);
    if !opened_ok {
        let _ = stream.close().await;
        let _ = client.request(WorkspaceRequest::CloseRoute { route }).await;
        return Err(anyhow!("tunnel did not open"));
    }
    if let Err(error) = socket.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n").await {
        let _ = stream.close().await;
        let _ = client.request(WorkspaceRequest::CloseRoute { route }).await;
        return Err(error.into());
    }
    let (mut reader, mut writer) = socket.into_split();
    let stream = Arc::new(stream);
    if !initial_payload.is_empty()
        && let Err(error) = stream.send(Bytes::from(initial_payload)).await
    {
        let _ = stream.close().await;
        let _ = client.request(WorkspaceRequest::CloseRoute { route }).await;
        return Err(error.into());
    }
    let upload = async {
        let mut buffer = [0_u8; 16 * 1024];
        loop {
            let read = AsyncReadExt::read(&mut reader, &mut buffer).await?;
            if read == 0 {
                stream.close().await?;
                return Ok::<(), anyhow::Error>(());
            }
            stream.send(Bytes::copy_from_slice(&buffer[..read])).await?;
        }
    };
    let download = async {
        while let Some(chunk) = stream.receive().await? {
            writer.write_all(&chunk.payload).await?;
            if chunk.finished {
                break;
            }
        }
        writer.shutdown().await?;
        Ok::<(), anyhow::Error>(())
    };
    tokio::pin!(upload);
    tokio::pin!(download);
    let relay_result = tokio::select! {
        result = &mut upload => {
            match result {
                Ok(()) => (&mut download).await,
                Err(error) => Err(error),
            }
        },
        result = &mut download => result,
    };
    let _ = stream.close().await;
    let _ = client.request(WorkspaceRequest::CloseRoute { route }).await;
    relay_result
}

async fn serve_websocket_bridge(
    mut socket: TcpStream,
    client: Arc<WorkspaceClient>,
    workspace: cmux_remote_protocol::WorkspaceId,
    policy: Arc<BrowserProxyPolicy>,
    websocket_token: String,
    initial_payload: Vec<u8>,
) -> anyhow::Result<()> {
    let deadline = tokio::time::Instant::now() + BROWSER_PROXY_HEADER_TIMEOUT;
    let (request, pending) = read_http_headers(&mut socket, deadline, initial_payload).await?;
    let mut lines = request.split("\r\n");
    let request_line = lines.next().ok_or_else(|| anyhow!("missing WebSocket request line"))?;
    let mut request_parts = request_line.split_whitespace();
    if request_parts.next() != Some("GET") {
        return Err(anyhow!("WebSocket bridge requires GET"));
    }
    let target = request_parts.next().ok_or_else(|| anyhow!("missing WebSocket target"))?;
    let version = request_parts.next().unwrap_or("HTTP/1.1");
    let prefix = "/__cmux_ws__/";
    let encoded =
        target.strip_prefix(prefix).ok_or_else(|| anyhow!("invalid WebSocket bridge path"))?;
    let (authority, path) = encoded.split_once('/').unwrap_or((encoded, ""));
    let (host, port) = parse_connect_authority_with_loopback(authority, policy.allow_loopback)?;
    if !policy.allowed_hosts.iter().any(|allowed| allowed == &host) || port == 0 || port == 1337 {
        return Err(anyhow!("WebSocket bridge target is not allowed"));
    }
    let protocol_header = lines
        .clone()
        .find_map(|line| {
            line.split_once(':')
                .filter(|(name, _)| name.eq_ignore_ascii_case("sec-websocket-protocol"))
                .map(|(_, value)| value.trim())
        })
        .unwrap_or("");
    let auth_protocol = format!("cmux-proxy-{websocket_token}");
    if !protocol_header
        .split(',')
        .any(|value| constant_time_equal(value.trim().as_bytes(), auth_protocol.as_bytes()))
    {
        return Err(anyhow!("WebSocket bridge authentication failed"));
    }

    let route = match tokio::time::timeout_at(
        deadline,
        client.request(WorkspaceRequest::CreateRoute {
            workspace: workspace.clone(),
            host: loopback_route_host(&host),
            port,
            policy: RoutePolicy::LoopbackOnly,
        }),
    )
    .await
    .map_err(|_| anyhow!("WebSocket route creation timed out"))??
    {
        WorkspaceResponse::RouteCreated { route, .. } => route,
        _ => return Err(anyhow!("unexpected WebSocket route response")),
    };
    let mut metadata = BTreeMap::new();
    metadata.insert("route".into(), route.0.to_string());
    let stream = match tokio::time::timeout_at(
        deadline,
        client.multiplexer().open(Service::TcpTunnel, metadata),
    )
    .await
    {
        Ok(Ok(stream)) => stream,
        Ok(Err(error)) => {
            let _ = client.request(WorkspaceRequest::CloseRoute { route }).await;
            return Err(error.into());
        }
        Err(_) => {
            let _ = client.request(WorkspaceRequest::CloseRoute { route }).await;
            return Err(anyhow!("WebSocket tunnel open timed out"));
        }
    };
    let opened = match tokio::time::timeout_at(deadline, stream.receive()).await {
        Ok(Ok(Some(opened))) => opened,
        _ => {
            let _ = stream.close().await;
            let _ = client.request(WorkspaceRequest::CloseRoute { route }).await;
            return Err(anyhow!("WebSocket tunnel did not open"));
        }
    };
    let opened_ok = serde_json::from_slice::<ServiceControl>(&opened.payload)
        .map(|control| control == (ServiceControl::Opened { service: Service::TcpTunnel }))
        .unwrap_or(false);
    if !opened_ok {
        let _ = stream.close().await;
        let _ = client.request(WorkspaceRequest::CloseRoute { route }).await;
        return Err(anyhow!("WebSocket tunnel control was invalid"));
    }

    let mut upstream_request = format!("GET /{path} {version}\r\n");
    for line in lines {
        if line.is_empty() {
            continue;
        }
        let lower = line.to_ascii_lowercase();
        if lower.starts_with("host:") || lower.starts_with("proxy-authorization:") {
            continue;
        }
        if lower.starts_with("sec-websocket-protocol:") {
            let protocols = application_protocols(protocol_header, &auth_protocol);
            if !protocols.is_empty() {
                upstream_request.push_str(&format!("Sec-WebSocket-Protocol: {protocols}\r\n"));
            }
            continue;
        }
        upstream_request.push_str(line);
        upstream_request.push_str("\r\n");
    }
    upstream_request.push_str(&format!("Host: {host}:{port}\r\n\r\n"));
    let stream = Arc::new(stream);
    let result = async {
    stream.send(Bytes::from(upstream_request)).await?;
    if !pending.is_empty() { stream.send(Bytes::from(pending)).await?; }
    let mut response_data = Vec::with_capacity(2048);
    while !response_data.windows(4).any(|window| window == b"\r\n\r\n") {
        let chunk = tokio::time::timeout_at(deadline, stream.receive())
            .await??
            .ok_or_else(|| anyhow!("WebSocket response closed"))?;
        response_data.extend_from_slice(&chunk.payload);
        if !response_data.windows(4).any(|part| part == b"\r\n\r\n") && response_data.len() > 32 * 1024 {
            return Err(anyhow!("WebSocket response headers too large"));
        }
    }
    let (response, pending_response) = split_http_headers(response_data)?;
    if !response.starts_with("HTTP/1.1 101") && !response.starts_with("HTTP/1.0 101") {
        return Err(anyhow!("remote WebSocket did not switch protocols"));
    }
    // The browser sees only the upstream-selected application protocol. Returning
    // the authentication token here corrupts WebSocket.protocol for real websites.
    socket.write_all(response.as_bytes()).await?;
    socket.write_all(&pending_response).await?;
    let (mut reader, mut writer) = socket.into_split();
    let upload = async {
        let mut buffer = [0_u8; 16 * 1024];
        loop {
            let read = reader.read(&mut buffer).await?;
            if read == 0 {
                stream.close().await?;
                return Ok::<(), anyhow::Error>(());
            }
            stream.send(Bytes::copy_from_slice(&buffer[..read])).await?;
        }
    };
    let download = async {
        while let Some(chunk) = stream.receive().await? {
            writer.write_all(&chunk.payload).await?;
            if chunk.finished {
                break;
            }
        }
        writer.shutdown().await?;
        Ok::<(), anyhow::Error>(())
    };
    tokio::pin!(upload);
    tokio::pin!(download);
    tokio::select! { result = &mut upload => { match result { Ok(()) => (&mut download).await, Err(error) => Err(error) } }, result = &mut download => result }
    }.await;
    let _ = stream.close().await;
    let _ = client.request(WorkspaceRequest::CloseRoute { route }).await;
    result
}

async fn read_http_headers(
    socket: &mut TcpStream,
    deadline: tokio::time::Instant,
    initial_payload: Vec<u8>,
) -> anyhow::Result<(String, Vec<u8>)> {
    let mut data = initial_payload;
    let mut buffer = [0_u8; 2048];
    while !data.windows(4).any(|window| window == b"\r\n\r\n") {
        let read = tokio::time::timeout_at(deadline, socket.read(&mut buffer)).await??;
        if read == 0 {
            return Err(anyhow!("invalid WebSocket headers"));
        }
        data.extend_from_slice(&buffer[..read]);
        if !data.windows(4).any(|part| part == b"\r\n\r\n") && data.len() > 32 * 1024 {
            return Err(anyhow!("WebSocket headers too large"));
        }
    }
    split_http_headers(data)
}

fn split_http_headers(data: Vec<u8>) -> anyhow::Result<(String, Vec<u8>)> {
    let end = data
        .windows(4)
        .position(|part| part == b"\r\n\r\n")
        .ok_or_else(|| anyhow!("incomplete WebSocket headers"))?
        + 4;
    if end > 32 * 1024 {
        return Err(anyhow!("WebSocket headers too large"));
    }
    let header = std::str::from_utf8(&data[..end])
        .map_err(|_| anyhow!("WebSocket headers were not UTF-8"))?
        .to_owned();
    Ok((header, data[end..].to_vec()))
}

fn application_protocols(header: &str, authentication: &str) -> String {
    header
        .split(',')
        .map(str::trim)
        .filter(|p| !p.is_empty() && *p != authentication)
        .collect::<Vec<_>>()
        .join(", ")
}

pub(super) fn parse_connect_authority_with_loopback(
    authority: &str,
    allow_loopback: bool,
) -> anyhow::Result<(String, u16)> {
    let (host, port) = if let Some(rest) = authority.strip_prefix('[') {
        let end = rest.find(']').ok_or_else(|| anyhow!("invalid CONNECT authority"))?;
        let host = &rest[..end];
        let port =
            rest[end + 1..].strip_prefix(':').ok_or_else(|| anyhow!("CONNECT port is required"))?;
        (host, port)
    } else {
        authority.rsplit_once(':').ok_or_else(|| anyhow!("CONNECT port is required"))?
    };
    let host = normalize_proxy_host(host, allow_loopback)?;
    let port = port.parse::<u16>().map_err(|_| anyhow!("invalid CONNECT port"))?;
    Ok((host, port))
}

/// Cloud advertises a private address as the browser identity, while the
/// authenticated route must still dial the guest loopback interface. SSH
/// loopback authorities remain unchanged so IPv6-only services keep working.
fn loopback_route_host(host: &str) -> String {
    host.parse::<std::net::IpAddr>()
        .ok()
        .filter(std::net::IpAddr::is_loopback)
        .map_or_else(|| "127.0.0.1".into(), |address| address.to_string())
}

fn constant_time_equal(left: &[u8], right: &[u8]) -> bool {
    let mut difference = left.len() ^ right.len();
    let length = left.len().max(right.len());
    for index in 0..length {
        let left_byte = left.get(index).copied().unwrap_or(0);
        let right_byte = right.get(index).copied().unwrap_or(0);
        difference |= usize::from(left_byte ^ right_byte);
    }
    difference == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn websocket_protocols_preserve_application_negotiation_without_proxy_secret() {
        assert_eq!(
            application_protocols(
                "graphql-transport-ws, chat, cmux-proxy-secret",
                "cmux-proxy-secret"
            ),
            "graphql-transport-ws, chat"
        );
        assert_eq!(application_protocols("cmux-proxy-secret", "cmux-proxy-secret"), "");
    }

    #[test]
    fn websocket_binary_frames_follow_upgrade_without_utf8_decoding() {
        let headers = b"HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Protocol: chat\r\n\r\n";
        let frame = [0x82, 0x03, 0xff, 0xfe, 0x00];
        let (parsed, remainder) =
            split_http_headers([headers.as_slice(), &frame].concat()).unwrap();
        assert_eq!(parsed.as_bytes(), headers);
        assert_eq!(remainder, frame);
        let large_frame = vec![0xff; 65536];
        let (_, remainder) =
            split_http_headers([headers.as_slice(), &large_frame].concat()).unwrap();
        assert_eq!(remainder, large_frame);
        assert!(split_http_headers(b"HTTP/1.1 101\r\n".to_vec()).is_err());
    }

    use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

    use cmux_remote::service::{EndpointRole, ServiceError, ServiceMultiplexer, SessionEndpoint};
    use cmux_remote::services::MessageStream;
    use cmux_remote::session::ReceivedFrame;
    use cmux_remote::workspace::WorkspaceService;
    use cmux_remote_protocol::{FrameFlags, Lane, RouteId, RpcRequest, WorkspaceId};
    use tokio::sync::{Mutex, mpsc, watch};

    // The public mux runs over in-memory frames; the workspace policy and TCP
    // dials are real, so an accepted browser identity cannot fake route success.
    struct TestEndpoint {
        outgoing: mpsc::Sender<ReceivedFrame>,
        incoming: Mutex<mpsc::Receiver<ReceivedFrame>>,
        sequence: AtomicU64,
        generation: watch::Sender<u64>,
    }

    #[async_trait::async_trait]
    impl SessionEndpoint for TestEndpoint {
        async fn send_frame(
            &self, _: Option<u64>, lane: Lane, stream: u64, payload: Bytes, flags: FrameFlags,
        ) -> Result<u64, ServiceError> {
            let sequence = self.sequence.fetch_add(1, Ordering::Relaxed) + 1;
            self.outgoing
                .send(ReceivedFrame { generation: 0, lane, stream, sequence, flags, payload })
                .await
                .map_err(|_| ServiceError::Closed)?;
            Ok(sequence)
        }

        async fn receive_frame(&self) -> Result<Option<ReceivedFrame>, ServiceError> {
            Ok(self.incoming.lock().await.recv().await)
        }

        fn subscribe_generation(&self) -> watch::Receiver<u64> { self.generation.subscribe() }
        async fn close_session(&self) -> Result<(), ServiceError> { Ok(()) }
    }

    struct ProxyFixture {
        client: Arc<WorkspaceClient>,
        workspace: WorkspaceId,
        routes: Arc<AtomicUsize>,
        mux: Arc<ServiceMultiplexer>,
        daemon_mux: Arc<ServiceMultiplexer>,
        server: tokio::task::JoinHandle<()>,
        _root: tempfile::TempDir,
    }

    impl ProxyFixture {
        async fn new() -> Self {
            let (left_tx, left_rx) = mpsc::channel(64);
            let (right_tx, right_rx) = mpsc::channel(64);
            let endpoint = |outgoing, incoming| Arc::new(TestEndpoint {
                outgoing, incoming: Mutex::new(incoming), sequence: AtomicU64::new(0),
                generation: watch::channel(0).0,
            });
            let mux = ServiceMultiplexer::new(endpoint(left_tx, right_rx), EndpointRole::Client);
            let daemon_mux = ServiceMultiplexer::new(endpoint(right_tx, left_rx), EndpointRole::Daemon);
            let routes = Arc::new(AtomicUsize::new(0));
            let service = WorkspaceService::new();
            let server = tokio::task::spawn_local({
                let daemon = daemon_mux.clone();
                let routes = routes.clone();
                async move {
                    let mut tasks = tokio::task::JoinSet::new();
                    while let Some(incoming) = daemon.accept().await.unwrap() {
                        let service = service.clone();
                        let routes = routes.clone();
                        tasks.spawn_local(async move {
                            let lane = match incoming.metadata.get("lane").map(String::as_str) {
                                Some("interactive") => Lane::Interactive,
                                Some("bulk") => Lane::Bulk,
                                _ => Lane::Control,
                            };
                            let stream = Arc::new(incoming.stream);
                            if incoming.service == Service::WorkspaceRpc {
                                stream.send_on(lane, Bytes::from(serde_json::to_vec(
                                    &ServiceControl::Opened { service: Service::WorkspaceRpc },
                                ).unwrap())).await.unwrap();
                                let messages = MessageStream::with_lane(stream, lane);
                                while let Some(bytes) = messages.receive().await.unwrap() {
                                    let request: RpcRequest = serde_json::from_slice(&bytes).unwrap();
                                    if let WorkspaceRequest::CreateRoute { policy, .. } = &request.request {
                                        assert_eq!(*policy, RoutePolicy::LoopbackOnly);
                                        routes.fetch_add(1, Ordering::SeqCst);
                                    }
                                    let response = service.handle_rpc(request).await;
                                    messages.send(&serde_json::to_vec(&response).unwrap()).await.unwrap();
                                }
                            } else {
                                assert_eq!(incoming.service, Service::TcpTunnel);
                                let route = RouteId(incoming.metadata["route"].parse().unwrap());
                                let socket = service.dial_route(route).await.unwrap();
                                stream.send(Bytes::from(serde_json::to_vec(
                                    &ServiceControl::Opened { service: Service::TcpTunnel },
                                ).unwrap())).await.unwrap();
                                let (mut reader, mut writer) = socket.into_split();
                                let upload = async {
                                    while let Some(chunk) = stream.receive().await.unwrap() {
                                        writer.write_all(&chunk.payload).await.unwrap();
                                        if chunk.finished { break; }
                                    }
                                    writer.shutdown().await.unwrap();
                                };
                                let download = async {
                                    let mut buffer = [0; 2048];
                                    loop {
                                        let size = reader.read(&mut buffer).await.unwrap();
                                        if size == 0 { break; }
                                        stream.send(Bytes::copy_from_slice(&buffer[..size])).await.unwrap();
                                    }
                                    stream.close().await.unwrap();
                                };
                                tokio::join!(upload, download);
                            }
                        });
                    }
                }
            });
            let client = WorkspaceClient::connect(mux.clone()).await.unwrap();
            let root = tempfile::tempdir().unwrap();
            let WorkspaceResponse::Workspace { id: workspace, .. } = client.request(
                WorkspaceRequest::OpenWorkspace { root: root.path().to_string_lossy().into_owned() },
            ).await.unwrap() else { panic!("workspace was not opened") };
            Self { client, workspace, routes, mux, daemon_mux, server, _root: root }
        }

        async fn request(&self, policy: BrowserProxyPolicy, request: String) -> (Vec<u8>, bool) {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let mut browser = TcpStream::connect(listener.local_addr().unwrap()).await.unwrap();
            let (socket, _) = listener.accept().await.unwrap();
            let proxy = serve_browser_connection(
                socket, self.client.clone(), self.workspace.clone(), Arc::new(policy),
                "fixture:password".into(), "fixture-token".into(), port,
            );
            let exchange = async {
                browser.write_all(request.as_bytes()).await.unwrap();
                let mut response = Vec::new();
                browser.read_to_end(&mut response).await.unwrap();
                response
            };
            let (result, response) = tokio::join!(proxy, exchange);
            (response, result.is_ok())
        }

        async fn close(self) {
            self.server.abort();
            let _ = self.server.await;
            self.mux.shutdown().await;
            self.daemon_mux.shutdown().await;
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn browser_proxy_dials_guest_loopback_for_cloud_and_retains_ssh_ipv6() {
        tokio::task::LocalSet::new().run_until(async {
            tokio::time::timeout(Duration::from_secs(10), async {
                let fixture = ProxyFixture::new().await;
                for (host, bind, allow_loopback) in [
                    ("10.42.0.7", "127.0.0.1:0", false),
                    ("fd12::7", "127.0.0.1:0", false),
                    ("::1", "[::1]:0", true),
                ] {
                    for websocket in [false, true] {
                        let listener = TcpListener::bind(bind).await.unwrap();
                        let port = listener.local_addr().unwrap().port();
                        let authority = if host.contains(':') { format!("[{host}]:{port}") }
                            else { format!("{host}:{port}") };
                        let target = async {
                            let (mut socket, _) = listener.accept().await.unwrap();
                            if websocket {
                                let (headers, _) = read_http_headers(&mut socket,
                                    tokio::time::Instant::now() + Duration::from_secs(5), Vec::new())
                                    .await.unwrap();
                                assert!(headers.contains(&format!("Host: {host}:{port}\r\n")));
                                assert!(!headers.contains("fixture-token"));
                                socket.write_all(b"HTTP/1.1 101 Switching Protocols\r\n\r\n").await.unwrap();
                            }
                            socket.write_all(b"guest-payload").await.unwrap();
                            socket.shutdown().await.unwrap();
                        };
                        let request = if websocket {
                            format!("GET /__cmux_ws__/{authority}/socket HTTP/1.1\r\nSec-WebSocket-Protocol: cmux-proxy-fixture-token\r\n\r\n")
                        } else {
                            let auth = base64::engine::general_purpose::STANDARD.encode("fixture:password");
                            format!("CONNECT {authority} HTTP/1.1\r\nProxy-Authorization: Basic {auth}\r\n\r\n")
                        };
                        let policy = BrowserProxyPolicy { allowed_hosts: vec![host.into()], allow_loopback };
                        let ((), (response, ok)) = tokio::join!(target, fixture.request(policy, request));
                        assert!(ok, "proxy rejected {authority}");
                        let expected = if websocket { "HTTP/1.1 101" } else { "HTTP/1.1 200" };
                        assert!(response.starts_with(expected.as_bytes()));
                        assert!(response.ends_with(b"guest-payload"));
                    }
                }
                assert_eq!(fixture.routes.load(Ordering::SeqCst), 6);
                fixture.close().await;
            }).await.expect("browser proxy loopback round trip timed out");
        }).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn browser_proxy_denies_untrusted_requests_before_creating_routes() {
        tokio::task::LocalSet::new().run_until(async {
            tokio::time::timeout(Duration::from_secs(5), async {
                let fixture = ProxyFixture::new().await;
                let auth = base64::engine::general_purpose::STANDARD.encode("fixture:password");
                for (authority, credentials, status) in [
                    ("10.42.0.7:3000", "", "407"),
                    ("10.42.0.7:3000", "invalid", "407"),
                    ("10.42.0.8:3000", auth.as_str(), "403"),
                    ("10.42.0.7:1337", auth.as_str(), "403"),
                ] {
                    let policy = BrowserProxyPolicy { allowed_hosts: vec!["10.42.0.7".into()], allow_loopback: false };
                    let request = format!("CONNECT {authority} HTTP/1.1\r\nProxy-Authorization: Basic {credentials}\r\n\r\n");
                    let (response, ok) = fixture.request(policy, request).await;
                    assert!(ok);
                    assert!(response.starts_with(format!("HTTP/1.1 {status}").as_bytes()));
                }
                for (authority, token) in [
                    ("10.42.0.7:3000", "wrong-token"),
                    ("10.42.0.8:3000", "fixture-token"),
                    ("10.42.0.7:1337", "fixture-token"),
                ] {
                    let policy = BrowserProxyPolicy { allowed_hosts: vec!["10.42.0.7".into()], allow_loopback: false };
                    let request = format!("GET /__cmux_ws__/{authority}/socket HTTP/1.1\r\nSec-WebSocket-Protocol: cmux-proxy-{token}\r\n\r\n");
                    let (response, ok) = fixture.request(policy, request).await;
                    assert!(!ok);
                    assert!(response.is_empty());
                }
                assert_eq!(fixture.routes.load(Ordering::SeqCst), 0);
                fixture.close().await;
            }).await.expect("browser proxy refusal timed out");
        }).await;
    }
}
