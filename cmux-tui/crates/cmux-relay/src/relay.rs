use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use axum::body::Bytes;
use axum::extract::ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Request, State};
use axum::http::header::{CONNECTION, RETRY_AFTER};
use axum::http::{HeaderValue, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use cmux_remote_protocol::{
    CircuitId, LaneToken, REMOTE_PROTOCOL_VERSION, RelayControl, RelayPermission, RelayRole,
    RelayTicketClaims,
};
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use serde::Serialize;
use tokio::net::TcpListener;
use tokio::sync::{Mutex, mpsc, watch};
use tokio::task::JoinHandle;
use uuid::Uuid;

use crate::AdmissionListener;
use crate::config::RelayConfig;
use crate::ticket::{TicketAuthority, TicketExpectation};

const MAX_SLOT_BYTES: usize = 256;
const MAX_LANE_TOKEN_BYTES: usize = 256;
const MAX_TICKET_BYTES: usize = 4 * 1024;
const WRITER_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(1);
const ALLOCATION_RATE_WINDOW: Duration = Duration::from_secs(1);

type ConnectionId = u64;

#[derive(Clone)]
pub struct Relay {
    inner: Arc<RelayInner>,
}

struct RelayInner {
    config: RelayConfig,
    tickets: TicketAuthority,
    state: Mutex<RelayState>,
    next_connection_id: AtomicU64,
    active_connections: AtomicUsize,
}

struct UpgradedConnectionPermit {
    inner: Arc<RelayInner>,
}

impl Drop for UpgradedConnectionPermit {
    fn drop(&mut self) {
        self.inner.active_connections.fetch_sub(1, Ordering::AcqRel);
    }
}

#[derive(Default)]
struct RelayState {
    controls: HashMap<String, ControlRegistration>,
    circuits: HashMap<CircuitId, Circuit>,
    attachments: HashMap<ConnectionId, Attachment>,
    slot_usage: HashMap<String, SlotUsage>,
}

#[derive(Default)]
struct SlotUsage {
    control_sockets: usize,
    pending_circuits: usize,
    active_circuits: usize,
    recent_allocations: VecDeque<Instant>,
}

struct ControlRegistration {
    peer: Peer,
    provider_ticket: String,
    deadline: Instant,
    provider_expiry: Option<Instant>,
}

struct Circuit {
    slot: String,
    lane: LaneToken,
    generation: u64,
    client_join_ticket: String,
    daemon_join_ticket: String,
    created_at: Instant,
    last_activity: Instant,
    client: Option<Peer>,
    daemon: Option<Peer>,
    ready: bool,
}

struct JoinRequest {
    protocol: u8,
    slot: String,
    circuit: CircuitId,
    lane: LaneToken,
    generation: u64,
    ticket: String,
    role: RelayRole,
}

#[derive(Debug, Clone)]
enum Attachment {
    Control { slot: String },
    ClientControl { slot: String },
    Circuit { circuit: CircuitId, role: RelayRole },
}

#[derive(Clone)]
struct Peer {
    id: ConnectionId,
    outbound: OutboundSender,
    shutdown: watch::Sender<Option<CloseNotice>>,
}

#[derive(Clone)]
struct OutboundSender {
    sender: mpsc::Sender<Outbound>,
    queued_bytes: Arc<AtomicUsize>,
    maximum_queue_bytes: usize,
}

enum Outbound {
    Control(RelayControl),
    Binary(QueuedBinary),
    Pong(Bytes),
}

struct QueuedBinary {
    bytes: Bytes,
    queued_bytes: Arc<AtomicUsize>,
}

impl Drop for QueuedBinary {
    fn drop(&mut self) {
        self.queued_bytes.fetch_sub(self.bytes.len(), Ordering::AcqRel);
    }
}

#[derive(Debug, Clone)]
struct CloseNotice {
    code: u16,
    reason: String,
    error: Option<RelayControl>,
}

impl CloseNotice {
    fn normal(reason: impl Into<String>) -> Self {
        Self { code: 1000, reason: reason.into(), error: None }
    }

    fn error(error: RelayError) -> Self {
        Self { code: error.close_code, reason: error.code.clone(), error: Some(error.control()) }
    }
}

#[derive(Debug, Clone)]
struct RelayError {
    code: String,
    message: String,
    retryable: bool,
    close_code: u16,
}

impl RelayError {
    fn protocol(code: &str, message: impl Into<String>) -> Self {
        Self { code: code.into(), message: message.into(), retryable: false, close_code: 1002 }
    }

    fn policy(code: &str, message: impl Into<String>, retryable: bool) -> Self {
        Self { code: code.into(), message: message.into(), retryable, close_code: 1008 }
    }

    fn capacity(code: &str, message: impl Into<String>) -> Self {
        Self { code: code.into(), message: message.into(), retryable: true, close_code: 1013 }
    }

    fn control(&self) -> RelayControl {
        RelayControl::Error {
            code: self.code.clone(),
            message: self.message.clone(),
            retryable: self.retryable,
        }
    }

    fn internal(code: &str, message: impl Into<String>) -> Self {
        Self { code: code.into(), message: message.into(), retryable: true, close_code: 1011 }
    }
}

enum ConnectionEnd {
    Closed,
    Failed(RelayError),
}

type ConnectionResult<T = ()> = Result<T, ConnectionEnd>;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct HealthSnapshot {
    pub status: &'static str,
    pub daemon_slots: usize,
    pub pending_circuits: usize,
    pub ready_circuits: usize,
}

impl Relay {
    pub fn new(config: RelayConfig) -> anyhow::Result<Self> {
        config.validate()?;
        let tickets = TicketAuthority::from_optional_secret(
            config.ticket_secret.clone(),
            config.ticket_issuer.clone(),
        )?;
        Ok(Self {
            inner: Arc::new(RelayInner {
                config,
                tickets,
                state: Mutex::new(RelayState::default()),
                next_connection_id: AtomicU64::new(1),
                active_connections: AtomicUsize::new(0),
            }),
        })
    }

    pub fn config(&self) -> &RelayConfig {
        &self.inner.config
    }

    /// Returns the only supported server pairing. The listener enforces raw
    /// TCP and HTTP admission before requests can reach the WebSocket router.
    pub fn server_parts(&self, listener: TcpListener) -> (AdmissionListener, Router) {
        (AdmissionListener::new(listener, &self.inner.config), self.router())
    }

    fn router(&self) -> Router {
        Router::new()
            .route("/healthz", get(Self::health_handler))
            .route("/v1/relay", get(Self::websocket_handler))
            .route("/ws", get(Self::websocket_handler))
            .with_state(self.clone())
            .layer(middleware::from_fn(Self::close_non_upgraded_keepalive))
    }

    pub fn spawn_cleanup(&self) -> JoinHandle<()> {
        let weak = Arc::downgrade(&self.inner);
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(1));
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                interval.tick().await;
                let Some(inner) = Weak::upgrade(&weak) else {
                    return;
                };
                Self { inner }.cleanup_expired(Instant::now()).await;
            }
        })
    }

    pub async fn health(&self) -> HealthSnapshot {
        let state = self.inner.state.lock().await;
        let ready_circuits = state.circuits.values().filter(|circuit| circuit.ready).count();
        HealthSnapshot {
            status: "ok",
            daemon_slots: state.controls.len(),
            pending_circuits: state.circuits.len() - ready_circuits,
            ready_circuits,
        }
    }

    async fn health_handler(State(relay): State<Self>) -> impl IntoResponse {
        (StatusCode::OK, Json(relay.health().await))
    }

    async fn websocket_handler(State(relay): State<Self>, upgrade: WebSocketUpgrade) -> Response {
        let Some(permit) = relay.try_admit_upgraded_socket() else {
            let mut response =
                (StatusCode::SERVICE_UNAVAILABLE, "relay concurrent WebSocket limit was reached")
                    .into_response();
            response.headers_mut().insert(RETRY_AFTER, HeaderValue::from_static("1"));
            return response;
        };
        let maximum = relay.inner.config.max_control_bytes.max(relay.inner.config.max_frame_bytes);
        upgrade
            .max_message_size(maximum)
            .max_frame_size(maximum)
            .on_upgrade(move |socket| async move { relay.handle_socket(socket, permit).await })
            .into_response()
    }

    async fn close_non_upgraded_keepalive(request: Request, next: Next) -> Response {
        let mut response = next.run(request).await;
        if response.status() != StatusCode::SWITCHING_PROTOCOLS {
            response.headers_mut().insert(CONNECTION, HeaderValue::from_static("close"));
        }
        response
    }

    fn try_admit_upgraded_socket(&self) -> Option<UpgradedConnectionPermit> {
        if self
            .inner
            .active_connections
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                (active < self.inner.config.max_connections).then_some(active + 1)
            })
            .is_err()
        {
            return None;
        }
        Some(UpgradedConnectionPermit { inner: self.inner.clone() })
    }

    async fn handle_socket(&self, socket: WebSocket, _permit: UpgradedConnectionPermit) {
        let peer_id = self.inner.next_connection_id.fetch_add(1, Ordering::Relaxed);
        let (socket_writer, mut socket_reader) = socket.split();
        let (outbound_sender, outbound_receiver) =
            mpsc::channel(self.inner.config.max_queue_frames);
        let (shutdown_sender, shutdown_receiver) = watch::channel(None);
        let peer = Peer {
            id: peer_id,
            outbound: OutboundSender {
                sender: outbound_sender,
                queued_bytes: Arc::new(AtomicUsize::new(0)),
                maximum_queue_bytes: self.inner.config.max_queue_bytes,
            },
            shutdown: shutdown_sender,
        };
        let mut writer =
            tokio::spawn(Self::write_socket(socket_writer, outbound_receiver, shutdown_receiver));

        let handshake = tokio::time::timeout(
            self.inner.config.handshake_timeout,
            self.read_control(&mut socket_reader, &peer),
        )
        .await;
        let result = match handshake {
            Ok(Ok(control)) => self.dispatch_connection(control, &mut socket_reader, &peer).await,
            Ok(Err(end)) => Err(end),
            Err(_) => Err(ConnectionEnd::Failed(RelayError::policy(
                "handshake-timeout",
                "first relay control message was not received before the deadline",
                true,
            ))),
        };

        self.disconnect(peer.id).await;
        match result {
            Ok(()) | Err(ConnectionEnd::Closed) => {
                peer.shutdown_if_open(CloseNotice::normal("connection closed"));
            }
            Err(ConnectionEnd::Failed(error)) => {
                peer.shutdown_if_open(CloseNotice::error(error));
            }
        }

        if tokio::time::timeout(WRITER_SHUTDOWN_TIMEOUT, &mut writer).await.is_err() {
            writer.abort();
        }
    }

    async fn dispatch_connection(
        &self,
        control: RelayControl,
        reader: &mut SplitStream<WebSocket>,
        peer: &Peer,
    ) -> ConnectionResult {
        match control {
            RelayControl::Register { protocol, slot, ticket } => {
                self.register(peer.clone(), protocol, slot.clone(), ticket)
                    .await
                    .map_err(ConnectionEnd::Failed)?;
                self.run_daemon_control(reader, peer, &slot).await
            }
            RelayControl::Connect { protocol, slot, ticket, lane, generation } => {
                self.allocate(peer, protocol, slot.clone(), ticket, lane, generation)
                    .await
                    .map_err(ConnectionEnd::Failed)?;
                self.run_client_control(reader, peer, &slot).await
            }
            RelayControl::Join { protocol, slot, circuit, lane, generation, ticket, role } => {
                self.join(
                    peer.clone(),
                    JoinRequest {
                        protocol,
                        slot,
                        circuit: circuit.clone(),
                        lane,
                        generation,
                        ticket,
                        role,
                    },
                )
                .await
                .map_err(ConnectionEnd::Failed)?;
                self.run_circuit(reader, peer, circuit).await
            }
            RelayControl::Ping { nonce } => {
                peer.send_control(RelayControl::Pong { nonce }).map_err(ConnectionEnd::Failed)?;
                Err(ConnectionEnd::Failed(RelayError::protocol(
                    "missing-attachment",
                    "first relay control message must register, connect, or join",
                )))
            }
            _ => Err(ConnectionEnd::Failed(RelayError::protocol(
                "unexpected-control",
                "first relay control message must register, connect, or join",
            ))),
        }
    }

    async fn run_daemon_control(
        &self,
        reader: &mut SplitStream<WebSocket>,
        peer: &Peer,
        slot: &str,
    ) -> ConnectionResult {
        loop {
            match self.read_authenticated_control(reader, peer).await? {
                RelayControl::Ping { nonce } => {
                    self.touch_control(peer.id, slot).await?;
                    peer.send_control(RelayControl::Pong { nonce })
                        .map_err(ConnectionEnd::Failed)?;
                }
                _ => {
                    peer.send_control(
                        RelayError::protocol(
                            "unexpected-control",
                            "daemon control sockets accept only ping after registration",
                        )
                        .control(),
                    )
                    .map_err(ConnectionEnd::Failed)?;
                }
            }
        }
    }

    async fn run_client_control(
        &self,
        reader: &mut SplitStream<WebSocket>,
        peer: &Peer,
        attached_slot: &str,
    ) -> ConnectionResult {
        loop {
            match self.read_authenticated_control(reader, peer).await? {
                RelayControl::Connect { protocol, slot, ticket, lane, generation } => {
                    let allocation = if slot == attached_slot {
                        self.allocate(peer, protocol, slot, ticket, lane, generation).await
                    } else {
                        Err(RelayError::policy(
                            "control-slot-mismatch",
                            "a client control socket may allocate circuits only for its authenticated slot",
                            false,
                        ))
                    };
                    if let Err(error) = allocation {
                        peer.send_control(error.control()).map_err(ConnectionEnd::Failed)?;
                    }
                }
                RelayControl::Ping { nonce } => {
                    peer.send_control(RelayControl::Pong { nonce })
                        .map_err(ConnectionEnd::Failed)?;
                }
                _ => {
                    peer.send_control(
                        RelayError::protocol(
                            "unexpected-control",
                            "client control sockets accept only connect or ping",
                        )
                        .control(),
                    )
                    .map_err(ConnectionEnd::Failed)?;
                }
            }
        }
    }

    async fn run_circuit(
        &self,
        reader: &mut SplitStream<WebSocket>,
        peer: &Peer,
        circuit: CircuitId,
    ) -> ConnectionResult {
        let mut shutdown = peer.shutdown.subscribe();
        if shutdown.borrow().is_some() {
            return Err(ConnectionEnd::Closed);
        }
        loop {
            tokio::select! {
                changed = shutdown.changed() => {
                    if changed.is_err() || shutdown.borrow().is_some() {
                        return Err(ConnectionEnd::Closed);
                    }
                }
                message = reader.next() => {
                    match message {
                        Some(Ok(Message::Binary(bytes))) => {
                            if bytes.len() > self.inner.config.max_frame_bytes {
                                return Err(ConnectionEnd::Failed(RelayError {
                                    code: "frame-too-large".into(),
                                    message: format!(
                                        "binary frame is {} bytes, maximum is {}",
                                        bytes.len(),
                                        self.inner.config.max_frame_bytes,
                                    ),
                                    retryable: false,
                                    close_code: 1009,
                                }));
                            }
                            self.forward(peer.id, &circuit, bytes)
                                .await
                                .map_err(ConnectionEnd::Failed)?;
                        }
                        Some(Ok(Message::Ping(bytes))) => {
                            peer.send_pong(bytes).map_err(ConnectionEnd::Failed)?;
                        }
                        Some(Ok(Message::Pong(_))) => {}
                        Some(Ok(Message::Close(_))) | None => return Err(ConnectionEnd::Closed),
                        Some(Ok(Message::Text(_))) => {
                            return Err(ConnectionEnd::Failed(RelayError::protocol(
                                "text-on-circuit",
                                "paired relay circuit sockets accept only binary messages",
                            )));
                        }
                        Some(Err(error)) => {
                            return Err(ConnectionEnd::Failed(RelayError::protocol(
                                "websocket-read",
                                format!("WebSocket read failed: {error}"),
                            )));
                        }
                    }
                }
            }
        }
    }

    async fn read_control_or_shutdown(
        &self,
        reader: &mut SplitStream<WebSocket>,
        peer: &Peer,
    ) -> ConnectionResult<RelayControl> {
        let mut shutdown = peer.shutdown.subscribe();
        if shutdown.borrow().is_some() {
            return Err(ConnectionEnd::Closed);
        }
        tokio::select! {
            changed = shutdown.changed() => {
                let _ = changed;
                Err(ConnectionEnd::Closed)
            }
            control = self.read_control(reader, peer) => control,
        }
    }

    async fn read_authenticated_control(
        &self,
        reader: &mut SplitStream<WebSocket>,
        peer: &Peer,
    ) -> ConnectionResult<RelayControl> {
        tokio::time::timeout(
            self.inner.config.control_idle_timeout,
            self.read_control_or_shutdown(reader, peer),
        )
        .await
        .map_err(|_| {
            ConnectionEnd::Failed(RelayError::policy(
                "control-idle-timeout",
                "authenticated relay control socket exceeded its idle deadline",
                true,
            ))
        })?
    }

    async fn read_control(
        &self,
        reader: &mut SplitStream<WebSocket>,
        peer: &Peer,
    ) -> ConnectionResult<RelayControl> {
        loop {
            match reader.next().await {
                Some(Ok(Message::Text(text))) => {
                    if text.len() > self.inner.config.max_control_bytes {
                        return Err(ConnectionEnd::Failed(RelayError {
                            code: "control-too-large".into(),
                            message: format!(
                                "control message is {} bytes, maximum is {}",
                                text.len(),
                                self.inner.config.max_control_bytes,
                            ),
                            retryable: false,
                            close_code: 1009,
                        }));
                    }
                    return serde_json::from_str(&text).map_err(|error| {
                        ConnectionEnd::Failed(RelayError::protocol(
                            "invalid-control-json",
                            format!("invalid relay control message: {error}"),
                        ))
                    });
                }
                Some(Ok(Message::Ping(bytes))) => {
                    peer.send_pong(bytes).map_err(ConnectionEnd::Failed)?;
                }
                Some(Ok(Message::Pong(_))) => {}
                Some(Ok(Message::Close(_))) | None => return Err(ConnectionEnd::Closed),
                Some(Ok(Message::Binary(_))) => {
                    return Err(ConnectionEnd::Failed(RelayError::protocol(
                        "binary-before-join",
                        "relay socket must join a circuit before sending binary messages",
                    )));
                }
                Some(Err(error)) => {
                    return Err(ConnectionEnd::Failed(RelayError::protocol(
                        "websocket-read",
                        format!("WebSocket read failed: {error}"),
                    )));
                }
            }
        }
    }

    async fn register(
        &self,
        peer: Peer,
        protocol: u8,
        slot: String,
        ticket: String,
    ) -> Result<(), RelayError> {
        validate_protocol(protocol)?;
        validate_slot(&slot)?;
        validate_ticket_size(&ticket)?;
        let system_now = SystemTime::now();
        let instant_now = Instant::now();
        let provider_claims = self
            .inner
            .tickets
            .verify_provider(
                &ticket,
                TicketExpectation {
                    permission: RelayPermission::Register,
                    role: RelayRole::Daemon,
                    slot: &slot,
                    circuit: None,
                    lane: None,
                    generation: None,
                    require_route_binding: false,
                },
                system_now,
            )
            .map_err(|error| RelayError::policy("invalid-ticket", error.to_string(), false))?;
        let provider_expiry = provider_claims
            .as_ref()
            .map(|claims| expiry_as_instant(claims.expires_at_unix, system_now, instant_now))
            .transpose()?;
        let deadline = provider_expiry
            .map_or(instant_now + self.inner.config.lease_duration, |expiry| {
                expiry.min(instant_now + self.inner.config.lease_duration)
            });

        let mut replaced = None;
        {
            let mut state = self.inner.state.lock().await;
            if let Some((existing_ticket, existing_peer)) = state
                .controls
                .get(&slot)
                .map(|existing| (existing.provider_ticket.clone(), existing.peer.clone()))
            {
                if !self.inner.tickets.uses_hmac() && existing_ticket != ticket {
                    return Err(RelayError::policy(
                        "slot-in-use",
                        "slot already has a daemon registered with a different ticket",
                        true,
                    ));
                }
                state.attachments.remove(&existing_peer.id);
                replaced = Some(existing_peer);
            } else if state.controls.len() >= self.inner.config.max_slots {
                return Err(RelayError::capacity(
                    "slot-limit",
                    "relay daemon slot limit was reached",
                ));
            } else {
                let usage = state.slot_usage.entry(slot.clone()).or_default();
                if usage.control_sockets >= self.inner.config.max_control_sockets_per_slot {
                    return Err(RelayError::capacity(
                        "slot-control-limit",
                        "relay control socket limit for this slot was reached",
                    ));
                }
                usage.control_sockets += 1;
            }
            state.controls.insert(
                slot.clone(),
                ControlRegistration {
                    peer: peer.clone(),
                    provider_ticket: ticket,
                    deadline,
                    provider_expiry,
                },
            );
            state.attachments.insert(peer.id, Attachment::Control { slot: slot.clone() });
        }

        if let Some(replaced) = replaced {
            replaced.shutdown(CloseNotice::normal("daemon registration replaced"));
        }
        if let Err(error) = peer.send_control(RelayControl::Registered {
            lease_seconds: self.inner.config.lease_duration.as_secs() as u32,
        }) {
            self.disconnect(peer.id).await;
            return Err(error);
        }
        Ok(())
    }

    async fn touch_control(&self, peer_id: ConnectionId, slot: &str) -> ConnectionResult {
        let mut state = self.inner.state.lock().await;
        let Some(control) = state.controls.get_mut(slot) else {
            return Err(ConnectionEnd::Closed);
        };
        if control.peer.id != peer_id {
            return Err(ConnectionEnd::Closed);
        }
        let lease_deadline = Instant::now() + self.inner.config.lease_duration;
        control.deadline =
            control.provider_expiry.map_or(lease_deadline, |expiry| expiry.min(lease_deadline));
        Ok(())
    }

    async fn allocate(
        &self,
        client_control: &Peer,
        protocol: u8,
        slot: String,
        ticket: String,
        lane: LaneToken,
        generation: u64,
    ) -> Result<CircuitId, RelayError> {
        validate_protocol(protocol)?;
        validate_slot(&slot)?;
        validate_lane(&lane)?;
        validate_ticket_size(&ticket)?;
        self.inner
            .tickets
            .verify_provider(
                &ticket,
                TicketExpectation {
                    permission: RelayPermission::Connect,
                    role: RelayRole::Client,
                    slot: &slot,
                    circuit: None,
                    lane: Some(&lane),
                    generation: Some(generation),
                    require_route_binding: false,
                },
                SystemTime::now(),
            )
            .map_err(|error| RelayError::policy("invalid-ticket", error.to_string(), false))?;
        let expires_at_unix = unix_timestamp(SystemTime::now())?
            .checked_add(self.inner.config.join_ticket_ttl.as_secs())
            .ok_or_else(|| {
                RelayError::internal("ticket-expiry", "relay join ticket expiry overflowed")
            })?;

        let (circuit, daemon, client_join_ticket, daemon_join_ticket) = {
            let mut state = self.inner.state.lock().await;
            let Some((daemon, control_deadline)) =
                state.controls.get(&slot).map(|control| (control.peer.clone(), control.deadline))
            else {
                return Err(RelayError::policy(
                    "slot-offline",
                    "no daemon is registered for the requested slot",
                    true,
                ));
            };
            let now = Instant::now();
            if control_deadline <= now {
                return Err(RelayError::policy(
                    "slot-offline",
                    "daemon registration lease has expired",
                    true,
                ));
            }
            admit_client_control(
                &mut state,
                client_control.id,
                &slot,
                self.inner.config.max_control_sockets_per_slot,
            )?;
            admit_slot_allocation(
                &mut state,
                &slot,
                now,
                self.inner.config.max_pending_circuits_per_slot,
                self.inner.config.max_allocations_per_second_per_slot,
            )?;
            if state.circuits.len() >= self.inner.config.max_circuits {
                return Err(RelayError::capacity(
                    "circuit-limit",
                    "relay circuit limit was reached",
                ));
            }
            let circuit = CircuitId(Uuid::new_v4().simple().to_string());
            let client_claims = join_claims(
                self.inner.tickets.issuer(),
                RelayRole::Client,
                &slot,
                &circuit,
                &lane,
                generation,
                expires_at_unix,
            );
            let daemon_claims = join_claims(
                self.inner.tickets.issuer(),
                RelayRole::Daemon,
                &slot,
                &circuit,
                &lane,
                generation,
                expires_at_unix,
            );
            let client_join_ticket =
                self.inner.tickets.issue_join_capability(&client_claims).map_err(|_| {
                    RelayError::internal(
                        "ticket-mint-failed",
                        "relay could not mint client join capability",
                    )
                })?;
            let daemon_join_ticket =
                self.inner.tickets.issue_join_capability(&daemon_claims).map_err(|_| {
                    RelayError::internal(
                        "ticket-mint-failed",
                        "relay could not mint daemon join capability",
                    )
                })?;
            state.circuits.insert(
                circuit.clone(),
                Circuit {
                    slot: slot.clone(),
                    lane: lane.clone(),
                    generation,
                    client_join_ticket: client_join_ticket.clone(),
                    daemon_join_ticket: daemon_join_ticket.clone(),
                    created_at: now,
                    last_activity: now,
                    client: None,
                    daemon: None,
                    ready: false,
                },
            );
            state
                .slot_usage
                .get_mut(&slot)
                .expect("allocated slot usage exists")
                .pending_circuits += 1;
            (circuit, daemon, client_join_ticket, daemon_join_ticket)
        };

        let incoming = RelayControl::Incoming {
            circuit: circuit.clone(),
            lane: lane.clone(),
            generation,
            join_ticket: daemon_join_ticket,
        };
        if let Err(error) = daemon.send_control(incoming) {
            self.terminate_circuit(&circuit, error.clone()).await;
            return Err(error);
        }
        let allocated = RelayControl::Allocated {
            circuit: circuit.clone(),
            lane,
            generation,
            join_ticket: client_join_ticket,
        };
        if let Err(error) = client_control.send_control(allocated) {
            self.terminate_circuit(&circuit, error.clone()).await;
            return Err(error);
        }
        Ok(circuit)
    }

    async fn join(&self, peer: Peer, request: JoinRequest) -> Result<(), RelayError> {
        let JoinRequest { protocol, slot, circuit: circuit_id, lane, generation, ticket, role } =
            request;
        validate_protocol(protocol)?;
        validate_slot(&slot)?;
        validate_lane(&lane)?;
        validate_ticket_size(&ticket)?;

        let ready_peers = {
            let mut state = self.inner.state.lock().await;
            let becomes_ready = {
                let circuit = state.circuits.get(&circuit_id).ok_or_else(|| {
                    RelayError::policy("circuit-not-found", "relay circuit does not exist", true)
                })?;
                if circuit.slot != slot {
                    return Err(RelayError::policy(
                        "circuit-slot-mismatch",
                        "relay circuit belongs to a different slot",
                        false,
                    ));
                }
                if circuit.lane != lane || circuit.generation != generation {
                    return Err(RelayError::policy(
                        "circuit-route-mismatch",
                        "relay join lane or generation does not match the allocation",
                        false,
                    ));
                }
                let (expected_ticket, target_joined, other_joined) = match role {
                    RelayRole::Daemon => (
                        &circuit.daemon_join_ticket,
                        circuit.daemon.is_some(),
                        circuit.client.is_some(),
                    ),
                    RelayRole::Client => (
                        &circuit.client_join_ticket,
                        circuit.client.is_some(),
                        circuit.daemon.is_some(),
                    ),
                };
                if expected_ticket != &ticket {
                    return Err(RelayError::policy(
                        "circuit-ticket-mismatch",
                        "relay join ticket does not match the circuit allocation",
                        false,
                    ));
                }
                if target_joined {
                    return Err(RelayError::policy(
                        "role-already-joined",
                        "this circuit role already has an attached socket",
                        false,
                    ));
                }
                other_joined
            };
            self.inner
                .tickets
                .verify_join(
                    &ticket,
                    TicketExpectation {
                        permission: RelayPermission::Join,
                        role,
                        slot: &slot,
                        circuit: Some(&circuit_id),
                        lane: Some(&lane),
                        generation: Some(generation),
                        require_route_binding: true,
                    },
                    SystemTime::now(),
                )
                .map_err(|error| {
                    RelayError::policy("invalid-join-ticket", error.to_string(), false)
                })?;
            if becomes_ready
                && state.slot_usage.get(&slot).is_some_and(|usage| {
                    usage.active_circuits >= self.inner.config.max_active_circuits_per_slot
                })
            {
                return Err(RelayError::capacity(
                    "slot-active-circuit-limit",
                    "relay active circuit limit for this slot was reached",
                ));
            }
            let circuit = state.circuits.get_mut(&circuit_id).unwrap();
            match role {
                RelayRole::Daemon => circuit.daemon = Some(peer.clone()),
                RelayRole::Client => circuit.client = Some(peer.clone()),
            }
            if becomes_ready {
                circuit.ready = true;
            }
            state
                .attachments
                .insert(peer.id, Attachment::Circuit { circuit: circuit_id.clone(), role });
            if becomes_ready {
                let usage = state.slot_usage.get_mut(&slot).expect("joined slot usage exists");
                usage.pending_circuits = usage
                    .pending_circuits
                    .checked_sub(1)
                    .expect("ready circuit was counted as pending");
                usage.active_circuits += 1;
            }
            let circuit = state.circuits.get(&circuit_id).unwrap();
            if let (Some(client), Some(daemon)) = (&circuit.client, &circuit.daemon) {
                Some((client.clone(), daemon.clone(), circuit.lane.clone(), circuit.generation))
            } else {
                None
            }
        };

        if let Some((client, daemon, lane, generation)) = ready_peers {
            let ready = RelayControl::Ready { circuit: circuit_id.clone(), lane, generation };
            if let Err(error) = client.send_control(ready.clone()) {
                self.terminate_circuit(&circuit_id, error.clone()).await;
                return Err(error);
            }
            if let Err(error) = daemon.send_control(ready) {
                self.terminate_circuit(&circuit_id, error.clone()).await;
                return Err(error);
            }
        }
        Ok(())
    }

    async fn forward(
        &self,
        sender_id: ConnectionId,
        circuit_id: &CircuitId,
        bytes: Bytes,
    ) -> Result<(), RelayError> {
        let recipient = {
            let mut state = self.inner.state.lock().await;
            let attachment = state.attachments.get(&sender_id).cloned().ok_or_else(|| {
                RelayError::policy("circuit-detached", "socket is no longer attached", true)
            })?;
            let Attachment::Circuit { circuit, role } = attachment else {
                return Err(RelayError::protocol(
                    "not-a-circuit",
                    "only joined circuit sockets may forward binary frames",
                ));
            };
            if &circuit != circuit_id {
                return Err(RelayError::protocol(
                    "circuit-mismatch",
                    "socket attachment does not match its circuit handler",
                ));
            }
            let circuit = state.circuits.get_mut(circuit_id).ok_or_else(|| {
                RelayError::policy("circuit-not-found", "relay circuit no longer exists", true)
            })?;
            if !circuit.ready {
                return Err(RelayError::protocol(
                    "circuit-not-ready",
                    "wait for ready before sending binary frames",
                ));
            }
            circuit.last_activity = Instant::now();
            match role {
                RelayRole::Daemon => circuit.client.clone(),
                RelayRole::Client => circuit.daemon.clone(),
            }
            .ok_or_else(|| {
                RelayError::policy("peer-detached", "circuit peer is no longer attached", true)
            })?
        };

        if let Err(error) = recipient.send_binary(bytes) {
            self.terminate_circuit(circuit_id, error.clone()).await;
            return Err(error);
        }
        Ok(())
    }

    async fn disconnect(&self, peer_id: ConnectionId) {
        let peers = {
            let mut state = self.inner.state.lock().await;
            let Some(attachment) = state.attachments.remove(&peer_id) else {
                return;
            };
            match attachment {
                Attachment::Control { slot } => {
                    if state.controls.get(&slot).is_some_and(|control| control.peer.id == peer_id) {
                        state.controls.remove(&slot);
                        release_control_socket(&mut state, &slot);
                    }
                    let pending = state
                        .circuits
                        .iter()
                        .filter(|(_, circuit)| {
                            circuit.slot == slot && !circuit.ready && circuit.daemon.is_none()
                        })
                        .map(|(id, _)| id.clone())
                        .collect::<Vec<_>>();
                    pending.into_iter().flat_map(|id| remove_circuit(&mut state, &id)).collect()
                }
                Attachment::ClientControl { slot } => {
                    release_control_socket(&mut state, &slot);
                    Vec::new()
                }
                Attachment::Circuit { circuit, .. } => remove_circuit(&mut state, &circuit),
            }
        };
        for peer in peers {
            if peer.id != peer_id {
                peer.shutdown(CloseNotice::error(RelayError::policy(
                    "peer-disconnected",
                    "relay circuit peer disconnected",
                    true,
                )));
            }
        }
    }

    async fn terminate_circuit(&self, circuit_id: &CircuitId, error: RelayError) {
        let peers = {
            let mut state = self.inner.state.lock().await;
            remove_circuit(&mut state, circuit_id)
        };
        for peer in peers {
            peer.shutdown(CloseNotice::error(error.clone()));
        }
    }

    async fn cleanup_expired(&self, now: Instant) {
        let (expired_controls, expired_circuits) = {
            let mut state = self.inner.state.lock().await;
            let control_slots = state
                .controls
                .iter()
                .filter(|(_, control)| control.deadline <= now)
                .map(|(slot, _)| slot.clone())
                .collect::<Vec<_>>();
            let mut expired_controls = Vec::new();
            for slot in control_slots {
                if let Some(control) = state.controls.remove(&slot) {
                    state.attachments.remove(&control.peer.id);
                    release_control_socket(&mut state, &slot);
                    expired_controls.push(control.peer);
                }
            }

            let circuit_ids = state
                .circuits
                .iter()
                .filter(|(_, circuit)| {
                    if circuit.ready {
                        now.saturating_duration_since(circuit.last_activity)
                            >= self.inner.config.idle_timeout
                    } else {
                        now.saturating_duration_since(circuit.created_at)
                            >= self.inner.config.join_timeout
                    }
                })
                .map(|(id, _)| id.clone())
                .collect::<Vec<_>>();
            let expired_circuits = circuit_ids
                .into_iter()
                .flat_map(|id| remove_circuit(&mut state, &id))
                .collect::<Vec<_>>();
            (expired_controls, expired_circuits)
        };

        for peer in expired_controls {
            peer.shutdown(CloseNotice::error(RelayError::policy(
                "lease-expired",
                "daemon registration lease expired",
                true,
            )));
        }
        for peer in expired_circuits {
            peer.shutdown(CloseNotice::error(RelayError::policy(
                "circuit-timeout",
                "relay circuit timed out",
                true,
            )));
        }
    }

    async fn write_socket(
        mut socket: SplitSink<WebSocket, Message>,
        mut outbound: mpsc::Receiver<Outbound>,
        mut shutdown: watch::Receiver<Option<CloseNotice>>,
    ) {
        loop {
            tokio::select! {
                biased;
                changed = shutdown.changed() => {
                    if changed.is_ok() {
                        let notice = shutdown.borrow().clone();
                        if let Some(notice) = notice {
                            if let Some(error) = notice.error
                                && let Ok(text) = serde_json::to_string(&error)
                            {
                                let _ = socket.send(Message::Text(text.into())).await;
                            }
                            let _ = socket
                                .send(Message::Close(Some(CloseFrame {
                                    code: notice.code,
                                    reason: notice.reason.into(),
                                })))
                                .await;
                        }
                    }
                    return;
                }
                message = outbound.recv() => {
                    let Some(message) = message else {
                        let _ = socket.send(Message::Close(None)).await;
                        return;
                    };
                    let result = match message {
                        Outbound::Control(control) => match serde_json::to_string(&control) {
                            Ok(text) => socket.send(Message::Text(text.into())).await,
                            Err(_) => return,
                        },
                        Outbound::Binary(frame) => {
                            socket.send(Message::Binary(frame.bytes.clone())).await
                        }
                        Outbound::Pong(bytes) => socket.send(Message::Pong(bytes)).await,
                    };
                    if result.is_err() {
                        return;
                    }
                }
            }
        }
    }
}

