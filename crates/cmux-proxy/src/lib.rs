use std::{
    cmp::min,
    convert::Infallible,
    future::Future,
    io,
    net::{SocketAddr, TcpListener as StdTcpListener},
    pin::Pin,
    str::FromStr,
    task::{Context, Poll},
    time::Duration,
};

use bytes::Bytes;
use futures_util::future;
use http::{HeaderMap, HeaderValue, Method, Request, Response, StatusCode, Uri, Version};
use http_body_util::{BodyExt, Empty, Full};
use hyper::body::Incoming;
use hyper::server::conn::{http1, http2};
use hyper::service::service_fn;
use hyper_util::client::legacy::{connect::HttpConnector, Client};
use hyper_util::rt::{TokioExecutor, TokioIo, TokioTimer};
use std::sync::Arc;
use tokio::io::{copy_bidirectional, AsyncRead, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Notify;
use tokio::task::{JoinHandle, JoinSet};
use tracing::{error, info, warn};

use http::header::{CONNECTION, HOST, UPGRADE};

type BoxBody =
    http_body_util::combinators::BoxBody<Bytes, Box<dyn std::error::Error + Send + Sync>>;
type BoxError = Box<dyn std::error::Error + Send + Sync>;
const HTTP2_PREFACE: &[u8] = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
const HOST_OVERRIDE_HEADER: &str = "X-Cmux-Host-Override";
const HTTP2_KEEP_ALIVE_INTERVAL_SECS: u64 = 30;
const HTTP2_KEEP_ALIVE_TIMEOUT_SECS: u64 = 10;

trait ClientKeepAliveConfig {
    fn set_pool_max_idle_per_host(&mut self, max: usize);
    fn set_http2_keep_alive_interval(&mut self, interval: Option<Duration>);
    fn set_http2_keep_alive_timeout(&mut self, timeout: Duration);
    fn set_http2_keep_alive_while_idle(&mut self, enabled: bool);
}

impl ClientKeepAliveConfig for hyper_util::client::legacy::Builder {
    fn set_pool_max_idle_per_host(&mut self, max: usize) {
        self.pool_max_idle_per_host(max);
    }

    fn set_http2_keep_alive_interval(&mut self, interval: Option<Duration>) {
        self.http2_keep_alive_interval(interval);
    }

    fn set_http2_keep_alive_timeout(&mut self, timeout: Duration) {
        self.http2_keep_alive_timeout(timeout);
    }

    fn set_http2_keep_alive_while_idle(&mut self, enabled: bool) {
        self.http2_keep_alive_while_idle(enabled);
    }
}

trait Http1ServerConfig {
    fn set_keep_alive(&mut self, val: bool);
    fn set_preserve_header_case(&mut self, val: bool);
    fn set_title_case_headers(&mut self, val: bool);
}

impl Http1ServerConfig for http1::Builder {
    fn set_keep_alive(&mut self, val: bool) {
        self.keep_alive(val);
    }

    fn set_preserve_header_case(&mut self, val: bool) {
        self.preserve_header_case(val);
    }

    fn set_title_case_headers(&mut self, val: bool) {
        self.title_case_headers(val);
    }
}

trait Http2ServerConfig {
    fn set_keep_alive_interval(&mut self, interval: Option<Duration>);
    fn set_keep_alive_timeout(&mut self, timeout: Duration);
}

impl<E> Http2ServerConfig for http2::Builder<E> {
    fn set_keep_alive_interval(&mut self, interval: Option<Duration>) {
        self.keep_alive_interval(interval);
    }

    fn set_keep_alive_timeout(&mut self, timeout: Duration) {
        self.keep_alive_timeout(timeout);
    }
}

fn configure_http_client_builder(builder: &mut impl ClientKeepAliveConfig) {
    builder.set_pool_max_idle_per_host(8);
    builder
        .set_http2_keep_alive_interval(Some(Duration::from_secs(HTTP2_KEEP_ALIVE_INTERVAL_SECS)));
    builder.set_http2_keep_alive_timeout(Duration::from_secs(HTTP2_KEEP_ALIVE_TIMEOUT_SECS));
    builder.set_http2_keep_alive_while_idle(true);
}

fn configure_http1_server_builder(builder: &mut impl Http1ServerConfig) {
    builder.set_keep_alive(true);
    builder.set_preserve_header_case(true);
    builder.set_title_case_headers(true);
}

fn configure_http2_server_builder(builder: &mut impl Http2ServerConfig) {
    builder.set_keep_alive_interval(Some(Duration::from_secs(HTTP2_KEEP_ALIVE_INTERVAL_SECS)));
    builder.set_keep_alive_timeout(Duration::from_secs(HTTP2_KEEP_ALIVE_TIMEOUT_SECS));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct RecordingClientBuilder {
        pool_max_idle: Option<usize>,
        interval: Option<Option<Duration>>,
        timeout: Option<Duration>,
        while_idle: Option<bool>,
    }

    impl ClientKeepAliveConfig for RecordingClientBuilder {
        fn set_pool_max_idle_per_host(&mut self, max: usize) {
            self.pool_max_idle = Some(max);
        }

        fn set_http2_keep_alive_interval(&mut self, interval: Option<Duration>) {
            self.interval = Some(interval);
        }

        fn set_http2_keep_alive_timeout(&mut self, timeout: Duration) {
            self.timeout = Some(timeout);
        }

        fn set_http2_keep_alive_while_idle(&mut self, enabled: bool) {
            self.while_idle = Some(enabled);
        }
    }

    #[derive(Default)]
    struct RecordingHttp1Builder {
        keep_alive: Option<bool>,
        preserve_header_case: Option<bool>,
        title_case_headers: Option<bool>,
    }

    impl Http1ServerConfig for RecordingHttp1Builder {
        fn set_keep_alive(&mut self, val: bool) {
            self.keep_alive = Some(val);
        }

        fn set_preserve_header_case(&mut self, val: bool) {
            self.preserve_header_case = Some(val);
        }

        fn set_title_case_headers(&mut self, val: bool) {
            self.title_case_headers = Some(val);
        }
    }

    #[derive(Default)]
    struct RecordingHttp2Builder {
        interval: Option<Option<Duration>>,
        timeout: Option<Duration>,
    }

    impl Http2ServerConfig for RecordingHttp2Builder {
        fn set_keep_alive_interval(&mut self, interval: Option<Duration>) {
            self.interval = Some(interval);
        }

        fn set_keep_alive_timeout(&mut self, timeout: Duration) {
            self.timeout = Some(timeout);
        }
    }

    #[test]
    fn configures_http_client_builder_keep_alive() {
        let mut builder = RecordingClientBuilder::default();
        configure_http_client_builder(&mut builder);
        assert_eq!(builder.pool_max_idle, Some(8));
        assert_eq!(
            builder.interval,
            Some(Some(Duration::from_secs(HTTP2_KEEP_ALIVE_INTERVAL_SECS)))
        );
        assert_eq!(
            builder.timeout,
            Some(Duration::from_secs(HTTP2_KEEP_ALIVE_TIMEOUT_SECS))
        );
        assert_eq!(builder.while_idle, Some(true));
    }

    #[test]
    fn configures_http1_server_builder_with_keep_alive_and_headers() {
        let mut builder = RecordingHttp1Builder::default();
        configure_http1_server_builder(&mut builder);
        assert_eq!(builder.keep_alive, Some(true));
        assert_eq!(builder.preserve_header_case, Some(true));
        assert_eq!(builder.title_case_headers, Some(true));
    }

    #[test]
    fn configures_http2_server_builder_keep_alive() {
        let mut builder = RecordingHttp2Builder::default();
        configure_http2_server_builder(&mut builder);
        assert_eq!(
            builder.interval,
            Some(Some(Duration::from_secs(HTTP2_KEEP_ALIVE_INTERVAL_SECS)))
        );
        assert_eq!(
            builder.timeout,
            Some(Duration::from_secs(HTTP2_KEEP_ALIVE_TIMEOUT_SECS))
        );
    }
}

struct BufferedStream {
    stream: TcpStream,
    buffer: Vec<u8>,
    cursor: usize,
}

impl BufferedStream {
    fn new(stream: TcpStream, buffer: Vec<u8>) -> Self {
        Self {
            stream,
            buffer,
            cursor: 0,
        }
    }
}

impl AsyncRead for BufferedStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        if self.cursor < self.buffer.len() && buf.remaining() > 0 {
            let remaining = self.buffer.len() - self.cursor;
            let to_copy = min(remaining, buf.remaining());
            buf.put_slice(&self.buffer[self.cursor..self.cursor + to_copy]);
            self.cursor += to_copy;
            return Poll::Ready(Ok(()));
        }

        Pin::new(&mut self.stream).poll_read(cx, buf)
    }
}

