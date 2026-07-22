use std::time::Duration;

use cmux_remote_protocol::{
    CircuitId, LaneToken, REMOTE_PROTOCOL_VERSION, RelayControl, RelayPermission, RelayRole,
    RelaySocketAttachment, RelayTicketClaims,
};
use worker::{
    Date, DurableObject, Env, Method, Request, Response, Result, State, WebSocket,
    WebSocketIncomingMessage, WebSocketPair, durable_object,
};

use crate::abuse::{
    CIRCUITS_STORAGE_KEY, CLIENT_CONTROL_IDLE_TIMEOUT_MS, CircuitLedger,
    DAEMON_CONTROL_IDLE_TIMEOUT_MS, MAX_SLOT_SOCKETS, SLOT_HANDSHAKE_TIMEOUT_MS, SlotEndpoint,
    SlotSocketCounts, admit_slot_socket,
};
use crate::attachment::{SlotAttachment, SlotPhase};
use crate::auth::{DEFAULT_TICKET_ISSUER, TicketExpectation, issue_ticket, verify_ticket};
use crate::wire::{
    close, decode_control, send_control, upgrade_required, valid_circuit_id,
    valid_opaque_identifier, websocket_upgrade,
};

const CONTROL_TAG: &str = "daemon-control";
const CONNECT_TAG: &str = "client-allocation";
const MAX_SLOT_ID_BYTES: usize = 128;
const MAX_LANE_TOKEN_BYTES: usize = 128;
const JOIN_TICKET_TTL_SECONDS: u64 = 30;
const REGISTRATION_HEARTBEAT_SECONDS: u64 = 30;
const CLOSE_POLICY: u16 = 1008;
const CLOSE_UNSUPPORTED: u16 = 1003;

#[durable_object]
pub struct RelaySlot {
    state: State,
    env: Env,
}

struct ConnectRequest {
    protocol: u8,
    slot: String,
    ticket: String,
    lane: LaneToken,
    generation: u64,
}

impl RelaySlot {
    fn now_ms(&self) -> u64 {
        Date::now().as_millis()
    }

