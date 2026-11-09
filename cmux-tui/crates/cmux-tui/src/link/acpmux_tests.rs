//! The link's `acpmux` service end to end: a dial on link B crosses two
//! real WireGuard meshes (loopback UDP) and reaches a real acpmux WebSocket
//! listener behind link A, which still checks its own token on the upgrade.
//! The link sends a peer's bytes only to the listener the live daemon
//! recorded and proved (`acpmux::listener_record`). Unknown services are
//! refused on both sides.

use std::collections::BTreeMap;
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::overlay_addr::overlay_address;
use cmux_link::pairing::{PairingRecord, Pairings};
use cmux_wg::{InterfaceAddress, WgMesh, WgMeshConfig};
use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _, DuplexStream};
use tokio::net::{TcpListener, UdpSocket};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::{Message as Frame, client::IntoClientRequest as _};
use zeroize::Zeroizing;

use super::acpmux::AcpmuxTarget;
use super::control::{Peers, serve_overlay};
use super::dial::{Overlay as _, serve_dial};
use super::inbound::{InboundRefused, serve_inbound_watched};
use super::lines::read_line;
use super::mesh::MeshOverlay;

const TOKEN: &str = "link-acpmux-listener-token";
const BOUND: Duration = Duration::from_secs(15);

async fn within<T>(future: impl Future<Output = T>) -> T {
    tokio::time::timeout(BOUND, future).await.expect("within 15 s")
}

/// Hub and listener need deep stacks (acpmux's own tests run them the same way).
fn run(body: impl Future<Output = ()> + Send + 'static) {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_stack_size(32 << 20)
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async { tokio::spawn(body).await.unwrap() });
}

/// A real acpmux WebSocket listener (in-memory store) on loopback.
async fn acpmux_listener() -> (SocketAddr, String, JoinHandle<()>, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let auth = acpmux::server::peer_auth::PeerAuth::create(dir.path()).unwrap();
    let peer_token = std::fs::read_to_string(auth.path()).unwrap();
    let mut config = acpmux::config::Config::default();
    config.store.mode = acpmux::config::StoreMode::Memory;
    let store = acpmux::store::open(&config.store, dir.path()).unwrap();
    let hub = acpmux::hub::Hub::new(config, store);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let task = tokio::spawn(async move {
        let auth = acpmux::server::WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
        let _ = acpmux::server::serve_ws_with(hub, listener, TOKEN.into(), auth).await;
    });
    (address, peer_token, task, dir)
}

/// An acpmux home whose `listener.json` names a listener as this process's:
/// this test process plays the daemon (its pid, start time and key). The
/// record goes when this is dropped, before the folder.
struct LiveHome {
    _written: acpmux::listener_record::Written,
    dir: tempfile::TempDir,
}

impl AsRef<std::path::Path> for LiveHome {
    fn as_ref(&self) -> &std::path::Path {
        self.dir.path()
    }
}

fn live_home(listen: SocketAddr) -> LiveHome {
    let dir = tempfile::tempdir().unwrap();
    let written = acpmux::listener_record::write(dir.path(), listen).unwrap();
    LiveHome { _written: written, dir }
}

fn live(home: &impl AsRef<std::path::Path>) -> AcpmuxTarget {
    AcpmuxTarget::Live(home.as_ref().to_path_buf())
}

fn record(install: &str, public: [u8; 32], endpoint: SocketAddr) -> PairingRecord {
    PairingRecord {
        install: install.into(),
        user: "42".into(),
        team: "team_a".into(),
        public_key: STANDARD.encode(public),
        endpoint: Some(endpoint),
    }
}

fn mesh(install: &str, private: [u8; 32], socket: UdpSocket) -> MeshOverlay {
    let config = WgMeshConfig {
        private_key: Zeroizing::new(private),
        addresses: vec![InterfaceAddress {
            address: IpAddr::V6(overlay_address(install)),
            prefix: 128,
        }],
        mtu: super::state::LINK_MTU,
    };
    MeshOverlay::new(WgMesh::start(config, socket).unwrap())
}

/// Link A (serving acpmux at `target`) and link B (dialing), paired both ways.
struct Links {
    dialer: Arc<MeshOverlay>,
    pairings_b: Arc<Pairings>,
    server: JoinHandle<()>,
    _directory: cmux_unix_socket::TestDir,
}

