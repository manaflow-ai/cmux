use std::time::Duration;

use cmux_remote_protocol::{
    CircuitId, LaneToken, MAX_RELAY_BATCH_BYTES, REMOTE_PROTOCOL_VERSION, RelayControl,
    RelayPermission, RelayRole, RelaySocketAttachment,
};
use serde::{Deserialize, Serialize};
use worker::{
    Date, DurableObject, Env, Method, Request, Response, Result, State, WebSocket,
    WebSocketIncomingMessage, WebSocketPair, durable_object,
};

use crate::abuse::{
    ACTIVE_CIRCUIT_LEASE_MS, ACTIVE_CIRCUIT_RENEW_MS, CIRCUIT_HANDSHAKE_TIMEOUT_MS,
    CIRCUIT_IDLE_TIMEOUT_MS, admit_circuit_socket, websocket_counts_toward_capacity,
    websocket_is_open,
};
use crate::attachment::{CircuitAttachment, CircuitPhase, OutboundQueue};
use crate::auth::{DEFAULT_TICKET_ISSUER, TicketExpectation, verify_ticket};
use crate::wire::{
    close, decode_control, send_control, upgrade_required, valid_opaque_identifier,
    websocket_upgrade,
};

const PEER_TAG: &str = "circuit-peer";
const MAX_SLOT_ID_BYTES: usize = 128;
const MAX_LANE_TOKEN_BYTES: usize = 128;
const MAX_OUTBOUND_QUEUE_FRAMES: usize = 128;
const MAX_OUTBOUND_QUEUE_BYTES: u32 = 2 * 1024 * 1024;
const ACTIVE_CIRCUIT_STORAGE_KEY: &str = "active-circuit-v1";
const RELEASE_RETRY_MS: u64 = 5_000;
const CLOSE_POLICY: u16 = 1008;
const CLOSE_UNSUPPORTED: u16 = 1003;
const CLOSE_OVERLOADED: u16 = 1013;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OutboundQueueError {
    EmptyFrame,
    FrameLimit,
    ByteLimit,
}

fn outbound_queue_close(error: OutboundQueueError) -> (u16, &'static str, &'static str) {
    match error {
        OutboundQueueError::EmptyFrame => (
            CLOSE_UNSUPPORTED,
            "circuit frames must not be empty",
            "circuit peer sent an empty frame",
        ),
        OutboundQueueError::FrameLimit | OutboundQueueError::ByteLimit => (
            CLOSE_OVERLOADED,
            "circuit peer is backpressured",
            "circuit outbound queue limit exceeded",
        ),
    }
}

fn reserve_outbound_frame(
    queue: &mut OutboundQueue,
    buffered_bytes: u32,
    frame_bytes: usize,
) -> std::result::Result<(), OutboundQueueError> {
    // Worker WebSocket sends are synchronous but not backpressured. Keep the
    // runtime's byte count and our per-frame ledger in the socket attachment
    // so the limits survive Durable Object hibernation.
    if frame_bytes == 0 {
        return Err(OutboundQueueError::EmptyFrame);
    }

    if buffered_bytes == 0 {
        queue.untracked_bytes = 0;
        queue.frame_bytes.clear();
    } else if buffered_bytes < queue.observed_bytes {
        let mut drained = queue.observed_bytes - buffered_bytes;
        let untracked_drained = drained.min(queue.untracked_bytes);
        queue.untracked_bytes -= untracked_drained;
        drained -= untracked_drained;
        while drained > 0 {
            let Some(front) = queue.frame_bytes.front_mut() else {
                break;
            };
            let frame_drained = drained.min(*front);
            *front -= frame_drained;
            drained -= frame_drained;
            if *front == 0 {
                queue.frame_bytes.pop_front();
            }
        }
    } else if buffered_bytes > queue.observed_bytes {
        queue.untracked_bytes =
            queue.untracked_bytes.saturating_add(buffered_bytes - queue.observed_bytes);
    }
    queue.observed_bytes = buffered_bytes;

    if queue.frame_bytes.len() >= MAX_OUTBOUND_QUEUE_FRAMES {
        return Err(OutboundQueueError::FrameLimit);
    }
    let frame_bytes = u32::try_from(frame_bytes).map_err(|_| OutboundQueueError::ByteLimit)?;
    let projected = buffered_bytes
        .checked_add(frame_bytes)
        .filter(|bytes| *bytes <= MAX_OUTBOUND_QUEUE_BYTES)
        .ok_or(OutboundQueueError::ByteLimit)?;
    queue.frame_bytes.push_back(frame_bytes);
    queue.observed_bytes = projected;
    Ok(())
}

