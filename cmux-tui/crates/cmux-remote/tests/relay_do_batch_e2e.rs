//! Measures `relay+do` batch framing end to end: a real Noise session crosses
//! a real `cmux-relay` behind a TLS front that serves the Durable Object relay
//! paths. The front counts every WebSocket message each peer sends, so the
//! test reports keystroke echo latency and relay message counts, the two costs
//! batch framing trades against each other.

use std::ffi::OsString;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_relay::{Relay, RelayConfig};
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::provider::{
    ConnectRequest, RelayClientConfig, RelayDaemonConfig, RelayProvider, TransportProvider,
    register_relay_daemon,
};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, RelayControl, RelayRole, SessionId};
use futures_util::{SinkExt, StreamExt};
use rcgen::{
    BasicConstraints, CertificateParams, CertifiedIssuer, DistinguishedName, DnType,
    ExtendedKeyUsagePurpose, IsCa, KeyPair, KeyUsagePurpose,
};
use tempfile::{TempDir, tempdir};
use tokio::net::TcpListener;
use tokio_rustls::TlsAcceptor;
use tokio_rustls::rustls::ServerConfig;
use tokio_rustls::rustls::pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::http::header::AUTHORIZATION;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use url::Url;
use zeroize::Zeroizing;

const MAXIMUM_FRAME_BYTES: usize = 65_535;
const RELAY_MESSAGE_LIMIT: usize = 2 * 1024 * 1024;
const LOOPBACK: IpAddr = IpAddr::V4(Ipv4Addr::LOCALHOST);
const WARMUP_ECHOES: usize = 32;
const ECHO_COUNT: usize = 500;
const TYPING_INTERVAL: Duration = Duration::from_millis(10);
const FLOOD_FRAMES: usize = 4096;
const FLOOD_FRAME_BYTES: usize = 64;
const KEYSTROKE_STREAM: u64 = 7;
const FLOOD_STREAM: u64 = 9;
const TEST_TIMEOUT: Duration = Duration::from_secs(120);
const TYPING_ECHO_BOUND: Duration = Duration::from_millis(2);
// Batching gives about 31 frames per message here, no batching about 1.6.
// The floor leaves room for a loaded runner that breaks the burst streak.
const MINIMUM_FLOOD_FRAMES_PER_MESSAGE: u64 = 4;

/// WebSocket messages and logical frames one peer role sent to the relay.
#[derive(Default)]
struct RoleCounters {
    messages: AtomicU64,
    frames: AtomicU64,
}

impl RoleCounters {
    fn record(&self, payload: &[u8]) {
        self.messages.fetch_add(1, Ordering::Relaxed);
        let frames =
            if payload.len() >= 8 && payload[..4] == *b"CMXB" { u64::from(payload[5]) } else { 1 };
        self.frames.fetch_add(frames, Ordering::Relaxed);
    }

    fn take(&self) -> (u64, u64) {
        (self.messages.swap(0, Ordering::Relaxed), self.frames.swap(0, Ordering::Relaxed))
    }
}

#[derive(Default)]
struct Counters {
    client: RoleCounters,
    daemon: RoleCounters,
}

impl Counters {
    fn reset(&self) {
        self.client.take();
        self.daemon.take();
    }
}

/// Serves the Durable Object relay paths over TLS and forwards each WebSocket
/// to the native relay's single `/v1/relay` endpoint, which speaks the same
/// relay control protocol.
async fn start_durable_object_front(
    tls: Arc<ServerConfig>,
    relay: SocketAddr,
    counters: Arc<Counters>,
) -> SocketAddr {
    let listener = TcpListener::bind(SocketAddr::new(LOOPBACK, 0)).await.unwrap();
    let address = listener.local_addr().unwrap();
    let acceptor = TlsAcceptor::from(tls);
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { return };
            stream.set_nodelay(true).unwrap();
            let acceptor = acceptor.clone();
            let counters = counters.clone();
            tokio::spawn(async move {
                let Ok(stream) = acceptor.accept(stream).await else { return };
                let authorization = Arc::new(std::sync::Mutex::new(None));
                let observed = authorization.clone();
                #[allow(clippy::result_large_err)] // tungstenite's callback signature.
                let callback = move |request: &Request, response: Response| {
                    *observed.lock().unwrap() = request.headers().get(AUTHORIZATION).cloned();
                    Ok(response)
                };
                let config = websocket_config();
                let Ok(downstream) =
                    tokio_tungstenite::accept_hdr_async_with_config(stream, callback, Some(config))
                        .await
                else {
                    return;
                };
                let mut request = format!("ws://{relay}/v1/relay").into_client_request().unwrap();
                if let Some(value) = authorization.lock().unwrap().take() {
                    request.headers_mut().insert(AUTHORIZATION, value);
                }
                let Ok((upstream, _)) =
                    tokio_tungstenite::connect_async_with_config(request, Some(config), true).await
                else {
                    return;
                };
                forward(downstream, upstream, counters).await;
            });
        }
    });
    address
}

