use std::{
    convert::Infallible,
    future::Future,
    net::SocketAddr,
    str::FromStr,
    time::Duration,
};

use futures_util::future;
use hyper::client::HttpConnector;
use hyper::header::{CONNECTION, UPGRADE};
use hyper::server::conn::AddrStream;
use hyper::service::{make_service_fn, service_fn};
use hyper::{
    body::Body,
    client::Client,
    http::{HeaderMap, HeaderValue, Method, Request, Response, StatusCode, Uri},
};
use tokio::io::{copy_bidirectional, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::task::{JoinHandle, JoinSet};
use tokio::sync::Notify;
use std::sync::Arc;
use tracing::{error, info, warn};

#[derive(Clone, Debug)]
pub struct ProxyConfig {
    pub listen: SocketAddr,
    pub upstream_host: String,
}

pub fn spawn_proxy<S>(cfg: ProxyConfig, shutdown: S) -> (SocketAddr, JoinHandle<()>)
where
    S: Future<Output = ()> + Send + 'static,
{
    // Hyper client for proxying HTTP/1.1
    let mut connector = HttpConnector::new();
    connector.set_connect_timeout(Some(Duration::from_secs(5)));
    let client: Client<HttpConnector, Body> = Client::builder().pool_max_idle_per_host(8).build(connector);

    let listen = cfg.listen;
    let make_cfg = cfg;
    let make_svc = make_service_fn(move |conn: &AddrStream| {
        let remote_addr = conn.remote_addr();
        let client = client.clone();
        let cfg = make_cfg.clone();
        async move {
            Ok::<_, Infallible>(service_fn(move |req| {
                handle(client.to_owned(), cfg.to_owned(), remote_addr, req)
            }))
        }
    });

    let builder = hyper::Server::bind(&listen).http1_only(true).serve(make_svc);
    let listen_addr = builder.local_addr();
    let server = builder.with_graceful_shutdown(shutdown);

    let handle = tokio::spawn(async move {
        if let Err(err) = server.await {
            error!(%err, "server error");
        }
    });

    (listen_addr, handle)
}

/// Start the proxy on multiple addresses. Returns the bound addresses actually used and a handle
/// that completes when all servers exit (after shutdown is signaled).
pub fn spawn_proxy_multi<S>(listens: Vec<SocketAddr>, upstream_host: String, shutdown: S) -> (Vec<SocketAddr>, JoinHandle<()>)
where
    S: Future<Output = ()> + Send + 'static,
{
    // Prepare shared client and shutdown notifier
    let mut connector = HttpConnector::new();
    connector.set_connect_timeout(Some(Duration::from_secs(5)));
    let client: Client<HttpConnector, Body> = Client::builder().pool_max_idle_per_host(8).build(connector);

    let notify = Arc::new(Notify::new());
    let notify_clone = notify.clone();
    tokio::spawn(async move {
        shutdown.await;
        notify_clone.notify_waiters();
    });

    let mut join_set: JoinSet<()> = JoinSet::new();
    let mut bound_addrs = Vec::new();

    for addr in listens {
        let client = client.clone();
        let upstream = upstream_host.clone();
        let notify = notify.clone();

        let make_svc = make_service_fn(move |conn: &AddrStream| {
            let remote_addr = conn.remote_addr();
            let client = client.clone();
            let upstream = upstream.clone();
            async move {
                Ok::<_, Infallible>(service_fn(move |req| {
                    let cfg = ProxyConfig { listen: addr, upstream_host: upstream.clone() };
                    handle(client.to_owned(), cfg, remote_addr, req)
                }))
            }
        });

        let builder = hyper::Server::bind(&addr).http1_only(true).serve(make_svc);
        let local = builder.local_addr();
        bound_addrs.push(local);
        let server = builder.with_graceful_shutdown(async move {
            notify.notified().await;
        });

        join_set.spawn(async move {
            if let Err(err) = server.await {
                error!(%err, "server error");
            }
        });
    }

    let handle = tokio::spawn(async move {
        while let Some(_res) = join_set.join_next().await {}
    });

    (bound_addrs, handle)
}

fn get_port_from_header(headers: &HeaderMap) -> Result<u16, Response<Body>> {
    const HDR: &str = "X-Cmux-Port-Internal";
    if let Some(val) = headers.get(HDR) {
        let s = val.to_str().map_err(|_| response_with(StatusCode::BAD_REQUEST, format!("{HDR}: invalid header")))?;
        let port = s.parse::<u16>().map_err(|_| response_with(StatusCode::BAD_REQUEST, format!("{HDR}: must be a number 1-65535")))?;
        if port == 0 { return Err(response_with(StatusCode::BAD_REQUEST, format!("{HDR}: must be 1-65535"))); }
        Ok(port)
    } else {
        Err(response_with(StatusCode::BAD_REQUEST, format!("missing required header: {HDR}")))
    }
}

fn upstream_host_from_headers(headers: &HeaderMap, default_host: &str) -> Result<String, Response<Body>> {
    const HDR_WS: &str = "X-Cmux-Workspace-Internal";
    if let Some(val) = headers.get(HDR_WS) {
        let s = val
            .to_str()
            .map_err(|_| response_with(StatusCode::BAD_REQUEST, format!("{HDR_WS}: invalid header")))?;
        // If workspace name ends with digits, use that as index; else, error for now
        if let Some(idx) = s.chars().rev().take_while(|c| c.is_ascii_digit()).collect::<String>().chars().rev().collect::<String>().parse::<u32>().ok() {
            let ip = workspace_ip_from_index(idx);
            Ok(ip.to_string())
        } else {
            Err(response_with(StatusCode::BAD_REQUEST, format!("{HDR_WS}: expected name ending in digits (e.g., workspace-1)")))
        }
    } else {
        Ok(default_host.to_string())
    }
}

fn response_with(status: StatusCode, msg: String) -> Response<Body> {
    Response::builder()
        .status(status)
        .body(Body::from(msg))
        .unwrap_or_else(|_| Response::new(Body::from("internal error")))
}

async fn handle(
    client: Client<HttpConnector, Body>,
    cfg: ProxyConfig,
    remote_addr: SocketAddr,
    req: Request<Body>,
) -> Result<Response<Body>, Infallible> {
    let res = match *req.method() {
        Method::CONNECT => handle_connect(req, &cfg, remote_addr).await,
        _ => handle_http_or_ws(client, cfg, remote_addr, req).await,
    };
    Ok(match res { Ok(r) => r, Err(r) => r })
}

fn workspace_ip_from_index(n: u32) -> std::net::Ipv4Addr {
    let b2 = ((n >> 8) & 0xFF) as u8;
    let b3 = (n & 0xFF) as u8;
    std::net::Ipv4Addr::new(127, 18, b2, b3)
}

pub fn workspace_ip_from_name(name: &str) -> Option<std::net::Ipv4Addr> {
    let digits = name.chars().rev().take_while(|c| c.is_ascii_digit()).collect::<String>();
    if digits.is_empty() { return None; }
    let idx = u32::from_str(&digits.chars().rev().collect::<String>()).ok()?;
    Some(workspace_ip_from_index(idx))
}

async fn handle_http_or_ws(
    client: Client<HttpConnector, Body>,
    cfg: ProxyConfig,
    remote_addr: SocketAddr,
    mut req: Request<Body>,
) -> Result<Response<Body>, Response<Body>> {
    let port = get_port_from_header(req.headers())?;
    let upstream_host = upstream_host_from_headers(req.headers(), &cfg.upstream_host)?;
    let scheme = if req.uri().scheme_str().unwrap_or("") == "https" { "https" } else { "http" };

    // Build the new URI: scheme://upstream_host:port + path_and_query
    let path_and_query = req.uri().path_and_query().map(|pq| pq.as_str()).unwrap_or("/");
    let uri_str = format!("{}://{}:{}{}", scheme, upstream_host, port, path_and_query);
    let new_uri = Uri::from_str(&uri_str).map_err(|_| response_with(StatusCode::BAD_REQUEST, "invalid target URI".into()))?;

    info!(client = %remote_addr, method = %req.method(), path = %req.uri().path(), target = %new_uri, "proxy");

    // If Upgrade request, handle specially
    let is_upgrade = req
        .headers()
        .get(CONNECTION)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_ascii_lowercase().contains("upgrade"))
        .unwrap_or(false)
        && req.headers().contains_key(UPGRADE);

    if is_upgrade {
        return handle_upgrade(client, cfg, remote_addr, req, new_uri).await;
    }

    // Normal HTTP proxy: forward request to upstream and stream response
    *req.uri_mut() = new_uri;
    let resp = client.request(req).await.map_err(|e| response_with(StatusCode::BAD_GATEWAY, format!("upstream error: {}", e)))?;
    Ok(resp)
}