fn persist_peer_before_forward<E>(
    now_ms: u64,
    peer: &mut CircuitAttachment,
    persist_peer: impl FnOnce(&CircuitAttachment) -> std::result::Result<(), E>,
    forward: impl FnOnce() -> std::result::Result<(), E>,
) -> std::result::Result<(), E> {
    // The latest deadline across the ready pair is the shared circuit idle
    // deadline. Persisting only the destination attachment also durably saves
    // its outbound FIFO ledger, while avoiding a second attachment write on
    // every interactive frame.
    peer.idle_deadline_ms = now_ms.saturating_add(CIRCUIT_IDLE_TIMEOUT_MS);
    persist_peer(peer)?;
    forward()
}

fn has_live_ready_pair(
    sockets: impl IntoIterator<Item = (u16, CircuitPhase, u64)>,
    now_ms: u64,
) -> bool {
    let (open_ready, latest_deadline) = sockets.into_iter().fold(
        (0_usize, 0_u64),
        |(count, latest), (ready_state, phase, deadline)| {
            if phase == CircuitPhase::Ready && websocket_is_open(ready_state) {
                (count + 1, latest.max(deadline))
            } else {
                (count, latest)
            }
        },
    );
    open_ready >= 2 && latest_deadline > now_ms
}

#[durable_object]
pub struct RelayCircuit {
    state: State,
    env: Env,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ActiveCircuit {
    slot: String,
    circuit: CircuitId,
    releasing: bool,
    renew_at_ms: u64,
    lease_expires_ms: u64,
}

impl RelayCircuit {
    fn now_ms(&self) -> u64 {
        Date::now().as_millis()
    }

    fn ticket_key(&self) -> Result<String> {
        Ok(self.env.secret("CMUX_RELAY_TICKET_KEY")?.to_string())
    }

    fn ticket_issuer(&self) -> String {
        self.env
            .var("CMUX_RELAY_TICKET_ISSUER")
            .map(|value| value.to_string())
            .unwrap_or_else(|_| DEFAULT_TICKET_ISSUER.into())
    }

    fn attachment(socket: &WebSocket) -> Result<CircuitAttachment> {
        socket.deserialize_attachment()?.ok_or_else(|| {
            worker::Error::RustError("relay circuit socket has no attachment".into())
        })
    }

    fn fail(socket: &WebSocket, code: &str, message: &str, close_code: u16) {
        let _ = send_control(
            socket,
            &RelayControl::Error { code: code.into(), message: message.into(), retryable: false },
        );
        close(socket, close_code, message);
    }

    async fn ensure_cleanup_alarm(&self, deadline_ms: u64) -> Result<()> {
        let storage = self.state.storage();
        let deadline = i64::try_from(deadline_ms).unwrap_or(i64::MAX);
        if storage.get_alarm().await?.is_some_and(|current| current <= deadline) {
            return Ok(());
        }
        let delay_ms = deadline_ms.saturating_sub(self.now_ms()).max(1);
        storage.set_alarm(Duration::from_millis(delay_ms)).await
    }

    async fn schedule_next_cleanup(&self, now_ms: u64) -> Result<()> {
        let socket_deadline = self
            .state
            .get_websockets()
            .into_iter()
            .filter_map(|socket| Self::attachment(&socket).ok())
            .map(|attachment| attachment.idle_deadline_ms)
            .filter(|deadline| *deadline > now_ms)
            .min();
        let active_deadline =
            self.state.storage().get::<ActiveCircuit>(ACTIVE_CIRCUIT_STORAGE_KEY).await?.map(
                |active| {
                    if active.releasing {
                        now_ms.saturating_add(RELEASE_RETRY_MS)
                    } else {
                        active.renew_at_ms
                    }
                },
            );
        if let Some(deadline) = socket_deadline.into_iter().chain(active_deadline).min() {
            self.ensure_cleanup_alarm(deadline).await?;
        }
        Ok(())
    }