async fn forward<D, U>(
    downstream: tokio_tungstenite::WebSocketStream<D>,
    upstream: tokio_tungstenite::WebSocketStream<U>,
    counters: Arc<Counters>,
) where
    D: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
    U: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    let (mut down_tx, mut down_rx) = downstream.split();
    let (mut up_tx, mut up_rx) = upstream.split();
    let to_relay = async move {
        let mut role = None;
        while let Some(Ok(message)) = down_rx.next().await {
            match &message {
                Message::Text(text) => {
                    if let Ok(RelayControl::Join { role: joined, .. }) =
                        serde_json::from_str::<RelayControl>(text)
                    {
                        role = Some(joined);
                    }
                }
                Message::Binary(payload) => match role {
                    Some(RelayRole::Client) => counters.client.record(payload),
                    Some(RelayRole::Daemon) => counters.daemon.record(payload),
                    None => {}
                },
                _ => {}
            }
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
}

fn websocket_config() -> WebSocketConfig {
    WebSocketConfig::default()
        .max_message_size(Some(RELAY_MESSAGE_LIMIT))
        .max_frame_size(Some(RELAY_MESSAGE_LIMIT))
}

fn certificate_authority() -> CertifiedIssuer<'static, KeyPair> {
    let mut params = CertificateParams::new(Vec::<String>::new()).unwrap();
    params.distinguished_name = distinguished_name("relay-do-test-ca");
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    params.key_usages = vec![KeyUsagePurpose::DigitalSignature, KeyUsagePurpose::KeyCertSign];
    CertifiedIssuer::self_signed(params, KeyPair::generate().unwrap()).unwrap()
}

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

fn distinguished_name(common_name: &str) -> DistinguishedName {
    let mut name = DistinguishedName::new();
    name.push(DnType::CommonName, common_name);
    name
}

struct TrustedCertificate {
    previous_file: Option<OsString>,
    previous_dir: Option<OsString>,
    _directory: TempDir,
}

impl TrustedCertificate {
    /// Must run before the runtime starts any thread.
    fn install(pem: &str) -> Self {
        let directory = tempdir().unwrap();
        let path = directory.path().join("trusted-ca.pem");
        std::fs::write(&path, pem).unwrap();
        let previous_file = std::env::var_os("SSL_CERT_FILE");
        let previous_dir = std::env::var_os("SSL_CERT_DIR");
        // SAFETY: this test binary has one test, which sets the trust store before it builds
        // the runtime and restores it after the runtime has shut down.
        unsafe {
            std::env::set_var("SSL_CERT_FILE", &path);
            std::env::remove_var("SSL_CERT_DIR");
        }
        Self { previous_file, previous_dir, _directory: directory }
    }
}

impl Drop for TrustedCertificate {
    fn drop(&mut self) {
        for (name, value) in [
            ("SSL_CERT_FILE", self.previous_file.take()),
            ("SSL_CERT_DIR", self.previous_dir.take()),
        ] {
            // SAFETY: the runtime has shut down; no other thread reads the environment.
            unsafe {
                match value {
                    Some(value) => std::env::set_var(name, value),
                    None => std::env::remove_var(name),
                }
            }
        }
    }
}

fn percentile(sorted: &[Duration], percentile: usize) -> Duration {
    sorted[(sorted.len() * percentile / 100).min(sorted.len() - 1)]
}

