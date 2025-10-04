use std::convert::Infallible;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Duration;

use cmux_proxy::{ProxyConfig, workspace_ip_from_name};
use hyper::body::to_bytes;
use hyper::service::{make_service_fn, service_fn};
use hyper::{Body, Client, Method, Request, Response, Server, StatusCode};
use hyper::client::HttpConnector;
use tokio::sync::oneshot;
use tokio::time::timeout;
use tokio::time::sleep;

async fn start_upstream_http_on(ip: Ipv4Addr) -> SocketAddr {
    let make_svc = make_service_fn(|_conn| async move {
        Ok::<_, Infallible>(service_fn(|req: Request<Body>| async move {
            let body = format!("ok:{}:{}", req.method(), req.uri().path());
            Ok::<_, Infallible>(Response::new(Body::from(body)))
        }))
    });
    let addr: SocketAddr = (IpAddr::V4(ip), 0).into();
    let server = Server::bind(&addr).serve(make_svc);
    let local = server.local_addr();
    tokio::spawn(server);
    local
}

#[cfg(target_os = "linux")]
async fn start_upstream_http_on_fixed(ip: Ipv4Addr, port: u16, body: &'static str) {
    let make_svc = make_service_fn(move |_conn| async move {
        let body_text = body;
        Ok::<_, Infallible>(service_fn(move |_req: Request<Body>| async move {
            Ok::<_, Infallible>(Response::new(Body::from(body_text)))
        }))
    });
    let addr: SocketAddr = (IpAddr::V4(ip), port).into();
    let server = Server::bind(&addr).serve(make_svc);
    tokio::spawn(server);
    // tiny delay to ensure listener is up
    sleep(Duration::from_millis(50)).await;
}

async fn start_proxy(listen: SocketAddr, upstream_host: &str) -> (SocketAddr, oneshot::Sender<()>, tokio::task::JoinHandle<()>) {
    let cfg = ProxyConfig { listen, upstream_host: upstream_host.to_string() };
    let (tx, rx) = oneshot::channel::<()>();
    let (bound, handle) = cmux_proxy::spawn_proxy(cfg, async move { let _ = rx.await; });
    (bound, tx, handle)
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
    let (proxy_addr, shutdown, handle) = start_proxy(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), "127.0.0.1").await;

    // HTTP client
    let client: Client<HttpConnector, Body> = Client::new();
    let url = format!("http://{}:{}/hello", proxy_addr.ip(), proxy_addr.port());
    let req = Request::builder()
        .method(Method::GET)
        .uri(url)
        .header("X-Cmux-Workspace-Internal", ws_name)
        .header("X-Cmux-Port-Internal", upstream_addr.port().to_string())
        .body(Body::empty())
        .unwrap();

        
    let resp = timeout(Duration::from_secs(5), client.request(req)).await.expect("resp timeout").unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    // fail on purpose
    let body = to_bytes(resp.into_body()).await.unwrap();
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
    let (proxy_addr, shutdown, handle) = start_proxy(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), "127.0.0.1").await;

    // HTTP client. Connect to proxy by address, but send Host: <workspace>-<port>.localhost
    let client: Client<HttpConnector, Body> = Client::new();
    let url = format!("http://{}:{}/hello", proxy_addr.ip(), proxy_addr.port());
    let req = Request::builder()
        .method(Method::GET)
        .uri(url)
        .header("Host", format!("{}-{}.localhost", ws_name, port))
        .body(Body::empty())
        .unwrap();

    let resp = timeout(Duration::from_secs(5), client.request(req))
        .await
        .expect("resp timeout")
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = to_bytes(resp.into_body()).await.unwrap();
    let s = String::from_utf8(body.to_vec()).unwrap();
    assert!(s.contains("ok-subdomain"), "unexpected body: {}", s);

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
    let (proxy_addr, shutdown, handle) = start_proxy(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), "127.0.0.1").await;

    // HTTP client
    let client: Client<HttpConnector, Body> = Client::new();
    let url = format!("http://{}:{}/hello", proxy_addr.ip(), proxy_addr.port());
    let req = Request::builder()
        .method(Method::GET)
        .uri(url)
        .header("X-Cmux-Workspace-Internal", ws_name)
        .header("X-Cmux-Port-Internal", upstream_addr.port().to_string())
        .body(Body::empty())
        .unwrap();

    let resp = timeout(Duration::from_secs(5), client.request(req)).await.expect("resp timeout").unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = to_bytes(resp.into_body()).await.unwrap();
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
    let (proxy_addr, shutdown, handle) = start_proxy(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), "127.0.0.1").await;
    let client: Client<HttpConnector, Body> = Client::new();
    let url = format!("http://{}:{}/hello", proxy_addr.ip(), proxy_addr.port());

    // First request should fail (no upstream yet)
    let req1 = Request::builder()
        .method(Method::GET)
        .uri(&url)
        .header("X-Cmux-Workspace-Internal", ws_name)
        .header("X-Cmux-Port-Internal", port.to_string())
        .body(Body::empty())
        .unwrap();
    let resp1 = timeout(Duration::from_secs(5), client.request(req1)).await.expect("resp1 timeout").unwrap();
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
        .body(Body::empty())
        .unwrap();
    let resp2 = timeout(Duration::from_secs(5), client.request(req2)).await.expect("resp2 timeout").unwrap();
    assert_eq!(resp2.status(), StatusCode::OK);
    let body2 = to_bytes(resp2.into_body()).await.unwrap();
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

    let (proxy_addr, shutdown, handle) = start_proxy(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), "127.0.0.1").await;
    let client: Client<HttpConnector, Body> = Client::new();
    let url = format!("http://{}:{}/check", proxy_addr.ip(), proxy_addr.port());

    // Request to A
    let req_a = Request::builder()
        .method(Method::GET)
        .uri(&url)
        .header("X-Cmux-Workspace-Internal", ws_a)
        .header("X-Cmux-Port-Internal", port.to_string())
        .body(Body::empty())
        .unwrap();
    let resp_a = timeout(Duration::from_secs(5), client.request(req_a)).await.expect("resp a timeout").unwrap();
    assert_eq!(resp_a.status(), StatusCode::OK);
    let body_a = to_bytes(resp_a.into_body()).await.unwrap();
    assert_eq!(String::from_utf8_lossy(&body_a), "hello-from-A");

    // Request to B
    let req_b = Request::builder()
        .method(Method::GET)
        .uri(&url)
        .header("X-Cmux-Workspace-Internal", ws_b)
        .header("X-Cmux-Port-Internal", port.to_string())
        .body(Body::empty())
        .unwrap();
    let resp_b = timeout(Duration::from_secs(5), client.request(req_b)).await.expect("resp b timeout").unwrap();
    assert_eq!(resp_b.status(), StatusCode::OK);
    let body_b = to_bytes(resp_b.into_body()).await.unwrap();
    assert_eq!(String::from_utf8_lossy(&body_b), "hello-from-B");

    let _ = shutdown.send(());
    let _ = handle.await;
}
