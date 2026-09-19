//! Authenticated per-VM SOCKS5 proxy over the cmux remote TCP tunnel.

use std::collections::BTreeMap;
use std::io::{self, Write};
use std::sync::Arc;
use std::time::Duration;

use anyhow::anyhow;
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
    owner: u32,
}

pub(super) fn parse_browser_proxy_args(args: &[String]) -> anyhow::Result<BrowserProxyArgs> {
    let mut connect = Vec::new();
    let mut allowed_hosts = Vec::new();
    let mut workspace_root = None;
    let mut index = 0;
    while index < args.len() {
        let argument = &args[index];
        match argument.as_str() {
            "--allowed-host" => {
                let value =
                    args.get(index + 1).ok_or_else(|| anyhow!("--allowed-host needs a value"))?;
                allowed_hosts.push(normalize_proxy_host(value)?);
                index += 2;
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
        owner: super::current_parent_process_id(),
    })
}

fn normalize_proxy_host(value: &str) -> anyhow::Result<String> {
    let value = value.trim();
    let value = value.strip_prefix('[').and_then(|value| value.strip_suffix(']')).unwrap_or(value);
    let ip = value
        .parse::<std::net::IpAddr>()
        .map_err(|_| anyhow!("--allowed-host must be an IP address"))?;
    if ip.is_unspecified() || ip.is_multicast() || ip.is_loopback() {
        return Err(anyhow!("--allowed-host must be a private VM address"));
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
    let allowed_hosts = Arc::new(parsed.allowed_hosts);
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
                let allowed_hosts = allowed_hosts.clone();
                let credentials = credentials.clone();
                let workspace = workspace.clone();
                let websocket_token = websocket_token.clone();
                tasks.spawn(async move {
                    let _ = serve_browser_connection(socket, client, workspace, allowed_hosts, credentials, websocket_token).await;
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
    mut socket: TcpStream,
    client: Arc<WorkspaceClient>,
    workspace: cmux_remote_protocol::WorkspaceId,
    allowed_hosts: Arc<Vec<String>>,
    credentials: String,
    websocket_token: String,
) -> anyhow::Result<()> {
    let mut first = [0_u8; 1];
    socket.peek(&mut first).await?;
    if first[0] == b'G' {
        return serve_websocket_bridge(socket, client, workspace, allowed_hosts, websocket_token)
            .await;
    }
    serve_socks5_connection(socket, client, workspace, allowed_hosts, credentials).await
}

async fn serve_socks5_connection(
    mut socket: TcpStream,
    client: Arc<WorkspaceClient>,
    workspace: cmux_remote_protocol::WorkspaceId,
    allowed_hosts: Arc<Vec<String>>,
    credentials: String,
) -> anyhow::Result<()> {
    let deadline = tokio::time::Instant::now() + BROWSER_PROXY_HEADER_TIMEOUT;
    let mut byte = [0_u8; 1];
    tokio::time::timeout_at(deadline, socket.read_exact(&mut byte)).await??;
    if byte[0] != 0x05 {
        return Err(anyhow!("browser proxy requires SOCKS5"));
    }

    let mut count = [0_u8; 1];
    read_exact_until(&mut socket, &mut count, deadline).await?;
    let mut methods = vec![0_u8; count[0] as usize];
    read_exact_until(&mut socket, &mut methods, deadline).await?;
    if !methods.contains(&0x02) {
        socket.write_all(&[0x05, 0xff]).await?;
        return Err(anyhow!(
            "browser proxy client does not offer username/password authentication"
        ));
    }
    socket.write_all(&[0x05, 0x02]).await?;

    let mut auth_header = [0_u8; 2];
    read_exact_until(&mut socket, &mut auth_header, deadline).await?;
    if auth_header[0] != 0x01 {
        return Err(anyhow!("unsupported SOCKS5 authentication version"));
    }
    let mut username = vec![0_u8; auth_header[1] as usize];
    read_exact_until(&mut socket, &mut username, deadline).await?;
    let mut password_length = [0_u8; 1];
    read_exact_until(&mut socket, &mut password_length, deadline).await?;
    let mut password = vec![0_u8; password_length[0] as usize];
    read_exact_until(&mut socket, &mut password, deadline).await?;
    let (expected_username, expected_password) =
        credentials.split_once(':').ok_or_else(|| anyhow!("invalid browser proxy credentials"))?;
    if username.as_slice() != expected_username.as_bytes()
        || password.as_slice() != expected_password.as_bytes()
    {
        socket.write_all(&[0x01, 0x01]).await?;
        return Err(anyhow!("browser proxy authentication failed"));
    }
    socket.write_all(&[0x01, 0x00]).await?;

    let mut request_header = [0_u8; 4];
    read_exact_until(&mut socket, &mut request_header, deadline).await?;
    if request_header[0] != 0x05 || request_header[1] != 0x01 || request_header[2] != 0x00 {
        send_socks_failure(&mut socket, 0x07).await?;
        return Err(anyhow!("browser proxy only supports SOCKS5 CONNECT"));
    }
    let host = match request_header[3] {
        0x01 => {
            let mut bytes = [0_u8; 4];
            read_exact_until(&mut socket, &mut bytes, deadline).await?;
            std::net::Ipv4Addr::from(bytes).to_string()
        }
        0x04 => {
            let mut bytes = [0_u8; 16];
            read_exact_until(&mut socket, &mut bytes, deadline).await?;
            std::net::Ipv6Addr::from(bytes).to_string()
        }
        _ => {
            send_socks_failure(&mut socket, 0x08).await?;
            return Err(anyhow!("browser proxy only accepts literal VM addresses"));
        }
    };
    let mut port_bytes = [0_u8; 2];
    read_exact_until(&mut socket, &mut port_bytes, deadline).await?;
    let port = u16::from_be_bytes(port_bytes);
    if !allowed_hosts.iter().any(|allowed| allowed == &host) {
        send_socks_failure(&mut socket, 0x02).await?;
        return Err(anyhow!("browser proxy target is not an allowed VM address"));
    }
    if port == 0 || port == 1337 {
        send_socks_failure(&mut socket, 0x02).await?;
        return Err(anyhow!("browser proxy target port is not allowed"));
    }

    let route = match tokio::time::timeout_at(
        deadline,
        client.request(WorkspaceRequest::CreateRoute {
            workspace: workspace.clone(),
            host: "127.0.0.1".into(),
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
            return Err(anyhow!("browser proxy tunnel open timed out"));
        }
    };
    let opened = match tokio::time::timeout_at(deadline, stream.receive()).await {
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
    socket.write_all(&[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;

    let (mut reader, mut writer) = socket.into_split();
    let stream = Arc::new(stream);
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

async fn read_exact_until(
    socket: &mut TcpStream,
    bytes: &mut [u8],
    deadline: tokio::time::Instant,
) -> anyhow::Result<()> {
    tokio::time::timeout_at(deadline, socket.read_exact(bytes)).await??;
    Ok(())
}

async fn serve_websocket_bridge(
    mut socket: TcpStream,
    client: Arc<WorkspaceClient>,
    workspace: cmux_remote_protocol::WorkspaceId,
    allowed_hosts: Arc<Vec<String>>,
    websocket_token: String,
) -> anyhow::Result<()> {
    let deadline = tokio::time::Instant::now() + BROWSER_PROXY_HEADER_TIMEOUT;
    let request = read_http_headers(&mut socket, deadline).await?;
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
    let (host, port) = parse_connect_authority(authority)?;
    if !allowed_hosts.iter().any(|allowed| allowed == &host) || port == 0 || port == 1337 {
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
    if !protocol_header.split(',').any(|value| value.trim() == auth_protocol) {
        return Err(anyhow!("WebSocket bridge authentication failed"));
    }

    let route = match tokio::time::timeout_at(
        deadline,
        client.request(WorkspaceRequest::CreateRoute {
            workspace: workspace.clone(),
            host: "127.0.0.1".into(),
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
        if lower.starts_with("host:") || lower.starts_with("sec-websocket-protocol:") {
            continue;
        }
        upstream_request.push_str(line);
        upstream_request.push_str("\r\n");
    }
    upstream_request.push_str(&format!("Host: {host}:{port}\r\n\r\n"));
    let stream = Arc::new(stream);
    stream.send(Bytes::from(upstream_request)).await?;
    let mut response_data = Vec::with_capacity(2048);
    while !response_data.windows(4).any(|window| window == b"\r\n\r\n") {
        let chunk = tokio::time::timeout_at(deadline, stream.receive())
            .await??
            .ok_or_else(|| anyhow!("WebSocket response closed"))?;
        response_data.extend_from_slice(&chunk.payload);
        if response_data.len() > 32 * 1024 {
            return Err(anyhow!("WebSocket response headers too large"));
        }
    }
    let response = String::from_utf8(response_data)
        .map_err(|_| anyhow!("WebSocket response was not UTF-8"))?;
    if !response.starts_with("HTTP/1.1 101") && !response.starts_with("HTTP/1.0 101") {
        let _ = stream.close().await;
        let _ = client.request(WorkspaceRequest::CloseRoute { route }).await;
        return Err(anyhow!("remote WebSocket did not switch protocols"));
    }
    let response =
        response.replacen("\r\n", &format!("\r\nSec-WebSocket-Protocol: {auth_protocol}\r\n"), 1);
    socket.write_all(response.as_bytes()).await?;
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
    let result = tokio::select! { result = &mut upload => { match result { Ok(()) => (&mut download).await, Err(error) => Err(error) } }, result = &mut download => result };
    let _ = stream.close().await;
    let _ = client.request(WorkspaceRequest::CloseRoute { route }).await;
    result
}

async fn read_http_headers(
    socket: &mut TcpStream,
    deadline: tokio::time::Instant,
) -> anyhow::Result<String> {
    let mut data = Vec::with_capacity(2048);
    let mut buffer = [0_u8; 2048];
    while !data.windows(4).any(|window| window == b"\r\n\r\n") {
        let read = tokio::time::timeout_at(deadline, socket.read(&mut buffer)).await??;
        if read == 0 || data.len() + read > 32 * 1024 {
            return Err(anyhow!("invalid WebSocket headers"));
        }
        data.extend_from_slice(&buffer[..read]);
    }
    Ok(String::from_utf8(data).map_err(|_| anyhow!("WebSocket headers were not UTF-8"))?)
}

async fn send_socks_failure(socket: &mut TcpStream, code: u8) -> anyhow::Result<()> {
    socket.write_all(&[0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
    Ok(())
}

#[cfg(test)]
pub(super) fn parse_connect_authority(authority: &str) -> anyhow::Result<(String, u16)> {
    let (host, port) = if let Some(rest) = authority.strip_prefix('[') {
        let end = rest.find(']').ok_or_else(|| anyhow!("invalid CONNECT authority"))?;
        let host = &rest[..end];
        let port =
            rest[end + 1..].strip_prefix(':').ok_or_else(|| anyhow!("CONNECT port is required"))?;
        (host, port)
    } else {
        authority.rsplit_once(':').ok_or_else(|| anyhow!("CONNECT port is required"))?
    };
    let host = normalize_proxy_host(host)?;
    let port = port.parse::<u16>().map_err(|_| anyhow!("invalid CONNECT port"))?;
    Ok((host, port))
}