    fn now(&self) -> u64 {
        self.now_ms() / 1_000
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

    fn attachment(socket: &WebSocket) -> Result<SlotAttachment> {
        socket
            .deserialize_attachment()?
            .ok_or_else(|| worker::Error::RustError("relay slot socket has no attachment".into()))
    }

    fn fail(socket: &WebSocket, code: &str, message: &str, close_code: u16) {
        let _ = send_control(
            socket,
            &RelayControl::Error { code: code.into(), message: message.into(), retryable: false },
        );
        close(socket, close_code, message);
    }

    fn capacity(socket: &WebSocket, code: &str, message: &str) {
        let _ = send_control(
            socket,
            &RelayControl::Error { code: code.into(), message: message.into(), retryable: true },
        );
    }

    fn socket_counts(&self, now_ms: u64) -> SlotSocketCounts {
        let mut counts = SlotSocketCounts::default();
        for socket in self.state.get_websockets() {
            let Ok(attachment) = Self::attachment(&socket) else {
                continue;
            };
            if attachment.idle_deadline_ms <= now_ms {
                continue;
            }
            counts.total += 1;
            if attachment.phase == SlotPhase::Pending {
                counts.pending += 1;
            }
            if attachment.relay.role == RelayRole::Client {
                counts.client += 1;
            } else if attachment.phase == SlotPhase::Pending {
                counts.daemon_pending += 1;
            }
        }
        counts
    }

    fn registered_daemon(
        &self,
        slot: &str,
        now: u64,
        now_ms: u64,
    ) -> Option<(WebSocket, SlotAttachment)> {
        self.state
            .get_websockets_with_tag(CONTROL_TAG)
            .into_iter()
            .find(|socket| {
                Self::attachment(socket).is_ok_and(|attachment| {
                    attachment.phase == SlotPhase::Registered
                        && attachment.relay.slot == slot
                        && attachment.expires_at > now
                        && attachment.idle_deadline_ms > now_ms
                })
            })
            .and_then(|socket| {
                Self::attachment(&socket).ok().map(|attachment| (socket, attachment))
            })
    }

    async fn circuits(&self) -> Result<CircuitLedger> {
        Ok(self.state.storage().get(CIRCUITS_STORAGE_KEY).await?.unwrap_or_default())
    }

    async fn write_circuits(&self, ledger: &CircuitLedger) -> Result<()> {
        if !ledger.is_empty() {
            self.state.storage().put(CIRCUITS_STORAGE_KEY, ledger).await
        } else {
            self.state.storage().delete(CIRCUITS_STORAGE_KEY).await.map(|_| ())
        }
    }

    async fn reserve_pending_circuit(
        &self,
        circuit: &CircuitId,
        deadline_ms: u64,
        now_ms: u64,
    ) -> Result<bool> {
        let mut ledger = self.circuits().await?;
        if !ledger.reserve(circuit.0.clone(), deadline_ms, now_ms) {
            return Ok(false);
        }
        self.write_circuits(&ledger).await?;
        self.ensure_cleanup_alarm(deadline_ms).await?;
        Ok(true)
    }

    async fn activate_circuit(&self, circuit: &str, now_ms: u64) -> Result<bool> {
        let mut ledger = self.circuits().await?;
        if !ledger.activate(circuit, now_ms) {
            return Ok(false);
        }
        let deadline = ledger.next_deadline_ms();
        self.write_circuits(&ledger).await?;
        if let Some(deadline) = deadline {
            self.ensure_cleanup_alarm(deadline).await?;
        }
        Ok(true)
    }

    async fn renew_circuit(&self, circuit: &str, now_ms: u64) -> Result<bool> {
        let mut ledger = self.circuits().await?;
        if !ledger.renew(circuit, now_ms) {
            return Ok(false);
        }
        let deadline = ledger.next_deadline_ms();
        self.write_circuits(&ledger).await?;
        if let Some(deadline) = deadline {
            self.ensure_cleanup_alarm(deadline).await?;
        }
        Ok(true)
    }

    async fn release_circuit(&self, circuit: &str) -> Result<()> {
        let mut ledger = self.circuits().await?;
        if ledger.release(circuit) {
            self.write_circuits(&ledger).await?;
        }
        Ok(())
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
        let mut ledger = self.circuits().await?;
        ledger.prune(now_ms);
        let ledger_deadline = ledger.next_deadline_ms();
        self.write_circuits(&ledger).await?;
        if let Some(deadline) = socket_deadline.into_iter().chain(ledger_deadline).min() {
            self.ensure_cleanup_alarm(deadline).await?;
        }
        Ok(())
    }

    async fn handle_register(
        &self,
        socket: &WebSocket,
        mut attachment: SlotAttachment,
        protocol: u8,
        slot: String,
        ticket: String,
    ) -> Result<()> {
        if protocol != REMOTE_PROTOCOL_VERSION
            || attachment.relay.role != RelayRole::Daemon
            || attachment.relay.slot != slot
        {
            Self::fail(
                socket,
                "invalid-register",
                "registration does not match this slot",
                CLOSE_POLICY,
            );
            return Ok(());
        }

        let now_ms = self.now_ms();
        let now = now_ms / 1_000;
        let key = self.ticket_key()?;
        let issuer = self.ticket_issuer();
        let claims = match verify_ticket(
            &ticket,
            key.as_bytes(),
            &issuer,
            TicketExpectation {
                permission: RelayPermission::Register,
                role: RelayRole::Daemon,
                slot: &slot,
                circuit: None,
                lane: None,
                generation: None,
                now,
            },
        ) {
            Ok(claims) => claims,
            Err(_) => {
                Self::fail(
                    socket,
                    "unauthorized",
                    "registration ticket was rejected",
                    CLOSE_POLICY,
                );
                return Ok(());
            }
        };

        for existing in self.state.get_websockets_with_tag(CONTROL_TAG) {
            if existing != *socket
                && Self::attachment(&existing).is_ok_and(|current| {
                    current.phase == SlotPhase::Registered && current.relay.slot == slot
                })
            {
                Self::fail(&existing, "replaced", "daemon control connection was replaced", 4001);
            }
        }

        attachment.phase = SlotPhase::Registered;
        attachment.generation = 0;
        attachment.expires_at = claims.expires_at_unix;
        attachment.idle_deadline_ms = now_ms
            .saturating_add(DAEMON_CONTROL_IDLE_TIMEOUT_MS)
            .min(claims.expires_at_unix.saturating_mul(1_000));
        socket.serialize_attachment(&attachment)?;
        self.ensure_cleanup_alarm(attachment.idle_deadline_ms).await?;

        let lease_seconds = claims
            .expires_at_unix
            .saturating_sub(now)
            .min(REGISTRATION_HEARTBEAT_SECONDS)
            .min(u32::MAX.into()) as u32;
        send_control(socket, &RelayControl::Registered { lease_seconds })
    }

    async fn handle_connect(
        &self,
        socket: &WebSocket,
        mut attachment: SlotAttachment,
        request: ConnectRequest,
    ) -> Result<()> {
        if request.protocol != REMOTE_PROTOCOL_VERSION
            || attachment.relay.role != RelayRole::Client
            || attachment.relay.slot != request.slot
            || !valid_opaque_identifier(&request.lane.0, MAX_LANE_TOKEN_BYTES)
        {
            Self::fail(socket, "invalid-connect", "connection request is invalid", CLOSE_POLICY);
            return Ok(());
        }

        let now_ms = self.now_ms();
        let now = now_ms / 1_000;
        let key = self.ticket_key()?;
        let issuer = self.ticket_issuer();
        let claims = match verify_ticket(
            &request.ticket,
            key.as_bytes(),
            &issuer,
            TicketExpectation {
                permission: RelayPermission::Connect,
                role: RelayRole::Client,
                slot: &request.slot,
                circuit: None,
                lane: Some(&request.lane),
                generation: Some(request.generation),
                now,
            },
        ) {
            Ok(claims) => claims,
            Err(_) => {
                Self::fail(socket, "unauthorized", "connection ticket was rejected", CLOSE_POLICY);
                return Ok(());
            }
        };

        attachment.phase = SlotPhase::ClientControl;
        attachment.generation = request.generation;
        attachment.expires_at = claims.expires_at_unix;
        attachment.idle_deadline_ms = now_ms
            .saturating_add(CLIENT_CONTROL_IDLE_TIMEOUT_MS)
            .min(claims.expires_at_unix.saturating_mul(1_000));
        socket.serialize_attachment(&attachment)?;
        self.ensure_cleanup_alarm(attachment.idle_deadline_ms).await?;

        let Some((daemon, daemon_attachment)) = self.registered_daemon(&request.slot, now, now_ms)
        else {
            Self::capacity(socket, "daemon-offline", "daemon is not connected");
            return Ok(());
        };

        let namespace = self.env.durable_object("RELAY_CIRCUITS")?;
        let circuit = CircuitId(namespace.unique_id()?.to_string());
        let join_expires_at = now
            .saturating_add(JOIN_TICKET_TTL_SECONDS)
            .min(claims.expires_at_unix)
            .min(daemon_attachment.expires_at);
        let join_claims = |role| RelayTicketClaims {
            version: RelayTicketClaims::VERSION,
            issuer: issuer.clone(),
            permission: RelayPermission::Join,
            role,
            slot: request.slot.clone(),
            circuit: Some(circuit.clone()),
            lane: Some(request.lane.clone()),
            generation: Some(request.generation),
            expires_at_unix: join_expires_at,
        };
        let client_join_ticket =
            issue_ticket(&join_claims(RelayRole::Client), key.as_bytes(), &issuer).map_err(
                |error| {
                    worker::Error::RustError(format!("failed to mint client join ticket: {error}"))
                },
            )?;
        let daemon_join_ticket =
            issue_ticket(&join_claims(RelayRole::Daemon), key.as_bytes(), &issuer).map_err(
                |error| {
                    worker::Error::RustError(format!("failed to mint daemon join ticket: {error}"))
                },
            )?;
        let join_deadline_ms = join_expires_at.saturating_mul(1_000);
        if !self.reserve_pending_circuit(&circuit, join_deadline_ms, now_ms).await? {
            Self::capacity(
                socket,
                "slot-circuit-capacity",
                "slot circuit quota or allocation rate limit was reached",
            );
            return Ok(());
        }

        let incoming = RelayControl::Incoming {
            circuit: circuit.clone(),
            lane: request.lane.clone(),
            generation: request.generation,
            join_ticket: daemon_join_ticket,
        };
        let allocated = RelayControl::Allocated {
            circuit: circuit.clone(),
            lane: request.lane,
            generation: request.generation,
            join_ticket: client_join_ticket,
        };
        if send_control(socket, &allocated).is_err() {
            self.release_circuit(&circuit.0).await?;
            close(socket, 1011, "circuit allocation failed");
            return Ok(());
        }
        if send_control(&daemon, &incoming).is_err() {
            self.release_circuit(&circuit.0).await?;
            close(&daemon, 1011, "circuit allocation failed");
            close(socket, 1011, "circuit allocation failed");
        }
        Ok(())
    }

    async fn handle_message(
        &self,
        socket: &WebSocket,
        message: WebSocketIncomingMessage,
    ) -> Result<()> {
        let mut attachment = Self::attachment(socket)?;
        let control = match decode_control(message) {
            Ok(control) => control,
            Err(message) => {
                Self::fail(socket, "invalid-control", message, CLOSE_UNSUPPORTED);
                return Ok(());
            }
        };

        match control {
            RelayControl::Register { protocol, slot, ticket } => {
                self.handle_register(socket, attachment, protocol, slot, ticket).await
            }
            RelayControl::Connect { protocol, slot, ticket, lane, generation }
                if matches!(attachment.phase, SlotPhase::Pending | SlotPhase::ClientControl) =>
            {
                self.handle_connect(
                    socket,
                    attachment,
                    ConnectRequest { protocol, slot, ticket, lane, generation },
                )
                .await
            }
            RelayControl::Ping { nonce }
                if attachment.phase == SlotPhase::Registered
                    && attachment.expires_at > self.now() =>
            {
                attachment.idle_deadline_ms = self
                    .now_ms()
                    .saturating_add(DAEMON_CONTROL_IDLE_TIMEOUT_MS)
                    .min(attachment.expires_at.saturating_mul(1_000));
                socket.serialize_attachment(&attachment)?;
                self.ensure_cleanup_alarm(attachment.idle_deadline_ms).await?;
                send_control(socket, &RelayControl::Pong { nonce })
            }
            RelayControl::Ping { .. } if attachment.phase == SlotPhase::Registered => {
                Self::fail(
                    socket,
                    "registration-expired",
                    "daemon registration ticket has expired",
                    CLOSE_POLICY,
                );
                Ok(())
            }
            _ => {
                Self::fail(
                    socket,
                    "unexpected-control",
                    "control message is not valid in this state",
                    CLOSE_POLICY,
                );
                Ok(())
            }
        }
    }

    async fn handle_internal_circuit(&self, request: &Request) -> Result<Option<Response>> {
        if request.method() != Method::Post {
            return Ok(None);
        }
        let path = request.path();
        let segments: Vec<_> = path.split('/').filter(|part| !part.is_empty()).collect();
        let ["internal", "v1", "circuits", circuit, event @ ("active" | "renew" | "release")] =
            segments.as_slice()
        else {
            return Ok(None);
        };
        if !valid_circuit_id(circuit) {
            return Response::error("Invalid circuit", 400).map(Some);
        }
        match *event {
            "active" => {
                if !self.activate_circuit(circuit, self.now_ms()).await? {
                    return Response::error("Circuit allocation is missing or expired", 409)
                        .map(Some);
                }
            }
            "renew" => {
                if !self.renew_circuit(circuit, self.now_ms()).await? {
                    return Response::error("Circuit lease is missing or expired", 409).map(Some);
                }
            }
            "release" => self.release_circuit(circuit).await?,
            _ => unreachable!(),
        }
        Response::ok("ok").map(Some)
    }
}

impl DurableObject for RelaySlot {
    fn new(state: State, env: Env) -> Self {
        Self { state, env }
    }

