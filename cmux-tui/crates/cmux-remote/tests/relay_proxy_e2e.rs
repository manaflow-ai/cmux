//! The Mac to Cloud carrier (`relay+do`) through a network whose only way out
//! is its HTTP proxy: a real Noise session crosses a real `cmux-relay` behind a
//! TLS front serving the Durable Object paths, and the client reaches the front
//! three ways:
//!
//! - directly (the baseline);
//! - through an explicit proxy that tunnels with `CONNECT` (the "explicit
//!   proxy, 443 only" cell);
//! - through a proxy that inspects TLS: it answers `CONNECT`, ends the client's
//!   TLS with a certificate a company root signed, and opens its own TLS to the
//!   front (the "TLS-inspecting proxy" cell). The client trusts the company
//!   root, as a Mac with the company's MDM profile does, and still pins the
//!   daemon's Noise key: the proxy sees only ciphertext.
//!
//! Each prints its link-up time (the provider's connect through the Noise
//! handshake) on loopback; that is the proxy's own cost, not a WAN number.
//! A client that does not trust the company root fails through the
//! inspecting proxy, so the outer TLS is still verified.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_proxy::{Hop, ProxyConfig, ProxyServer};
use cmux_relay::{Relay, RelayConfig};
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::provider::{
    ConnectRequest, RelayClientConfig, RelayDaemonConfig, RelayProvider, RelayTls,
    TransportProvider, register_relay_daemon_with_tls,
};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, SessionId};
use futures_util::{SinkExt, StreamExt};
use rcgen::{
    BasicConstraints, CertificateParams, CertifiedIssuer, DistinguishedName, DnType,
    ExtendedKeyUsagePurpose, IsCa, KeyPair, KeyUsagePurpose,
};
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_rustls::rustls::pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer, ServerName};
use tokio_rustls::rustls::{ClientConfig, RootCertStore, ServerConfig};
use tokio_rustls::{TlsAcceptor, TlsConnector};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::http::header::AUTHORIZATION;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use url::Url;
use zeroize::Zeroizing;

const MAXIMUM_FRAME_BYTES: usize = 65_535;
const RELAY_MESSAGE_LIMIT: usize = 2 * 1024 * 1024;
const LOOPBACK: IpAddr = IpAddr::V4(Ipv4Addr::LOCALHOST);
const TEST_TIMEOUT: Duration = Duration::from_secs(60);
const KEYSTROKE_STREAM: u64 = 7;

fn distinguished_name(common_name: &str) -> DistinguishedName {
    let mut name = DistinguishedName::new();
    name.push(DnType::CommonName, common_name);
    name
}

fn certificate_authority(name: &str) -> CertifiedIssuer<'static, KeyPair> {
    let mut params = CertificateParams::new(Vec::<String>::new()).unwrap();
    params.distinguished_name = distinguished_name(name);
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    params.key_usages = vec![KeyUsagePurpose::DigitalSignature, KeyUsagePurpose::KeyCertSign];
    CertifiedIssuer::self_signed(params, KeyPair::generate().unwrap()).unwrap()
}

/// A server configuration for `localhost`, signed by `issuer`.
fn server_config(issuer: &CertifiedIssuer<'static, KeyPair>) -> Arc<ServerConfig> {
    let mut params = CertificateParams::new(vec!["localhost".to_owned()]).unwrap();
    params.distinguished_name = distinguished_name("localhost");
    params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
    params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    params.use_authority_key_identifier_extension = true;
    let key = KeyPair::generate().unwrap();
    let certificate = params.signed_by(&key, issuer).unwrap();
    let private_key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der()));
    Arc::new(
        ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![certificate.der().clone()], private_key)
            .unwrap(),
    )
}

fn websocket_config() -> WebSocketConfig {
    WebSocketConfig::default()
        .max_message_size(Some(RELAY_MESSAGE_LIMIT))
        .max_frame_size(Some(RELAY_MESSAGE_LIMIT))
}