    fn matching_peer(
        &self,
        socket: &WebSocket,
        current: &CircuitAttachment,
        relay: &RelaySocketAttachment,
        require_ready: bool,
    ) -> Option<(WebSocket, CircuitAttachment)> {
        let now_ms = self.now_ms();
        self.state
            .get_websockets_with_tag(PEER_TAG)
            .into_iter()
            .filter(|candidate| candidate != socket)
            .find_map(|candidate| {
                let attachment = Self::attachment(&candidate).ok()?;
                let shares_ready_deadline = current.phase == CircuitPhase::Ready
                    && attachment.phase == CircuitPhase::Ready;
                let effective_deadline = if shares_ready_deadline {
                    current.idle_deadline_ms.max(attachment.idle_deadline_ms)
                } else {
                    attachment.idle_deadline_ms
                };
                if !websocket_counts_toward_capacity(
                    candidate.as_ref().ready_state(),
                    effective_deadline,
                    now_ms,
                ) || (require_ready
                    && (!websocket_is_open(socket.as_ref().ready_state())
                        || current.phase != CircuitPhase::Ready))
                {
                    return None;
                }
                let candidate_relay = attachment.relay.as_ref()?;
                let phase_matches = if require_ready {
                    attachment.phase == CircuitPhase::Ready
                } else {
                    attachment.phase != CircuitPhase::Pending
                };
                (phase_matches
                    && candidate_relay.role != relay.role
                    && candidate_relay.slot == relay.slot
                    && candidate_relay.circuit == relay.circuit
                    && candidate_relay.lane == relay.lane
                    && attachment.generation == current.generation)
                    .then_some((candidate, attachment))
            })
    }

    fn joined_socket_for_role(&self, socket: &WebSocket, role: RelayRole) -> Option<WebSocket> {
        let now_ms = self.now_ms();
        let sockets = self
            .state
            .get_websockets_with_tag(PEER_TAG)
            .into_iter()
            .filter(|candidate| candidate != socket)
            .filter_map(|candidate| {
                Self::attachment(&candidate).ok().map(|attachment| (candidate, attachment))
            })
            .collect::<Vec<_>>();
        let latest_ready_deadline = sockets
            .iter()
            .filter(|(candidate, attachment)| {
                attachment.phase == CircuitPhase::Ready
                    && websocket_is_open(candidate.as_ref().ready_state())
            })
            .map(|(_, attachment)| attachment.idle_deadline_ms)
            .max()
            .unwrap_or(0);
        sockets.into_iter().find_map(|(candidate, attachment)| {
            let effective_deadline = if attachment.phase == CircuitPhase::Ready {
                attachment.idle_deadline_ms.max(latest_ready_deadline)
            } else {
                attachment.idle_deadline_ms
            };
            (websocket_counts_toward_capacity(
                candidate.as_ref().ready_state(),
                effective_deadline,
                now_ms,
            ) && attachment.phase != CircuitPhase::Pending
                && attachment.relay.as_ref().is_some_and(|relay| relay.role == role))
                .then_some(candidate)
        })
    }

    async fn notify_slot(&self, slot: &str, circuit: &CircuitId, event: &str) -> Result<()> {
        let namespace = self.env.durable_object("RELAY_SLOTS")?;
        let stub = namespace.id_from_name(slot)?.get_stub()?;
        let request = Request::new(
            &format!("https://relay.internal/internal/v1/circuits/{}/{event}", circuit.0),
            Method::Post,
        )?;
        let response = stub.fetch_with_request(request).await?;
        if response.status_code() != 200 {
            return Err(worker::Error::RustError("slot rejected circuit lease update".into()));
        }
        Ok(())
    }

    async fn activate_slot_circuit(&self, active: &ActiveCircuit) -> Result<()> {
        self.state.storage().put(ACTIVE_CIRCUIT_STORAGE_KEY, active).await?;
        if let Err(error) = self.notify_slot(&active.slot, &active.circuit, "active").await {
            let mut releasing = active.clone();
            releasing.releasing = true;
            let _ = self.state.storage().put(ACTIVE_CIRCUIT_STORAGE_KEY, releasing).await;
            return Err(error);
        }
        Ok(())
    }

    async fn try_release_slot_circuit(&self) -> Result<()> {
        let Some(active): Option<ActiveCircuit> =
            self.state.storage().get(ACTIVE_CIRCUIT_STORAGE_KEY).await?
        else {
            return Ok(());
        };
        self.notify_slot(&active.slot, &active.circuit, "release").await?;
        self.state.storage().delete(ACTIVE_CIRCUIT_STORAGE_KEY).await?;
        Ok(())
    }

