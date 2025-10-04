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
        let s = val.to_str().map_err(|_| {
            response_with(StatusCode::BAD_REQUEST, "invalid header value (not UTF-8)".to_string())
        })?;

        let s = s.trim();
        if s.is_empty() {
            return Err(response_with(
                StatusCode::BAD_REQUEST,
                "header value cannot be empty".to_string(),
            ));
        }

        let port: u16 = s.parse().map_err(|_| {
            response_with(
                StatusCode::BAD_REQUEST,
                "invalid port in X-Cmux-Port-Internal".to_string(),
            )
        })?;
        return Ok(port);
    }

    // Fallback: try parsing from Host subdomain pattern: <workspace>-<port>.localhost[:...]
    if let Some((_ws, port)) = parse_workspace_port_from_host(headers) {
        return Ok(port);
    }

    Err(response_with(
        StatusCode::BAD_REQUEST,
        format!("missing required header: {}", HDR),
    ))
}

/// Public helper: compute a per-workspace IPv4 address in 127/8 based on a workspace name
/// of the form `workspace-N` (N >= 1). If input contains path separators, the last component
/// is used. Returns None if no trailing digits are found.
pub fn workspace_ip_from_name(name: &str) -> Option<std::net::Ipv4Addr> {
    use std::net::Ipv4Addr;

    let base = name.rsplit('/').next().unwrap_or(name);
    // Extract trailing digits
    let digits: String = base
        .chars()
        .rev()
        .take_while(|c| c.is_ascii_digit())
        .collect::<String>()
        .chars()
        .rev()
        .collect();

    let n: u32 = if !digits.is_empty() {
        digits.parse().ok()?
    } else {
        // Stable 32-bit FNV-1a hash of lowercase name; map to 16-bit space
        let mut h: u32 = 0x811C9DC5;
        for b in base.to_ascii_lowercase().as_bytes() {
            h ^= *b as u32;
            h = h.wrapping_mul(0x01000193);
        }
        h & 0xFFFF
    };

    let b2 = ((n >> 8) & 0xFF) as u8;
    let b3 = (n & 0xFF) as u8;
    Some(Ipv4Addr::new(127, 18, b2, b3))
}

fn upstream_host_from_headers(headers: &HeaderMap, default_host: &str) -> Result<String, Response<Body>> {
    const HDR_WS: &str = "X-Cmux-Workspace-Internal";
    if let Some(val) = headers.get(HDR_WS) {
        let v = val.to_str().map_err(|_| {
            response_with(StatusCode::BAD_REQUEST, format!("invalid header value (not UTF-8): {}", HDR_WS))
        })?;
        let ws = v.trim();
        if ws.is_empty() {
            return Err(response_with(StatusCode::BAD_REQUEST, format!("{} cannot be empty", HDR_WS)));
        }
        let ip = workspace_ip_from_name(ws)
            .ok_or_else(|| response_with(StatusCode::BAD_REQUEST, format!("invalid workspace name: {}", ws)))?;
        return Ok(ip.to_string());
    }

    // Fallback: try parsing from subdomain pattern if present
    if let Some((ws, _port)) = parse_workspace_port_from_host(headers) {
        if let Some(ip) = workspace_ip_from_name(&ws) {
            return Ok(ip.to_string());
        } else {
            return Err(response_with(
                StatusCode::BAD_REQUEST,
                format!("invalid workspace name: {}", ws),
            ));
        }
    }

    Ok(default_host.to_string())
}

fn is_upgrade_request(req: &Request<Body>) -> bool {
    if req.method() == Method::CONNECT {
        return true;
    }
    // Check headers like: Connection: upgrade and Upgrade: websocket
    let has_conn_upgrade = req
        .headers()
        .get(CONNECTION)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.to_ascii_lowercase().contains("upgrade"))
        .unwrap_or(false);
    let has_upgrade_hdr = req.headers().contains_key(UPGRADE);
    has_conn_upgrade && has_upgrade_hdr
}