fn micros(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1e6
}

/// Sends one keystroke at a time and waits for its echo. `interval` spaces the
/// keystrokes like a fast typist; `None` sends the next one as soon as the
/// previous echo arrives.
async fn measure_echoes(
    client: &ClientConnection,
    counters: &Counters,
    label: &str,
    interval: Option<Duration>,
) -> Duration {
    let mut pace = interval.map(tokio::time::interval);
    let mut round_trips = Vec::with_capacity(ECHO_COUNT);
    for index in 0..WARMUP_ECHOES + ECHO_COUNT {
        if index == WARMUP_ECHOES {
            counters.reset();
        }
        if let Some(pace) = pace.as_mut() {
            pace.tick().await;
        }
        let payload = Bytes::from(format!("key-{index:06}"));
        let started = Instant::now();
        client
            .send(Lane::Interactive, KEYSTROKE_STREAM, payload.clone(), FrameFlags::empty())
            .await
            .unwrap();
        let echoed = client.receive().await.unwrap().unwrap();
        let elapsed = started.elapsed();
        assert_eq!(echoed.payload, payload);
        if index >= WARMUP_ECHOES {
            round_trips.push(elapsed);
        }
    }
    let (client_messages, client_frames) = counters.client.take();
    let (daemon_messages, daemon_frames) = counters.daemon.take();
    round_trips.sort();
    let mean = round_trips.iter().sum::<Duration>() / ECHO_COUNT as u32;
    eprintln!(
        "relay+do keystroke echo ({label}): n={ECHO_COUNT} mean={:.0}us p50={:.0}us \
         p95={:.0}us p99={:.0}us max={:.0}us",
        micros(mean),
        micros(percentile(&round_trips, 50)),
        micros(percentile(&round_trips, 95)),
        micros(percentile(&round_trips, 99)),
        micros(round_trips[ECHO_COUNT - 1]),
    );
    eprintln!(
        "relay+do keystroke messages ({label}): client {client_messages} messages / \
         {client_frames} frames, daemon {daemon_messages} messages / {daemon_frames} frames"
    );
    assert!(client_frames >= ECHO_COUNT as u64 && daemon_frames >= ECHO_COUNT as u64);
    percentile(&round_trips, 50)
}

#[test]
fn relay_do_batches_only_queued_frames_and_echoes_keystrokes_without_delay() {
    let issuer = certificate_authority();
    let trust = TrustedCertificate::install(&issuer.pem());
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(4).enable_all().build().unwrap();
    runtime.block_on(async {
        tokio::time::timeout(TEST_TIMEOUT, run(server_config(&issuer)))
            .await
            .expect("relay+do measurement timed out");
    });
    drop(runtime);
    drop(trust);
}