    async fn renew_slot_circuit(&self, mut active: ActiveCircuit) -> Result<()> {
        let now_ms = self.now_ms();
        self.notify_slot(&active.slot, &active.circuit, "renew").await?;
        active.renew_at_ms = now_ms.saturating_add(ACTIVE_CIRCUIT_RENEW_MS);
        active.lease_expires_ms = now_ms.saturating_add(ACTIVE_CIRCUIT_LEASE_MS);
        self.state.storage().put(ACTIVE_CIRCUIT_STORAGE_KEY, active).await
    }

    async fn release_slot_circuit(&self) {
        if let Err(error) = self.try_release_slot_circuit().await {
            worker::console_error!("RelayCircuit release notification failed: {error}");
            if let Ok(Some(mut active)) =
                self.state.storage().get::<ActiveCircuit>(ACTIVE_CIRCUIT_STORAGE_KEY).await
            {
                active.releasing = true;
                let _ = self.state.storage().put(ACTIVE_CIRCUIT_STORAGE_KEY, active).await;
            }
            let _ = self.ensure_cleanup_alarm(self.now_ms().saturating_add(RELEASE_RETRY_MS)).await;
        }
    }

    async fn handle_join(
        &self,
        socket: &WebSocket,
        mut attachment: CircuitAttachment,
        request: JoinRequest,
    ) -> Result<()> {
        let now_ms = self.now_ms();
        if request.protocol != REMOTE_PROTOCOL_VERSION
            || attachment.phase != CircuitPhase::Pending
            || attachment.circuit != request.circuit
            || attachment.idle_deadline_ms <= now_ms
            || !valid_opaque_identifier(&request.slot, MAX_SLOT_ID_BYTES)
            || !valid_opaque_identifier(&request.lane.0, MAX_LANE_TOKEN_BYTES)
        {
            Self::fail(socket, "invalid-join", "circuit join is invalid", CLOSE_POLICY);
            return Ok(());
        }

        if self.joined_socket_for_role(socket, request.role).is_some() {
            Self::fail(
                socket,
                "duplicate-role",
                "this circuit role is already connected",
                CLOSE_POLICY,
            );
            return Ok(());
        }

        let key = self.ticket_key()?;
        let issuer = self.ticket_issuer();
        let claims = match verify_ticket(
            &request.ticket,
            key.as_bytes(),
            &issuer,
            TicketExpectation {
                permission: RelayPermission::Join,
                role: request.role,
                slot: &request.slot,
                circuit: Some(&request.circuit),
                lane: Some(&request.lane),
                generation: Some(request.generation),
                now: now_ms / 1_000,
            },
        ) {
            Ok(claims) => claims,
            Err(_) => {
                Self::fail(socket, "unauthorized", "circuit ticket was rejected", CLOSE_POLICY);
                return Ok(());
            }
        };

        let relay = RelaySocketAttachment::circuit(
            request.role,
            request.slot.clone(),
            request.circuit.clone(),
            request.lane.clone(),
        );
        if self
            .state
            .get_websockets_with_tag(PEER_TAG)
            .into_iter()
            .filter(|candidate| candidate != socket)
            .filter_map(|candidate| Self::attachment(&candidate).ok())
            .filter(|candidate| candidate.phase != CircuitPhase::Pending)
            .filter_map(|candidate| {
                let generation = candidate.generation;
                candidate.relay.map(|relay| (relay, generation))
            })
            .any(|(candidate, generation)| {
                candidate.slot != relay.slot
                    || candidate.circuit != relay.circuit
                    || candidate.lane != relay.lane
                    || generation != request.generation
            })
        {
            Self::fail(
                socket,
                "circuit-mismatch",
                "circuit peer metadata does not match",
                CLOSE_POLICY,
            );
            return Ok(());
        }

        attachment.relay = Some(relay.clone());
        attachment.phase = CircuitPhase::Joined;
        attachment.generation = request.generation;
        attachment.expires_at = claims.expires_at_unix;
        attachment.idle_deadline_ms = claims.expires_at_unix.saturating_mul(1_000);
        socket.serialize_attachment(&attachment)?;
        self.ensure_cleanup_alarm(attachment.idle_deadline_ms).await?;

        if let Some((peer, mut peer_attachment)) =
            self.matching_peer(socket, &attachment, &relay, false)
        {
            let active = ActiveCircuit {
                slot: request.slot.clone(),
                circuit: request.circuit.clone(),
                releasing: false,
                renew_at_ms: self.now_ms().saturating_add(ACTIVE_CIRCUIT_RENEW_MS),
                lease_expires_ms: self.now_ms().saturating_add(ACTIVE_CIRCUIT_LEASE_MS),
            };
            if let Err(error) = self.activate_slot_circuit(&active).await {
                close(socket, CLOSE_POLICY, "circuit quota activation failed");
                close(&peer, CLOSE_POLICY, "circuit quota activation failed");
                worker::console_error!("RelayCircuit activation failed: {error}");
                self.release_slot_circuit().await;
                return Ok(());
            }

            let idle_deadline_ms = self.now_ms().saturating_add(CIRCUIT_IDLE_TIMEOUT_MS);
            attachment.phase = CircuitPhase::Ready;
            attachment.idle_deadline_ms = idle_deadline_ms;
            peer_attachment.phase = CircuitPhase::Ready;
            peer_attachment.idle_deadline_ms = idle_deadline_ms;
            if socket.serialize_attachment(&attachment).is_err()
                || peer.serialize_attachment(&peer_attachment).is_err()
                || self.ensure_cleanup_alarm(idle_deadline_ms).await.is_err()
            {
                close(socket, 1011, "circuit setup failed");
                close(&peer, 1011, "circuit setup failed");
                self.release_slot_circuit().await;
                return Ok(());
            }

            let ready = RelayControl::Ready {
                circuit: request.circuit.clone(),
                lane: request.lane,
                generation: request.generation,
            };
            if send_control(socket, &ready).is_err() || send_control(&peer, &ready).is_err() {
                close(socket, 1011, "circuit setup failed");
                close(&peer, 1011, "circuit setup failed");
                self.release_slot_circuit().await;
                return Ok(());
            }
        }
        Ok(())
    }