    async fn fetch(&self, request: Request) -> Result<Response> {
        if let Some(response) = self.handle_internal_circuit(&request).await? {
            return Ok(response);
        }
        if !websocket_upgrade(&request)? {
            return upgrade_required();
        }

        let path = request.path();
        let segments: Vec<_> = path.split('/').filter(|part| !part.is_empty()).collect();
        let ["v1", "slots", slot, endpoint] = segments.as_slice() else {
            return Response::error("Not found", 404);
        };
        if !valid_opaque_identifier(slot, MAX_SLOT_ID_BYTES) {
            return Response::error("Invalid slot", 400);
        }

        let (role, tag, admission_endpoint) = match *endpoint {
            "control" => (RelayRole::Daemon, CONTROL_TAG, SlotEndpoint::Daemon),
            "connect" => (RelayRole::Client, CONNECT_TAG, SlotEndpoint::Client),
            _ => return Response::error("Not found", 404),
        };
        if self.state.get_websockets().len() >= MAX_SLOT_SOCKETS
            || !admit_slot_socket(self.socket_counts(self.now_ms()), admission_endpoint)
        {
            return Response::error("Slot connection limit reached", 429);
        }

        let pair = WebSocketPair::new()?;
        let relay = if role == RelayRole::Daemon {
            RelaySocketAttachment::control((*slot).into())
        } else {
            RelaySocketAttachment { role, slot: (*slot).into(), circuit: None, lane: None }
        };
        let idle_deadline_ms = self.now_ms().saturating_add(SLOT_HANDSHAKE_TIMEOUT_MS);
        pair.server.serialize_attachment(SlotAttachment {
            relay,
            phase: SlotPhase::Pending,
            generation: 0,
            expires_at: 0,
            idle_deadline_ms,
        })?;
        self.state.accept_websocket_with_tags(&pair.server, &[tag]);
        if let Err(error) = self.ensure_cleanup_alarm(idle_deadline_ms).await {
            close(&pair.server, 1011, "cleanup scheduling failed");
            return Err(error);
        }
        Response::from_websocket(pair.client)
    }

    async fn alarm(&self) -> Result<Response> {
        let now_ms = self.now_ms();
        for socket in self.state.get_websockets() {
            if Self::attachment(&socket)
                .is_ok_and(|attachment| attachment.idle_deadline_ms <= now_ms)
            {
                close(&socket, CLOSE_POLICY, "relay socket expired");
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
            worker::console_error!("RelaySlot message error: {error}");
        }
        Ok(())
    }

    async fn websocket_close(
        &self,
        _socket: WebSocket,
        _code: usize,
        _reason: String,
        _was_clean: bool,
    ) -> Result<()> {
        Ok(())
    }

    async fn websocket_error(&self, _socket: WebSocket, error: worker::Error) -> Result<()> {
        worker::console_error!("RelaySlot WebSocket error: {error}");
        Ok(())
    }
}
