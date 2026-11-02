use super::*;
use crate::config::{Config, PeerConfig, StoreMode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::{Message as Frame, client::IntoClientRequest};

const BOUND: Duration = Duration::from_secs(15);
const TOKEN: &str = "wireguard-test-listener-token";

fn peer(key: String, endpoint: SocketAddr, address: SocketAddr) -> PeerConfig {
    PeerConfig {
        url: "ws://127.0.0.1:1".into(),
        wireguard: Some(StaticPeer { public_key: key, endpoint: endpoint.to_string(), address }),
        token: Some(TOKEN.into()),
        peer_token: None,
        vm_boundary: false,
        github_broker: false,
    }
}

async fn pair(
    target: SocketAddr,
    wrong_key: bool,
) -> (Arc<Transport>, Arc<Transport>, Vec<tempfile::TempDir>) {
    pair_on(UdpSocket::bind("127.0.0.1:0").await.unwrap(), target, wrong_key).await
}

/// A pair whose `a` side runs on `a_socket`.
async fn pair_on(
    a_socket: UdpSocket,
    target: SocketAddr,
    wrong_key: bool,
) -> (Arc<Transport>, Arc<Transport>, Vec<tempfile::TempDir>) {
    let homes = vec![tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
    let a_key = crate::cli::mesh_node_key::load_or_create_at(homes[0].path()).unwrap();
    let b_key = crate::cli::mesh_node_key::load_or_create_at(homes[1].path()).unwrap();
    let b_socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let a = StaticConfig {
        listen: a_socket.local_addr().unwrap(),
        address: "10.77.0.1:4100".parse().unwrap(),
    };
    let b = StaticConfig {
        listen: b_socket.local_addr().unwrap(),
        address: "10.77.0.2:4100".parse().unwrap(),
    };
    let b_public = if wrong_key {
        base64::engine::general_purpose::STANDARD.encode([7; 32])
    } else {
        b_key.public_key_b64()
    };
    let a_peers = BTreeMap::from([("b".into(), peer(b_public, b.listen, b.address))]);
    let b_peers = BTreeMap::from([("a".into(), peer(a_key.public_key_b64(), a.listen, a.address))]);
    let a = Transport::from_socket(&a, &a_peers, homes[0].path(), target, a_socket).await.unwrap();
    let b = Transport::from_socket(&b, &b_peers, homes[1].path(), target, b_socket).await.unwrap();
    (a, b, homes)
}

/// What `/proc/self/fd` shows for `socket`'s descriptor: `socket:[inode]`.
#[cfg(target_os = "linux")]
fn fd_link(socket: &impl std::os::fd::AsRawFd) -> std::path::PathBuf {
    std::fs::read_link(format!("/proc/self/fd/{}", socket.as_raw_fd())).unwrap()
}

/// Whether any descriptor of this process is `link`'s socket.
#[cfg(target_os = "linux")]
fn this_process_holds(link: &std::path::Path) -> bool {
    std::fs::read_dir("/proc/self/fd")
        .unwrap()
        .flatten()
        .any(|fd| std::fs::read_link(fd.path()).is_ok_and(|target| target == link))
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_stack_size(32 << 20)
        .enable_all()
        .build()
        .unwrap()
}

#[test]
fn disabled_never_binds_udp_or_reads_a_key() {
    runtime().block_on(async {
        let occupied = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let dir = tempfile::tempdir().unwrap();
        let mut cfg = Config::default();
        cfg.transport.wireguard_static = Some(StaticConfig {
            listen: occupied.local_addr().unwrap(),
            address: "10.77.0.1:4100".parse().unwrap(),
        });
        let disabled =
            Transport::start(&cfg, &dir.path().join("absent"), "127.0.0.1:1".parse().unwrap())
                .await
                .unwrap();
        assert!(disabled.is_none());
        assert!(!dir.path().join("absent").exists());
        cfg.transport.wireguard = true;
        assert!(
            Transport::start(&cfg, dir.path(), "127.0.0.1:1".parse().unwrap()).await.is_err(),
            "the occupied UDP socket must prevent enabled startup"
        );
    });
}

#[test]
fn wrong_key_cannot_open_a_stream() {
    runtime().block_on(async {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let (a, b, _homes) = pair(target.local_addr().unwrap(), true).await;
        let result =
            tokio::time::timeout(Duration::from_secs(1), a.connect(a.route("b").unwrap())).await;
        assert!(!matches!(result, Ok(Ok(_))), "a wrong-key tunnel opened");
        assert!(tokio::time::timeout(Duration::from_millis(50), target.accept()).await.is_err());
        a.shutdown(tokio::time::Instant::now()).await;
        b.shutdown(tokio::time::Instant::now()).await;
    });
}

async fn websocket_server() -> (SocketAddr, String, JoinHandle<()>, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let auth = crate::server::peer_auth::PeerAuth::create(dir.path()).unwrap();
    let peer_token = std::fs::read_to_string(auth.path()).unwrap();
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, dir.path()).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let task = tokio::spawn(async move {
        crate::server::serve_ws_with(
            hub,
            listener,
            TOKEN.into(),
            crate::server::WsAuth { local_app: None, peer: Some(Arc::new(auth)) },
        )
        .await
        .unwrap();
    });
    (address, peer_token, task, dir)
}

async fn connect_ws(
    transport: &Transport,
    token: &str,
    peer_token: Option<&str>,
) -> Result<tokio_tungstenite::WebSocketStream<WgStream>> {
    let stream = transport.connect(transport.route("b").unwrap()).await?;
    let mut request = "ws://localhost:4100/".into_client_request()?;
    request.headers_mut().insert("authorization", format!("Bearer {token}").parse()?);
    if let Some(peer_token) = peer_token {
        request.headers_mut().insert(crate::server::peer_auth::HEADER, peer_token.trim().parse()?);
    }
    Ok(tokio_tungstenite::client_async_with_config(
        request,
        stream,
        Some(crate::server::ws_config()),
    )
    .await?
    .0)
}

async fn call(
    ws: &mut tokio_tungstenite::WebSocketStream<WgStream>,
    id: u64,
    method: &str,
) -> Value {
    ws.send(Frame::Text(json!({"jsonrpc":"2.0", "id":id, "method":method,
        "params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"wg-test","version":"1"}}}).to_string().into())).await.unwrap();
    tokio::time::timeout(BOUND, async {
        while let Some(frame) = ws.next().await {
            if let Frame::Text(text) = frame.unwrap() {
                let message: Value = serde_json::from_str(&text).unwrap();
                if message["id"] == id {
                    return message;
                }
            }
        }
        panic!("session stream closed before its response")
    })
    .await
    .unwrap()
}

#[test]
fn session_streams_are_multiplexed_and_keep_websocket_authorization() {
    runtime().block_on(async {
        let (target, peer_token, server, _server_home) = websocket_server().await;
        let (a, b, _homes) = pair(target, false).await;
        assert!(tokio::time::timeout(BOUND, connect_ws(&a, "wrong", None)).await.unwrap().is_err());
        let mut web =
            tokio::time::timeout(BOUND, connect_ws(&a, TOKEN, None)).await.unwrap().unwrap();
        let mut peer = tokio::time::timeout(BOUND, connect_ws(&a, TOKEN, Some(&peer_token)))
            .await
            .unwrap()
            .unwrap();
        let web_hello = call(&mut web, 1, "initialize").await;
        assert_eq!(web_hello["result"]["_meta"]["acpmux"]["origin"], "remote");
        assert_eq!(web_hello["result"]["_meta"]["acpmux"]["auth"], "listenerToken");
        let peer_hello = call(&mut peer, 1, "initialize").await;
        assert_eq!(peer_hello["result"]["_meta"]["acpmux"]["origin"], "peer");
        assert_eq!(peer_hello["result"]["_meta"]["acpmux"]["auth"], "peerToken");
        let web_calls = async {
            for id in 2..10 {
                assert!(call(&mut web, id, "session/list").await["result"].is_object());
            }
        };
        let peer_calls = async {
            for id in 2..10 {
                assert!(call(&mut peer, id, "session/list").await["result"].is_object());
            }
        };
        tokio::join!(web_calls, peer_calls);
        web.close(None).await.unwrap();
        peer.close(None).await.unwrap();
        a.shutdown(tokio::time::Instant::now()).await;
        b.shutdown(tokio::time::Instant::now()).await;
        server.abort();
        let _ = server.await;
    });
}

#[test]
fn peer_uses_the_shared_mesh_before_its_unreachable_fallback() {
    runtime().block_on(async {
        let (target, peer_token, server, _server_home) = websocket_server().await;
        let (a, b, _homes) = pair(target, false).await;
        let (notices, mut received) = tokio::sync::mpsc::channel(32);
        let peer = crate::peer::Peer::new(
            "b",
            "ws://127.0.0.1:1",
            Some(TOKEN.into()),
            Some(peer_token.trim().into()),
            notices,
        );
        peer.set_wireguard(a.clone(), a.route("b").unwrap());
        let task = tokio::spawn(peer.clone().run());
        tokio::time::timeout(BOUND, async {
            while let Some((_, _, notice)) = received.recv().await {
                if matches!(notice, crate::peer::PeerNotice::Connected) {
                    return;
                }
            }
            panic!("peer did not connect");
        })
        .await
        .unwrap();
        assert!(peer.request("session/list", json!({})).await.unwrap().is_object());
        peer.stop();
        tokio::time::timeout(BOUND, task).await.unwrap().unwrap();
        a.shutdown(tokio::time::Instant::now()).await;
        b.shutdown(tokio::time::Instant::now()).await;
        server.abort();
        let _ = server.await;
    });
}

async fn measure_websocket<S>(
    stream: S,
    payload: &[u8],
) -> (tokio_tungstenite::WebSocketStream<S>, f64)
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let mut request = "ws://localhost:4100/".into_client_request().unwrap();
    request.headers_mut().insert("authorization", format!("Bearer {TOKEN}").parse().unwrap());
    request
        .headers_mut()
        .insert(crate::server::peer_auth::HEADER, "benchmark-peer-token".parse().unwrap());
    let (mut ws, _) = tokio_tungstenite::client_async_with_config(
        request,
        stream,
        Some(crate::server::ws_config()),
    )
    .await
    .unwrap();
    let started = std::time::Instant::now();
    ws.send(Frame::Binary(payload.to_vec().into())).await.unwrap();
    let echoed = tokio::time::timeout(BOUND, ws.next()).await.unwrap().unwrap().unwrap();
    assert_eq!(echoed.into_data().as_ref(), payload, "ordered bytes changed in transit");
    let rate = (payload.len() * 2) as f64 / (1024.0 * 1024.0) / started.elapsed().as_secs_f64();
    (ws, rate)
}

#[test]
fn loopback_throughput_and_shutdown() {
    runtime().block_on(async {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target_address = target.local_addr().unwrap();
        let a_socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        #[cfg(target_os = "linux")]
        let a_socket_link = fd_link(&a_socket);
        let (a, b, _homes) = pair_on(a_socket, target_address, false).await;
        // Both paths use the same token-authenticated WebSocket echo fixture,
        // payload, limits and runner. Only the stream beneath WS changes.
        let echo = tokio::spawn(async move {
            let mut connections = JoinSet::new();
            for _ in 0..2 {
                let (stream, _) = target.accept().await.unwrap();
                connections.spawn(async move {
                    let callback = |request: &tokio_tungstenite::tungstenite::handshake::server::Request,
                        response: tokio_tungstenite::tungstenite::handshake::server::Response| {
                        let listener = request.headers().get("authorization").and_then(|v| v.to_str().ok())
                            .and_then(cmux_local_auth::bearer_token);
                        let peer = request.headers().get(crate::server::peer_auth::HEADER).and_then(|v| v.to_str().ok());
                        if cmux_local_auth::check_token(listener, TOKEN).is_ok()
                            && peer.is_some_and(|p| cmux_local_auth::tokens_match(p, "benchmark-peer-token")) {
                            Ok(response)
                        } else {
                            Err(tokio_tungstenite::tungstenite::http::Response::builder().status(401)
                                .body(Some("credential refused".into())).unwrap())
                        }
                    };
                    let mut ws = tokio_tungstenite::accept_hdr_async_with_config(stream, callback,
                        Some(crate::server::ws_config())).await.unwrap();
                    while let Some(Ok(frame)) = ws.next().await {
                        if frame.is_close() { break; }
                        if ws.send(frame).await.is_err() { break; }
                    }
                });
            }
            while connections.join_next().await.is_some() {}
        });
        let payload: Vec<u8> = (0..8 * 1024 * 1024).map(|i| (i % 251) as u8).collect();
        let started = std::time::Instant::now();
        let direct = TcpStream::connect(target_address).await.unwrap();
        direct.set_nodelay(true).unwrap();
        let before_handshake_ms = started.elapsed().as_secs_f64() * 1000.0;
        let (mut direct, before_rate) = measure_websocket(direct, &payload).await;
        direct.close(None).await.unwrap();
        let started = std::time::Instant::now();
        let stream = tokio::time::timeout(BOUND, a.connect(a.route("b").unwrap())).await.unwrap().unwrap();
        let after_handshake_ms = started.elapsed().as_secs_f64() * 1000.0;
        let (mut tunneled, after_rate) = measure_websocket(stream, &payload).await;
        println!("WIREGUARD_PERF before_tcp_ms={before_handshake_ms:.3} after_wg_tcp_ms={after_handshake_ms:.3} before_authenticated_ws_mib_s={before_rate:.3} after_authenticated_ws_mib_s={after_rate:.3} bytes={}", payload.len());
        #[cfg(target_os = "linux")]
        assert!(this_process_holds(&a_socket_link), "the transport runs on its UDP socket");
        #[cfg(not(target_os = "linux"))]
        let local = a.local_addr();
        a.shutdown(tokio::time::Instant::now()).await;
        // Releasing UDP is this process closing its socket. A process another test is spawning
        // holds a copy from its fork until its exec, and the port stays bound until that copy
        // closes too, so a rebind here could fail with nothing of ours left holding it.
        #[cfg(target_os = "linux")]
        assert!(!this_process_holds(&a_socket_link), "shutdown must release UDP");
        #[cfg(not(target_os = "linux"))]
        assert!(UdpSocket::bind(local).await.is_ok(), "shutdown must release UDP");
        let closed = tokio::time::timeout(BOUND, tunneled.next()).await
            .expect("shutdown must resolve a pending stream read");
        assert!(!matches!(closed, Some(Ok(frame)) if !frame.is_close()), "shutdown must end the stream");
        b.shutdown(tokio::time::Instant::now()).await;
        tokio::time::timeout(BOUND, echo).await.unwrap().unwrap();
    });
}

/// What this daemon's listener sent a peer just before the transport stops (a restart's
/// WebSocket close 1012, sent as the daemon stops) reaches that peer before the tunnel's end.
/// Before, the stop aborted each bridge before it forwarded those bytes and reset every tunnel
/// connection, so the peer read a reset or an end with no close frame (full Linux test runs,
/// jobs 38e8e52e01839ea5d499f49e and dd8687a112bd464b1a8350b0). The order is forced, not
/// timed: on one thread the stop runs before the bridge reads the listener's last bytes.
#[test]
fn a_stop_delivers_what_the_listener_sent_before_the_tunnel_ends() {
    tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let (a, b, _homes) = pair(target.local_addr().unwrap(), false).await;
        let mut stream =
            tokio::time::timeout(BOUND, a.connect(a.route("b").unwrap())).await.unwrap().unwrap();
        stream.write_all(b"hello").await.unwrap();
        let (mut local, _) = tokio::time::timeout(BOUND, target.accept()).await.unwrap().unwrap();
        let mut hello = [0; 5];
        local.read_exact(&mut hello).await.unwrap();
        // The listener's last words, then its close, as a draining WebSocket listener does.
        local.write_all(b"last words").await.unwrap();
        drop(local);
        b.shutdown(tokio::time::Instant::now() + BOUND).await;
        let mut got = Vec::new();
        let read = tokio::time::timeout(BOUND, stream.read_to_end(&mut got)).await.unwrap();
        assert!(read.is_ok(), "the tunnel was reset: {read:?}, after {got:?}");
        assert_eq!(got, b"last words");
        a.shutdown(tokio::time::Instant::now()).await;
    });
}
