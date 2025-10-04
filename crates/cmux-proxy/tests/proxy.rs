use std::convert::Infallible;
use std::io::{ErrorKind};
use std::net::{SocketAddr, IpAddr, Ipv4Addr};
use std::time::Duration;

use cmux_proxy::ProxyConfig;
use hyper::body::to_bytes;
use hyper::service::{make_service_fn, service_fn};
use hyper::{Body, Request, Response, Server, StatusCode, Client};
use hyper::client::HttpConnector;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio::time::timeout;
use futures_util::{StreamExt, SinkExt};

async fn start_upstream_real_ws_echo() -> (SocketAddr, tokio::task::JoinHandle<()>) {
    use tokio_tungstenite::accept_async;

    let listener = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).await.unwrap();
    let local = listener.local_addr().unwrap();

    let handle = tokio::spawn(async move {
        // Accept a single WebSocket connection and echo frames
        if let Ok((stream, _addr)) = listener.accept().await {
            match accept_async(stream).await {
                Ok(mut ws) => {
                    while let Some(msg) = ws.next().await {
                        match msg {
                            Ok(m) => {
                                if m.is_close() { break; }
                                if m.is_text() || m.is_binary() {
                                    if ws.send(m).await.is_err() { break; }
                                } else if let tungstenite::Message::Ping(p) = m {
                                    // Reply to ping with pong
                                    if ws.send(tungstenite::Message::Pong(p)).await.is_err() { break; }
                                }
                            }
                            Err(_) => break,
                        }
                    }
                }
                Err(_) => {}
            }
        }
    });

    (local, handle)
}

async fn start_upstream_real_ws_echo_multi() -> (SocketAddr, tokio::task::JoinHandle<()>) {
    use tokio_tungstenite::accept_async;

    let listener = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).await.unwrap();
    let local = listener.local_addr().unwrap();

    let handle = tokio::spawn(async move {
        loop {
            let (stream, _addr) = match listener.accept().await { Ok(s) => s, Err(_) => break };
            tokio::spawn(async move {
                match accept_async(stream).await {
                    Ok(mut ws) => {
                        while let Some(msg) = ws.next().await {
                            match msg {
                                Ok(m) => {
                                    if m.is_close() { break; }
                                    if m.is_text() || m.is_binary() {
                                        if ws.send(m).await.is_err() { break; }
                                    } else if let tungstenite::Message::Ping(p) = m {
                                        let _ = ws.send(tungstenite::Message::Pong(p)).await;
                                    }
                                }
                                Err(_) => break,
                            }
                        }
                    }
                    Err(_) => {}
                }
            });
        }
    });

    (local, handle)
}

async fn start_upstream_http() -> SocketAddr {
    let make_svc = make_service_fn(|_conn| async move {
        Ok::<_, Infallible>(service_fn(|req: Request<Body>| async move {
            let body = format!("ok:{}:{}", req.method(), req.uri().path());
            Ok::<_, Infallible>(Response::new(Body::from(body)))
        }))
    });
    let addr: SocketAddr = (IpAddr::V4(Ipv4Addr::LOCALHOST), 0).into();
    let server = Server::bind(&addr).serve(make_svc);
    let local = server.local_addr();
    tokio::spawn(server);
    local
}