fn strip_hop_by_hop_headers(h: &mut HeaderMap) {
    // Standard hop-by-hop headers per RFC 7230
    const HOP_HEADERS: &[&str] = &[
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailers",
        "transfer-encoding",
        "upgrade",
        "proxy-connection",
        "x-cmux-port-internal",
        "x-cmux-workspace-internal",
    ];
    for name in HOP_HEADERS {
        h.remove(*name);
    }

    // Also remove headers listed in Connection: <header-names>
    if let Some(conn_val) = h.get(CONNECTION).and_then(|v| v.to_str().ok()).map(|s| s.to_string()) {
        for token in conn_val.split(',') {
            let name = token.trim().to_ascii_lowercase();
            if !name.is_empty() {
                h.remove(&name);
            }
        }
    }
}

fn build_upstream_uri(upstream_host: &str, port: u16, orig: &Uri) -> Result<Uri, Response<Body>> {
    let path_and_query = orig
        .path_and_query()
        .map(|pq| pq.as_str())
        .unwrap_or("/");
    let uri_str = format!("http://{}:{}{}", upstream_host, port, path_and_query);
    Uri::from_str(&uri_str).map_err(|_| response_with(StatusCode::BAD_GATEWAY, "invalid upstream uri".into()))
}

// Attempt to parse a pattern like: <workspace>-<port>.localhost[:...]
// Returns (workspace, port) if found and valid.
fn parse_workspace_port_from_host(headers: &HeaderMap) -> Option<(String, u16)> {
    let host_val = headers.get("host")?.to_str().ok()?.trim();
    if host_val.is_empty() { return None; }

    // Strip optional :port from Host header
    let host_only = host_val.split_once(':').map(|(h, _)| h).unwrap_or(host_val);
    let host_lc = host_only.to_ascii_lowercase();

    // Must end with .localhost
    const SUFFIX: &str = ".localhost";
    if !host_lc.ends_with(SUFFIX) {
        return None;
    }

    // Take the label before .localhost
    let base_len = host_only.len() - SUFFIX.len();
    let label = &host_only[..base_len];

    // Expect last '-' separates workspace and port
    let dash_idx = label.rfind('-')?;
    let (ws_part, port_part) = label.split_at(dash_idx);
    // port_part still has leading '-' from split_at
    let port_str = &port_part[1..];
    if ws_part.is_empty() || port_str.is_empty() { return None; }
    let port: u16 = match port_str.parse() { Ok(p) => p, Err(_) => return None };
    Some((ws_part.to_string(), port))
}

fn response_with(status: StatusCode, msg: String) -> Response<Body> {
    Response::builder()
        .status(status)
        .header("content-type", "text/plain; charset=utf-8")
        .body(Body::from(msg))
        .unwrap()
}

async fn handle(
    client: Client<HttpConnector, Body>,
    cfg: ProxyConfig,
    remote_addr: SocketAddr,
    mut req: Request<Body>,
) -> Result<Response<Body>, Infallible> {
    let method = req.method().clone();
    let is_upgrade = is_upgrade_request(&req);

    match method {
        Method::CONNECT => match handle_connect(req, &cfg, remote_addr).await {
            Ok(resp) => Ok(resp),
            Err(resp) => Ok(resp),
        },
        _ => {
            if is_upgrade {
                match handle_upgrade(client, cfg, remote_addr, req).await {
                    Ok(resp) => Ok(resp),
                    Err(resp) => Ok(resp),
                }
            } else {
                match handle_http(client, &cfg, remote_addr, &mut req).await {
                    Ok(resp) => Ok(resp),
                    Err(resp) => Ok(resp),
                }
            }
        }
    }
}

