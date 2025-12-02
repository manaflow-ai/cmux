#![cfg(target_os = "linux")]

use std::convert::Infallible;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Duration;

use bytes::Bytes;
use cmux_proxy::{workspace_ip_from_name, ProxyConfig};
use futures_util::FutureExt;
use http::{Method, Request, Response, StatusCode};
use http_body_util::{BodyExt, Empty, Full};
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper_util::client::legacy::{connect::HttpConnector, Client};
use hyper_util::rt::{TokioExecutor, TokioIo};
use hyper_util::server::conn::auto::Builder as AutoBuilder;
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio::time::{sleep, timeout};

async fn start_upstream_http_on(ip: Ipv4Addr) -> SocketAddr {
    let listener = TcpListener::bind(SocketAddr::from((IpAddr::V4(ip), 0)))
        .await
        .expect("bind upstream");
    let local = listener.local_addr().expect("local addr");
    tokio::spawn(async move {
        loop {
            let (stream, _) = match listener.accept().await {
                Ok(s) => s,
                Err(_) => break,
            };
            tokio::spawn(async move {
                let service = service_fn(|req: Request<Incoming>| async move {
                    let body = format!("ok:{}:{}", req.method(), req.uri().path());
                    Ok::<_, Infallible>(Response::new(Full::new(Bytes::from(body))))
                });
                if let Err(err) = AutoBuilder::new(TokioExecutor::new())
                    .serve_connection(TokioIo::new(stream), service)
                    .await
                {
                    eprintln!("HTTP upstream error: {err}");
                }
            });
        }
    });
    local
}

#[cfg(target_os = "linux")]
async fn start_upstream_http_on_fixed(ip: Ipv4Addr, port: u16, body: &'static str) {
    let listener = TcpListener::bind(SocketAddr::from((IpAddr::V4(ip), port)))
        .await
        .expect("bind fixed upstream");
    let response_bytes = Bytes::from_static(body.as_bytes());
    tokio::spawn(async move {
        loop {
            let (stream, _) = match listener.accept().await {
                Ok(s) => s,
                Err(_) => break,
            };
            let response_bytes = response_bytes.clone();
            tokio::spawn(async move {
                let service = service_fn(move |_req: Request<Incoming>| {
                    let response_bytes = response_bytes.clone();
                    async move { Ok::<_, Infallible>(Response::new(Full::new(response_bytes))) }
                });
                if let Err(err) = AutoBuilder::new(TokioExecutor::new())
                    .serve_connection(TokioIo::new(stream), service)
                    .await
                {
                    eprintln!("HTTP upstream fixed error: {err}");
                }
            });
        }
    });
    sleep(Duration::from_millis(50)).await;
}

async fn start_proxy(
    listen: SocketAddr,
    upstream_host: &str,
    allow_default_upstream: bool,
) -> (SocketAddr, oneshot::Sender<()>, tokio::task::JoinHandle<()>) {
    let cfg = ProxyConfig {
        listen,
        upstream_host: upstream_host.to_string(),
        allow_default_upstream,
    };
    let (tx, rx) = oneshot::channel::<()>();
    let (bound, handle) = cmux_proxy::spawn_proxy(
        cfg,
        async move {
            let _ = rx.await;
        }
        .boxed(),
    )
    .expect("failed to spawn proxy");
    sleep(Duration::from_millis(25)).await;
    (bound, tx, handle)
}

fn new_test_client() -> Client<HttpConnector, Empty<Bytes>> {
    let connector = HttpConnector::new();
    Client::builder(TokioExecutor::new()).build(connector)
}

fn next_port() -> u16 {
    std::net::TcpListener::bind(("127.0.0.1", 0))
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

#[cfg(target_os = "linux")]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_http_proxy_routes_by_workspace_header() {
    // workspace-1 -> 127.18.0.1
    let ws_name = "workspace-1";
    let ws_ip = workspace_ip_from_name(ws_name).expect("mapping");

    // Start upstream on the workspace IP
    let upstream_addr = start_upstream_http_on(ws_ip).await;

    // Start proxy on localhost
    let (proxy_addr, shutdown, handle) = start_proxy(
        SocketAddr::from((Ipv4Addr::LOCALHOST, next_port())),
        "127.0.0.1",
        false,
    )
    .await;

    // HTTP client
    let client = new_test_client();
    let url = format!("http://{}:{}/hello", proxy_addr.ip(), proxy_addr.port());
    let req = Request::builder()
        .method(Method::GET)
        .uri(url)
        .header("X-Cmux-Workspace-Internal", ws_name)
        .header("X-Cmux-Port-Internal", upstream_addr.port().to_string())
        .body(Empty::new())
        .unwrap();

    let resp = timeout(Duration::from_secs(5), client.request(req))
        .await
        .expect("resp timeout")
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    // fail on purpose
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let s = String::from_utf8(body.to_vec()).unwrap();
    assert!(s.contains("ok:GET:/hello"), "unexpected body: {}", s);

    let _ = shutdown.send(());
    let _ = handle.await;
}

