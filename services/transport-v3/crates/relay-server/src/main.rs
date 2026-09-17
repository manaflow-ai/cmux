//! Private relay. Authority grants gate reservations and circuits before forwarding.
mod admission;

use admission::Gate;
use anyhow::{bail, Context, Result};
use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use clap::Parser;
use cmux_v3_grants::AuthorityKeys;
use cmux_v3_transport::relay_auth;
use ed25519_dalek::VerifyingKey;
use futures::StreamExt;
use libp2p::{
    connection_limits, identify, identity, noise, ping, relay, request_response,
    swarm::{NetworkBehaviour, SwarmEvent},
    tcp, yamux, Multiaddr, SwarmBuilder,
};
use prometheus_client::{
    encoding::text::encode,
    metrics::{counter::Counter, gauge::Gauge},
    registry::Registry,
};
use std::{
    collections::{BTreeMap, HashSet},
    future::IntoFuture,
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
use subtle::ConstantTimeEq;
use tokio::{net::TcpListener, time::Instant};
use tracing::{info, warn};

#[derive(Parser)]
#[command(version, about = "Private cmux transport v3 relay")]
struct Args {
    #[arg(long, env = "CMUX_V3_RELAY_HTTP", default_value = "127.0.0.1:8080")]
    http: SocketAddr,
    #[arg(long, default_value = "/ip4/0.0.0.0/tcp/4001")]
    tcp: Multiaddr,
    #[arg(long, default_value = "/ip4/0.0.0.0/udp/4001/quic-v1")]
    quic: Multiaddr,
    /// Public browser traffic must pass through a TLS proxy.
    #[arg(long, default_value = "/ip4/127.0.0.1/tcp/4002/ws")]
    websocket: Multiaddr,
    #[arg(
        long,
        env = "CMUX_V3_RELAY_ADVERTISE",
        value_delimiter = ',',
        required = true
    )]
    advertise: Vec<Multiaddr>,
    #[arg(long, env = "CMUX_V3_RELAY_IDENTITY_FILE")]
    identity_file: PathBuf,
    /// JSON map of issuer key ID to hex-encoded Ed25519 public key.
    #[arg(long, env = "CMUX_V3_RELAY_AUTHORITY_KEYS")]
    authority_keys: PathBuf,
    #[arg(long, env = "CMUX_V3_RELAY_DRAIN_TOKEN_FILE")]
    drain_token_file: PathBuf,
    #[arg(long, default_value_t = 2000)]
    max_circuits: usize,
    #[arg(long, default_value_t = 10000)]
    max_reservations: usize,
    #[arg(long, default_value_t = 10000)]
    max_connections: u32,
    #[arg(long, default_value_t = 10000)]
    max_cached_permits: usize,
    #[arg(long, default_value_t = 256)]
    max_cached_permits_per_team: usize,
    #[arg(long, default_value_t = 86400)]
    circuit_duration_seconds: u64,
    #[arg(long, default_value_t = 1024 * 1024 * 1024)]
    circuit_bytes: u64,
    /// Drain waits for every circuit to hand over or finish, never force-kills on this timer.
    #[arg(long, default_value_t = 5)]
    drain_min_seconds: u64,
    /// Optional private control-service feed for cross-region revocation delivery.
    #[arg(long, env = "CMUX_V3_CONTROL_URL")]
    control_url: Option<String>,
    #[arg(long, env = "CMUX_V3_CONTROL_TOKEN_FILE")]
    control_token_file: Option<PathBuf>,
}

#[derive(NetworkBehaviour)]
struct Behaviour {
    limits: connection_limits::Behaviour,
    relay: relay::Behaviour,
    auth: relay_auth::Behaviour,
    identify: identify::Behaviour,
    ping: ping::Behaviour,
}