    async fn handle_pending_message(
        &self,
        socket: &WebSocket,
        attachment: CircuitAttachment,
        message: WebSocketIncomingMessage,
    ) -> Result<()> {
        let control = match decode_control(message) {
            Ok(control) => control,
            Err(message) => {
                Self::fail(socket, "invalid-control", message, CLOSE_UNSUPPORTED);
                return Ok(());
            }
        };
        match control {
            RelayControl::Join { protocol, slot, circuit, lane, generation, ticket, role } => {
                self.handle_join(
                    socket,
                    attachment,
                    JoinRequest { protocol, slot, circuit, lane, generation, ticket, role },
                )
                .await
            }
            _ => {
                Self::fail(
                    socket,
                    "expected-join",
                    "first circuit message must be join",
                    CLOSE_POLICY,
                );
                Ok(())
            }
        }
    }

    fn forward_binary(
        &self,
        socket: &WebSocket,
        attachment: CircuitAttachment,
        bytes: Vec<u8>,
    ) -> Result<()> {
        if bytes.len() > MAX_RELAY_BATCH_BYTES {
            close(socket, 1009, "relay frame is too large");
            return Ok(());
        }
        let Some(relay) = attachment.relay.clone() else {
            close(socket, 1011, "circuit attachment is incomplete");
            return Ok(());
        };
        let Some((peer, mut peer_attachment)) =
            self.matching_peer(socket, &attachment, &relay, true)
        else {
            close(socket, 1011, "circuit peer disconnected");
            return Ok(());
        };

        if let Err(error) = reserve_outbound_frame(
            &mut peer_attachment.outbound,
            peer.as_ref().buffered_amount(),
            bytes.len(),
        ) {
            let (close_code, sender_reason, peer_reason) = outbound_queue_close(error);
            close(socket, close_code, sender_reason);
            close(&peer, close_code, peer_reason);
            return Ok(());
        }

        let result = persist_peer_before_forward(
            self.now_ms(),
            &mut peer_attachment,
            |attachment| peer.serialize_attachment(attachment),
            || peer.send_with_bytes(bytes),
        );
        if let Err(error) = result {
            close(socket, 1011, "circuit peer unavailable");
            close(&peer, 1011, "circuit forwarding failed");
            return Err(error);
        }
        Ok(())
    }