/// Serves the Durable Object relay paths over TLS and forwards each WebSocket
/// to the native relay's `/v1/relay` endpoint (as `relay_do_batch_e2e` does).
async fn start_durable_object_front(tls: Arc<ServerConfig>, relay: SocketAddr) -> SocketAddr {
    let listener = TcpListener::bind(SocketAddr::new(LOOPBACK, 0)).await.unwrap();
    let address = listener.local_addr().unwrap();
    let acceptor = TlsAcceptor::from(tls);
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { return };
            let acceptor = acceptor.clone();
            tokio::spawn(async move {
                let Ok(stream) = acceptor.accept(stream).await else { return };
                let authorization = Arc::new(Mutex::new(None));
                let observed = authorization.clone();
                #[allow(clippy::result_large_err)] // tungstenite's callback signature.
                let callback = move |request: &Request, response: Response| {
                    *observed.lock().unwrap() = request.headers().get(AUTHORIZATION).cloned();
                    Ok(response)
                };
                let Ok(downstream) = tokio_tungstenite::accept_hdr_async_with_config(
                    stream,
                    callback,
                    Some(websocket_config()),
                )
                .await
                else {
                    return;
                };
                let mut request = format!("ws://{relay}/v1/relay").into_client_request().unwrap();
                if let Some(value) = authorization.lock().unwrap().take() {
                    request.headers_mut().insert(AUTHORIZATION, value);
                }
                let Ok((upstream, _)) = tokio_tungstenite::connect_async_with_config(
                    request,
                    Some(websocket_config()),
                    true,
                )
                .await
                else {
                    return;
                };
                let (mut down_tx, mut down_rx) = downstream.split();
                let (mut up_tx, mut up_rx) = upstream.split();
                let to_relay = async move {
                    while let Some(Ok(message)) = down_rx.next().await {
                        if up_tx.send(message).await.is_err() {
                            break;
                        }
                    }
                    let _ = up_tx.close().await;
                };
                let to_peer = async move {
                    while let Some(Ok(message)) = up_rx.next().await {
                        if down_tx.send(message).await.is_err() {
                            break;
                        }
                    }
                    let _ = down_tx.close().await;
                };
                tokio::join!(to_relay, to_peer);
            });
        }
    });
    address
}

/// What an in-process proxy saw.
#[derive(Default)]
struct ProxyLog {
    tunnels: AtomicUsize,
    targets: Mutex<Vec<String>>,
}

/// How the proxy carries a tunnel once it has said 200.
#[derive(Clone)]
enum Carry {
    /// Bytes as they are: an explicit proxy.
    Plain,
    /// End the client's TLS with `client_side` (a company root's certificate)
    /// and open its own TLS to the target trusting `upstream`: an inspecting proxy.
    Inspect { client_side: Arc<ServerConfig>, upstream: Arc<ClientConfig> },
}

/// Reads a `CONNECT host:port` request head, byte by byte.
async fn read_connect(stream: &mut TcpStream) -> Option<String> {
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        if stream.read(&mut byte).await.ok()? == 0 || head.len() > 8192 {
            return None;
        }
        head.push(byte[0]);
    }
    let head = String::from_utf8(head).ok()?;
    let mut words = head.lines().next()?.split_whitespace();
    (words.next()? == "CONNECT").then(|| words.next().map(str::to_owned))?
}