async fn links(target: AcpmuxTarget) -> Links {
    let (a_private, a_public) = cmux_wg::testing::random_keypair();
    let (b_private, b_public) = cmux_wg::testing::random_keypair();
    let a_socket = UdpSocket::bind(SocketAddr::from((Ipv6Addr::LOCALHOST, 0))).await.unwrap();
    let b_socket = UdpSocket::bind(SocketAddr::from((Ipv6Addr::LOCALHOST, 0))).await.unwrap();
    let (a_udp, b_udp) = (a_socket.local_addr().unwrap(), b_socket.local_addr().unwrap());
    let directory = cmux_unix_socket::short_test_dir("linkacp");
    let mut pairings_a = Pairings::default();
    pairings_a.upsert(record("inst_b", b_public, b_udp)).unwrap();
    let peers_path = directory.path().join("peers.json");
    pairings_a.save(&peers_path).unwrap();
    let mut pairings_b = Pairings::default();
    pairings_b.upsert(record("inst_a", a_public, a_udp)).unwrap();
    let overlay_a = mesh("inst_a", a_private, a_socket);
    let overlay_b = mesh("inst_b", b_private, b_socket);
    overlay_a.sync_peers(&pairings_a).await.unwrap();
    overlay_b.sync_peers(&pairings_b).await.unwrap();
    let listener = overlay_a.listen(cmux_link::LINK_PORT).await.unwrap();
    let peers = Arc::new(Peers::load(peers_path).unwrap());
    // No session socket: this link serves only acpmux.
    let server = tokio::spawn(async move {
        let _overlay_a = overlay_a;
        serve_overlay(listener, peers, None, None, target).await;
    });
    Links {
        dialer: Arc::new(overlay_b),
        pairings_b: Arc::new(pairings_b),
        server,
        _directory: directory,
    }
}

/// `link.dial` for `service` on link B; the caller's end after the reply line.
async fn dial(links: &Links, service: &str) -> (String, DuplexStream) {
    let (mut caller, link_side) = tokio::io::duplex(256 * 1024);
    let (overlay, pairings) = (links.dialer.clone(), links.pairings_b.clone());
    tokio::spawn(async move { serve_dial(link_side, &*overlay, &pairings).await });
    caller
        .write_all(
            format!("{{\"op\":\"link.dial\",\"host\":\"inst_a\",\"service\":\"{service}\"}}\n")
                .as_bytes(),
        )
        .await
        .unwrap();
    // Byte by byte: the WebSocket handshake that follows must find every byte.
    let reply = within(read_line(&mut caller, 1024)).await.unwrap();
    (reply, caller)
}

type Socket<S> = tokio_tungstenite::WebSocketStream<S>;

async fn upgrade<S>(
    stream: S,
    token: Option<&str>,
    peer_token: Option<&str>,
) -> anyhow::Result<Socket<S>>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let mut request = "ws://localhost/".into_client_request()?;
    if let Some(token) = token {
        request.headers_mut().insert("authorization", format!("Bearer {token}").parse()?);
    }
    if let Some(peer_token) = peer_token {
        request.headers_mut().insert(acpmux::server::peer_auth::HEADER, peer_token.trim().parse()?);
    }
    let config = Some(acpmux::server::ws_config());
    Ok(tokio_tungstenite::client_async_with_config(request, stream, config).await?.0)
}

async fn initialize<S>(ws: &mut Socket<S>) -> Value
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let request = json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        "protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"link-test","version":"1"}}});
    ws.send(Frame::Text(request.to_string().into())).await.unwrap();
    within(async {
        while let Some(frame) = ws.next().await {
            if let Frame::Text(text) = frame.unwrap() {
                let message: Value = serde_json::from_str(&text).unwrap();
                if message["id"] == 1 {
                    return message;
                }
            }
        }
        panic!("the WebSocket closed before its answer")
    })
    .await
}

const CONNECTED: &str = "{\"ok\":true,\"path_state\":\"direct\",\"relay_available\":false}";