impl Peer {
    fn send_control(&self, control: RelayControl) -> Result<(), RelayError> {
        self.outbound.send_control(control)
    }

    fn send_binary(&self, bytes: Bytes) -> Result<(), RelayError> {
        self.outbound.send_binary(bytes)
    }

    fn send_pong(&self, bytes: Bytes) -> Result<(), RelayError> {
        self.outbound
            .sender
            .try_send(Outbound::Pong(bytes))
            .map_err(|_| RelayError::capacity("queue-full", "relay socket queue is full or closed"))
    }

    fn shutdown(&self, notice: CloseNotice) {
        self.shutdown.send_replace(Some(notice));
    }

    fn shutdown_if_open(&self, notice: CloseNotice) {
        if self.shutdown.borrow().is_none() {
            self.shutdown(notice);
        }
    }
}

impl OutboundSender {
    fn send_control(&self, control: RelayControl) -> Result<(), RelayError> {
        self.sender
            .try_send(Outbound::Control(control))
            .map_err(|_| RelayError::capacity("queue-full", "relay socket queue is full or closed"))
    }

    fn send_binary(&self, bytes: Bytes) -> Result<(), RelayError> {
        let size = bytes.len();
        self.queued_bytes
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |queued| {
                queued.checked_add(size).filter(|next| *next <= self.maximum_queue_bytes)
            })
            .map_err(|_| {
                RelayError::capacity(
                    "queue-bytes-exceeded",
                    "relay socket queued-byte limit was exceeded",
                )
            })?;
        let frame = QueuedBinary { bytes, queued_bytes: self.queued_bytes.clone() };
        self.sender.try_send(Outbound::Binary(frame)).map_err(|_| {
            RelayError::capacity("queue-full", "relay socket frame queue is full or closed")
        })
    }
}