#[derive(Clone)]
struct Metrics {
    reservations: Gauge,
    circuits: Gauge,
    connections: Gauge,
    ready: Gauge,
    draining_seconds: Gauge,
    auth_accepted: Counter,
    auth_denied: Counter,
    reservation_denied: Counter,
    circuit_denied: Counter,
    feed_sequence: Gauge,
    feed_healthy: Gauge,
    feed_failures: Counter,
}
impl Metrics {
    fn new(registry: &mut Registry) -> Self {
        let m = Self {
            reservations: Gauge::default(),
            circuits: Gauge::default(),
            connections: Gauge::default(),
            ready: Gauge::default(),
            draining_seconds: Gauge::default(),
            auth_accepted: Counter::default(),
            auth_denied: Counter::default(),
            reservation_denied: Counter::default(),
            circuit_denied: Counter::default(),
            feed_sequence: Gauge::default(),
            feed_healthy: Gauge::default(),
            feed_failures: Counter::default(),
        };
        registry.register(
            "cmux_v3_reservations",
            "Active reservations",
            m.reservations.clone(),
        );
        registry.register(
            "cmux_v3_circuits",
            "Active or negotiating circuits",
            m.circuits.clone(),
        );
        registry.register(
            "cmux_v3_connections",
            "Transport connections",
            m.connections.clone(),
        );
        registry.register(
            "cmux_v3_ready",
            "All listeners ready and accepting",
            m.ready.clone(),
        );
        registry.register(
            "cmux_v3_draining_seconds",
            "Time spent draining",
            m.draining_seconds.clone(),
        );
        registry.register(
            "cmux_v3_auth_accepted",
            "Accepted authority grants",
            m.auth_accepted.clone(),
        );
        registry.register(
            "cmux_v3_auth_denied",
            "Rejected authority grants",
            m.auth_denied.clone(),
        );
        registry.register(
            "cmux_v3_reservation_denied",
            "Denied reservations",
            m.reservation_denied.clone(),
        );
        registry.register(
            "cmux_v3_circuit_denied",
            "Denied circuits",
            m.circuit_denied.clone(),
        );
        registry.register(
            "cmux_v3_feed_sequence",
            "Last applied revocation feed sequence",
            m.feed_sequence.clone(),
        );
        registry.register(
            "cmux_v3_feed_healthy",
            "Revocation feed has responded successfully recently",
            m.feed_healthy.clone(),
        );
        registry.register(
            "cmux_v3_feed_failures",
            "Revocation feed request or validation failures",
            m.feed_failures.clone(),
        );
        m
    }
}
#[derive(Clone)]
struct AppState {
    gate: Arc<Gate>,
    listening: Arc<AtomicBool>,
    metrics: Metrics,
    registry: Arc<Registry>,
    peer_id: String,
    drain_token: Arc<Vec<u8>>,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();
    validate(&args)?;
    let key = identity::Keypair::ed25519_from_bytes(read_secret(&args.identity_file, 32)?)?;
    let peer_id = key.public().to_peer_id();
    let keys = read_authority_keys(&args.authority_keys)?;
    let drain_token = Arc::new(read_secret(&args.drain_token_file, 32)?);
    let gate = Arc::new(Gate::new(
        keys,
        peer_id,
        args.max_cached_permits,
        args.max_cached_permits_per_team,
    ));
    let config = relay::Config {
        access_control: Some(gate.clone()),
        max_reservations: args.max_reservations,
        max_circuits: args.max_circuits,
        max_reservations_per_peer: 2,
        max_circuits_per_peer: 32,
        max_circuit_duration: Duration::from_secs(args.circuit_duration_seconds),
        max_circuit_bytes: args.circuit_bytes,
        ..Default::default()
    };
    let mut swarm = SwarmBuilder::with_existing_identity(key)
        .with_tokio()
        .with_tcp(
            tcp::Config::default().nodelay(true),
            noise::Config::new,
            yamux::Config::default,
        )?
        .with_quic()
        .with_dns()?
        .with_websocket(noise::Config::new, yamux::Config::default)
        .await?
        .with_behaviour(|key| Behaviour {
            limits: connection_limits::Behaviour::new(
                connection_limits::ConnectionLimits::default()
                    .with_max_pending_incoming(Some(64))
                    .with_max_established(Some(args.max_connections))
                    .with_max_established_per_peer(Some(2)),
            ),
            relay: relay::Behaviour::new(peer_id, config),
            auth: relay_auth::behaviour(),
            identify: identify::Behaviour::new(identify::Config::new(
                "cmux/transport/3-relay".into(),
                key.public(),
            )),
            ping: ping::Behaviour::default(),
        })?
        .with_swarm_config(|config| config.with_idle_connection_timeout(Duration::from_secs(15)))
        .build();
    let listeners = [
        swarm.listen_on(args.tcp)?,
        swarm.listen_on(args.quic)?,
        swarm.listen_on(args.websocket)?,
    ];
    for address in args.advertise {
        swarm.add_external_address(address);
    }
    let mut registry = Registry::default();
    let metrics = Metrics::new(&mut registry);
    let state = AppState {
        gate: gate.clone(),
        listening: Arc::new(AtomicBool::new(false)),
        metrics: metrics.clone(),
        registry: Arc::new(registry),
        peer_id: peer_id.to_string(),
        drain_token,
    };
    let feed = match (&args.control_url, &args.control_token_file) {
        (Some(url), Some(path)) => Some(spawn_revocation_feed(
            url.clone(),
            read_secret(path, 64)?,
            peer_id,
            gate.clone(),
            metrics.clone(),
        )),
        (None, None) => None,
        _ => bail!("control URL and control token file must be supplied together"),
    };
    // A relay without a configured control feed is intentionally offline-only;
    // report that state as healthy rather than as a broken feed.
    if feed.is_none() {
        metrics.feed_healthy.set(1);
    }
    let http_listener = TcpListener::bind(args.http)
        .await
        .context("bind management listener")?;
    let mut http = tokio::spawn(axum::serve(http_listener, router(state.clone())).into_future());
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut drain_started: Option<Instant> = None;
    let mut ready_listeners = HashSet::new();
    info!(%peer_id, version = env!("CARGO_PKG_VERSION"), "relay starting");
    let outcome = loop {
        tokio::select! {
            result = &mut http => break Err(anyhow::anyhow!("management listener stopped: {result:?}")),
            _ = terminate.recv() => gate.drain(),
            _ = interrupt.recv() => gate.drain(),
            _ = tick.tick() => {
                for peer in gate.sweep() { let _ = swarm.disconnect_peer_id(peer); }
            },
            event = swarm.select_next_some() => match event {
                SwarmEvent::NewListenAddr { listener_id, .. } => { ready_listeners.insert(listener_id); },
                SwarmEvent::ListenerError { error, .. } => break Err(error.into()),
                SwarmEvent::ListenerClosed { listener_id, .. } if listeners.contains(&listener_id) => break Err(anyhow::anyhow!("relay listener closed")),
                SwarmEvent::Behaviour(BehaviourEvent::Auth(request_response::Event::Message {
                    peer, message: request_response::Message::Request { request, channel, .. }, ..
                })) => {
                    let result = gate.authorize(peer, request);
                    if result == relay_auth::Response::Accepted { metrics.auth_accepted.inc(); } else { metrics.auth_denied.inc(); }
                    let _ = swarm.behaviour_mut().auth.send_response(channel, result);
                },
                SwarmEvent::Behaviour(BehaviourEvent::Relay(relay::Event::ReservationReqDenied { .. })) => { metrics.reservation_denied.inc(); },
                SwarmEvent::Behaviour(BehaviourEvent::Relay(relay::Event::CircuitReqDenied { .. })) => { metrics.circuit_denied.inc(); },
                _ => {}
            }
        }
        let ready = ready_listeners.len() == listeners.len();
        state.listening.store(ready, Ordering::Release);
        metrics.ready.set(i64::from(ready && !gate.draining()));
        metrics
            .reservations
            .set(swarm.behaviour().relay.num_reservations() as i64);
        metrics
            .circuits
            .set(swarm.behaviour().relay.num_circuits() as i64);
        metrics
            .connections
            .set(swarm.network_info().connection_counters().num_established() as i64);
        if gate.draining() {
            let start = drain_started.get_or_insert_with(|| {
                info!("draining; new reservations and circuits refused");
                Instant::now()
            });
            metrics
                .draining_seconds
                .set(start.elapsed().as_secs() as i64);
            if start.elapsed() >= Duration::from_secs(args.drain_min_seconds)
                && swarm.behaviour().relay.num_circuits() == 0
            {
                break Ok(());
            }
        }
    };
    state.listening.store(false, Ordering::Release);
    http.abort();
    if let Some(feed) = feed {
        feed.abort();
    }
    info!(
        remaining_circuits = swarm.behaviour().relay.num_circuits(),
        "relay stopped"
    );
    outcome
}

