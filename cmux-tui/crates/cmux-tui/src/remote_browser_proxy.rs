//! Authenticated per-VM HTTP CONNECT proxy over the cmux remote TCP tunnel.

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
use tokio::io::AsyncWriteExt;
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
    println!(
        "{}",
        serde_json::json!({"event":"browser-proxy-ready","host":"127.0.0.1","port":address.port(),"username":username,"password":password})
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
                tasks.spawn(async move {
                    let _ = serve_browser_connection(socket, client, workspace, allowed_hosts, credentials).await;
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
) -> anyhow::Result<()> {
    let handshake_deadline = tokio::time::Instant::now() + BROWSER_PROXY_HEADER_TIMEOUT;
    let mut request = Vec::with_capacity(4096);
    let mut buffer = [0_u8; 1024];
    let header_end = loop {
        let read = tokio::time::timeout_at(
            handshake_deadline,
            tokio::io::AsyncReadExt::read(&mut socket, &mut buffer),
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
    let (host, port) = parse_connect_authority(target)?;
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
    if !allowed_hosts.iter().any(|allowed| allowed == &host) {
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
            let read = tokio::io::AsyncReadExt::read(&mut reader, &mut buffer).await?;
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