async fn start_upstream_ws_like_upgrade_echo() -> SocketAddr {
    use hyper::header::{CONNECTION, UPGRADE};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let make_svc = make_service_fn(|_conn| async move {
        Ok::<_, Infallible>(service_fn(|mut req: Request<Body>| async move {
            let is_upgrade = req
                .headers()
                .get(CONNECTION)
                .and_then(|v| v.to_str().ok())
                .map(|s| s.to_ascii_lowercase().contains("upgrade"))
                .unwrap_or(false)
                && req.headers().contains_key(UPGRADE);

            if is_upgrade {
                let resp = Response::builder()
                    .status(StatusCode::SWITCHING_PROTOCOLS)
                    .header(CONNECTION, "upgrade")
                    .header(UPGRADE, "websocket")
                    .body(Body::empty())
                    .unwrap();

                tokio::spawn(async move {
                    match hyper::upgrade::on(&mut req).await {
                        Ok(mut upgraded) => {
                            let mut buf = [0u8; 1024];
                            loop {
                                match upgraded.read(&mut buf).await {
                                    Ok(0) => break,
                                    Ok(n) => {
                                        if upgraded.write_all(&buf[..n]).await.is_err() { break; }
                                    }
                                    Err(_) => break,
                                }
                            }
                        }
                        Err(_) => {}
                    }
                });

                return Ok::<_, Infallible>(resp);
            }

            Ok::<_, Infallible>(Response::builder().status(400).body(Body::from("no upgrade")).unwrap())
        }))
    });

    let addr: SocketAddr = (IpAddr::V4(Ipv4Addr::LOCALHOST), 0).into();
    let server = Server::bind(&addr).serve(make_svc);
    let local = server.local_addr();
    tokio::spawn(server);
    local
}

async fn start_upstream_tcp_echo() -> (SocketAddr, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).await.unwrap();
    let local = listener.local_addr().unwrap();
    let handle = tokio::spawn(async move {
        if let Ok((mut stream, _)) = listener.accept().await {
            let mut buf = vec![0u8; 1024];
            loop {
                match stream.read(&mut buf).await {
                    Ok(0) => break,
                    Ok(n) => {
                        if stream.write_all(&buf[..n]).await.is_err() { break; }
                    }
                    Err(e) => {
                        if e.kind() != ErrorKind::WouldBlock { break; }
                    }
                }
            }
        }
    });
    (local, handle)
}