fn spawn_revocation_feed(
    url: String,
    token: Vec<u8>,
    relay: libp2p::PeerId,
    gate: Arc<Gate>,
    metrics: Metrics,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let url = url.trim_end_matches('/').to_owned();
        if !(url.starts_with("https://")
            || url.starts_with("http://127.0.0.1")
            || url.starts_with("http://localhost"))
        {
            warn!("refusing non-private revocation feed URL");
            metrics.feed_healthy.set(0);
            metrics.feed_failures.inc();
            return;
        }
        let client = match reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(5))
            .build()
        {
            Ok(client) => client,
            Err(_) => {
                metrics.feed_healthy.set(0);
                metrics.feed_failures.inc();
                return;
            }
        };
        let token = match String::from_utf8(token) {
            Ok(token) => token,
            Err(_) => return,
        };
        let mut sequence = 0_u64;
        let mut ticker = tokio::time::interval(Duration::from_secs(5));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            ticker.tick().await;
            let response = client
                .post(format!("{url}/v3/relay-events"))
                .bearer_auth(&token)
                .json(&serde_json::json!({
                    "relay_peer": relay.to_string(),
                    "team": "*",
                    "after_sequence": sequence,
                    "limit": 256
                }))
                .send()
                .await;
            let response = match response {
                Ok(response) if response.status().is_success() => response,
                _ => {
                    metrics.feed_healthy.set(0);
                    metrics.feed_failures.inc();
                    continue;
                }
            };
            let body = match response.bytes().await {
                Ok(body) if body.len() <= 64 * 1024 => body,
                _ => {
                    metrics.feed_healthy.set(0);
                    metrics.feed_failures.inc();
                    continue;
                }
            };
            let body = match serde_json::from_slice::<FeedResponse>(&body) {
                Ok(body) => body,
                Err(_) => {
                    metrics.feed_healthy.set(0);
                    metrics.feed_failures.inc();
                    continue;
                }
            };
            metrics.feed_healthy.set(1);
            for event in body.events {
                if event.cursor <= sequence || gate.apply_revocation_token(&event.update).is_err() {
                    metrics.feed_healthy.set(0);
                    metrics.feed_failures.inc();
                    break;
                }
                sequence = event.cursor;
                metrics.feed_sequence.set(sequence as i64);
            }
        }
    })
}