#[test]
fn an_acpmux_websocket_crosses_two_links_and_acpmux_still_checks_its_token() {
    run(async {
        let (address, peer_token, listener, _home) = acpmux_listener().await;
        let record = live_home(address);
        let links = links(live(&record)).await;

        // No token, then a wrong one: the link carried the upgrade, acpmux refused it.
        for token in [None, Some("wrong")] {
            let (reply, caller) = dial(&links, "acpmux").await;
            assert_eq!(reply, CONNECTED);
            let refused = within(upgrade(caller, token, None)).await;
            assert!(refused.is_err(), "acpmux accepted token {token:?} through the link");
        }

        // The listener token: the WebSocket is served, as a remote-origin connection.
        let (reply, caller) = dial(&links, "acpmux").await;
        assert_eq!(reply, CONNECTED);
        let mut web = within(upgrade(caller, Some(TOKEN), None)).await.unwrap();
        let hello = initialize(&mut web).await;
        assert_eq!(hello["result"]["_meta"]["acpmux"]["origin"], "remote", "{hello}");
        assert_eq!(hello["result"]["_meta"]["acpmux"]["auth"], "listenerToken", "{hello}");

        // With the peer proof too, it is a peer connection: acpmux decides, not the link.
        let (_, caller) = dial(&links, "acpmux").await;
        let mut peer = within(upgrade(caller, Some(TOKEN), Some(&peer_token))).await.unwrap();
        let hello = initialize(&mut peer).await;
        assert_eq!(hello["result"]["_meta"]["acpmux"]["origin"], "peer", "{hello}");

        links.server.abort();
        listener.abort();
    });
}

#[test]
fn an_acpmux_dial_closes_when_no_listener_is_there() {
    run(async {
        // A loopback port with nothing listening.
        let free = TcpListener::bind("127.0.0.1:0").await.unwrap().local_addr().unwrap();
        let record = live_home(free);
        let links = links(live(&record)).await;
        let (reply, mut caller) = dial(&links, "acpmux").await;
        assert_eq!(reply, CONNECTED);
        let mut rest = Vec::new();
        within(caller.read_to_end(&mut rest)).await.unwrap();
        assert!(rest.is_empty());
        links.server.abort();
    });
}

/// A paired peer's stream on link A, with `hello` as its first line.
async fn inbound(hello: &str, target: &AcpmuxTarget) -> Result<(), InboundRefused> {
    let mut pairings = Pairings::default();
    pairings.upsert(record("inst_b", [2; 32], "[::1]:1".parse().unwrap())).unwrap();
    let (mut peer, link_side) = tokio::io::duplex(1024);
    peer.write_all(hello.as_bytes()).await.unwrap();
    within(serve_inbound_watched(
        link_side,
        [2; 32],
        SocketAddr::new(IpAddr::V6(overlay_address("inst_b")), 40000),
        &pairings,
        None,
        None,
        target,
        None,
    ))
    .await
}

#[test]
fn an_unknown_service_is_refused_and_never_reaches_acpmux() {
    run(async {
        let acpmux = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let record = live_home(acpmux.local_addr().unwrap());
        let target = live(&record);
        // Inbound: an unknown service, and acpmux with a token a paired peer never sends.
        for hello in [
            "{\"service\":\"nonsense\"}\n",
            "{\"service\":\"acpmux\",\"link_token\":\"t\",\"epoch\":1}\n",
            "{\"service\":\"acpmux\",\"extra\":1}\n",
        ] {
            assert_eq!(inbound(hello, &target).await, Err(InboundRefused::BadHello), "{hello}");
        }
        // Without a session socket, a daemon stream is refused too.
        assert_eq!(
            inbound("{\"service\":\"daemon\"}\n", &target).await,
            Err(InboundRefused::EntryUnavailable)
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(100), acpmux.accept()).await.is_err(),
            "a refused stream reached the acpmux listener"
        );

        // Outbound: the dial line names a service the link does not know.
        let links = links(target).await;
        let (reply, _) = dial(&links, "nonsense").await;
        assert_eq!(
            reply,
            "{\"ok\":false,\"path_state\":\"unreachable\",\"relay_available\":false,\"error_code\":\"bad_request\"}"
        );
        // A paired install serves no ssh or desktop stream.
        for service in ["ssh", "desktop"] {
            let (reply, _) = dial(&links, service).await;
            assert!(reply.contains("\"error_code\":\"not_authorized\""), "{service}: {reply}");
        }
        links.server.abort();
    });
}

#[test]
fn a_link_with_acpmux_off_serves_no_acpmux_stream() {
    run(async {
        let mut pairings = Pairings::default();
        pairings.upsert(record("inst_b", [2; 32], "[::1]:1".parse().unwrap())).unwrap();
        let (mut peer, link_side) = tokio::io::duplex(1024);
        peer.write_all(b"{\"service\":\"acpmux\"}\n").await.unwrap();
        let served = within(serve_inbound_watched(
            link_side,
            [2; 32],
            SocketAddr::new(IpAddr::V6(overlay_address("inst_b")), 40000),
            &pairings,
            None,
            None,
            &AcpmuxTarget::Off,
            None,
        ))
        .await;
        assert_eq!(served, Err(InboundRefused::AcpmuxUnavailable));
    });
}