/// An HTTP proxy on loopback that answers `CONNECT` and carries the tunnel as `carry` says.
async fn start_proxy(carry: Carry) -> (u16, Arc<ProxyLog>) {
    let listener = TcpListener::bind(SocketAddr::new(LOOPBACK, 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let log = Arc::new(ProxyLog::default());
    let kept = log.clone();
    tokio::spawn(async move {
        loop {
            let Ok((mut client, _)) = listener.accept().await else { return };
            let log = kept.clone();
            let carry = carry.clone();
            tokio::spawn(async move {
                let Some(target) = read_connect(&mut client).await else { return };
                log.tunnels.fetch_add(1, Ordering::SeqCst);
                log.targets.lock().unwrap().push(target.clone());
                let (host, port) = target.rsplit_once(':').unwrap();
                // A name the proxy resolves itself, as a proxy-only network's proxy does.
                let address = if host == "localhost" { "127.0.0.1" } else { host };
                let Ok(upstream) = TcpStream::connect((address, port.parse().unwrap())).await
                else {
                    let _ = client.write_all(b"HTTP/1.1 502 Bad Gateway\r\n\r\n").await;
                    return;
                };
                client.write_all(b"HTTP/1.1 200 Connection established\r\n\r\n").await.unwrap();
                match carry {
                    Carry::Plain => {
                        let mut upstream = upstream;
                        let _ = tokio::io::copy_bidirectional(&mut client, &mut upstream).await;
                    }
                    Carry::Inspect { client_side, upstream: trust } => {
                        let Ok(mut inner) = TlsAcceptor::from(client_side).accept(client).await
                        else {
                            return;
                        };
                        let name = ServerName::try_from(host.to_owned()).unwrap();
                        let Ok(mut outer) = TlsConnector::from(trust).connect(name, upstream).await
                        else {
                            return;
                        };
                        let _ = tokio::io::copy_bidirectional(&mut inner, &mut outer).await;
                    }
                }
            });
        }
    });
    (port, log)
}

fn client_config_trusting(issuer: &CertifiedIssuer<'static, KeyPair>) -> Arc<ClientConfig> {
    let mut roots = RootCertStore::empty();
    roots.add(issuer.der().clone()).unwrap();
    Arc::new(ClientConfig::builder().with_root_certificates(roots).with_no_client_auth())
}

struct Rig {
    endpoint: Url,
    auth: Arc<AuthDatabase>,
    accepted: tokio::sync::mpsc::Receiver<Arc<cmux_remote::daemon::ServerConnection>>,
    registration: cmux_remote::provider::RelayDaemonRegistration,
    relay_task: tokio::task::JoinHandle<()>,
    _state: tempfile::TempDir,
}

/// One client session over `relay+do` with `trust`: its link-up time and how it went out.
async fn link_up(rig: &mut Rig, trust: RelayTls, label: &str, seed: u8) -> Duration {
    let invitation = rig.auth.create_invitation(Duration::from_secs(60), vec![]).await.unwrap();
    let approver = tokio::spawn({
        let auth = rig.auth.clone();
        async move {
            let pending = auth.wait_for_pending(Duration::from_secs(10)).await.unwrap();
            auth.approve(&pending[0].invitation_id).await.unwrap();
        }
    });
    let started = Instant::now();
    let provider = RelayProvider::new(RelayClientConfig {
        slot: "slot-proxy-test".into(),
        ticket: "open-client-ticket".into(),
        maximum_frame_bytes: MAXIMUM_FRAME_BYTES,
        control_timeout: Duration::from_secs(10),
    })
    .unwrap()
    .with_tls(trust);
    let session = SessionId([seed; 16]);
    let group = provider
        .connect(ConnectRequest {
            endpoint: rig.endpoint.clone(),
            session,
            lane_policy: LanePolicy::Single,
            routing: Default::default(),
        })
        .await
        .unwrap();
    let client = ClientConnection::connect(
        group,
        ClientConnectionConfig {
            identity: StaticIdentity::generate().unwrap(),
            // The daemon's key stays pinned whatever carries the outer TLS.
            expected_daemon: Some(rig.auth.identity().public_key()),
            auth: ClientAuthMode::Invitation {
                secret: Zeroizing::new(invitation.secret_bytes().unwrap()),
                id: invitation.id,
            },
            device_name: format!("relay-proxy-{label}"),
            session,
            lane_policy: LanePolicy::Single,
            limits: SessionLimits::default(),
            reconnect: ReconnectPolicy { maximum_attempts: Some(1), ..ReconnectPolicy::default() },
        },
    )
    .await
    .unwrap();
    let linked = started.elapsed();
    approver.await.unwrap();
    let server =
        tokio::time::timeout(Duration::from_secs(10), rig.accepted.recv()).await.unwrap().unwrap();

    // One keystroke and its echo cross the proxied link.
    let payload = Bytes::from_static(b"keystroke");
    client
        .send(Lane::Interactive, KEYSTROKE_STREAM, payload.clone(), FrameFlags::empty())
        .await
        .unwrap();
    let frame = loop {
        let frame = server.receive().await.unwrap().unwrap();
        if frame.stream == KEYSTROKE_STREAM {
            break frame;
        }
    };
    assert_eq!(frame.payload, payload);
    server
        .send(Lane::Interactive, KEYSTROKE_STREAM, frame.payload, FrameFlags::empty())
        .await
        .unwrap();
    let echoed = loop {
        let frame = client.receive().await.unwrap().unwrap();
        if frame.stream == KEYSTROKE_STREAM {
            break frame;
        }
    };
    assert_eq!(echoed.payload, payload);
    eprintln!("relay+do link up ({label}): {:.1} ms", linked.as_secs_f64() * 1e3);
    client.close().await.unwrap();
    linked
}

async fn start_rig(front_tls: Arc<ServerConfig>, daemon_trust: RelayTls) -> Rig {
    let relay_listener = TcpListener::bind(SocketAddr::new(LOOPBACK, 0)).await.unwrap();
    let relay_address = relay_listener.local_addr().unwrap();
    let relay = Relay::new(RelayConfig {
        allow_open: true,
        max_frame_bytes: RELAY_MESSAGE_LIMIT,
        max_queue_bytes: 8 * RELAY_MESSAGE_LIMIT,
        ..RelayConfig::default()
    })
    .unwrap();
    let (relay_listener, router) = relay.server_parts(relay_listener);
    let relay_task = tokio::spawn(async move {
        axum::serve(relay_listener, router).await.unwrap();
    });
    let front = start_durable_object_front(front_tls, relay_address).await;
    let endpoint = Url::parse(&format!("relay+do://localhost:{}", front.port())).unwrap();
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "relay-proxy-test", false).unwrap();
    let (daemon, accepted) =
        cmux_remote::daemon::RemoteDaemon::new(auth.clone(), SessionLimits::default());
    let registration = register_relay_daemon_with_tls(
        daemon,
        RelayDaemonConfig {
            endpoint: endpoint.clone(),
            slot: "slot-proxy-test".into(),
            ticket: "open-daemon-ticket".into(),
            maximum_frame_bytes: MAXIMUM_FRAME_BYTES,
            control_timeout: Duration::from_secs(5),
        },
        // The Cloud machine's daemon goes out directly.
        daemon_trust.with_proxy(ProxyConfig::Direct),
    )
    .await
    .unwrap();
    Rig { endpoint, auth, accepted, registration, relay_task, _state: state }
}

fn via_proxy(port: u16) -> ProxyConfig {
    ProxyConfig::Fixed(vec![Hop::Http(ProxyServer::new("127.0.0.1", port))])
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn relay_do_links_through_an_explicit_and_an_inspecting_proxy() {
    tokio::time::timeout(TEST_TIMEOUT, async {
        let relay_ca = certificate_authority("relay-proxy-test relay CA");
        let company_ca = certificate_authority("relay-proxy-test company root");
        let relay_trust = RelayTls::with_root_certificates([relay_ca.der().to_vec()]).unwrap();
        let mut rig = start_rig(server_config(&relay_ca), relay_trust.clone()).await;

        // Baseline: direct.
        let direct = relay_trust.clone().with_proxy(ProxyConfig::Direct);
        link_up(&mut rig, direct.clone(), "direct", 1).await;
        let outer = direct.outer_path().expect("a direct connection records its path");
        assert_eq!(outer.proxy, None);

        // An explicit proxy: every relay socket of the session is a CONNECT tunnel.
        let (explicit_port, explicit_log) = start_proxy(Carry::Plain).await;
        let explicit = relay_trust.clone().with_proxy(via_proxy(explicit_port));
        link_up(&mut rig, explicit.clone(), "explicit CONNECT proxy", 2).await;
        assert!(explicit_log.tunnels.load(Ordering::SeqCst) >= 1, "the relay sockets tunnel");
        let front_port = rig.endpoint.port().unwrap();
        assert!(
            explicit_log
                .targets
                .lock()
                .unwrap()
                .iter()
                .all(|t| *t == format!("localhost:{front_port}")),
            "the proxy is handed the relay's name, unresolved: {:?}",
            explicit_log.targets.lock().unwrap()
        );
        let outer = explicit.outer_path().unwrap();
        assert_eq!(
            outer.proxy.as_deref(),
            Some(format!("HTTP proxy 127.0.0.1:{explicit_port}").as_str())
        );

        // A proxy that inspects TLS, re-signing with the company root.
        let (inspect_port, inspect_log) = start_proxy(Carry::Inspect {
            client_side: server_config(&company_ca),
            upstream: client_config_trusting(&relay_ca),
        })
        .await;
        // The Mac trusts the company root (its MDM profile), not the relay's own CA.
        let inspected = RelayTls::with_root_certificates([company_ca.der().to_vec()])
            .unwrap()
            .with_proxy(via_proxy(inspect_port));
        link_up(&mut rig, inspected.clone(), "TLS-inspecting proxy", 3).await;
        assert!(inspect_log.tunnels.load(Ordering::SeqCst) >= 1);
        let outer = inspected.outer_path().unwrap();
        assert!(outer.tls_inspected, "a company root's chain is marked inspected");
        assert!(outer.proxy.is_some());

        // Without the company root the outer TLS still fails: nothing was loosened.
        let untrusting = relay_trust.clone().with_proxy(via_proxy(inspect_port));
        let provider = RelayProvider::new(RelayClientConfig {
            slot: "slot-proxy-test".into(),
            ticket: "open-client-ticket".into(),
            maximum_frame_bytes: MAXIMUM_FRAME_BYTES,
            control_timeout: Duration::from_secs(5),
        })
        .unwrap()
        .with_tls(untrusting);
        let refused = provider
            .connect(ConnectRequest {
                endpoint: rig.endpoint.clone(),
                session: SessionId([9; 16]),
                lane_policy: LanePolicy::Single,
                routing: Default::default(),
            })
            .await;
        let error = match refused {
            Ok(_) => panic!("a re-signed chain the client does not trust was accepted"),
            Err(error) => error.to_string(),
        };
        assert!(error.contains("certificate") || error.contains("TLS"), "{error}");

        rig.registration.shutdown().await;
        rig.relay_task.abort();
    })
    .await
    .expect("the proxy run timed out");
}

/// A proxy that refuses the tunnel says so in the dial's error, naming the proxy.
#[tokio::test]
async fn a_proxy_refusal_names_the_proxy() {
    let listener = TcpListener::bind(SocketAddr::new(LOOPBACK, 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let (mut client, _) = listener.accept().await.unwrap();
        let _ = read_connect(&mut client).await;
        client.write_all(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n").await.unwrap();
    });
    let provider = RelayProvider::new(RelayClientConfig {
        slot: "slot-refused".into(),
        ticket: "open-client-ticket".into(),
        maximum_frame_bytes: MAXIMUM_FRAME_BYTES,
        control_timeout: Duration::from_secs(5),
    })
    .unwrap()
    .with_tls(RelayTls::default().with_proxy(via_proxy(port)));
    let error = match provider
        .connect(ConnectRequest {
            endpoint: Url::parse("relay+do://relay.cmux.invalid").unwrap(),
            session: SessionId([5; 16]),
            lane_policy: LanePolicy::Single,
            routing: Default::default(),
        })
        .await
    {
        Ok(_) => panic!("a refused tunnel connected"),
        Err(error) => error.to_string(),
    };
    assert!(error.contains(&format!("127.0.0.1:{port}")) && error.contains("403"), "{error}");
}