fn join_claims(
    issuer: &str,
    role: RelayRole,
    slot: &str,
    circuit: &CircuitId,
    lane: &LaneToken,
    generation: u64,
    expires_at_unix: u64,
) -> RelayTicketClaims {
    RelayTicketClaims {
        version: RelayTicketClaims::VERSION,
        issuer: issuer.into(),
        permission: RelayPermission::Join,
        role,
        slot: slot.into(),
        circuit: Some(circuit.clone()),
        lane: Some(lane.clone()),
        generation: Some(generation),
        expires_at_unix,
    }
}

fn unix_timestamp(now: SystemTime) -> Result<u64, RelayError> {
    now.duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .map_err(|_| RelayError::internal("invalid-clock", "system clock is before Unix epoch"))
}

fn expiry_as_instant(
    expires_at_unix: u64,
    system_now: SystemTime,
    instant_now: Instant,
) -> Result<Instant, RelayError> {
    let remaining = expires_at_unix
        .checked_sub(unix_timestamp(system_now)?)
        .ok_or_else(|| RelayError::policy("expired-ticket", "relay ticket has expired", false))?;
    instant_now.checked_add(Duration::from_secs(remaining)).ok_or_else(|| {
        RelayError::internal("ticket-expiry", "relay ticket expiry exceeded monotonic time")
    })
}