async fn start_proxy(listen: SocketAddr, upstream_host: &str) -> (SocketAddr, oneshot::Sender<()>, tokio::task::JoinHandle<()>) {
    let cfg = ProxyConfig { listen, upstream_host: upstream_host.to_string() };
    let (tx, rx) = oneshot::channel::<()>();
    let (bound, handle) = cmux_proxy::spawn_proxy(cfg, async move { let _ = rx.await; });
    (bound, tx, handle)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_http_proxy_routes_by_header() {
    let upstream_addr = start_upstream_http().await;
    let (proxy_addr, shutdown, handle) = start_proxy(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), "127.0.0.1").await;

    // Build client
    let client: Client<HttpConnector, Body> = Client::new();
    let url = format!("http://{}:{}/hello", proxy_addr.ip(), proxy_addr.port());
    let req = Request::builder()
        .method("GET")
        .uri(url)
        .header("X-Cmux-Port-Internal", upstream_addr.port().to_string())
        .body(Body::empty())
        .unwrap();

    let resp = timeout(Duration::from_secs(5), client.request(req)).await.expect("resp timeout").unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = to_bytes(resp.into_body()).await.unwrap();
    let s = String::from_utf8(body.to_vec()).unwrap();
    assert!(s.contains("ok:GET:/hello"), "unexpected body: {}", s);

    // Missing header -> 400
    let url2 = format!("http://{}:{}/missing", proxy_addr.ip(), proxy_addr.port());
    let req2 = Request::builder().method("GET").uri(url2).body(Body::empty()).unwrap();
    let resp2 = timeout(Duration::from_secs(5), client.request(req2)).await.expect("resp2 timeout").unwrap();
    assert_eq!(resp2.status(), StatusCode::BAD_REQUEST);

    // shutdown
    let _ = shutdown.send(());
    let _ = handle.await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_wildcard_bind_accepts_localhost_clients() {
    let upstream_addr = start_upstream_http().await;
    let (proxy_addr, shutdown, handle) = start_proxy(SocketAddr::from((Ipv4Addr::UNSPECIFIED, 0)), "127.0.0.1").await;

    let client: Client<HttpConnector, Body> = Client::new();
    let host_addr = SocketAddr::from((Ipv4Addr::LOCALHOST, proxy_addr.port()));
    let url = format!("http://{}:{}/wildcard", host_addr.ip(), host_addr.port());
    let req = Request::builder()
        .method("GET")
        .uri(url)
        .header("X-Cmux-Port-Internal", upstream_addr.port().to_string())
        .body(Body::empty())
        .unwrap();

    let resp = timeout(Duration::from_secs(5), client.request(req))
        .await
        .expect("resp timeout")
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    shutdown.send(()).ok();
    let _ = handle.await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_websocket_proxy_upgrade() {
    let ws_addr = start_upstream_ws_like_upgrade_echo().await;
    let (proxy_addr, shutdown, handle) = start_proxy(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), "127.0.0.1").await;

    // Raw HTTP upgrade handshake to proxy
    let mut stream = TcpStream::connect(proxy_addr).await.unwrap();
    let req = format!(
        "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nConnection: upgrade\r\nUpgrade: websocket\r\nX-Cmux-Port-Internal: {}\r\n\r\n",
        proxy_addr.port(), ws_addr.port()
    );
    stream.write_all(req.as_bytes()).await.unwrap();

    // Read 101 response
    let mut resp_buf = Vec::new();
    let mut tmp = [0u8; 1024];
    loop {
        let n = timeout(Duration::from_secs(5), stream.read(&mut tmp)).await.expect("read timeout").unwrap();
        assert!(n > 0);
        resp_buf.extend_from_slice(&tmp[..n]);
        if resp_buf.windows(4).any(|w| w == b"\r\n\r\n") { break; }
    }
    let resp_text = String::from_utf8_lossy(&resp_buf);
    assert!(resp_text.starts_with("HTTP/1.1 101"), "resp: {}", resp_text);

    // Echo over upgraded connection
    let payload = b"hello-upgrade\n";
    stream.write_all(payload).await.unwrap();
    let mut recv = vec![0u8; payload.len()];
    timeout(Duration::from_secs(5), stream.read_exact(&mut recv)).await.expect("upgrade echo timeout").unwrap();
    assert_eq!(&recv, payload);

    let _ = shutdown.send(());
    let _ = handle.await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_connect_tcp_tunnel() {
    let (echo_addr, _echo_handle) = start_upstream_tcp_echo().await;
    let (proxy_addr, shutdown, handle) = start_proxy(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), "127.0.0.1").await;

    // Connect to proxy and issue CONNECT request with header
    let mut stream = TcpStream::connect(proxy_addr).await.unwrap();
    let req = format!(
        "CONNECT foo HTTP/1.1\r\nHost: foo\r\nX-Cmux-Port-Internal: {}\r\n\r\n",
        echo_addr.port()
    );
    stream.write_all(req.as_bytes()).await.unwrap();

    // Read response headers
    let mut resp_buf = Vec::new();
    let mut tmp = [0u8; 1024];
    loop {
        let n = timeout(Duration::from_secs(5), stream.read(&mut tmp)).await.expect("read timeout").unwrap();
        assert!(n > 0);
        resp_buf.extend_from_slice(&tmp[..n]);
        if resp_buf.windows(4).any(|w| w == b"\r\n\r\n") { break; }
        if resp_buf.len() > 8192 { panic!("response too large"); }
    }
    let resp_text = String::from_utf8_lossy(&resp_buf);
    assert!(resp_text.starts_with("HTTP/1.1 200"), "resp: {}", resp_text);

    // Tunnel is established now. Send and receive echo
    let payload = b"ping-123\n";
    stream.write_all(payload).await.unwrap();

    let mut recv = vec![0u8; payload.len()];
    timeout(Duration::from_secs(5), stream.read_exact(&mut recv)).await.expect("echo timeout").unwrap();
    assert_eq!(&recv, payload);

    let _ = shutdown.send(());
    let _ = handle.await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_websocket_end_to_end_frames() {
    use tokio_tungstenite::connect_async;
    use tungstenite::client::IntoClientRequest;

    // Start real WebSocket upstream and proxy
    let (ws_addr, _ws_handle) = start_upstream_real_ws_echo().await;
    let (proxy_addr, shutdown, handle) = start_proxy(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), "127.0.0.1").await;

    // Build a WebSocket client request to the proxy, adding routing header
    let url = format!("ws://{}:{}/ws", proxy_addr.ip(), proxy_addr.port());
    let mut req = url.into_client_request().unwrap();
    req.headers_mut().insert(
        "X-Cmux-Port-Internal",
        ws_addr.port().to_string().parse().unwrap(),
    );

    // Connect and perform WebSocket handshake via proxy
    let (mut ws, _resp) = timeout(Duration::from_secs(5), connect_async(req))
        .await
        .expect("ws connect timeout")
        .expect("ws connect failed");

    // Send and receive text frame
    ws.send(tungstenite::Message::Text("hello-ws".into())).await.unwrap();
    let msg = timeout(Duration::from_secs(5), ws.next()).await.expect("ws recv timeout").unwrap().unwrap();
    assert!(msg.is_text());
    assert_eq!(msg.into_text().unwrap(), "hello-ws");

    // Send and receive binary frame
    ws.send(tungstenite::Message::Binary(vec![1,2,3,4])).await.unwrap();
    let msg = timeout(Duration::from_secs(5), ws.next()).await.expect("ws recv timeout").unwrap().unwrap();
    assert!(msg.is_binary());
    assert_eq!(msg.into_data(), vec![1,2,3,4]);

    // Close
    let _ = ws.close(None).await;

    let _ = shutdown.send(());
    let _ = handle.await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_websocket_ping_pong_forwarding() {
    use tokio_tungstenite::connect_async;
    use tungstenite::client::IntoClientRequest;

    let (ws_addr, _ws_handle) = start_upstream_real_ws_echo().await;
    let (proxy_addr, shutdown, handle) = start_proxy(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), "127.0.0.1").await;

    // Connect via proxy
    let url = format!("ws://{}:{}/ws", proxy_addr.ip(), proxy_addr.port());
    let mut req = url.into_client_request().unwrap();
    req.headers_mut().insert(
        "X-Cmux-Port-Internal",
        ws_addr.port().to_string().parse().unwrap(),
    );
    let (mut ws, _resp) = timeout(Duration::from_secs(5), connect_async(req))
        .await
        .expect("ws connect timeout")
        .expect("ws connect failed");

    // Send a ping; expect a pong with same payload
    let payload = b"pp".to_vec();
    ws.send(tungstenite::Message::Ping(payload.clone())).await.unwrap();
    let msg = timeout(Duration::from_secs(5), ws.next()).await.expect("pong recv timeout").unwrap().unwrap();
    assert!(matches!(msg, tungstenite::Message::Pong(p) if p == payload));

    let _ = ws.close(None).await;
    let _ = shutdown.send(());
    let _ = handle.await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_concurrent_websocket_connections() {
    use tokio_tungstenite::connect_async;
    use tungstenite::client::IntoClientRequest;

    let (ws_addr, ws_handle) = start_upstream_real_ws_echo_multi().await;
    let (proxy_addr, shutdown, handle) = start_proxy(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), "127.0.0.1").await;

    let n = 16usize;
    let mut tasks = Vec::new();
    for i in 0..n {
        let proxy_addr = proxy_addr.clone();
        let ws_port = ws_addr.port();
        tasks.push(tokio::spawn(async move {
            let url = format!("ws://{}:{}/ws", proxy_addr.ip(), proxy_addr.port());
            let mut req = url.into_client_request().unwrap();
            req.headers_mut().insert(
                "X-Cmux-Port-Internal",
                ws_port.to_string().parse().unwrap(),
            );
            let (mut ws, _resp) = timeout(Duration::from_secs(5), connect_async(req))
                .await
                .expect("connect timeout")
                .expect("connect failed");

            // Each client sends a unique message and expects echo back
            let msg_text = format!("hello-{}", i);
            ws.send(tungstenite::Message::Text(msg_text.clone())).await.unwrap();
            let msg = timeout(Duration::from_secs(5), ws.next()).await.expect("recv timeout").unwrap().unwrap();
            assert!(msg.is_text());
            assert_eq!(msg.into_text().unwrap(), msg_text);

            // Close cleanly
            let _ = ws.close(None).await;
            Ok::<(), ()>(())
        }));
    }

    for t in tasks {
        t.await.unwrap().unwrap_or(());
    }

    // Shutdown
    ws_handle.abort();
    let _ = shutdown.send(());
    let _ = handle.await;
}