impl AsyncWrite for BufferedStream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        data: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        let this = self.get_mut();
        Pin::new(&mut this.stream).poll_write(cx, data)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        let this = self.get_mut();
        Pin::new(&mut this.stream).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        let this = self.get_mut();
        Pin::new(&mut this.stream).poll_shutdown(cx)
    }
}

fn empty_body() -> BoxBody {
    Empty::<Bytes>::new()
        .map_err(|never: Infallible| match never {})
        .boxed()
}

fn full_body(b: impl Into<Bytes>) -> BoxBody {
    Full::new(b.into())
        .map_err(|never: Infallible| match never {})
        .boxed()
}

fn incoming_to_box(b: Incoming) -> BoxBody {
    b.map_err(|e| -> BoxError { Box::new(e) }).boxed()
}

#[derive(Clone, Debug)]
pub struct ProxyConfig {
    pub listen: SocketAddr,
    pub upstream_host: String,
    pub allow_default_upstream: bool,
}

pub fn spawn_proxy<S>(cfg: ProxyConfig, mut shutdown: S) -> Result<(SocketAddr, JoinHandle<()>), BoxError>
where
    S: Future<Output = ()> + Send + 'static + Unpin,
{
    // Hyper client for proxying HTTP/1.1
    let mut connector = HttpConnector::new();
    connector.set_connect_timeout(Some(Duration::from_secs(5)));
    let mut client_builder = Client::builder(TokioExecutor::new());
    configure_http_client_builder(&mut client_builder);
    let client: Client<HttpConnector, BoxBody> = client_builder.build(connector);

    let listen = cfg.listen;
    let std_listener = StdTcpListener::bind(listen)
        .map_err(|e| -> BoxError { Box::new(e) })?;
    std_listener.set_nonblocking(true)
        .map_err(|e| -> BoxError { Box::new(e) })?;
    let listen_addr = std_listener.local_addr()
        .map_err(|e| -> BoxError { Box::new(e) })?;
    let listener = TcpListener::from_std(std_listener)
        .map_err(|e| -> BoxError { Box::new(e) })?;

    let handle = tokio::spawn(async move {
        info!("proxy listening on {}", listen_addr);

        loop {
            tokio::select! {
                result = listener.accept() => {
                    match result {
                        Ok((stream, remote_addr)) => {
                            let client = client.clone();
                            let cfg = cfg.clone();
                            tokio::spawn(async move {
                                if let Err(err) = serve_client_stream(stream, remote_addr, client, cfg).await {
                                    error!(%err, "connection error");
                                }
                            });
                        }
                        Err(e) => {
                            error!(%e, "accept error");
                        }
                    }
                }
                _ = &mut shutdown => {
                    info!("shutting down proxy");
                    break;
                }
            }
        }
    });
    // Return the actual bound address so callers can discover OS-assigned ports
    Ok((listen_addr, handle))
}

