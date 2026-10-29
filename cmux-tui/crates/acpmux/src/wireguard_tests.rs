use super::*;
use crate::config::{Config, PeerConfig, StoreMode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
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
    let homes = vec![tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
    let a_key = crate::cli::mesh_node_key::load_or_create_at(homes[0].path()).unwrap();
    let b_key = crate::cli::mesh_node_key::load_or_create_at(homes[1].path()).unwrap();
    let a_socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
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
        a.shutdown().await;
        b.shutdown().await;
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
        a.shutdown().await;
        b.shutdown().await;
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
        a.shutdown().await;
        b.shutdown().await;
        server.abort();
        let _ = server.await;
    });
}

#[test]
fn loopback_throughput_and_shutdown() {
    runtime().block_on(async {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let (a, b, _homes) = pair(target.local_addr().unwrap(), false).await;
        let echo = tokio::spawn(async move {
            let (stream, _) = target.accept().await.unwrap();
            let (mut read, mut write) = stream.into_split();
            tokio::io::copy(&mut read, &mut write).await.unwrap();
        });
        let start = std::time::Instant::now();
        let mut stream =
            tokio::time::timeout(BOUND, a.connect(a.route("b").unwrap())).await.unwrap().unwrap();
        let handshake_ms = start.elapsed().as_secs_f64() * 1000.0;
        let payload: Vec<u8> = (0..8 * 1024 * 1024).map(|i| (i % 251) as u8).collect();
        let start = std::time::Instant::now();
        let (mut read, mut write) = tokio::io::split(&mut stream);
        tokio::time::timeout(BOUND, async {
            let sent = async {
                write.write_all(&payload).await.unwrap();
            };
            let received = async {
                let mut received = vec![0; payload.len()];
                read.read_exact(&mut received).await.unwrap();
                assert!(received == payload, "ordered bytes changed in transit");
            };
            tokio::join!(sent, received);
        })
        .await
        .unwrap();
        println!(
            "WIREGUARD_PERF handshake_ms={handshake_ms:.3} roundtrip_mib_s={:.3} bytes={}",
            16.0 / start.elapsed().as_secs_f64(),
            payload.len()
        );
        let local = a.local_addr();
        a.shutdown().await;
        assert!(UdpSocket::bind(local).await.is_ok(), "shutdown must release UDP");
        assert!(!matches!(tokio::time::timeout(BOUND, stream.read_u8()).await, Ok(Ok(_))));
        b.shutdown().await;
        echo.abort();
        let _ = echo.await;
    });
}