fn admit_client_control(
    state: &mut RelayState,
    peer_id: ConnectionId,
    slot: &str,
    maximum_control_sockets: usize,
) -> Result<(), RelayError> {
    match state.attachments.get(&peer_id) {
        Some(Attachment::ClientControl { slot: attached_slot }) if attached_slot == slot => {
            return Ok(());
        }
        Some(_) => {
            return Err(RelayError::policy(
                "invalid-control-attachment",
                "relay socket already has a different attachment",
                false,
            ));
        }
        None => {}
    }
    let usage = state.slot_usage.entry(slot.to_owned()).or_default();
    if usage.control_sockets >= maximum_control_sockets {
        return Err(RelayError::capacity(
            "slot-control-limit",
            "relay control socket limit for this slot was reached",
        ));
    }
    usage.control_sockets += 1;
    state.attachments.insert(peer_id, Attachment::ClientControl { slot: slot.to_owned() });
    Ok(())
}

fn admit_slot_allocation(
    state: &mut RelayState,
    slot: &str,
    now: Instant,
    maximum_pending_circuits: usize,
    maximum_allocations_per_second: usize,
) -> Result<(), RelayError> {
    let usage = state.slot_usage.entry(slot.to_owned()).or_default();
    while usage.recent_allocations.front().is_some_and(|allocation| {
        now.saturating_duration_since(*allocation) >= ALLOCATION_RATE_WINDOW
    }) {
        usage.recent_allocations.pop_front();
    }
    if usage.recent_allocations.len() >= maximum_allocations_per_second {
        return Err(RelayError::capacity(
            "slot-allocation-rate-limit",
            "relay allocation rate limit for this slot was reached",
        ));
    }
    usage.recent_allocations.push_back(now);
    if usage.pending_circuits >= maximum_pending_circuits {
        return Err(RelayError::capacity(
            "slot-pending-circuit-limit",
            "relay pending circuit limit for this slot was reached",
        ));
    }
    Ok(())
}