/// Start the proxy on multiple addresses. Returns the bound addresses actually used and a handle
/// that completes when all servers exit (after shutdown is signaled).
pub fn spawn_proxy_multi<S>(
    listens: Vec<SocketAddr>,
    upstream_host: String,
    allow_default_upstream: bool,
    shutdown: S,
) -> (Vec<SocketAddr>, JoinHandle<()>)
where
    S: Future<Output = ()> + Send + 'static,
{
    // Prepare shared client and shutdown notifier
    let mut connector = HttpConnector::new();
    connector.set_connect_timeout(Some(Duration::from_secs(5)));
    let mut client_builder = Client::builder(TokioExecutor::new());
    configure_http_client_builder(&mut client_builder);
    let client: Client<HttpConnector, BoxBody> = client_builder.build(connector);

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
        let allow_default = allow_default_upstream;

        let std_listener = match StdTcpListener::bind(addr) {
            Ok(listener) => listener,
            Err(e) => {
                error!(%e, "failed to bind to {}", addr);
                continue;
            }
        };
        if let Err(e) = std_listener.set_nonblocking(true) {
            error!(%e, "failed to set nonblocking on {}", addr);
            continue;
        }
        let actual_addr = match std_listener.local_addr() {
            Ok(addr) => addr,
            Err(e) => {
                error!(%e, "failed to get local addr for {}", addr);
                continue;
            }
        };
        let listener = match TcpListener::from_std(std_listener) {
            Ok(listener) => listener,
            Err(e) => {
                error!(%e, "failed to create tokio listener for {}", actual_addr);
                continue;
            }
        };

        bound_addrs.push(actual_addr);

        join_set.spawn(async move {
            info!("proxy listening on {}", actual_addr);

            loop {
                tokio::select! {
                    result = listener.accept() => {
                        match result {
                            Ok((stream, remote_addr)) => {
                                let client = client.clone();
                                let upstream = upstream.clone();

                                tokio::spawn(async move {
                                    let cfg = ProxyConfig {
                                        listen: actual_addr,
                                        upstream_host: upstream.clone(),
                                        allow_default_upstream: allow_default,
                                    };
                                    if let Err(err) =
                                        serve_client_stream(stream, remote_addr, client, cfg).await
                                    {
                                        error!(%err, "connection error");
                                    }
                                });
                            }
                            Err(e) => {
                                error!(%e, "accept error");
                            }
                        }
                    }
                    _ = notify.notified() => {
                        info!("shutting down proxy on {}", actual_addr);
                        break;
                    }
                }
            }
        });
    }

    let handle = tokio::spawn(async move { while let Some(_res) = join_set.join_next().await {} });

    (bound_addrs, handle)
}