async fn run(tls: Arc<ServerConfig>) {
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
    let counters = Arc::new(Counters::default());
    let front = start_durable_object_front(tls, relay_address, counters.clone()).await;
    let endpoint = Url::parse(&format!("relay+do://localhost:{}", front.port())).unwrap();

    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "relay-do-test", false).unwrap();
    let (daemon, mut accepted) =
        cmux_remote::daemon::RemoteDaemon::new(auth.clone(), SessionLimits::default());
    let registration = register_relay_daemon(
        daemon,
        RelayDaemonConfig {
            endpoint: endpoint.clone(),
            slot: "slot-do-test".into(),
            ticket: "open-daemon-ticket".into(),
            maximum_frame_bytes: MAXIMUM_FRAME_BYTES,
            control_timeout: Duration::from_secs(5),
        },
    )
    .await
    .unwrap();
    let invitation = auth.create_invitation(Duration::from_secs(60), vec![]).await.unwrap();
    let approver = tokio::spawn({
        let auth = auth.clone();
        async move {
            let pending = auth.wait_for_pending(Duration::from_secs(5)).await.unwrap();
            auth.approve(&pending[0].invitation_id).await.unwrap();
        }
    });
    let provider = RelayProvider::new(RelayClientConfig {
        slot: "slot-do-test".into(),
        ticket: "open-client-ticket".into(),
        maximum_frame_bytes: MAXIMUM_FRAME_BYTES,
        control_timeout: Duration::from_secs(5),
    })
    .unwrap();
    let invitation_secret = invitation.secret_bytes().unwrap();
    let session = SessionId([43; 16]);
    let group = provider
        .connect(ConnectRequest {
            endpoint,
            session,
            lane_policy: LanePolicy::Auto,
            routing: Default::default(),
        })
        .await
        .unwrap();
    let client = Arc::new(
        ClientConnection::connect(
            group,
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: Some(auth.identity().public_key()),
                auth: ClientAuthMode::Invitation {
                    id: invitation.id,
                    secret: Zeroizing::new(invitation_secret),
                },
                device_name: "relay-do-client".into(),
                session,
                lane_policy: LanePolicy::Auto,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy {
                    maximum_attempts: Some(1),
                    ..ReconnectPolicy::default()
                },
            },
        )
        .await
        .unwrap(),
    );
    approver.await.unwrap();
    let server = Arc::new(
        tokio::time::timeout(Duration::from_secs(5), accepted.recv()).await.unwrap().unwrap(),
    );
    assert!(client.snapshot().await.transport.route.starts_with("relay+do://"));

    // The daemon echoes every frame it receives, as a PTY echoes a keystroke.
    let echo = tokio::spawn({
        let server = server.clone();
        async move {
            while let Ok(Some(frame)) = server.receive().await {
                if frame.stream != KEYSTROKE_STREAM {
                    continue;
                }
                server
                    .send(Lane::Interactive, KEYSTROKE_STREAM, frame.payload, FrameFlags::empty())
                    .await
                    .unwrap();
            }
        }
    });

    measure_echoes(&client, &counters, "back to back", None).await;
    let typing_echo =
        measure_echoes(&client, &counters, "typing pace", Some(TYPING_INTERVAL)).await;
    // Two relay hops that each wait on a timer cost at least 2 ms; an
    // immediate send costs a small fraction of that on loopback.
    assert!(
        typing_echo < TYPING_ECHO_BOUND,
        "a typed keystroke's median echo took {typing_echo:?}; relay+do must send it at once"
    );

    // A burst: the client writes frames back to back while the daemon drains.
    echo.abort();
    let _ = echo.await;
    counters.reset();
    let drain = tokio::spawn({
        let server = server.clone();
        async move {
            let mut received = 0;
            while received < FLOOD_FRAMES {
                let frame = server.receive().await.unwrap().unwrap();
                if frame.stream == FLOOD_STREAM {
                    assert_eq!(&frame.payload[..8], &(received as u64).to_be_bytes());
                    received += 1;
                }
            }
            Instant::now()
        }
    });
    // Session acknowledgements reach the client only through its receive path.
    let client_receiver = tokio::spawn({
        let client = client.clone();
        async move { while let Ok(Some(_)) = client.receive().await {} }
    });
    let started = Instant::now();
    for index in 0..FLOOD_FRAMES {
        let mut payload = vec![0_u8; FLOOD_FRAME_BYTES];
        payload[..8].copy_from_slice(&(index as u64).to_be_bytes());
        client
            .send(Lane::Interactive, FLOOD_STREAM, Bytes::from(payload), FrameFlags::empty())
            .await
            .unwrap();
    }
    let finished = drain.await.unwrap();
    client_receiver.abort();
    let _ = client_receiver.await;
    let (flood_messages, flood_frames) = counters.client.take();
    eprintln!(
        "relay+do flood: {FLOOD_FRAMES} frames x {FLOOD_FRAME_BYTES} B in {:.1}ms, client \
         {flood_messages} messages / {flood_frames} frames ({:.2} frames per message)",
        (finished - started).as_secs_f64() * 1e3,
        flood_frames as f64 / flood_messages.max(1) as f64,
    );
    assert!(flood_frames >= FLOOD_FRAMES as u64);
    assert!(
        flood_frames >= MINIMUM_FLOOD_FRAMES_PER_MESSAGE * flood_messages,
        "a burst must still share relay messages: {flood_messages} messages for {flood_frames} \
         frames"
    );

    client.close().await.unwrap();
    registration.shutdown().await;
    relay_task.abort();
}