async fn handle_upgrade(
    client: Client<HttpConnector, Body>,
    _cfg: ProxyConfig,
    _remote_addr: SocketAddr,
    mut req: Request<Body>,
    new_uri: Uri,
) -> Result<Response<Body>, Response<Body>> {
    // For upgrades, we perform the handshake with upstream and then tunnel raw bytes between client and upstream
    let (parts, body) = req.into_parts();
    let mut upstream_req = Request::from_parts(parts, body);
    *upstream_req.uri_mut() = new_uri;

    // Make upstream request to establish upgrade
    let upstream_resp = client.request(upstream_req).await.map_err(|e| response_with(StatusCode::BAD_GATEWAY, format!("upgrade upstream error: {}", e)))?;
    if upstream_resp.status() != StatusCode::SWITCHING_PROTOCOLS {
        return Err(response_with(StatusCode::BAD_GATEWAY, format!("upstream did not switch protocols: {}", upstream_resp.status())));
    }

    // Clone headers to send to client, but we must keep upstream_resp for upgrade
    let mut client_resp_builder = Response::builder().status(StatusCode::SWITCHING_PROTOCOLS);
    let out_headers = client_resp_builder.headers_mut().expect("headers_mut available");
    for (k, v) in upstream_resp.headers().iter() {
        out_headers.insert(k, v.clone());
    }
    // Ensure Connection: upgrade and Upgrade headers are present
    out_headers.insert(CONNECTION, HeaderValue::from_static("upgrade"));

    // Prepare response to client (empty body; the connection upgrades)
    let client_resp = client_resp_builder
        .body(Body::empty())
        .map_err(|_| response_with(StatusCode::INTERNAL_SERVER_ERROR, "failed to build upgrade response".into()))?;

    // Spawn tunnel after returning the 101 to the client
    tokio::spawn(async move {
        match future::try_join(hyper::upgrade::on(&mut req), hyper::upgrade::on(upstream_resp)).await {
            Ok((mut client_upgraded, mut upstream_upgraded)) => {
                if let Err(e) = copy_bidirectional(&mut client_upgraded, &mut upstream_upgraded).await {
                    warn!(%e, "upgrade tunnel error");
                }
                // Try to shutdown both sides
                let _ = client_upgraded.shutdown().await;
                let _ = upstream_upgraded.shutdown().await;
            }
            Err(e) => {
                warn!("upgrade error: {:?}", e);
            }
        }
    });

    Ok(client_resp)
}