async fn serve_client_stream(
    stream: TcpStream,
    remote_addr: SocketAddr,
    client: Client<HttpConnector, BoxBody>,
    cfg: ProxyConfig,
) -> Result<(), BoxError> {
    let (buffered_stream, client_prefers_http2) = sniff_http2_preface(stream).await?;
    let io = TokioIo::new(buffered_stream);
    let svc_client = client.clone();
    let svc_cfg = cfg.clone();
    let service =
        service_fn(move |req| handle(svc_client.clone(), svc_cfg.clone(), remote_addr, req));

    if client_prefers_http2 {
        let mut builder = http2::Builder::new(TokioExecutor::new());
        configure_http2_server_builder(&mut builder);
        builder.timer(TokioTimer::new());
        builder.serve_connection(io, service).await?;
    } else {
        let mut builder = http1::Builder::new();
        configure_http1_server_builder(&mut builder);
        builder
            .serve_connection(io, service)
            .with_upgrades()
            .await?;
    }
    Ok(())
}

async fn sniff_http2_preface(stream: TcpStream) -> io::Result<(BufferedStream, bool)> {
    let mut buffer: Vec<u8> = Vec::new();
    let mut temp = [0u8; 24];

    loop {
        if buffer.len() >= HTTP2_PREFACE.len() {
            break;
        }

        stream.readable().await?;
        let needed = HTTP2_PREFACE.len() - buffer.len();
        match stream.try_read(&mut temp[..needed]) {
            Ok(0) => break,
            Ok(n) => {
                buffer.extend_from_slice(&temp[..n]);
                if !HTTP2_PREFACE.starts_with(&buffer) {
                    return Ok((BufferedStream::new(stream, buffer), false));
                }
            }
            Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => continue,
            Err(e) => return Err(e),
        }
    }

    let is_http2 =
        buffer.len() >= HTTP2_PREFACE.len() && buffer[..HTTP2_PREFACE.len()] == *HTTP2_PREFACE;
    Ok((BufferedStream::new(stream, buffer), is_http2))
}