async fn handle_http(
    client: Client<HttpConnector, Body>,
    cfg: &ProxyConfig,
    remote_addr: SocketAddr,
    req: &mut Request<Body>,
) -> Result<Response<Body>, Response<Body>> {
    let port = get_port_from_header(req.headers())?;
    let upstream_host = upstream_host_from_headers(req.headers(), &cfg.upstream_host)?;
    let uri = build_upstream_uri(&upstream_host, port, req.uri())?;

    // Build proxied request
    let body = std::mem::replace(req.body_mut(), Body::empty());
    let mut new_req = Request::builder()
        .method(req.method())
        .uri(uri)
        .version(req.version())
        .body(body)
        .map_err(|_| response_with(StatusCode::INTERNAL_SERVER_ERROR, "failed to build request".into()))?;

    // Copy headers
    for (name, value) in req.headers().iter() {
        if name.as_str().eq_ignore_ascii_case("x-cmux-port-internal") || name.as_str().eq_ignore_ascii_case("x-cmux-workspace-internal") {
            continue;
        }
        new_req.headers_mut().insert(name, value.clone());
    }

    // Strip hop-by-hop headers on the proxied request
    strip_hop_by_hop_headers(new_req.headers_mut());

    info!(
        client = %remote_addr,
        method = %new_req.method(),
        path = %req.uri().path(),
        port = port,
        upstream = %upstream_host,
        "proxy http"
    );

    let upstream_resp = client
        .request(new_req)
        .await
        .map_err(|e| response_with(StatusCode::BAD_GATEWAY, format!("upstream request error: {}", e)))?;

    // Map upstream response back to client, stripping hop-by-hop headers
    let mut client_resp_builder = Response::builder().status(upstream_resp.status());

    let headers = client_resp_builder
        .headers_mut()
        .expect("headers_mut available");
    for (name, value) in upstream_resp.headers().iter() {
        headers.insert(name, value.clone());
    }
    strip_hop_by_hop_headers(headers);

    let body = upstream_resp.into_body();
    let resp = client_resp_builder
        .body(body)
        .map_err(|_| response_with(StatusCode::INTERNAL_SERVER_ERROR, "failed to build response".into()))?;
    Ok(resp)
}

async fn handle_upgrade(
    client: Client<HttpConnector, Body>,
    cfg: ProxyConfig,
    remote_addr: SocketAddr,
    mut req: Request<Body>,
) -> Result<Response<Body>, Response<Body>> {
    // Treat as reverse-proxied upgrade (e.g., WebSocket). We forward the request to upstream,
    // then mirror the 101 response headers to the client and tunnel bytes between both upgrades.
    let port = get_port_from_header(req.headers())?;
    let upstream_host = upstream_host_from_headers(req.headers(), &cfg.upstream_host)?;
    let upstream_uri = build_upstream_uri(&upstream_host, port, req.uri())?;

    // Build proxied request for upstream
    let body = std::mem::replace(req.body_mut(), Body::empty());
    let mut proxied_req = Request::builder()
        .method(req.method())
        .uri(upstream_uri)
        .version(req.version())
        .body(body)
        .map_err(|_| response_with(StatusCode::INTERNAL_SERVER_ERROR, "failed to build upgrade request".into()))?;

    // Copy headers (keep upgrade headers)
    for (name, value) in req.headers().iter() {
        if name.as_str().eq_ignore_ascii_case("x-cmux-port-internal") || name.as_str().eq_ignore_ascii_case("x-cmux-workspace-internal") {
            continue;
        }
        proxied_req.headers_mut().insert(name, value.clone());
    }
    // Do NOT strip upgrade/connection here; upstream needs them
    proxied_req.headers_mut().remove("proxy-connection");
    proxied_req.headers_mut().remove("keep-alive");
    proxied_req.headers_mut().remove("te");
    proxied_req.headers_mut().remove("transfer-encoding");
    proxied_req.headers_mut().remove("trailers");

    info!(client = %remote_addr, port = port, upstream = %upstream_host, "proxy upgrade (e.g. websocket)");

    // Send to upstream and get its response (should be 101)
    let upstream_resp = client
        .request(proxied_req)
        .await
        .map_err(|e| response_with(StatusCode::BAD_GATEWAY, format!("upstream upgrade error: {}", e)))?;

    if upstream_resp.status() != StatusCode::SWITCHING_PROTOCOLS {
        // Return upstream status (probably 4xx/5xx) to client with body
        let status = upstream_resp.status();
        let mut builder = Response::builder().status(status);
        let headers = builder.headers_mut().unwrap();
        for (k, v) in upstream_resp.headers() {
            headers.insert(k, v.clone());
        }
        let body = upstream_resp.into_body();
        return builder
            .body(body)
            .map_err(|_| response_with(StatusCode::INTERNAL_SERVER_ERROR, "failed to build response".into()));
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
                            warn!(%e, "tcp tunnel error");
                        }
                        let _ = upgraded.shutdown().await;
                        let _ = upstream.shutdown().await;
                    }
                    Err(e) => {
                        warn!(%e, "failed to connect to upstream for CONNECT");
                        let _ = upgraded.write_all(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n").await;
                        let _ = upgraded.shutdown().await;
                    }
                }
            }
            Err(e) => warn!("CONNECT upgrade error: {:?}", e),
        }
    });

    Ok(resp)
}