async fn handle_connect(
    mut req: Request<Body>,
    cfg: &ProxyConfig,
    remote_addr: SocketAddr,
) -> Result<Response<Body>, Response<Body>> {
    let port = get_port_from_header(req.headers())?;
    let upstream_host = upstream_host_from_headers(req.headers(), &cfg.upstream_host)?;
    let target = format!("{}:{}", upstream_host, port);
    info!(client = %remote_addr, %target, "tcp tunnel via CONNECT");

    // Respond that the connection is established; then upgrade to a raw tunnel
    let resp = Response::builder()
        .status(StatusCode::OK)
        .header(CONNECTION, HeaderValue::from_static("upgrade"))
        .body(Body::empty())
        .map_err(|_| response_with(StatusCode::INTERNAL_SERVER_ERROR, "failed to build CONNECT response".into()))?;

    tokio::spawn(async move {
        match hyper::upgrade::on(&mut req).await {
            Ok(mut upgraded) => {
                match TcpStream::connect(&target).await {
                    Ok(mut upstream) => {
                        if let Err(e) = copy_bidirectional(&mut upgraded, &mut upstream).await {
                            warn!(%e, "CONNECT tunnel error");
                        }
                        let _ = upgraded.shutdown().await;
                        let _ = upstream.shutdown().await;
                    }
                    Err(e) => {
                        warn!(%e, "failed to connect to upstream");
                        let _ = upgraded.shutdown().await;
                    }
                }
            }
            Err(e) => {
                warn!("CONNECT upgrade error: {:?}", e);
            }
        }
    });

    Ok(resp)
}