    async fn handle_message(
        &self,
        socket: &WebSocket,
        message: WebSocketIncomingMessage,
    ) -> Result<()> {
        let attachment = Self::attachment(socket)?;
        match attachment.phase {
            CircuitPhase::Pending => self.handle_pending_message(socket, attachment, message).await,
            CircuitPhase::Joined => {
                Self::fail(socket, "not-ready", "circuit peer has not joined", CLOSE_POLICY);
                Ok(())
            }
            CircuitPhase::Ready => match message {
                WebSocketIncomingMessage::Binary(bytes) => {
                    self.forward_binary(socket, attachment, bytes)
                }
                WebSocketIncomingMessage::String(_) => {
                    close(socket, CLOSE_UNSUPPORTED, "ready circuits accept binary frames only");
                    Ok(())
                }
            },
        }
    }

    fn close_peer(&self, socket: &WebSocket, reason: &str) {
        let Ok(attachment) = Self::attachment(socket) else {
            return;
        };
        let Some(relay) = attachment.relay.as_ref() else {
            return;
        };
        if let Some((peer, _)) = self.matching_peer(socket, &attachment, relay, false) {
            close(&peer, 1011, reason);
        }
    }

    fn live_socket_counts(&self, now_ms: u64) -> (usize, usize) {
        let sockets = self
            .state
            .get_websockets()
            .into_iter()
            .filter_map(|socket| {
                Self::attachment(&socket).ok().map(|attachment| (socket, attachment))
            })
            .collect::<Vec<_>>();
        let latest_ready_deadline = sockets
            .iter()
            .filter(|(socket, attachment)| {
                attachment.phase == CircuitPhase::Ready
                    && websocket_is_open(socket.as_ref().ready_state())
            })
            .map(|(_, attachment)| attachment.idle_deadline_ms)
            .max()
            .unwrap_or(0);
        sockets.into_iter().fold((0, 0), |(total, pending), (socket, attachment)| {
            let effective_deadline = if attachment.phase == CircuitPhase::Ready {
                attachment.idle_deadline_ms.max(latest_ready_deadline)
            } else {
                attachment.idle_deadline_ms
            };
            if websocket_counts_toward_capacity(
                socket.as_ref().ready_state(),
                effective_deadline,
                now_ms,
            ) {
                (total + 1, pending + usize::from(attachment.phase == CircuitPhase::Pending))
            } else {
                (total, pending)
            }
        })
    }
}

impl DurableObject for RelayCircuit {
    fn new(state: State, env: Env) -> Self {
        Self { state, env }
    }

    async fn fetch(&self, request: Request) -> Result<Response> {
        if !websocket_upgrade(&request)? {
            return upgrade_required();
        }
        let now_ms = self.now_ms();
        let (total, pending) = self.live_socket_counts(now_ms);
        if !admit_circuit_socket(total, pending) {
            return Response::error("Circuit connection limit reached", 429);
        }

        let circuit = self.state.id().to_string();
        let request_circuit =
            request.path().rsplit('/').find(|part| !part.is_empty()).unwrap_or_default().to_owned();
        if circuit != request_circuit {
            return Response::error("Circuit route mismatch", 400);
        }
        let idle_deadline_ms = now_ms.saturating_add(CIRCUIT_HANDSHAKE_TIMEOUT_MS);
        let pair = WebSocketPair::new()?;
        pair.server.serialize_attachment(CircuitAttachment::pending(
            CircuitId(circuit),
            idle_deadline_ms,
        ))?;
        self.state.accept_websocket_with_tags(&pair.server, &[PEER_TAG]);
        if let Err(error) = self.ensure_cleanup_alarm(idle_deadline_ms).await {
            close(&pair.server, 1011, "cleanup scheduling failed");
            return Err(error);
        }
        Response::from_websocket(pair.client)
    }