#[allow(clippy::result_large_err)]
fn get_port_from_header(headers: &HeaderMap) -> Result<u16, Response<BoxBody>> {
    const HDR: &str = "X-Cmux-Port-Internal";
    if let Some(val) = headers.get(HDR) {
        let s = val.to_str().map_err(|_| {
            response_with(
                StatusCode::BAD_REQUEST,
                "invalid header value (not UTF-8)".to_string(),
            )
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

#[allow(clippy::result_large_err)]
fn upstream_host_from_headers(
    headers: &HeaderMap,
    default_host: &str,
    allow_default_without_workspace: bool,
) -> Result<String, Response<BoxBody>> {
    const HDR_WS: &str = "X-Cmux-Workspace-Internal";
    if let Some(val) = headers.get(HDR_WS) {
        let v = val.to_str().map_err(|_| {
            response_with(
                StatusCode::BAD_REQUEST,
                format!("invalid header value (not UTF-8): {}", HDR_WS),
            )
        })?;
        let ws = v.trim();
        if ws.is_empty() {
            return Err(response_with(
                StatusCode::BAD_REQUEST,
                format!("{} cannot be empty", HDR_WS),
            ));
        }
        let ip = workspace_ip_from_name(ws).ok_or_else(|| {
            response_with(
                StatusCode::BAD_REQUEST,
                format!("invalid workspace name: {}", ws),
            )
        })?;
        return Ok(ip.to_string());
    }

    if allow_default_without_workspace {
        return Ok(default_host.to_string());
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

fn is_upgrade_request(req: &Request<Incoming>) -> bool {
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
        "x-cmux-host-override",
    ];
    for name in HOP_HEADERS {
        h.remove(*name);
    }

    // Also remove headers listed in Connection: <header-names>
    if let Some(conn_val) = h
        .get(CONNECTION)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string())
    {
        for token in conn_val.split(',') {
            let name = token.trim().to_ascii_lowercase();
            if !name.is_empty() {
                h.remove(&name);
            }
        }
    }
}

#[allow(clippy::result_large_err)]
fn build_upstream_uri(
    upstream_host: &str,
    port: u16,
    orig: &Uri,
) -> Result<Uri, Response<BoxBody>> {
    let path_and_query = orig.path_and_query().map(|pq| pq.as_str()).unwrap_or("/");
    let uri_str = format!("http://{}:{}{}", upstream_host, port, path_and_query);
    Uri::from_str(&uri_str)
        .map_err(|_| response_with(StatusCode::BAD_GATEWAY, "invalid upstream uri".into()))
}

// Attempt to parse a pattern like: <workspace>-<port>.localhost[:...]
// Returns (workspace, port) if found and valid.
fn parse_workspace_port_from_host(headers: &HeaderMap) -> Option<(String, u16)> {
    let host_val = headers.get("host")?.to_str().ok()?.trim();
    if host_val.is_empty() {
        return None;
    }

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
    if ws_part.is_empty() || port_str.is_empty() {
        return None;
    }
    let port: u16 = match port_str.parse() {
        Ok(p) => p,
        Err(_) => return None,
    };
    Some((ws_part.to_string(), port))
}

#[allow(clippy::result_large_err)]
fn enforce_local_host_header(
    headers: &HeaderMap,
    host_override: Option<&str>,
) -> Result<(), Response<BoxBody>> {
    if host_override.is_some() {
        return Ok(());
    }

    if let Some(value) = headers.get(HOST) {
        value.to_str().map_err(|_| {
            response_with(
                StatusCode::BAD_REQUEST,
                "invalid Host header (not UTF-8)".to_string(),
            )
        })?;
    }

    Ok(())
}

fn response_with(status: StatusCode, msg: String) -> Response<BoxBody> {
    Response::builder()
        .status(status)
        .header("content-type", "text/plain; charset=utf-8")
        .body(full_body(msg))
        .unwrap_or_else(|e| {
            error!("failed to build error response: {}", e);
            // Fallback to a minimal response if building fails
            Response::new(full_body("Internal server error"))
        })
}

async fn handle(
    client: Client<HttpConnector, BoxBody>,
    cfg: ProxyConfig,
    remote_addr: SocketAddr,
    req: Request<Incoming>,
) -> Result<Response<BoxBody>, Infallible> {
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
                match handle_http(client, &cfg, remote_addr, req).await {
                    Ok(resp) => Ok(resp),
                    Err(resp) => Ok(resp),
                }
            }
        }
    }
}

async fn handle_http(
    client: Client<HttpConnector, BoxBody>,
    cfg: &ProxyConfig,
    remote_addr: SocketAddr,
    req: Request<Incoming>,
) -> Result<Response<BoxBody>, Response<BoxBody>> {
    let (mut parts, incoming) = req.into_parts();

    let port = get_port_from_header(&parts.headers)?;
    let upstream_host = upstream_host_from_headers(
        &parts.headers,
        &cfg.upstream_host,
        cfg.allow_default_upstream,
    )?;
    let host_override = parts
        .headers
        .get(HOST_OVERRIDE_HEADER)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    enforce_local_host_header(&parts.headers, host_override.as_deref())?;

    parts.uri = build_upstream_uri(&upstream_host, port, &parts.uri)?;
    parts.version = Version::HTTP_11;

    // Convert incoming body to BoxBody
    let proxied_body: BoxBody = incoming_to_box(incoming);
    let mut new_req = Request::from_parts(parts, proxied_body);

    // Strip internal headers
    new_req.headers_mut().remove("x-cmux-port-internal");
    new_req.headers_mut().remove("x-cmux-workspace-internal");
    new_req.headers_mut().remove(HOST_OVERRIDE_HEADER);
    if let Some(host) = host_override.as_ref() {
        if let Ok(value) = HeaderValue::from_str(host.as_str()) {
            new_req.headers_mut().insert(HOST, value);
        }
    }

    // Strip hop-by-hop headers on the proxied request
    strip_hop_by_hop_headers(new_req.headers_mut());

    info!(
        client = %remote_addr,
        method = %new_req.method(),
        path = %new_req.uri().path(),
        port = port,
        upstream = %upstream_host,
        "proxy http"
    );

    let upstream_resp = client.request(new_req).await.map_err(|e| {
        response_with(
            StatusCode::BAD_GATEWAY,
            format!("upstream request error: {}", e),
        )
    })?;

    // Map upstream response back to client, stripping hop-by-hop headers
    let mut client_resp_builder = Response::builder().status(upstream_resp.status());

    let headers = client_resp_builder
        .headers_mut()
        .ok_or_else(|| {
            response_with(
                StatusCode::INTERNAL_SERVER_ERROR,
                "failed to get response headers".into(),
            )
        })?;
    for (name, value) in upstream_resp.headers().iter() {
        headers.insert(name, value.clone());
    }
    strip_hop_by_hop_headers(headers);

    let body = incoming_to_box(upstream_resp.into_body());
    let resp = client_resp_builder.body(body).map_err(|_| {
        response_with(
            StatusCode::INTERNAL_SERVER_ERROR,
            "failed to build response".into(),
        )
    })?;
    Ok(resp)
}

async fn handle_upgrade(
    client: Client<HttpConnector, BoxBody>,
    cfg: ProxyConfig,
    remote_addr: SocketAddr,
    req: Request<Incoming>,
) -> Result<Response<BoxBody>, Response<BoxBody>> {
    // Treat as reverse-proxied upgrade (e.g., WebSocket). We forward the request to upstream,
    // then mirror the 101 response headers to the client and tunnel bytes between both upgrades.

    let port = get_port_from_header(req.headers())?;
    let upstream_host = upstream_host_from_headers(
        req.headers(),
        &cfg.upstream_host,
        cfg.allow_default_upstream,
    )?;
    let upstream_uri = build_upstream_uri(&upstream_host, port, req.uri())?;
    let host_override = req
        .headers()
        .get(HOST_OVERRIDE_HEADER)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    enforce_local_host_header(req.headers(), host_override.as_deref())?;

    // Build proxied request for upstream - need to clone headers before consuming req
    let mut proxied_req_builder = Request::builder()
        .method(req.method())
        .uri(upstream_uri)
        .version(req.version());

    // Copy headers
    for (name, value) in req.headers().iter() {
        if !name.as_str().eq_ignore_ascii_case("x-cmux-port-internal")
            && !name
                .as_str()
                .eq_ignore_ascii_case("x-cmux-workspace-internal")
            && !name.as_str().eq_ignore_ascii_case(HOST_OVERRIDE_HEADER)
        {
            proxied_req_builder = proxied_req_builder.header(name, value);
        }
    }

    let (parts, incoming) = req.into_parts();
    let proxied_body: BoxBody = incoming_to_box(incoming);
    let mut proxied_req = proxied_req_builder.body(proxied_body).map_err(|_| {
        response_with(
            StatusCode::INTERNAL_SERVER_ERROR,
            "failed to build upgrade request".into(),
        )
    })?;

    // Do NOT strip upgrade/connection here; upstream needs them
    proxied_req.headers_mut().remove("proxy-connection");
    proxied_req.headers_mut().remove("keep-alive");
    proxied_req.headers_mut().remove("te");
    proxied_req.headers_mut().remove("transfer-encoding");
    proxied_req.headers_mut().remove("trailers");
    if let Some(host) = host_override {
        if let Ok(value) = HeaderValue::from_str(host.as_str()) {
            proxied_req.headers_mut().insert(HOST, value);
        }
    }

    info!(client = %remote_addr, port = port, upstream = %upstream_host, "proxy upgrade (e.g. websocket)");

    // Send to upstream and get its response (should be 101)
    let upstream_resp = client.request(proxied_req).await.map_err(|e| {
        response_with(
            StatusCode::BAD_GATEWAY,
            format!("upstream upgrade error: {}", e),
        )
    })?;

    if upstream_resp.status() != StatusCode::SWITCHING_PROTOCOLS {
        // Return upstream status (probably 4xx/5xx) to client with body
        let status = upstream_resp.status();
        let mut builder = Response::builder().status(status);
        let headers = builder.headers_mut().ok_or_else(|| {
            response_with(
                StatusCode::INTERNAL_SERVER_ERROR,
                "failed to get response headers".into(),
            )
        })?;
        for (k, v) in upstream_resp.headers() {
            headers.insert(k, v.clone());
        }
        let body = incoming_to_box(upstream_resp.into_body());
        return builder.body(body).map_err(|_| {
            response_with(
                StatusCode::INTERNAL_SERVER_ERROR,
                "failed to build response".into(),
            )
        });
    }

    // Clone headers to send to client, but we must keep upstream_resp for upgrade
    let mut client_resp_builder = Response::builder().status(StatusCode::SWITCHING_PROTOCOLS);
    let out_headers = client_resp_builder
        .headers_mut()
        .ok_or_else(|| {
            response_with(
                StatusCode::INTERNAL_SERVER_ERROR,
                "failed to get response headers".into(),
            )
        })?;
    for (k, v) in upstream_resp.headers().iter() {
        out_headers.insert(k, v.clone());
    }
    // Ensure Connection: upgrade and Upgrade headers are present
    out_headers.insert(CONNECTION, HeaderValue::from_static("upgrade"));

    // Prepare response to client (empty body; the connection upgrades)
    let client_resp = client_resp_builder.body(empty_body()).map_err(|_| {
        response_with(
            StatusCode::INTERNAL_SERVER_ERROR,
            "failed to build upgrade response".into(),
        )
    })?;

    // Reconstruct the original request for upgrade
    let original_req = Request::from_parts(parts, ());

    // Spawn tunnel after returning the 101 to the client
    tokio::spawn(async move {
        match future::try_join(
            hyper::upgrade::on(original_req),
            hyper::upgrade::on(upstream_resp),
        )
        .await
        {
            Ok((client_upgraded, upstream_upgraded)) => {
                let mut client_io = TokioIo::new(client_upgraded);
                let mut upstream_io = TokioIo::new(upstream_upgraded);
                if let Err(e) = copy_bidirectional(&mut client_io, &mut upstream_io).await {
                    warn!(%e, "upgrade tunnel error");
                }
                // Try to shutdown both sides
                let _ = client_io.shutdown().await;
                let _ = upstream_io.shutdown().await;
            }
            Err(e) => {
                warn!("upgrade error: {:?}", e);
            }
        }
    });

    Ok(client_resp)
}

async fn handle_connect(
    req: Request<Incoming>,
    cfg: &ProxyConfig,
    remote_addr: SocketAddr,
) -> Result<Response<BoxBody>, Response<BoxBody>> {
    let port = get_port_from_header(req.headers())?;
    let upstream_host = upstream_host_from_headers(
        req.headers(),
        &cfg.upstream_host,
        cfg.allow_default_upstream,
    )?;
    let target = format!("{}:{}", upstream_host, port);
    info!(client = %remote_addr, %target, "tcp tunnel via CONNECT");

    // Consume request to get parts for upgrade later
    let (parts, _incoming) = req.into_parts();

    // Respond that the connection is established; then upgrade to a raw tunnel
    let resp = Response::builder()
        .status(StatusCode::OK)
        .header(CONNECTION, HeaderValue::from_static("upgrade"))
        .body(empty_body())
        .map_err(|_| {
            response_with(
                StatusCode::INTERNAL_SERVER_ERROR,
                "failed to build CONNECT response".into(),
            )
        })?;

    tokio::spawn(async move {
        let original_req = Request::from_parts(parts, ());
        match hyper::upgrade::on(original_req).await {
            Ok(upgraded) => {
                let mut client_io = TokioIo::new(upgraded);
                match TcpStream::connect(&target).await {
                    Ok(mut upstream) => {
                        if let Err(e) = copy_bidirectional(&mut client_io, &mut upstream).await {
                            warn!(%e, "tcp tunnel error");
                        }
                        let _ = client_io.shutdown().await;
                        let _ = upstream.shutdown().await;
                    }
                    Err(e) => {
                        warn!(%e, "failed to connect to upstream for CONNECT");
                        let _ = client_io
                            .write_all(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
                            .await;
                        let _ = client_io.shutdown().await;
                    }
                }
            }
            Err(e) => warn!("CONNECT upgrade error: {:?}", e),
        }
    });

    Ok(resp)
}