#[derive(serde::Deserialize)]
struct FeedResponse {
    events: Vec<FeedEvent>,
}
#[derive(serde::Deserialize)]
struct FeedEvent {
    cursor: u64,
    update: String,
}

fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(health))
        .route("/readyz", get(readiness))
        .route("/metrics", get(metrics))
        .route("/drain", post(drain))
        .with_state(state)
}
async fn health(State(state): State<AppState>) -> impl IntoResponse {
    Json(
        serde_json::json!({"peer_id": state.peer_id, "draining": state.gate.draining(), "circuits": state.metrics.circuits.get(), "feed_healthy": state.metrics.feed_healthy.get(), "feed_sequence": state.metrics.feed_sequence.get(), "version": env!("CARGO_PKG_VERSION")}),
    )
}
async fn readiness(State(state): State<AppState>) -> impl IntoResponse {
    if state.listening.load(Ordering::Acquire) && !state.gate.draining() {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    }
}
async fn metrics(State(state): State<AppState>) -> impl IntoResponse {
    let mut body = String::new();
    if encode(&mut body, &state.registry).is_err() {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    (
        [(
            axum::http::header::CONTENT_TYPE,
            "application/openmetrics-text; version=1.0.0; charset=utf-8",
        )],
        body,
    )
        .into_response()
}
async fn drain(State(state): State<AppState>, headers: HeaderMap) -> impl IntoResponse {
    let token = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .and_then(|v| hex::decode(v).ok())
        .unwrap_or_default();
    if token.ct_eq(state.drain_token.as_slice()).unwrap_u8() != 1 {
        return StatusCode::UNAUTHORIZED;
    }
    state.gate.drain();
    StatusCode::ACCEPTED
}
fn read_secret(path: &Path, length: usize) -> Result<Vec<u8>> {
    use std::os::unix::fs::PermissionsExt;
    let metadata = path.metadata().context("inspect secret file")?;
    if !metadata.is_file()
        || metadata.len() != length as u64
        || metadata.permissions().mode() & 0o077 != 0
    {
        bail!("secret must be a private regular file of exactly {length} bytes");
    }
    std::fs::read(path).context("read secret file")
}
fn read_authority_keys(path: &Path) -> Result<AuthorityKeys> {
    if path.metadata()?.len() > 16384 {
        bail!("authority key set is too large");
    }
    let keys: BTreeMap<String, String> = serde_json::from_slice(&std::fs::read(path)?)?;
    if keys.is_empty() || keys.len() > 32 {
        bail!("authority key set must contain 1..32 keys");
    }
    let mut trusted = AuthorityKeys::default();
    for (id, hex) in keys {
        if id.is_empty() || id.len() > 128 {
            bail!("invalid authority key id");
        }
        let bytes: [u8; 32] = hex::decode(hex)?
            .try_into()
            .map_err(|_| anyhow::anyhow!("invalid public key length"))?;
        trusted.insert(id, VerifyingKey::from_bytes(&bytes)?);
    }
    Ok(trusted)
}
fn validate(args: &Args) -> Result<()> {
    if args.max_circuits == 0
        || args.max_reservations == 0
        || args.max_connections == 0
        || args.max_cached_permits == 0
        || args.max_cached_permits_per_team == 0
        || args.circuit_duration_seconds == 0
        || args.circuit_duration_seconds > u32::MAX.into()
        || args.circuit_bytes == 0
    {
        bail!("relay limits must be positive and circuit duration must fit u32 seconds");
    }
    if !args.http.ip().is_loopback() {
        warn!("management listener requires a private network firewall");
    }
    Ok(())
}

#[cfg(test)]
mod feed_tests {
    use super::*;
    use cmux_v3_grants::{GrantSigner, RevocationUpdate};
    use ed25519_dalek::SigningKey;
    use libp2p::identity::Keypair;

    fn now() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
    }

    #[tokio::test]
    async fn revocation_feed_applies_signed_ordered_events_and_reports_health() {
        let signing = SigningKey::from_bytes(&[101; 32]);
        let signer = GrantSigner::new("feed-test".into(), &signing).unwrap();
        let update = RevocationUpdate {
            key_id: String::new(),
            team_id: "team".into(),
            sequence: 1,
            policy_revision: 2,
            revoked_peers: vec![Keypair::generate_ed25519()
                .public()
                .to_peer_id()
                .to_string()],
            issued_at: now(),
        };
        let token = signer.sign_revocation(update, now()).unwrap();
        let response = serde_json::json!({
            "events": [{"cursor": 1, "sequence": 1, "update": token}]
        });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let app = Router::new().route(
            "/v3/relay-events",
            post(move || {
                let response = response.clone();
                async move { Json(response) }
            }),
        );
        let server = tokio::spawn(axum::serve(listener, app).into_future());
        let relay = Keypair::generate_ed25519().public().to_peer_id();
        let mut keys = AuthorityKeys::default();
        keys.insert("feed-test".into(), signing.verifying_key());
        let gate = Arc::new(Gate::new(keys, relay, 16, 8));
        let mut registry = Registry::default();
        let metrics = Metrics::new(&mut registry);
        let feed = spawn_revocation_feed(
            format!("http://{address}"),
            b"feed-token".to_vec(),
            relay,
            gate,
            metrics.clone(),
        );
        for _ in 0..30 {
            if metrics.feed_healthy.get() == 1 && metrics.feed_sequence.get() == 1 {
                feed.abort();
                server.abort();
                return;
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        feed.abort();
        server.abort();
        panic!("signed revocation feed did not become healthy");
    }
}