    async fn alarm(&self) -> Result<Response> {
        let now_ms = self.now_ms();
        let sockets = self.state.get_websockets();
        let has_ready = sockets.iter().any(|socket| {
            Self::attachment(socket).is_ok_and(|attachment| attachment.phase == CircuitPhase::Ready)
        });
        let has_live_ready = has_live_ready_pair(
            sockets.iter().filter_map(|socket| {
                Self::attachment(socket).ok().map(|attachment| {
                    (socket.as_ref().ready_state(), attachment.phase, attachment.idle_deadline_ms)
                })
            }),
            now_ms,
        );
        let ready_expired = has_ready && !has_live_ready;
        for socket in &sockets {
            let expired_non_ready = Self::attachment(socket).is_ok_and(|attachment| {
                attachment.phase != CircuitPhase::Ready && attachment.idle_deadline_ms <= now_ms
            });
            if expired_non_ready || ready_expired {
                close(socket, CLOSE_POLICY, "relay circuit expired");
            }
        }
        let active = self.state.storage().get::<ActiveCircuit>(ACTIVE_CIRCUIT_STORAGE_KEY).await?;
        if let Some(mut active) = active {
            if ready_expired
                || !has_live_ready
                || active.releasing
                || active.lease_expires_ms <= now_ms
            {
                if active.releasing || active.lease_expires_ms <= now_ms {
                    for socket in &sockets {
                        close(socket, 1011, "circuit lease expired");
                    }
                }
                self.release_slot_circuit().await;
            } else if active.renew_at_ms <= now_ms
                && let Err(error) = self.renew_slot_circuit(active.clone()).await
            {
                worker::console_error!("RelayCircuit lease renewal failed: {error}");
                active.releasing = true;
                let _ = self.state.storage().put(ACTIVE_CIRCUIT_STORAGE_KEY, active).await;
                for socket in &sockets {
                    close(socket, 1011, "circuit lease renewal failed");
                }
                self.release_slot_circuit().await;
            }
        }
        self.schedule_next_cleanup(now_ms).await?;
        Response::ok("cleaned")
    }

    async fn websocket_message(
        &self,
        socket: WebSocket,
        message: WebSocketIncomingMessage,
    ) -> Result<()> {
        if let Err(error) = self.handle_message(&socket, message).await {
            Self::fail(&socket, "internal-error", "relay could not process the message", 1011);
            worker::console_error!("RelayCircuit message error: {error}");
        }
        Ok(())
    }

    async fn websocket_close(
        &self,
        socket: WebSocket,
        _code: usize,
        _reason: String,
        _was_clean: bool,
    ) -> Result<()> {
        let was_ready = Self::attachment(&socket)
            .is_ok_and(|attachment| attachment.phase == CircuitPhase::Ready);
        self.close_peer(&socket, "circuit peer disconnected");
        if was_ready {
            self.release_slot_circuit().await;
        }
        Ok(())
    }