#[cfg(target_os = "linux")]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_http_proxy_routes_by_subdomain_workspace() {
    // Verify subdomain pattern <workspace>-<port>.localhost maps to workspace IP and port
    let ws_name = "workspace-a";
    let ws_ip = workspace_ip_from_name(ws_name).expect("mapping");
    let port = 3002u16;

    // Start upstream bound to workspace IP:port
    start_upstream_http_on_fixed(ws_ip, port, "ok-subdomain").await;

    // Start proxy
    let (proxy_addr, shutdown, handle) = start_proxy(
        SocketAddr::from((Ipv4Addr::LOCALHOST, next_port())),
        "127.0.0.1",
        false,
    )
    .await;

    // HTTP client. Connect to proxy by address, but send Host: <workspace>-<port>.localhost
    let client = new_test_client();
    let url = format!("http://{}:{}/hello", proxy_addr.ip(), proxy_addr.port());
    let req = Request::builder()
        .method(Method::GET)
        .uri(url)
        .header("Host", format!("{}-{}.localhost", ws_name, port))
        .body(Empty::new())
        .unwrap();

    let resp = timeout(Duration::from_secs(5), client.request(req))
        .await
        .expect("resp timeout")
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let s = String::from_utf8(body.to_vec()).unwrap();
    assert!(s.contains("ok-subdomain"), "unexpected body: {}", s);

    let _ = shutdown.send(());
    let _ = handle.await;
}

#[cfg(target_os = "linux")]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_default_upstream_mode_without_workspace_header() {
    // Start upstream on default loopback host
    let upstream_addr = start_upstream_http_on(Ipv4Addr::LOCALHOST).await;
    let ws_name = "workspace-a";
    let ws_ip = workspace_ip_from_name(ws_name).expect("workspace ip");
    let ws_upstream_addr = start_upstream_http_on(ws_ip).await;

    // Start proxy with allow_default_upstream enabled
    let (proxy_addr, shutdown, handle) = start_proxy(
        SocketAddr::from((Ipv4Addr::LOCALHOST, next_port())),
        "127.0.0.1",
        true,
    )
    .await;

    // Send request without workspace header but with workspace-looking host
    let client = new_test_client();
    let url = format!("http://{}:{}/default", proxy_addr.ip(), proxy_addr.port());
    let req = Request::builder()
        .method(Method::GET)
        .uri(url)
        .header("X-Cmux-Port-Internal", upstream_addr.port().to_string())
        .body(Empty::new())
        .unwrap();

    let resp = timeout(Duration::from_secs(5), client.request(req))
        .await
        .expect("resp timeout")
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let s = String::from_utf8(body.to_vec()).unwrap();
    assert!(
        s.contains("ok:GET:/default"),
        "unexpected body from default upstream: {}",
        s
    );

    // Workspace-specific request still honors per-workspace routing
    let ws_url = format!("http://{}:{}/workspace", proxy_addr.ip(), proxy_addr.port());
    let ws_req = Request::builder()
        .method(Method::GET)
        .uri(ws_url)
        .header("X-Cmux-Workspace-Internal", ws_name)
        .header("X-Cmux-Port-Internal", ws_upstream_addr.port().to_string())
        .body(Empty::new())
        .unwrap();

    let ws_resp = timeout(Duration::from_secs(5), client.request(ws_req))
        .await
        .expect("workspace resp timeout")
        .unwrap();
    assert_eq!(ws_resp.status(), StatusCode::OK);
    let ws_body = ws_resp.into_body().collect().await.unwrap().to_bytes();
    let ws_text = String::from_utf8(ws_body.to_vec()).unwrap();
    assert!(
        ws_text.contains("ok:GET:/workspace"),
        "unexpected body from workspace upstream: {}",
        ws_text
    );

    let _ = shutdown.send(());
    let _ = handle.await;
}

#[cfg(target_os = "linux")]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_http_proxy_routes_by_workspace_non_numeric() {
    // workspace-c -> hashed mapping
    let ws_name = "workspace-c";
    let ws_ip = workspace_ip_from_name(ws_name).expect("mapping");

    // Start upstream on the workspace IP
    let upstream_addr = start_upstream_http_on(ws_ip).await;

    // Start proxy on localhost
    let (proxy_addr, shutdown, handle) = start_proxy(
        SocketAddr::from((Ipv4Addr::LOCALHOST, next_port())),
        "127.0.0.1",
        false,
    )
    .await;

    // HTTP client
    let client = new_test_client();
    let url = format!("http://{}:{}/hello", proxy_addr.ip(), proxy_addr.port());
    let req = Request::builder()
        .method(Method::GET)
        .uri(url)
        .header("X-Cmux-Workspace-Internal", ws_name)
        .header("X-Cmux-Port-Internal", upstream_addr.port().to_string())
        .body(Empty::new())
        .unwrap();

    let resp = timeout(Duration::from_secs(5), client.request(req))
        .await
        .expect("resp timeout")
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let s = String::from_utf8(body.to_vec()).unwrap();
    assert!(s.contains("ok:GET:/hello"), "unexpected body: {}", s);

    let _ = shutdown.send(());
    let _ = handle.await;
}