/// A loopback listener that is not acpmux: it keeps every byte it is sent
/// and closes each connection after a quiet moment, never answering.
async fn unrelated_listener() -> (SocketAddr, Arc<std::sync::Mutex<Vec<Vec<u8>>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let seen: Arc<std::sync::Mutex<Vec<Vec<u8>>>> = Arc::default();
    let kept = seen.clone();
    tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let mut bytes = Vec::new();
            let _ =
                tokio::time::timeout(Duration::from_millis(300), stream.read_to_end(&mut bytes))
                    .await;
            kept.lock().unwrap().push(bytes);
        }
    });
    (address, seen)
}

/// What a paired peer sends: the hello, then bytes that must reach acpmux only.
const PEER_BYTES: &str = "{\"service\":\"acpmux\"}\nGET /peer-secret HTTP/1.1\r\n\r\n";

/// Serve one paired peer stream carrying [`PEER_BYTES`] on link A.
async fn peer_stream(target: &AcpmuxTarget) -> Result<(), InboundRefused> {
    inbound(PEER_BYTES, target).await
}

fn received(seen: &std::sync::Mutex<Vec<Vec<u8>>>) -> Vec<String> {
    seen.lock().unwrap().iter().map(|bytes| String::from_utf8_lossy(bytes).into_owned()).collect()
}