    async fn websocket_error(&self, socket: WebSocket, error: worker::Error) -> Result<()> {
        worker::console_error!("RelayCircuit WebSocket error: {error}");
        let was_ready = Self::attachment(&socket)
            .is_ok_and(|attachment| attachment.phase == CircuitPhase::Ready);
        self.close_peer(&socket, "circuit peer failed");
        if was_ready {
            self.release_slot_circuit().await;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::cell::{Cell, RefCell};

    use super::*;

    #[test]
    fn active_release_record_survives_hibernation_and_retry() {
        let active = ActiveCircuit {
            slot: "slot".into(),
            circuit: CircuitId("ab".repeat(32)),
            releasing: true,
            renew_at_ms: 500,
            lease_expires_ms: 1_000,
        };
        let encoded = serde_json::to_vec(&active).unwrap();
        let decoded: ActiveCircuit = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(decoded.slot, active.slot);
        assert_eq!(decoded.circuit, active.circuit);
        assert!(decoded.releasing);
        assert_eq!(decoded.renew_at_ms, 500);
        assert_eq!(decoded.lease_expires_ms, 1_000);
    }

    #[test]
    fn forwarded_activity_persists_one_peer_deadline_before_payload() {
        let mut peer = CircuitAttachment::pending(CircuitId("peer".into()), 2);
        let operations = RefCell::new(Vec::new());

        persist_peer_before_forward(
            10_000,
            &mut peer,
            |_| {
                operations.borrow_mut().push("peer");
                Ok::<_, &'static str>(())
            },
            || {
                operations.borrow_mut().push("forward");
                Ok(())
            },
        )
        .unwrap();

        let expected = 10_000 + CIRCUIT_IDLE_TIMEOUT_MS;
        assert_eq!(peer.idle_deadline_ms, expected);
        assert_eq!(&*operations.borrow(), &["peer", "forward"]);
    }

    #[test]
    fn peer_attachment_failure_prevents_payload() {
        let mut peer = CircuitAttachment::pending(CircuitId("peer".into()), 2);
        let forwarded = Cell::new(false);

        let result = persist_peer_before_forward(
            10_000,
            &mut peer,
            |_| Err("peer serialization failed"),
            || {
                forwarded.set(true);
                Ok(())
            },
        );

        assert_eq!(result, Err("peer serialization failed"));
        assert!(!forwarded.get());
    }

    #[test]
    fn outbound_queue_reconciles_runtime_drain_before_reserving() {
        let mut queue = OutboundQueue::default();
        reserve_outbound_frame(&mut queue, 20, 100).unwrap();
        assert_eq!(queue.untracked_bytes, 20);
        assert_eq!(queue.frame_bytes.iter().copied().collect::<Vec<_>>(), vec![100]);
        assert_eq!(queue.observed_bytes, 120);

        reserve_outbound_frame(&mut queue, 50, 10).unwrap();
        assert_eq!(queue.untracked_bytes, 0);
        assert_eq!(queue.frame_bytes.iter().copied().collect::<Vec<_>>(), vec![50, 10]);
        assert_eq!(queue.observed_bytes, 60);

        reserve_outbound_frame(&mut queue, 0, 1).unwrap();
        assert_eq!(queue.frame_bytes.iter().copied().collect::<Vec<_>>(), vec![1]);
        assert_eq!(queue.observed_bytes, 1);
    }

    #[test]
    fn outbound_queue_rejects_slow_consumers_by_frame_and_byte_budget() {
        let mut frames = OutboundQueue::default();
        for _ in 0..MAX_OUTBOUND_QUEUE_FRAMES {
            let buffered = frames.observed_bytes;
            reserve_outbound_frame(&mut frames, buffered, 1).unwrap();
        }
        let buffered = frames.observed_bytes;
        assert_eq!(
            reserve_outbound_frame(&mut frames, buffered, 1),
            Err(OutboundQueueError::FrameLimit)
        );

        let mut bytes = OutboundQueue::default();
        reserve_outbound_frame(&mut bytes, 0, MAX_RELAY_BATCH_BYTES).unwrap();
        reserve_outbound_frame(&mut bytes, MAX_RELAY_BATCH_BYTES as u32, MAX_RELAY_BATCH_BYTES)
            .unwrap();
        assert_eq!(
            reserve_outbound_frame(&mut bytes, MAX_OUTBOUND_QUEUE_BYTES, MAX_RELAY_BATCH_BYTES,),
            Err(OutboundQueueError::ByteLimit)
        );
        assert_eq!(
            reserve_outbound_frame(&mut OutboundQueue::default(), 0, 0),
            Err(OutboundQueueError::EmptyFrame)
        );
    }

    #[test]
    fn outbound_queue_close_reasons_match_the_failure() {
        assert_eq!(
            outbound_queue_close(OutboundQueueError::EmptyFrame),
            (
                CLOSE_UNSUPPORTED,
                "circuit frames must not be empty",
                "circuit peer sent an empty frame",
            )
        );
        for error in [OutboundQueueError::FrameLimit, OutboundQueueError::ByteLimit] {
            assert_eq!(
                outbound_queue_close(error),
                (
                    CLOSE_OVERLOADED,
                    "circuit peer is backpressured",
                    "circuit outbound queue limit exceeded",
                )
            );
        }
    }

    #[test]
    fn maximum_outbound_queue_fits_the_hibernation_attachment_limit() {
        let mut attachment = CircuitAttachment::pending(CircuitId("ab".repeat(32)), 1_000);
        attachment.outbound.observed_bytes = MAX_OUTBOUND_QUEUE_BYTES;
        attachment.outbound.frame_bytes =
            std::iter::repeat_n(MAX_RELAY_BATCH_BYTES as u32, MAX_OUTBOUND_QUEUE_FRAMES).collect();

        let encoded = serde_json::to_vec(&attachment).unwrap();
        assert!(encoded.len() <= 2_048, "attachment used {} bytes", encoded.len());
    }

    #[test]
    fn ready_pair_uses_the_latest_shared_activity_deadline() {
        let ready = |state| (state, CircuitPhase::Ready, 200);
        assert!(has_live_ready_pair([ready(1), ready(1)], 100));
        assert!(!has_live_ready_pair([ready(1)], 100));
        assert!(!has_live_ready_pair([ready(1), ready(2)], 100));
        assert!(has_live_ready_pair(
            [(1, CircuitPhase::Ready, 200), (1, CircuitPhase::Ready, 100)],
            100,
        ));
        assert!(!has_live_ready_pair(
            [(1, CircuitPhase::Ready, 100), (1, CircuitPhase::Ready, 100)],
            100,
        ));
        assert!(!has_live_ready_pair(
            [(1, CircuitPhase::Ready, 200), (1, CircuitPhase::Joined, 200)],
            100,
        ));
    }
}