#[cfg(target_os = "linux")]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_workspace_dynamic_server_then_success() {
    let ws_name = "workspace-a";
    let ws_ip = workspace_ip_from_name(ws_name).expect("mapping");
    let port = 3000u16;

    // Start proxy
    let (proxy_addr, shutdown, handle) = start_proxy(
        SocketAddr::from((Ipv4Addr::LOCALHOST, next_port())),
        "127.0.0.1",
        false,
    )
    .await;
    let client = new_test_client();
    let url = format!("http://{}:{}/hello", proxy_addr.ip(), proxy_addr.port());

    // First request should fail (no upstream yet)
    let req1 = Request::builder()
        .method(Method::GET)
        .uri(&url)
        .header("X-Cmux-Workspace-Internal", ws_name)
        .header("X-Cmux-Port-Internal", port.to_string())
        .body(Empty::new())
        .unwrap();
    let resp1 = timeout(Duration::from_secs(5), client.request(req1))
        .await
        .expect("resp1 timeout")
        .unwrap();
    assert_eq!(resp1.status(), StatusCode::BAD_GATEWAY);

    // Create workspace dir and start upstream bound to workspace IP:port
    let _ = std::fs::create_dir_all("/root/workspace-a");
    start_upstream_http_on_fixed(ws_ip, port, "ok-from-a").await;

    // Second request should succeed
    let req2 = Request::builder()
        .method(Method::GET)
        .uri(&url)
        .header("X-Cmux-Workspace-Internal", ws_name)
        .header("X-Cmux-Port-Internal", port.to_string())
        .body(Empty::new())
        .unwrap();
    let resp2 = timeout(Duration::from_secs(5), client.request(req2))
        .await
        .expect("resp2 timeout")
        .unwrap();
    assert_eq!(resp2.status(), StatusCode::OK);
    let body2 = resp2.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(String::from_utf8_lossy(&body2), "ok-from-a");

    let _ = shutdown.send(());
    let _ = handle.await;
}

#[cfg(target_os = "linux")]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_same_port_isolation_across_workspaces() {
    // Same port in different workspaces; ensure isolation by workspace IP
    let ws_a = "workspace-a";
    let ws_b = "workspace-b";
    let ip_a = workspace_ip_from_name(ws_a).expect("map a");
    let ip_b = workspace_ip_from_name(ws_b).expect("map b");
    let port = 3001u16;

    start_upstream_http_on_fixed(ip_a, port, "hello-from-A").await;
    start_upstream_http_on_fixed(ip_b, port, "hello-from-B").await;

    let (proxy_addr, shutdown, handle) = start_proxy(
        SocketAddr::from((Ipv4Addr::LOCALHOST, next_port())),
        "127.0.0.1",
        false,
    )
    .await;
    let client = new_test_client();
    let url = format!("http://{}:{}/check", proxy_addr.ip(), proxy_addr.port());

    // Request to A
    let req_a = Request::builder()
        .method(Method::GET)
        .uri(&url)
        .header("X-Cmux-Workspace-Internal", ws_a)
        .header("X-Cmux-Port-Internal", port.to_string())
        .body(Empty::new())
        .unwrap();
    let resp_a = timeout(Duration::from_secs(5), client.request(req_a))
        .await
        .expect("resp a timeout")
        .unwrap();
    assert_eq!(resp_a.status(), StatusCode::OK);
    let body_a = resp_a.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(String::from_utf8_lossy(&body_a), "hello-from-A");

    // Request to B
    let req_b = Request::builder()
        .method(Method::GET)
        .uri(&url)
        .header("X-Cmux-Workspace-Internal", ws_b)
        .header("X-Cmux-Port-Internal", port.to_string())
        .body(Empty::new())
        .unwrap();
    let resp_b = timeout(Duration::from_secs(5), client.request(req_b))
        .await
        .expect("resp b timeout")
        .unwrap();
    assert_eq!(resp_b.status(), StatusCode::OK);
    let body_b = resp_b.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(String::from_utf8_lossy(&body_b), "hello-from-B");

    let _ = shutdown.send(());
    let _ = handle.await;
}