fn release_control_socket(state: &mut RelayState, slot: &str) {
    if let Some(usage) = state.slot_usage.get_mut(slot) {
        usage.control_sockets = usage.control_sockets.saturating_sub(1);
    }
    prune_slot_usage(state, slot);
}

fn prune_slot_usage(state: &mut RelayState, slot: &str) {
    if state.slot_usage.get(slot).is_some_and(|usage| {
        usage.control_sockets == 0 && usage.pending_circuits == 0 && usage.active_circuits == 0
    }) {
        state.slot_usage.remove(slot);
    }
}

fn remove_circuit(state: &mut RelayState, circuit_id: &CircuitId) -> Vec<Peer> {
    let Some(circuit) = state.circuits.remove(circuit_id) else {
        return Vec::new();
    };
    if let Some(usage) = state.slot_usage.get_mut(&circuit.slot) {
        let count =
            if circuit.ready { &mut usage.active_circuits } else { &mut usage.pending_circuits };
        *count = count.saturating_sub(1);
    }
    prune_slot_usage(state, &circuit.slot);
    let mut peers = Vec::with_capacity(2);
    if let Some(peer) = circuit.client {
        state.attachments.remove(&peer.id);
        peers.push(peer);
    }
    if let Some(peer) = circuit.daemon {
        state.attachments.remove(&peer.id);
        peers.push(peer);
    }
    peers
}

fn validate_protocol(protocol: u8) -> Result<(), RelayError> {
    if protocol == REMOTE_PROTOCOL_VERSION {
        Ok(())
    } else {
        Err(RelayError::protocol(
            "unsupported-protocol",
            format!("relay protocol {protocol} is unsupported, expected {REMOTE_PROTOCOL_VERSION}"),
        ))
    }
}

fn validate_slot(slot: &str) -> Result<(), RelayError> {
    if slot.is_empty()
        || slot.len() > MAX_SLOT_BYTES
        || slot.bytes().any(|byte| matches!(byte, b'\n' | b'\r'))
    {
        Err(RelayError::policy(
            "invalid-slot",
            format!("slot must contain 1 to {MAX_SLOT_BYTES} bytes"),
            false,
        ))
    } else {
        Ok(())
    }
}

fn validate_lane(lane: &LaneToken) -> Result<(), RelayError> {
    if lane.0.is_empty()
        || lane.0.len() > MAX_LANE_TOKEN_BYTES
        || lane.0.bytes().any(|byte| matches!(byte, b'\n' | b'\r'))
    {
        Err(RelayError::policy(
            "invalid-lane",
            format!("lane token must contain 1 to {MAX_LANE_TOKEN_BYTES} bytes"),
            false,
        ))
    } else {
        Ok(())
    }
}

