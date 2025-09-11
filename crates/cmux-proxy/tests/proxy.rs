use std::convert::Infallible;
use std::io::ErrorKind;
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
                            let _ = upgraded.shutdown().await;
                        }
                        Err(_) => {}
                    }
                });

                Ok::<_, Infallible>(resp)
            } else {
                Ok::<_, Infallible>(Response::new(Body::from("not an upgrade")))
            }
        }))
    });
    let addr: SocketAddr = (IpAddr::V4(Ipv4Addr::LOCALHOST), 0).into();
    let server = Server::bind(&addr).serve(make_svc);
    let local = server.local_addr();
    tokio::spawn(server);
    local
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn http_proxy_basic() {
    let upstream = start_upstream_http().await;

    // Start proxy
    let (tx, rx) = oneshot::channel::<()>();
    let (addr, handle) = cmux_proxy::spawn_proxy(
        ProxyConfig { listen: SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), upstream_host: upstream.ip().to_string() },
        async move { let _ = rx.await; },
    );

    // HTTP client
    let client: Client<HttpConnector, Body> = Client::new();

    // Request through proxy: header picks upstream port
    let req = Request::builder()
        .method("GET")
        .uri(format!("http://{}/hello", addr))
        .header("X-Cmux-Port-Internal", upstream.port().to_string())
        .body(Body::empty())
        .unwrap();

    let resp = client.request(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = to_bytes(resp.into_body()).await.unwrap();
    assert_eq!(&body[..], b"ok:GET:/hello");

    // Shutdown
    let _ = tx.send(());
    let _ = handle.await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn http_upgrade_tunnel_echo() {
    let upstream = start_upstream_ws_like_upgrade_echo().await;

    let (tx, rx) = oneshot::channel::<()>();
    let (addr, handle) = cmux_proxy::spawn_proxy(
        ProxyConfig { listen: SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), upstream_host: upstream.ip().to_string() },
        async move { let _ = rx.await; },
    );

    // Make an upgrade request to proxy and then send bytes on the upgraded stream
    let req = Request::builder()
        .method("GET")
        .uri(format!("http://{}/upgrade", addr))
        .header("X-Cmux-Port-Internal", upstream.port().to_string())
        .header("Connection", "upgrade")
        .header("Upgrade", "websocket")
        .body(Body::empty())
        .unwrap();

    let (mut parts, _body) = req.into_parts();
    let req = Request::from_parts(parts.clone(), Body::empty());
    let client: Client<HttpConnector, Body> = Client::new();
    let mut resp = client.request(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::SWITCHING_PROTOCOLS);

    // Upgrade client side
    let mut upgraded = hyper::upgrade::on(&mut resp).await.unwrap();
    upgraded.write_all(b"ping").await.unwrap();
    let mut buf = [0u8; 4];
    upgraded.read_exact(&mut buf).await.unwrap();
    assert_eq!(&buf, b"ping");
    let _ = upgraded.shutdown().await;

    let _ = tx.send(());
    let _ = handle.await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_proxy_echo() {
    let (upstream, _handle) = start_upstream_real_ws_echo().await;

    let (tx, rx) = oneshot::channel::<()>();
    let (addr, handle) = cmux_proxy::spawn_proxy(
        ProxyConfig { listen: SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), upstream_host: upstream.ip().to_string() },
        async move { let _ = rx.await; },
    );

    // Connect a websocket client to proxy
    let url = format!("ws://{}/ws", addr);
    let (mut ws, _resp) = tokio_tungstenite::connect_async(
        url,
        Some(vec![("X-Cmux-Port-Internal".to_string(), upstream.port().to_string())])
    ).await.unwrap();

    ws.send(tungstenite::Message::Text("hello".into())).await.unwrap();
    match timeout(Duration::from_secs(3), ws.next()).await {
        Ok(Some(Ok(tungstenite::Message::Text(s)))) => assert_eq!(s, "hello"),
        other => panic!("unexpected recv: {:?}", other),
    }

    let _ = tx.send(());
    let _ = handle.await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn connect_tunnel_echo() {
    // Start a TCP echo server
    let listener = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).await.unwrap();
    let upstream = listener.local_addr().unwrap();
    tokio::spawn(async move {
        if let Ok((mut s, _addr)) = listener.accept().await {
            let mut buf = [0u8; 4];
            if s.read_exact(&mut buf).await.is_ok() {
                let _ = s.write_all(&buf).await;
            }
        }
    });

    let (tx, rx) = oneshot::channel::<()>();
    let (addr, handle) = cmux_proxy::spawn_proxy(
        ProxyConfig { listen: SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), upstream_host: upstream.ip().to_string() },
        async move { let _ = rx.await; },
    );

    // Make a CONNECT request via hyper and then upgrade to a tunnel
    let req = Request::builder()
        .method("CONNECT")
        .uri(format!("http://{}/anything", addr))
        .header("X-Cmux-Port-Internal", upstream.port().to_string())
        .body(Body::empty())
        .unwrap();

    let client: Client<HttpConnector, Body> = Client::new();
    let mut resp = client.request(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let mut upgraded = hyper::upgrade::on(&mut resp).await.unwrap();
    upgraded.write_all(b"pong").await.unwrap();
    let mut buf = [0u8; 4];
    upgraded.read_exact(&mut buf).await.unwrap();
    assert_eq!(&buf, b"pong");
    let _ = upgraded.shutdown().await;

    let _ = tx.send(());
    let _ = handle.await;
}