#[test]
fn an_unrelated_listener_on_a_stale_saved_port_gets_no_peer_bytes() {
    use acpmux::listener_record::NotLive;
    run(async {
        let (stale, seen) = unrelated_listener().await;
        // The daemon is gone; config.json still names its old port, now someone else's.
        let home = tempfile::tempdir().unwrap();
        let config = json!({"websocket": {"listen": stale.to_string(), "token": "t"}});
        std::fs::write(home.path().join("config.json"), config.to_string()).unwrap();
        assert_eq!(
            peer_stream(&live(&home)).await,
            Err(InboundRefused::AcpmuxNotLive(NotLive::NoRecord))
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(received(&seen).is_empty(), "config.json's port was dialed: {:?}", received(&seen));

        // Even a record of a live process naming that port: the listener cannot answer the
        // challenge under the record's key, so it gets the probe and nothing of the peer's.
        let _written = acpmux::listener_record::write(home.path(), stale).unwrap();
        assert_eq!(
            peer_stream(&live(&home)).await,
            Err(InboundRefused::AcpmuxNotLive(NotLive::WrongListener))
        );
        tokio::time::sleep(Duration::from_millis(400)).await;
        let got = received(&seen);
        assert_eq!(got.len(), 1, "{got:?}");
        assert!(got[0].starts_with("ACPMUX-LINK/2 ") && got[0].ends_with("\r\n\r\n"), "{got:?}");
        assert!(!got[0].contains("peer-secret"), "{got:?}");
    });
}

/// `listener.json` naming `listen`, as a daemon that has since ended left it: another pid and
/// a key no live process holds. This process's guard leaves it in place.
fn dead_daemons_record(home: &std::path::Path, listen: SocketAddr) {
    let written = acpmux::listener_record::write(home, listen).unwrap();
    let path = home.join(acpmux::listener_record::FILE_NAME);
    let mut record: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    record["pid"] = json!(1);
    record["key"] = json!("01".repeat(32));
    std::fs::write(&path, record.to_string()).unwrap();
    drop(written);
    assert!(path.exists());
}

#[test]
fn a_record_left_by_an_ended_daemon_is_refused() {
    use acpmux::listener_record::NotLive;
    run(async {
        // The record outlived its daemon (a crash). Whatever now listens at its address, the
        // real acpmux listener of a newer daemon or an unrelated service, cannot answer the
        // challenge under the dead daemon's key, so no peer byte goes there.
        let (address, _peer_token, listener, _acpmux_home) = acpmux_listener().await;
        let (spy, seen) = unrelated_listener().await;
        for target in [address, spy] {
            let home = tempfile::tempdir().unwrap();
            dead_daemons_record(home.path(), target);
            assert_eq!(
                peer_stream(&live(&home)).await,
                Err(InboundRefused::AcpmuxNotLive(NotLive::WrongListener))
            );
        }
        tokio::time::sleep(Duration::from_millis(400)).await;
        let got = received(&seen);
        assert_eq!(got.len(), 1, "{got:?}");
        assert!(got[0].starts_with("ACPMUX-LINK/2 ") && got[0].ends_with("\r\n\r\n"), "{got:?}");
        assert!(!got[0].contains("peer-secret"), "{got:?}");
        listener.abort();
    });
}

/// The baseline for one-link slice 3: how long an acpmux peer connect takes
/// (overlay stream open plus the WebSocket upgrade, to a real acpmux
/// listener) over acpmux's own WireGuard transport and over the link, both on
/// loopback UDP in this process. Prints p50 and p90 of `DIALS` warm dials
/// after one cold dial that also does the WireGuard handshake.
///
/// `cargo test -p cmux-tui acpmux_connect_baseline -- --ignored --nocapture`
#[test]
#[ignore = "a measurement, not a check"]
fn acpmux_connect_baseline() {
    const DIALS: usize = 200;
    run(async {
        let (address, _peer_token, listener, _home) = acpmux_listener().await;
        let record = live_home(address);

        // acpmux's own transport: two daemons' meshes, b bridging to the listener.
        let homes = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
        let ports = [free_udp().await, free_udp().await];
        let keys = homes
            .iter()
            .map(|home| acpmux::cli::mesh_node_key::load_or_create_at(home.path()).unwrap())
            .collect::<Vec<_>>();
        let service = ["10.77.0.1:4100", "10.77.0.2:4100"].map(|text| text.parse().unwrap());
        let config = |own: usize, other: usize| {
            let mut config = acpmux::config::Config::default();
            config.transport.wireguard = true;
            config.transport.wireguard_static =
                Some(acpmux::wireguard::StaticConfig { listen: ports[own], address: service[own] });
            config.peers = BTreeMap::from([(
                "other".to_string(),
                acpmux::config::PeerConfig {
                    link_host: None,
                    url: "ws://127.0.0.1:1".into(),
                    wireguard: Some(acpmux::wireguard::StaticPeer {
                        public_key: keys[other].public_key_b64(),
                        endpoint: ports[other].to_string(),
                        address: service[other],
                    }),
                    token: None,
                    peer_token: None,
                    vm_boundary: false,
                    github_broker: false,
                },
            )]);
            config
        };
        let a = acpmux::wireguard::Transport::start(&config(0, 1), homes[0].path(), address)
            .await
            .unwrap()
            .unwrap();
        let b = acpmux::wireguard::Transport::start(&config(1, 0), homes[1].path(), address)
            .await
            .unwrap()
            .unwrap();
        let route = a.route("other").unwrap();
        let own_wg = measure(DIALS, || {
            let a = a.clone();
            async move {
                let stream = a.connect(route).await.unwrap();
                upgrade(stream, Some(TOKEN), None).await.unwrap()
            }
        })
        .await;
        a.shutdown(tokio::time::Instant::now()).await;
        b.shutdown(tokio::time::Instant::now()).await;

        let links = links(live(&record)).await;
        let over_link = measure(DIALS, || {
            let links = &links;
            async move {
                let (reply, caller) = dial(links, "acpmux").await;
                assert_eq!(reply, CONNECTED);
                upgrade(caller, Some(TOKEN), None).await.unwrap()
            }
        })
        .await;
        links.server.abort();
        listener.abort();

        println!("acpmux connect baseline, {DIALS} warm dials each (cold = first dial):");
        println!("  acpmux own WireGuard: {own_wg}");
        println!("  cmux link (acpmux service): {over_link}");
    });
}

async fn free_udp() -> SocketAddr {
    UdpSocket::bind("127.0.0.1:0").await.unwrap().local_addr().unwrap()
}

struct Timings {
    cold: Duration,
    warm: Vec<Duration>,
}

impl std::fmt::Display for Timings {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let at = |quantile: f64| {
            let index = ((self.warm.len() as f64 - 1.0) * quantile).round() as usize;
            self.warm[index]
        };
        write!(
            formatter,
            "cold {:.2} ms, p50 {:.3} ms, p90 {:.3} ms, max {:.3} ms",
            self.cold.as_secs_f64() * 1e3,
            at(0.5).as_secs_f64() * 1e3,
            at(0.9).as_secs_f64() * 1e3,
            self.warm.last().unwrap().as_secs_f64() * 1e3,
        )
    }
}

/// Time `dials + 1` connects; each socket is closed before the next one.
async fn measure<F, Fut, S>(dials: usize, connect: F) -> Timings
where
    F: Fn() -> Fut,
    Fut: Future<Output = Socket<S>>,
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let mut times = Vec::with_capacity(dials + 1);
    for _ in 0..=dials {
        let started = Instant::now();
        let mut socket = within(connect()).await;
        times.push(started.elapsed());
        let _ = socket.close(None).await;
    }
    let cold = times.remove(0);
    times.sort();
    Timings { cold, warm: times }
}