fn validate_ticket_size(ticket: &str) -> Result<(), RelayError> {
    if ticket.is_empty() || ticket.len() > MAX_TICKET_BYTES {
        Err(RelayError::policy(
            "invalid-ticket",
            format!("ticket must contain 1 to {MAX_TICKET_BYTES} bytes"),
            false,
        ))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::net::SocketAddr;

    use futures_util::{SinkExt, StreamExt};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpStream;
    use tokio::sync::{mpsc, watch};
    use tokio::task::JoinHandle;
    use tokio::time::timeout;
    use tokio_tungstenite::tungstenite::Message as ClientMessage;
    use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};

    use super::*;

    const RELAY_CONTROL_CONFORMANCE: &str =
        include_str!("../../cmux-remote-protocol/tests/fixtures/relay-control-v1.jsonl");

    #[test]
    fn relay_control_matches_shared_wire_fixture() {
        for encoded in RELAY_CONTROL_CONFORMANCE.lines() {
            let control: RelayControl = serde_json::from_str(encoded).unwrap();
            assert_eq!(serde_json::to_string(&control).unwrap(), encoded);
        }
    }

    type TestSocket = WebSocketStream<MaybeTlsStream<TcpStream>>;

    struct TestServer {
        address: SocketAddr,
        relay: Relay,
        task: JoinHandle<()>,
    }

    impl TestServer {
        async fn start(config: RelayConfig) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let relay = Relay::new(config).unwrap();
            let (listener, router) = relay.server_parts(listener);
            let task = tokio::spawn(async move {
                axum::serve(listener, router).await.unwrap();
            });
            Self { address, relay, task }
        }

        async fn connect(&self) -> TestSocket {
            let url = format!("ws://{}/v1/relay", self.address);
            connect_async(url).await.unwrap().0
        }
    }

    impl Drop for TestServer {
        fn drop(&mut self) {
            self.task.abort();
        }
    }

    async fn send_control(socket: &mut TestSocket, control: RelayControl) {
        let text = serde_json::to_string(&control).unwrap();
        socket.send(ClientMessage::Text(text.into())).await.unwrap();
    }

    async fn receive_control(socket: &mut TestSocket) -> RelayControl {
        loop {
            let message = timeout(Duration::from_secs(2), socket.next())
                .await
                .expect("timed out waiting for relay control")
                .expect("relay closed before control response")
                .unwrap();
            match message {
                ClientMessage::Text(text) => return serde_json::from_str(&text).unwrap(),
                ClientMessage::Ping(bytes) => {
                    socket.send(ClientMessage::Pong(bytes)).await.unwrap();
                }
                other => panic!("expected relay control text, got {other:?}"),
            }
        }
    }

    async fn receive_binary(socket: &mut TestSocket) -> Bytes {
        loop {
            let message = timeout(Duration::from_secs(2), socket.next())
                .await
                .expect("timed out waiting for relay binary frame")
                .expect("relay closed before binary frame")
                .unwrap();
            match message {
                ClientMessage::Binary(bytes) => return bytes,
                ClientMessage::Ping(bytes) => {
                    socket.send(ClientMessage::Pong(bytes)).await.unwrap();
                }
                other => panic!("expected opaque binary frame, got {other:?}"),
            }
        }
    }

    async fn register_open_daemon(server: &TestServer, slot: &str) -> TestSocket {
        let mut daemon = server.connect().await;
        send_control(
            &mut daemon,
            RelayControl::Register {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: slot.into(),
                ticket: format!("{slot}-daemon-ticket"),
            },
        )
        .await;
        assert!(matches!(receive_control(&mut daemon).await, RelayControl::Registered { .. }));
        daemon
    }

    async fn open_client_control(
        server: &TestServer,
        daemon: &mut TestSocket,
        slot: &str,
        lane: &str,
        generation: u64,
    ) -> TestSocket {
        let mut client = server.connect().await;
        send_control(
            &mut client,
            RelayControl::Connect {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: slot.into(),
                ticket: format!("{slot}-client-ticket"),
                lane: LaneToken(lane.into()),
                generation,
            },
        )
        .await;
        assert!(matches!(receive_control(&mut client).await, RelayControl::Allocated { .. }));
        assert!(matches!(receive_control(daemon).await, RelayControl::Incoming { .. }));
        client
    }

    fn test_peer(
        id: ConnectionId,
        config: &RelayConfig,
    ) -> (Peer, mpsc::Receiver<Outbound>, watch::Receiver<Option<CloseNotice>>) {
        let (sender, receiver) = mpsc::channel(config.max_queue_frames);
        let (shutdown, shutdown_receiver) = watch::channel(None);
        (
            Peer {
                id,
                outbound: OutboundSender {
                    sender,
                    queued_bytes: Arc::new(AtomicUsize::new(0)),
                    maximum_queue_bytes: config.max_queue_bytes,
                },
                shutdown,
            },
            receiver,
            shutdown_receiver,
        )
    }

    fn provider_ticket(
        config: &RelayConfig,
        permission: RelayPermission,
        lane: Option<LaneToken>,
        generation: Option<u64>,
    ) -> String {
        let role = match permission {
            RelayPermission::Register => RelayRole::Daemon,
            RelayPermission::Connect => RelayRole::Client,
            RelayPermission::Join => panic!("join tickets are minted by the relay"),
        };
        let authority = TicketAuthority::hmac_with_issuer(
            config.ticket_secret.clone().unwrap(),
            config.ticket_issuer.clone(),
        )
        .unwrap();
        authority
            .issue(&RelayTicketClaims {
                version: RelayTicketClaims::VERSION,
                issuer: config.ticket_issuer.clone(),
                permission,
                role,
                slot: "slot-a".into(),
                circuit: None,
                lane,
                generation,
                expires_at_unix: unix_timestamp(SystemTime::now()).unwrap() + 60,
            })
            .unwrap()
    }

    #[tokio::test]
    async fn websocket_circuit_registers_pairs_and_forwards_opaque_binary() {
        let server = TestServer::start(RelayConfig::default()).await;
        let mut daemon_control = server.connect().await;
        send_control(
            &mut daemon_control,
            RelayControl::Register {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "slot-a".into(),
                ticket: "daemon-ticket".into(),
            },
        )
        .await;
        assert!(matches!(
            receive_control(&mut daemon_control).await,
            RelayControl::Registered { .. }
        ));

        let mut client_control = server.connect().await;
        send_control(
            &mut client_control,
            RelayControl::Connect {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "slot-a".into(),
                ticket: "client-ticket".into(),
                lane: LaneToken("interactive".into()),
                generation: 7,
            },
        )
        .await;
        let RelayControl::Allocated { circuit, lane, generation, join_ticket: client_join_ticket } =
            receive_control(&mut client_control).await
        else {
            panic!("client did not receive circuit allocation");
        };
        assert_eq!(lane, LaneToken("interactive".into()));
        assert_eq!(generation, 7);
        let RelayControl::Incoming {
            circuit: daemon_circuit_id,
            lane: daemon_lane,
            generation: daemon_generation,
            join_ticket: daemon_join_ticket,
        } = receive_control(&mut daemon_control).await
        else {
            panic!("daemon did not receive incoming circuit");
        };
        assert_eq!(daemon_circuit_id, circuit);
        assert_eq!(daemon_lane, lane);
        assert_eq!(daemon_generation, generation);
        assert_ne!(client_join_ticket, daemon_join_ticket);
        assert_ne!(client_join_ticket, "client-ticket");
        assert_ne!(daemon_join_ticket, "daemon-ticket");
        assert!(client_join_ticket.starts_with("o2."));
        assert!(daemon_join_ticket.starts_with("o2."));

        let mut client_circuit = server.connect().await;
        send_control(
            &mut client_circuit,
            RelayControl::Join {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "slot-a".into(),
                circuit: circuit.clone(),
                lane: lane.clone(),
                generation,
                ticket: client_join_ticket,
                role: RelayRole::Client,
            },
        )
        .await;
        let mut daemon_circuit = server.connect().await;
        send_control(
            &mut daemon_circuit,
            RelayControl::Join {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "slot-a".into(),
                circuit: circuit.clone(),
                lane: lane.clone(),
                generation,
                ticket: daemon_join_ticket,
                role: RelayRole::Daemon,
            },
        )
        .await;
        let ready =
            RelayControl::Ready { circuit: circuit.clone(), lane: lane.clone(), generation };
        assert_eq!(receive_control(&mut client_circuit).await, ready);
        assert_eq!(
            receive_control(&mut daemon_circuit).await,
            RelayControl::Ready { circuit: circuit.clone(), lane, generation }
        );

        client_circuit
            .send(ClientMessage::Binary(Bytes::from_static(b"client ciphertext")))
            .await
            .unwrap();
        assert_eq!(
            receive_binary(&mut daemon_circuit).await,
            Bytes::from_static(b"client ciphertext")
        );
        daemon_circuit
            .send(ClientMessage::Binary(Bytes::from_static(b"daemon ciphertext")))
            .await
            .unwrap();
        assert_eq!(
            receive_binary(&mut client_circuit).await,
            Bytes::from_static(b"daemon ciphertext")
        );

        assert_eq!(
            server.relay.health().await,
            HealthSnapshot {
                status: "ok",
                daemon_slots: 1,
                pending_circuits: 0,
                ready_circuits: 1,
            }
        );

        client_circuit.send(ClientMessage::Close(None)).await.unwrap();
        let error = receive_control(&mut daemon_circuit).await;
        assert!(matches!(
            error,
            RelayControl::Error { code, retryable: true, .. } if code == "peer-disconnected"
        ));
    }

    #[tokio::test]
    async fn hmac_provider_and_join_tickets_enforce_permission_lane_and_generation() {
        let config = RelayConfig {
            ticket_secret: Some(vec![9; 32]),
            ticket_issuer: "relay.test".into(),
            ..RelayConfig::default()
        };
        let server = TestServer::start(config.clone()).await;
        let connect_ticket = provider_ticket(
            &config,
            RelayPermission::Connect,
            Some(LaneToken("interactive".into())),
            Some(19),
        );

        let mut wrong_provider = server.connect().await;
        send_control(
            &mut wrong_provider,
            RelayControl::Register {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "slot-a".into(),
                ticket: connect_ticket.clone(),
            },
        )
        .await;
        assert!(matches!(
            receive_control(&mut wrong_provider).await,
            RelayControl::Error { code, retryable: false, .. } if code == "invalid-ticket"
        ));

        let mut daemon_control = server.connect().await;
        send_control(
            &mut daemon_control,
            RelayControl::Register {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "slot-a".into(),
                ticket: provider_ticket(&config, RelayPermission::Register, None, None),
            },
        )
        .await;
        assert!(matches!(
            receive_control(&mut daemon_control).await,
            RelayControl::Registered { .. }
        ));

        let lane = LaneToken("interactive".into());
        let generation = 19;
        let mut client_control = server.connect().await;
        send_control(
            &mut client_control,
            RelayControl::Connect {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "slot-a".into(),
                ticket: connect_ticket,
                lane: lane.clone(),
                generation,
            },
        )
        .await;
        let RelayControl::Allocated { circuit, join_ticket: client_join_ticket, .. } =
            receive_control(&mut client_control).await
        else {
            panic!("client did not receive allocation");
        };
        let RelayControl::Incoming { join_ticket: daemon_join_ticket, .. } =
            receive_control(&mut daemon_control).await
        else {
            panic!("daemon did not receive incoming circuit");
        };
        assert!(client_join_ticket.starts_with("v2."));
        assert!(daemon_join_ticket.starts_with("v2."));
        assert_ne!(client_join_ticket, daemon_join_ticket);

        let mut wrong_join = server.connect().await;
        send_control(
            &mut wrong_join,
            RelayControl::Join {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "slot-a".into(),
                circuit: circuit.clone(),
                lane: LaneToken("bulk".into()),
                generation,
                ticket: client_join_ticket.clone(),
                role: RelayRole::Client,
            },
        )
        .await;
        assert!(matches!(
            receive_control(&mut wrong_join).await,
            RelayControl::Error { code, retryable: false, .. }
                if code == "circuit-route-mismatch"
        ));

        let mut client_circuit = server.connect().await;
        send_control(
            &mut client_circuit,
            RelayControl::Join {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "slot-a".into(),
                circuit: circuit.clone(),
                lane: lane.clone(),
                generation,
                ticket: client_join_ticket,
                role: RelayRole::Client,
            },
        )
        .await;
        let mut daemon_circuit = server.connect().await;
        send_control(
            &mut daemon_circuit,
            RelayControl::Join {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "slot-a".into(),
                circuit: circuit.clone(),
                lane: lane.clone(),
                generation,
                ticket: daemon_join_ticket,
                role: RelayRole::Daemon,
            },
        )
        .await;
        let ready = RelayControl::Ready { circuit, lane, generation };
        assert_eq!(receive_control(&mut client_circuit).await, ready);
        assert_eq!(receive_control(&mut daemon_circuit).await, ready);
    }

    #[tokio::test]
    async fn health_endpoint_is_available_without_a_websocket_upgrade() {
        let server = TestServer::start(RelayConfig::default()).await;
        let mut stream = TcpStream::connect(server.address).await.unwrap();
        stream
            .write_all(
                format!("GET /healthz HTTP/1.1\r\nHost: {}\r\n\r\n", server.address).as_bytes(),
            )
            .await
            .unwrap();
        let mut response = Vec::new();
        timeout(Duration::from_secs(2), stream.read_to_end(&mut response)).await.unwrap().unwrap();
        let response = String::from_utf8(response).unwrap();
        assert!(response.starts_with("HTTP/1.1 200 OK"));
        assert!(response.to_ascii_lowercase().contains("connection: close"));
        assert!(response.contains("\"status\":\"ok\""));
    }

    #[tokio::test]
    async fn pending_circuit_cleanup_closes_a_joined_peer() {
        let config = RelayConfig::default();
        let relay = Relay::new(config.clone()).unwrap();
        let (daemon, _daemon_outbound, _daemon_shutdown) = test_peer(1, &config);
        relay
            .register(daemon, REMOTE_PROTOCOL_VERSION, "slot-a".into(), "daemon-ticket".into())
            .await
            .unwrap();
        let (client_control, _client_outbound, _client_shutdown) = test_peer(2, &config);
        let circuit = relay
            .allocate(
                &client_control,
                REMOTE_PROTOCOL_VERSION,
                "slot-a".into(),
                "client-ticket".into(),
                LaneToken("bulk".into()),
                11,
            )
            .await
            .unwrap();
        let client_join_ticket = relay
            .inner
            .state
            .lock()
            .await
            .circuits
            .get(&circuit)
            .unwrap()
            .client_join_ticket
            .clone();
        let (client_join, _join_outbound, join_shutdown) = test_peer(3, &config);
        relay
            .join(
                client_join,
                JoinRequest {
                    protocol: REMOTE_PROTOCOL_VERSION,
                    slot: "slot-a".into(),
                    circuit,
                    lane: LaneToken("bulk".into()),
                    generation: 11,
                    ticket: client_join_ticket,
                    role: RelayRole::Client,
                },
            )
            .await
            .unwrap();

        relay.cleanup_expired(Instant::now() + config.join_timeout).await;
        assert_eq!(relay.health().await.pending_circuits, 0);
        let notice = join_shutdown.borrow().clone().expect("joined client was not closed");
        assert!(matches!(
            notice.error,
            Some(RelayControl::Error { code, retryable: true, .. }) if code == "circuit-timeout"
        ));
    }

    #[tokio::test]
    async fn outgoing_queue_enforces_frame_and_byte_bounds() {
        let (sender, mut receiver) = mpsc::channel(1);
        let queued_bytes = Arc::new(AtomicUsize::new(0));
        let outbound =
            OutboundSender { sender, queued_bytes: queued_bytes.clone(), maximum_queue_bytes: 3 };
        outbound.send_binary(Bytes::from_static(b"abc")).unwrap();
        assert_eq!(queued_bytes.load(Ordering::Acquire), 3);
        let error = outbound.send_binary(Bytes::from_static(b"d")).unwrap_err();
        assert_eq!(error.code, "queue-bytes-exceeded");
        let frame = receiver.recv().await.unwrap();
        drop(frame);
        assert_eq!(queued_bytes.load(Ordering::Acquire), 0);

        outbound.send_binary(Bytes::from_static(b"a")).unwrap();
        let error = outbound.send_binary(Bytes::from_static(b"b")).unwrap_err();
        assert_eq!(error.code, "queue-full");
        assert_eq!(queued_bytes.load(Ordering::Acquire), 1);
        drop(receiver.recv().await);
        assert_eq!(queued_bytes.load(Ordering::Acquire), 0);
    }

    #[tokio::test]
    async fn slot_and_circuit_counts_are_bounded() {
        let config = RelayConfig { max_slots: 1, max_circuits: 1, ..RelayConfig::default() };
        let relay = Relay::new(config.clone()).unwrap();
        let (daemon, _daemon_outbound, _daemon_shutdown) = test_peer(1, &config);
        relay
            .register(daemon, REMOTE_PROTOCOL_VERSION, "slot-a".into(), "daemon-ticket".into())
            .await
            .unwrap();
        let (extra_daemon, _extra_outbound, _extra_shutdown) = test_peer(2, &config);
        let error = relay
            .register(
                extra_daemon,
                REMOTE_PROTOCOL_VERSION,
                "slot-b".into(),
                "other-daemon-ticket".into(),
            )
            .await
            .unwrap_err();
        assert_eq!(error.code, "slot-limit");

        let (client, _client_outbound, _client_shutdown) = test_peer(3, &config);
        relay
            .allocate(
                &client,
                REMOTE_PROTOCOL_VERSION,
                "slot-a".into(),
                "client-ticket".into(),
                LaneToken("interactive".into()),
                1,
            )
            .await
            .unwrap();
        let error = relay
            .allocate(
                &client,
                REMOTE_PROTOCOL_VERSION,
                "slot-a".into(),
                "client-ticket".into(),
                LaneToken("bulk".into()),
                1,
            )
            .await
            .unwrap_err();
        assert_eq!(error.code, "circuit-limit");
    }

    #[tokio::test]
    async fn concurrent_websocket_count_is_bounded() {
        let config = RelayConfig { max_connections: 1, ..RelayConfig::default() };
        let server = TestServer::start(config).await;
        let mut first = server.connect().await;
        send_control(
            &mut first,
            RelayControl::Register {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "slot-a".into(),
                ticket: "daemon-ticket".into(),
            },
        )
        .await;
        assert!(matches!(receive_control(&mut first).await, RelayControl::Registered { .. }));
        let url = format!("ws://{}/v1/relay", server.address);
        let error = connect_async(url).await.expect_err("second WebSocket upgrade was admitted");
        assert!(matches!(
            error,
            tokio_tungstenite::tungstenite::Error::Http(response)
                if response.status() == StatusCode::SERVICE_UNAVAILABLE
        ));
    }

    #[tokio::test]
    async fn partial_http_headers_expire_and_raw_admission_remains_bounded() {
        let config = RelayConfig {
            http_header_timeout: Duration::from_millis(120),
            max_http_connections: 1,
            ..RelayConfig::default()
        };
        let server = TestServer::start(config).await;
        let mut slow = TcpStream::connect(server.address).await.unwrap();
        slow.write_all(b"GET /healthz HTTP/1.1\r\nHost:").await.unwrap();

        let mut queued = TcpStream::connect(server.address).await.unwrap();
        queued
            .write_all(
                format!("GET /healthz HTTP/1.1\r\nHost: {}\r\n\r\n", server.address).as_bytes(),
            )
            .await
            .unwrap();
        let mut first_byte = [0_u8; 1];
        assert!(timeout(Duration::from_millis(50), queued.read(&mut first_byte)).await.is_err());

        let mut response = first_byte[..0].to_vec();
        timeout(Duration::from_secs(2), queued.read_to_end(&mut response))
            .await
            .expect("queued connection was not admitted after the header deadline")
            .unwrap();
        assert!(String::from_utf8(response).unwrap().starts_with("HTTP/1.1 200 OK"));

        let mut discarded = Vec::new();
        let slow_result = timeout(Duration::from_secs(1), slow.read_to_end(&mut discarded))
            .await
            .expect("partial HTTP connection remained open past its deadline");
        assert!(slow_result.is_ok() || discarded.is_empty());
    }

    #[tokio::test]
    async fn per_slot_control_socket_quota_prevents_global_capacity_capture() {
        let config = RelayConfig {
            max_control_sockets_per_slot: 2,
            max_pending_circuits_per_slot: 8,
            max_allocations_per_second_per_slot: 8,
            ..RelayConfig::default()
        };
        let server = TestServer::start(config).await;
        let mut daemon = register_open_daemon(&server, "slot-a").await;
        let _first = open_client_control(&server, &mut daemon, "slot-a", "interactive", 1).await;

        let mut second = server.connect().await;
        send_control(
            &mut second,
            RelayControl::Connect {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "slot-a".into(),
                ticket: "slot-a-client-ticket".into(),
                lane: LaneToken("bulk".into()),
                generation: 1,
            },
        )
        .await;
        assert!(matches!(
            receive_control(&mut second).await,
            RelayControl::Error { code, retryable: true, .. } if code == "slot-control-limit"
        ));
        assert_eq!(server.relay.health().await.pending_circuits, 1);
    }

    #[tokio::test]
    async fn per_slot_pending_circuit_quota_bounds_repeated_connect() {
        let config = RelayConfig {
            max_pending_circuits_per_slot: 1,
            max_allocations_per_second_per_slot: 8,
            ..RelayConfig::default()
        };
        let server = TestServer::start(config).await;
        let mut daemon = register_open_daemon(&server, "slot-a").await;
        let mut client =
            open_client_control(&server, &mut daemon, "slot-a", "interactive", 1).await;
        send_control(
            &mut client,
            RelayControl::Connect {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "slot-a".into(),
                ticket: "slot-a-client-ticket".into(),
                lane: LaneToken("bulk".into()),
                generation: 1,
            },
        )
        .await;
        assert!(matches!(
            receive_control(&mut client).await,
            RelayControl::Error { code, retryable: true, .. }
                if code == "slot-pending-circuit-limit"
        ));
        assert_eq!(server.relay.health().await.pending_circuits, 1);
    }

    #[tokio::test]
    async fn per_slot_sliding_rate_limit_bounds_repeated_connect() {
        let config = RelayConfig {
            max_pending_circuits_per_slot: 8,
            max_allocations_per_second_per_slot: 1,
            ..RelayConfig::default()
        };
        let server = TestServer::start(config).await;
        let mut daemon = register_open_daemon(&server, "slot-a").await;
        let mut client =
            open_client_control(&server, &mut daemon, "slot-a", "interactive", 1).await;
        send_control(
            &mut client,
            RelayControl::Connect {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "slot-a".into(),
                ticket: "slot-a-client-ticket".into(),
                lane: LaneToken("bulk".into()),
                generation: 1,
            },
        )
        .await;
        assert!(matches!(
            receive_control(&mut client).await,
            RelayControl::Error { code, retryable: true, .. }
                if code == "slot-allocation-rate-limit"
        ));
        assert_eq!(server.relay.health().await.pending_circuits, 1);
    }

    #[tokio::test]
    async fn per_slot_active_circuit_quota_is_enforced_at_pairing() {
        let config = RelayConfig {
            max_active_circuits_per_slot: 1,
            max_pending_circuits_per_slot: 4,
            max_allocations_per_second_per_slot: 4,
            ..RelayConfig::default()
        };
        let relay = Relay::new(config.clone()).unwrap();
        let (daemon_control, _daemon_outbound, _daemon_shutdown) = test_peer(1, &config);
        relay
            .register(
                daemon_control,
                REMOTE_PROTOCOL_VERSION,
                "slot-a".into(),
                "daemon-ticket".into(),
            )
            .await
            .unwrap();
        let (client_control, _client_outbound, _client_shutdown) = test_peer(2, &config);

        for (offset, expected) in [(0_u64, Ok(())), (1, Err("slot-active-circuit-limit"))] {
            let lane = LaneToken(format!("lane-{offset}"));
            let generation = offset + 1;
            let circuit = relay
                .allocate(
                    &client_control,
                    REMOTE_PROTOCOL_VERSION,
                    "slot-a".into(),
                    "client-ticket".into(),
                    lane.clone(),
                    generation,
                )
                .await
                .unwrap();
            let (client_ticket, daemon_ticket) = {
                let state = relay.inner.state.lock().await;
                let circuit = state.circuits.get(&circuit).unwrap();
                (circuit.client_join_ticket.clone(), circuit.daemon_join_ticket.clone())
            };
            let (client, _client_join_outbound, _client_join_shutdown) =
                test_peer(10 + offset * 2, &config);
            relay
                .join(
                    client,
                    JoinRequest {
                        protocol: REMOTE_PROTOCOL_VERSION,
                        slot: "slot-a".into(),
                        circuit: circuit.clone(),
                        lane: lane.clone(),
                        generation,
                        ticket: client_ticket,
                        role: RelayRole::Client,
                    },
                )
                .await
                .unwrap();
            let (daemon, _daemon_join_outbound, _daemon_join_shutdown) =
                test_peer(11 + offset * 2, &config);
            let result = relay
                .join(
                    daemon,
                    JoinRequest {
                        protocol: REMOTE_PROTOCOL_VERSION,
                        slot: "slot-a".into(),
                        circuit,
                        lane,
                        generation,
                        ticket: daemon_ticket,
                        role: RelayRole::Daemon,
                    },
                )
                .await;
            match expected {
                Ok(()) => result.unwrap(),
                Err(code) => assert_eq!(result.unwrap_err().code, code),
            }
        }

        let state = relay.inner.state.lock().await;
        let usage = state.slot_usage.get("slot-a").unwrap();
        assert_eq!(usage.active_circuits, 1);
        assert_eq!(usage.pending_circuits, 1);
    }

    #[tokio::test]
    async fn authenticated_control_socket_has_an_idle_deadline() {
        let config = RelayConfig {
            lease_duration: Duration::from_secs(2),
            control_idle_timeout: Duration::from_millis(50),
            ..RelayConfig::default()
        };
        let server = TestServer::start(config).await;
        let mut daemon = register_open_daemon(&server, "slot-a").await;
        assert!(matches!(
            receive_control(&mut daemon).await,
            RelayControl::Error { code, retryable: true, .. } if code == "control-idle-timeout"
        ));
    }
}
